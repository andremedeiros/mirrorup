import CoreMedia
import CoreMediaIO
import Foundation
import MirrorupDiagnostics
import os

/// Feeds the Camera Extension's sink stream through the CoreMediaIO C API.
///
/// The control path (device discovery, starting/stopping the sink stream) runs on a private serial
/// queue because those calls are IPC round-trips to the extension. The frame path (`enqueue`) never
/// waits on it: it reads the current connection under a lock and does a lock-free
/// `CMSimpleQueueEnqueue`, dropping the frame when the queue is full.
final class VirtualCameraSink: @unchecked Sendable {
    enum State: Sendable, Equatable {
        /// Not started yet.
        case inactive
        /// The Mirrorup Camera device is not present (extension not installed, not approved, or restarting).
        case deviceNotFound
        case connected
        case failed(message: String, detail: String)
    }

    struct Counters: Sendable, Equatable {
        var enqueued = 0
        var droppedQueueFull = 0
        var enqueueFailures = 0
        var connects = 0
    }

    private struct Connection {
        let device: CMIODeviceID
        let stream: CMIOStreamID
        let queue: CMSimpleQueue
    }

    private let log = Diagnostics.virtualCamera
    private let deviceUID = VirtualCameraConfig.deviceID.uuidString
    private let stateContinuation: AsyncStream<State>.Continuation
    /// Connection state changes. Buffers only the newest state, so a slow reader skips intermediate ones.
    let states: AsyncStream<State>
    private let connection = OSAllocatedUnfairLock<Connection?>(uncheckedState: nil)
    private let counters = OSAllocatedUnfairLock(initialState: Counters())

    // Confined to `control`.
    private let control = DispatchQueue(label: "cool.andre.Mirrorup.sink.control", qos: .userInitiated)
    private var active = false
    private var devicesListener: CMIOObjectPropertyListenerBlock?
    /// A rename attempt is scheduled (another app was using the camera).
    private var renameScheduled = false
    /// The device being renamed away from, and until when to wait for its replacement before
    /// reconnecting to it (the extension ignores a rename when a client started streaming meanwhile).
    private var renaming: (from: CMIODeviceID, deadline: DispatchTime)?
    private var state: State = .inactive
    private var retryScheduled = false
    /// Name the device should carry; sent on every connect and whenever it changes.
    private var deviceName: String?

    init() {
        (states, stateContinuation) = AsyncStream.makeStream(of: State.self, bufferingPolicy: .bufferingNewest(1))
        stateContinuation.yield(.inactive)
    }

    var counterSnapshot: Counters { counters.withLock { $0 } }

    /// Starts looking for the Mirrorup Camera and keeps the sink stream connected while it exists,
    /// reconnecting whenever the extension (re)appears.
    func activate() {
        control.async { [self] in
            guard !active else { return }
            active = true
            installDevicesListener()
            refresh()
        }
    }

    /// Stops the sink stream and device monitoring. Synchronous so it completes before app exit.
    func deactivate() {
        control.sync { [self] in
            guard active else { return }
            active = false
            removeDevicesListener()
            disconnect()
            publish(.inactive)
        }
    }

    /// Names the Mirrorup device after the selected camera (see `renameIfNeeded`).
    func setDeviceName(_ name: String) {
        control.async { [self] in
            guard name != deviceName else { return }
            deviceName = name
            renameIfNeeded()
        }
    }

    /// Hands one sample buffer to the extension. Returns `false` (frame dropped) when no sink is
    /// connected or its queue is full. Never blocks. Must be called from one task at a time:
    /// CMSimpleQueue is a single-producer queue.
    func enqueue(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let queue = connection.withLockUnchecked({ $0?.queue }) else { return false }
        if CMSimpleQueueGetCount(queue) >= CMSimpleQueueGetCapacity(queue) {
            counters.withLock { $0.droppedQueueFull += 1 }
            return false
        }
        // The queue holds raw pointers; the retain is balanced by the extension side consuming it.
        let element = Unmanaged.passRetained(sampleBuffer)
        let status = CMSimpleQueueEnqueue(queue, element: element.toOpaque())
        guard status == noErr else {
            element.release()
            counters.withLock { $0.enqueueFailures += 1 }
            return false
        }
        counters.withLock { $0.enqueued += 1 }
        return true
    }

