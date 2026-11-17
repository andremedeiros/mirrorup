public import Foundation
public import ImageCaptureCore
public import MirrorupPTP
import MirrorupDiagnostics
import Synchronization

/// PTP transport over ImageCaptureCore's pass-through (`requestSendPTPCommand`).
///
/// macOS's `ptpcamerad` owns the USB interface and the PTP session; it forwards our command
/// containers verbatim and returns the device's data and response. This is the supported way for an
/// application to talk PTP to a camera on macOS 26+ while the system camera service is running.
/// `ptpcamerad` assigns its own transaction IDs, so this transport cannot (and does not) check them.
public final class ImageCapturePTPTransport: PTPTransport, @unchecked Sendable {
    // @unchecked: `camera` and `delegate` are only touched on the main actor; all other mutable state
    // is inside `state`'s Mutex.
    public let sessionOwnership = PTPSessionOwnership.system

    private let camera: ICCameraDevice
    private let delegate: CameraDelegate
    private let state = Mutex(State())
    private let openTimeout: Duration

    private struct State {
        var phase: Phase = .closed
        var removalToken: UInt64?
        /// The in-flight request, so removal can fail it immediately instead of waiting for timeout.
        var pending: Pending?
    }

    private enum Phase { case closed, open, failed(PTPTransportError) }

    private final class Pending: Sendable {
        let completion = Mutex<CheckedContinuation<Result<PTPTransactionResult, PTPError>, Never>?>(nil)
        func finish(_ result: Result<PTPTransactionResult, PTPError>) {
            completion.withLock { c in
                c?.resume(returning: result)
                c = nil
            }
        }
    }

    @MainActor
    public init(camera: ICCameraDevice, openTimeout: Duration = .seconds(10)) {
        self.camera = camera
        self.openTimeout = openTimeout
        delegate = CameraDelegate()
        camera.delegate = delegate
    }

    public func open() async throws(PTPTransportError) {
        let result: Result<Void, PTPTransportError> = await withCheckedContinuation { cont in
            let once = Mutex<CheckedContinuation<Result<Void, PTPTransportError>, Never>?>(cont)
            let finish: @Sendable (Result<Void, PTPTransportError>) -> Void = { r in
                once.withLock { c in c?.resume(returning: r); c = nil }
            }
            let timeout = openTimeout
            Task { @MainActor in
                camera.requestOpenSession(options: [:]) { error in
                    finish(error.map { .failure(Self.map($0, during: "open session")) } ?? .success(()))
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                finish(.failure(.timedOut(operation: "open ImageCaptureCore session", after: timeout)))
            }
        }
        try result.get()
        let token = await MainActor.run { () -> UInt64 in
            delegate.onSessionClosed = { [weak self] in self?.fail(.disconnected("ImageCaptureCore closed the session")) }
            return ImageCaptureBrowser.shared.onRemoval(of: camera) { [weak self] in
                self?.fail(.disconnected("camera removed"))
            }
        }
        state.withLock {
            $0.phase = .open
            $0.removalToken = token
        }
        Diagnostics.imageCapture.info("ImageCaptureCore session open on \(self.cameraNameForLogs, privacy: .public)")
    }

    public func execute(
        _ command: PTPCommand, transactionID: UInt32, dataOut: Data?, timeout: Duration
    ) async throws(PTPError) -> PTPTransactionResult {
        switch state.withLock({ $0.phase }) {
        case .open: break
        case .closed: throw .transport(.notOpen)
        case .failed(let e): throw .transport(e)
        }
        let container = try command.encodedContainer(transactionID: transactionID)
        let pending = Pending()

        let result: Result<PTPTransactionResult, PTPError> = await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                pending.completion.withLock { $0 = cont }
                state.withLock { $0.pending = pending }
                let camera = UncheckedBox(camera)
                Task { @MainActor in
                    camera.value.requestSendPTPCommand(container, outData: dataOut) { data, response, error in
                        if let error {
                            pending.finish(.failure(.transport(Self.map(error, during: command.code.description))))
                            return
                        }
                        // ptpcamerad completes requests with no response and no error once the
                        // camera has gone away (observed when the SL2 powers off).
                        guard !response.isEmpty else {
                            pending.finish(.failure(.transport(.disconnected("\(command.code) returned no response container"))))
                            return
                        }
                        do {
                            let decoded = try PTPResponse(container: response)
                            pending.finish(.success(PTPTransactionResult(response: decoded, data: data)))
                        } catch let error as PTPError {
                            pending.finish(.failure(error))
                        } catch {
                            pending.finish(.failure(.invalidContainerLength(UInt32(response.count))))
                        }
                    }
                }
                Task {
                    try? await Task.sleep(for: timeout)
                    pending.finish(.failure(.transport(.timedOut(operation: command.code.description, after: timeout))))
                }
            }
        } onCancel: {
            pending.finish(.failure(.transport(.cancelled)))
        }

