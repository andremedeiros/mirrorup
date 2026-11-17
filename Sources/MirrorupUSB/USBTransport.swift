public import Foundation
import IOKit
import IOUSBHost
public import MirrorupPTP
import MirrorupDiagnostics
import Synchronization

/// Direct PTP-over-USB access through IOUSBHost.
///
/// On macOS 26+ this only works while no other process owns the Still Image interface. In a normal
/// login session `/usr/libexec/ptpcamerad` claims it as soon as a camera is attached, and IOUSBHost
/// then refuses to create the interface client (it reports kIOReturnInternalError). Mirrorup never
/// terminates system daemons; this path exists for systems or moments where the interface is free,
/// and to validate the PTP stack independently of ImageCaptureCore. See docs/usb-feasibility.md.
public enum USBPTPConnection {
    /// Opens the Still Image interface of `device` and returns a PTP transport over its bulk pipes.
    public static func open(_ device: USBDeviceSnapshot) throws(USBError) -> PTPUSBTransport<IOUSBHostBulkPipe> {
        guard let registryInterface = device.stillImageRegistryInterface else {
            throw USBError("find Still Image interface", code: kIOReturnNoDevice)
        }
        guard let service = USBDiscovery.service(registryID: registryInterface.registryID) else {
            throw USBError("look up interface service", code: kIOReturnNoDevice)
        }
        let pipe = try IOUSBHostBulkPipe(interfaceService: service, ownerHint: registryInterface.exclusiveOwner)
        return PTPUSBTransport(pipe: pipe, readChunkSize: 1 << 20)
    }
}

/// Bulk IN/OUT pipe pair of one claimed interface.
///
/// IOUSBHost objects are documented as callable from any thread with completions delivered on the
/// object's serial queue; the PTP transport additionally guarantees one request at a time, so the
/// class is safe to mark Sendable. Mutable state (read buffer use, termination) is behind a Mutex.
public final class IOUSBHostBulkPipe: PTPBulkPipe, @unchecked Sendable {
    public let maxPacketSize: Int

    private let interface: IOUSBHostInterface
    private let inPipe: IOUSBHostPipe
    private let outPipe: IOUSBHostPipe
    private let readBuffer: NSMutableData
    private let terminated: TerminationFlag

    init(interfaceService service: io_service_t, ownerHint: String?) throws(USBError) {
        let terminated = TerminationFlag()
        let interface: IOUSBHostInterface
        do {
            // The IOUSBHostObject keeps (and later releases) the service reference we pass in.
            interface = try IOUSBHostInterface(__ioService: service, options: [], queue: nil) { _, messageType, _ in
                if messageType == 0xE000_0010 /* kIOMessageServiceIsTerminated */ {
                    terminated.set()
                    Diagnostics.usb.notice("USB interface terminated (device removed)")
                }
            }
        } catch {
            // Re-read the owner now; the snapshot may be stale.
            let owner = USBDiscovery.stringProperty(service, "UsbExclusiveOwner") ?? ownerHint
            throw USBError("open IOUSBHostInterface", code: USBDiscovery.ioReturn(from: error), owner: owner)
        }

        let config = interface.configurationDescriptor
        let configBytes = [UInt8](UnsafeRawBufferPointer(start: UnsafeRawPointer(config), count: Int(config.pointee.wTotalLength)))
        let number = interface.interfaceDescriptor.pointee.bInterfaceNumber
        let alt = interface.interfaceDescriptor.pointee.bAlternateSetting
        guard let parsed = try? USBDescriptorParser.parseConfiguration(configBytes),
              let info = parsed.interfaces.first(where: { $0.number == number && $0.alternateSetting == alt }),
              let bulkIn = info.bulkIn, let bulkOut = info.bulkOut
        else {
            interface.destroy()
            throw USBError("locate bulk endpoints", code: kIOReturnUnsupported)
        }
        do {
            inPipe = try interface.copyPipe(withAddress: Int(bulkIn.address))
            outPipe = try interface.copyPipe(withAddress: Int(bulkOut.address))
            readBuffer = try interface.ioData(withCapacity: 1 << 20)
        } catch {
            interface.destroy()
            throw USBError("open bulk pipes", code: USBDiscovery.ioReturn(from: error))
        }
        self.interface = interface
        self.terminated = terminated
        maxPacketSize = bulkIn.maxPacketSize
        Diagnostics.usb.info("claimed PTP interface \(number): \(bulkIn.description, privacy: .public), \(bulkOut.description, privacy: .public)")
    }