    // MARK: Control path (on `control`)

    private func publish(_ newState: State) {
        guard newState != state else { return }
        state = newState
        stateContinuation.yield(newState)
    }

    private func refresh() {
        guard active else { return }
        let device = findDevice()
        if let renaming {
            // Don't reconnect to the device being replaced; give up waiting after the deadline.
            if device == renaming.from, DispatchTime.now() < renaming.deadline {
                scheduleRetry()
                return
            }
            self.renaming = nil
        }
        if let current = connection.withLockUnchecked({ $0 }) {
            if current.device == device { return }
            log.info("Mirrorup Camera device changed or disappeared; disconnecting sink")
            disconnect()
        }
        guard let device else {
            publish(.deviceNotFound)
            // The device-list listener reports devices of the extension process already running,
            // but not the first device of a newly launched one (after an extension upgrade), so
            // keep looking while the device is missing.
            scheduleRetry()
            return
        }
        do {
            try connect(device: device)
            publish(.connected)
            renameIfNeeded()
        } catch {
            log.error("Sink connect failed: \(error.detail, privacy: .public)")
            publish(.failed(message: error.message, detail: error.detail))
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        control.asyncAfter(deadline: .now() + .seconds(2)) { [self] in
            retryScheduled = false
            refresh()
        }
    }

    /// Renames the device when it doesn't carry `deviceName`. The extension renames by replacing the
    /// device, and a client streaming into a device never sees its replacement (it keeps feeding the
    /// removed one), so the sink stops first. While another app streams from the camera the rename
    /// waits (checked before stopping, so the camera never freezes for it) and is retried every 5 s.
    private func renameIfNeeded() {
        guard active, !renameScheduled, let name = deviceName, let current = connection.withLockUnchecked({ $0 }),
              CMIO.string(current.device, kCMIOObjectPropertyName) != name else { return }
        let device = current.device
        if CMIO.string(device, Int(VirtualCameraConfig.sourceActiveSelector)) == "1" {
            log.info("Renaming the Mirrorup camera to \(name, privacy: .public) waits until no app uses it")
            scheduleRename()
            return
        }
        disconnect()
        var address = CMIO.address(Int(VirtualCameraConfig.deviceNameSelector))
        var value = name as CFString
        let status = withUnsafeMutablePointer(to: &value) {
            CMIOObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<CFString>.size), $0)
        }
        if status != noErr {
            log.error("Setting the device name failed: \(CMIO.describe(status), privacy: .public)")
        }
        // The device-list listener reconnects to the renamed device; the retry covers a missed
        // change or an ignored rename.
        renaming = (device, .now() + .seconds(2))
        publish(.deviceNotFound)
        scheduleRetry()
    }

    private func scheduleRename() {
        guard !renameScheduled else { return }
        renameScheduled = true
        control.asyncAfter(deadline: .now() + .seconds(5)) { [self] in
            renameScheduled = false
            renameIfNeeded()
        }
    }

    private struct ConnectError: Error {
        let message: String
        let detail: String
    }

    private func connect(device: CMIODeviceID) throws(ConnectError) {
        guard let sinkStream = sinkStream(of: device) else {
            throw ConnectError(
                message: "The Mirrorup Camera extension is out of date. Reinstall it from Mirrorup Settings.",
                detail: "No output-direction stream on device \(device) (streams: \(CMIO.objectIDs(device, kCMIODevicePropertyStreams)))"
            )
        }

        var queueRef: Unmanaged<CMSimpleQueue>?
        let copyStatus = CMIOStreamCopyBufferQueue(sinkStream, { _, _, _ in }, nil, &queueRef)
        guard copyStatus == noErr, let queue = queueRef?.takeRetainedValue() else {
            throw ConnectError(
                message: "Mirrorup couldn't connect to the Mirrorup Camera.",
                detail: "CMIOStreamCopyBufferQueue(\(sinkStream)) failed: \(CMIO.describe(copyStatus))"
            )
        }
        let startStatus = CMIODeviceStartStream(device, sinkStream)
        guard startStatus == noErr else {
            throw ConnectError(
                message: "Mirrorup couldn't start the Mirrorup Camera. Check that Mirrorup is allowed to use the camera in System Settings › Privacy & Security › Camera.",
                detail: "CMIODeviceStartStream(\(device), \(sinkStream)) failed: \(CMIO.describe(startStatus))"
            )
        }
        connection.withLockUnchecked { $0 = Connection(device: device, stream: sinkStream, queue: queue) }
        counters.withLock { $0.connects += 1 }
        log.info("Sink connected: device=\(device) stream=\(sinkStream) capacity=\(CMSimpleQueueGetCapacity(queue))")
    }

    private func disconnect() {
        guard let current = connection.withLockUnchecked({ value -> Connection? in
            defer { value = nil }
            return value
        }) else { return }
        let status = CMIODeviceStopStream(current.device, current.stream)
        // The device may already be gone (extension replaced); that is not an error worth surfacing.
        if status != noErr { log.debug("CMIODeviceStopStream: \(CMIO.describe(status), privacy: .public)") }
        var unused: Unmanaged<CMSimpleQueue>?
        _ = CMIOStreamCopyBufferQueue(current.stream, nil, nil, &unused)
        unused?.release()
        log.info("Sink disconnected")
    }

    private func findDevice() -> CMIODeviceID? {
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        return CMIO.objectIDs(system, kCMIOHardwarePropertyDevices).first { device in
            CMIO.string(device, kCMIODevicePropertyDeviceUID)?.caseInsensitiveCompare(deviceUID) == .orderedSame
        }
    }

    /// kCMIOStreamPropertyDirection 0 = output stream: data flows from the client into the device,
    /// i.e. the CMIOExtension sink.
    private func sinkStream(of device: CMIODeviceID) -> CMIOStreamID? {
        CMIO.objectIDs(device, kCMIODevicePropertyStreams).first { CMIO.uint32($0, kCMIOStreamPropertyDirection) == 0 }
    }

    private func installDevicesListener() {
        guard devicesListener == nil else { return }
        let listener: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            // Runs on `control`.
            self?.refresh()
        }
        var address = CMIO.address(kCMIOHardwarePropertyDevices)
        let status = CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &address, control, listener)
        if status == noErr {
            devicesListener = listener
        } else {
            log.error("Device list listener failed: \(CMIO.describe(status), privacy: .public); polling instead")
            pollDevices()
        }
    }

    /// Fallback when the property listener cannot be installed: re-check the device list every 2 s.
    private func pollDevices() {
        control.asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
            guard let self, active, devicesListener == nil else { return }
            refresh()
            pollDevices()
        }
    }

    private func removeDevicesListener() {
        guard let listener = devicesListener else { return }
        var address = CMIO.address(kCMIOHardwarePropertyDevices)
        _ = CMIOObjectRemovePropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &address, control, listener)
        devicesListener = nil
    }
}

/// Minimal typed accessors for the CoreMediaIO property API.
private enum CMIO {
    static func address(_ selector: Int, scope: Int = kCMIOObjectPropertyScopeGlobal) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(scope),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }

    static func objectIDs(_ object: CMIOObjectID, _ selector: Int, scope: Int = kCMIOObjectPropertyScopeGlobal) -> [CMIOObjectID] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    static func uint32(_ object: CMIOObjectID, _ selector: Int) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &value) == noErr else { return nil }
        return value
    }

    static func string(_ object: CMIOObjectID, _ selector: Int) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, $0)
        }
        guard status == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static func describe(_ status: OSStatus) -> String {
        let bytes = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian) { Array($0) }
        if bytes.allSatisfy({ (0x20...0x7e).contains($0) }) {
            return "\(status) '\(String(decoding: bytes, as: UTF8.self))'"
        }
        return "\(status)"
    }
}