        state.withLock { if $0.pending === pending { $0.pending = nil } }
        switch result {
        case .success(let r):
            return r
        case .failure(let error):
            if let t = error.transportError {
                // ptpcamerad may still complete the abandoned request later; the late completion is
                // ignored by `Pending`. The session stays usable only for non-sticky errors.
                switch t {
                case .timedOut, .disconnected, .cancelled, .notOpen:
                    state.withLock { $0.phase = .failed(t) }
                default: break
                }
            }
            throw error
        }
    }

    public func close() async {
        let token: UInt64? = state.withLock { s in
            let wasOpen: Bool
            if case .closed = s.phase { wasOpen = false } else { wasOpen = true }
            s.phase = .closed
            defer { s.removalToken = nil }
            return wasOpen ? (s.removalToken ?? 0) : nil
        }
        guard let token else { return }
        let camera = UncheckedBox(camera)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = Mutex<CheckedContinuation<Void, Never>?>(cont)
            let finish: @Sendable () -> Void = { once.withLock { c in c?.resume(); c = nil } }
            Task { @MainActor in
                if token != 0 { ImageCaptureBrowser.shared.removeRemovalHandler(token, for: camera.value) }
                delegate.onSessionClosed = nil
                camera.value.requestCloseSession(options: [:]) { error in
                    if let error { Diagnostics.imageCapture.notice("close session: \(error.localizedDescription, privacy: .public)") }
                    finish()
                }
            }
            Task {
                // Don't let a wedged ptpcamerad block teardown.
                try? await Task.sleep(for: .seconds(3))
                finish()
            }
        }
    }

    private func fail(_ error: PTPTransportError) {
        let pending = state.withLock { s -> Pending? in
            s.phase = .failed(error)
            defer { s.pending = nil }
            return s.pending
        }
        pending?.finish(.failure(.transport(error)))
        Diagnostics.imageCapture.notice("transport failed: \(error.description, privacy: .public)")
    }

    private var cameraNameForLogs: String { UncheckedBox(camera).value.name ?? "camera" }

    static func map(_ error: any Error, during operation: String) -> PTPTransportError {
        let ns = error as NSError
        let text = "\(operation): \(ns.localizedDescription) (\(ns.domain) \(ns.code))"
        // ICReturnCode values from ImageCaptureConstants.h.
        switch ns.code {
        case -21343 /* ConnectionNotAuthorizedToOpenDevice */, -21249 /* PTPNotAuthorizedToSendCommand */:
            return .accessDenied(text)
        case -9923 /* CommunicationTimedOut */:
            return .timedOut(operation: operation, after: .zero)
        case -9958 /* SessionNotOpened */, -21349 /* ConnectionClosedSessionSuddenly */, -21350 /* ConnectionDriverExited */:
            return .disconnected(text)
        default:
            return .io(text, code: ns.code)
        }
    }
}

/// Minimal ICCameraDeviceDelegate: ImageCaptureCore requires a delegate to deliver session events.
@MainActor
final class CameraDelegate: NSObject, ICCameraDeviceDelegate {
    var onSessionClosed: (@MainActor () -> Void)?

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        MainActor.assumeIsolated { onSessionClosed?() }
    }
    nonisolated func didRemove(_ device: ICDevice) {}
    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        Diagnostics.imageCapture.debug("PTP event \(eventData.count) bytes")
    }
    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {}
    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}

struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