    deinit {
        interface.destroy()
    }

    public func write(_ data: Data, timeout: Duration) async throws(PTPTransportError) {
        try checkAlive()
        let payload: NSMutableData? = data.isEmpty ? nil : NSMutableData(data: data)
        let (status, transferred) = try await transfer(on: outPipe, data: payload, timeout: timeout, what: "bulk OUT")
        guard status == kIOReturnSuccess else { throw mapped(status, "bulk OUT") }
        guard transferred == data.count else {
            throw .io("short bulk OUT write: \(transferred) of \(data.count) bytes", code: Int(kIOReturnUnderrun))
        }
    }

    public func read(maxLength: Int, timeout: Duration) async throws(PTPTransportError) -> Data {
        try checkAlive()
        precondition(maxLength <= readBuffer.length, "read larger than the preallocated buffer")
        let (status, transferred) = try await transfer(on: inPipe, data: readBuffer, timeout: timeout, what: "bulk IN")
        guard status == kIOReturnSuccess else { throw mapped(status, "bulk IN") }
        return Data(bytes: readBuffer.bytes, count: transferred)
    }

    private func checkAlive() throws(PTPTransportError) {
        if terminated.isSet { throw .disconnected("USB interface terminated") }
    }

    private func mapped(_ status: IOReturn, _ what: String) -> PTPTransportError {
        if terminated.isSet { return .disconnected("USB interface terminated during \(what)") }
        return USBError(what, code: status).transportError
    }

    /// Enqueues one asynchronous request. The IOUSBHost completion timeout bounds the wait; task
    /// cancellation aborts the pipe so the completion fires promptly with kIOReturnAborted.
    private func transfer(on pipe: IOUSBHostPipe, data: NSMutableData?, timeout: Duration, what: String) async throws(PTPTransportError) -> (IOReturn, Int) {
        let seconds = max(timeout.milliseconds / 1000, 0.001)
        // IOUSBHost objects are not annotated Sendable; one request is in flight at a time and the
        // framework is thread-safe for enqueue/abort, so handing them to the closures is sound.
        let io = UncheckedSendable((pipe, data))
        let result: Result<(IOReturn, Int), PTPTransportError> = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Result<(IOReturn, Int), PTPTransportError>, Never>) in
                do {
                    try io.value.0.enqueueIORequest(with: io.value.1, completionTimeout: seconds) { status, transferred in
                        cont.resume(returning: .success((status, transferred)))
                    }
                } catch {
                    cont.resume(returning: .failure(USBError("enqueue \(what)", code: USBDiscovery.ioReturn(from: error)).transportError))
                }
            }
        } onCancel: {
            try? io.value.0.__abort(with: .asynchronous)
        }
        if case .success((let status, _)) = result, status == kIOReturnTimeout {
            throw .timedOut(operation: what, after: timeout)
        }
        if case .success((let status, _)) = result, status == kIOReturnAborted, Task.isCancelled {
            throw .cancelled
        }
        return try result.get()
    }
}

/// Set once by the IOKit interest handler when the interface is terminated.
final class TerminationFlag: Sendable {
    private let state = Mutex(false)
    func set() { state.withLock { $0 = true } }
    var isSet: Bool { state.withLock { $0 } }
}

struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
