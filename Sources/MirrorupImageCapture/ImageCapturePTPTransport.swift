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
    private let readyTimeout: Duration
    /// How long a catalog wait must last before it is reported (`PTPPreparationReporter`).
    private let preparationGrace: Duration

    private struct State {
        var phase: Phase = .closed
        var removalToken: UInt64?
        /// The in-flight request, so removal can fail it immediately instead of waiting for timeout.
        var pending: Pending?
    }

    private enum Phase { case closed, open, failed(PTPTransportError) }

    /// One in-flight request. The first outcome wins (camera reply, timeout, cancellation, removal);
    /// an outcome that arrives before the continuation is installed is kept, not lost.
    private final class Pending: Sendable {
        typealias Outcome = Result<PTPTransactionResult, PTPError>
        private enum Slot {
            case empty
            case waiting(CheckedContinuation<Outcome, Never>)
            case early(Outcome)
            case done
        }
        private let slot = Mutex(Slot.empty)

        func install(_ continuation: CheckedContinuation<Outcome, Never>) {
            let early: Outcome? = slot.withLock { slot in
                if case .early(let outcome) = slot {
                    slot = .done
                    return outcome
                }
                slot = .waiting(continuation)
                return nil
            }
            if let early { continuation.resume(returning: early) }
        }

        func finish(_ outcome: Outcome) {
            let waiter: CheckedContinuation<Outcome, Never>? = slot.withLock { slot in
                switch slot {
                case .empty:
                    slot = .early(outcome)
                    return nil
                case .waiting(let continuation):
                    slot = .done
                    return continuation
                case .early, .done:
                    return nil
                }
            }
            waiter?.resume(returning: outcome)
        }
    }

    @MainActor
    public init(camera: ICCameraDevice, openTimeout: Duration = .seconds(10), readyTimeout: Duration = .seconds(60),
                preparationGrace: Duration = .seconds(1)) {
        self.camera = camera
        self.openTimeout = openTimeout
        self.readyTimeout = readyTimeout
        self.preparationGrace = preparationGrace
        delegate = CameraDelegate()
        camera.delegate = delegate
    }

    /// ptpcamerad answers PTP pass-through only after it has catalogued the card: with 479 files a
    /// 7D took 10–24 s after the session opened, and GetDeviceInfo sent before that timed out (5 s).
    /// Waits for the complete catalog, bounded by `readyTimeout` and by cancellation (the capture
    /// engine's connect deadline stays in charge); either way it carries on and lets the command
    /// deadlines decide. Returns how long it waited and whether the catalog completed.
    ///
    /// While it waits it reports `.indexingStorage` through `preparation` (with
    /// `contentCatalogPercentCompleted`, observed), then `nil` when the wait ends however it ends.
    /// A wait that ends within `preparationGrace` reports nothing: right after `requestOpenSession`
    /// the catalog can look incomplete for a few milliseconds even on a warm start.
    private func waitForContentCatalog(
        preparation: @escaping PTPPreparationHandler
    ) async -> (waited: Duration, complete: Bool) {
        let start = ContinuousClock.now
        let timeout = readyTimeout
        let camera = UncheckedBox(camera)
        let wait = CatalogWait()
        let reporter = PTPPreparationReporter(grace: preparationGrace, handler: preparation)
        let timer = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            wait.finish(false)
        }
        defer { timer.cancel() }
        Task { @MainActor in
            if delegate.isReady || camera.value.contentCatalogPercentCompleted >= 100 {
                wait.finish(true)
            } else if !reporter.isFinished {
                // `isFinished`: the wait may already be over (cancelled) by the time this runs.
                reporter.report(.indexingStorage(percentComplete: Self.clampedPercent(camera.value.contentCatalogPercentCompleted)))
                delegate.onReady = { wait.finish(true) }
                delegate.catalogObservation = camera.value.observe(\.contentCatalogPercentCompleted) { device, _ in
                    reporter.report(.indexingStorage(percentComplete: Self.clampedPercent(device.contentCatalogPercentCompleted)))
                }
            }
        }
        let complete = await withTaskCancellationHandler {
            await withCheckedContinuation { wait.install($0) }
        } onCancel: {
            wait.finish(false)
        }
        reporter.finish()
        await MainActor.run {
            delegate.onReady = nil
            delegate.catalogObservation = nil
        }
        return (ContinuousClock.now - start, complete)
    }

    private static func clampedPercent(_ percent: Int) -> Int { min(max(percent, 0), 100) }

    /// One-shot result for `waitForContentCatalog`; the first `finish` wins, before or after `install`.
    private final class CatalogWait: Sendable {
        private enum Slot { case empty, early(Bool), waiting(CheckedContinuation<Bool, Never>), done }
        private let slot = Mutex(Slot.empty)

        func install(_ continuation: CheckedContinuation<Bool, Never>) {
            let early: Bool? = slot.withLock { slot in
                if case .early(let value) = slot {
                    slot = .done
                    return value
                }
                slot = .waiting(continuation)
                return nil
            }
            if let early { continuation.resume(returning: early) }
        }

        func finish(_ value: Bool) {
            let waiter: CheckedContinuation<Bool, Never>? = slot.withLock { slot in
                switch slot {
                case .empty:
                    slot = .early(value)
                    return nil
                case .waiting(let continuation):
                    slot = .done
                    return continuation
                case .early, .done:
                    return nil
                }
            }
            waiter?.resume(returning: value)
        }
    }

    public func open() async throws(PTPTransportError) {
        try await open(preparation: { _ in })
    }

    public func open(preparation: @escaping PTPPreparationHandler) async throws(PTPTransportError) {
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
        // Both handlers also end a pending content-catalog wait (`onReady`), which then sees the failure.
        let token = await MainActor.run { () -> UInt64 in
            delegate.onSessionClosed = { [weak self] in
                self?.fail(.disconnected("ImageCaptureCore closed the session"))
                self?.delegate.onReady?()
            }
            return ImageCaptureBrowser.shared.onRemoval(of: camera) { [weak self] in
                self?.fail(.disconnected("camera removed"))
                self?.delegate.onReady?()
            }
        }
        state.withLock {
            $0.phase = .open
            $0.removalToken = token
        }
        let (waited, complete) = await waitForContentCatalog(preparation: preparation)
        if case .failed(let error) = state.withLock({ $0.phase }) { throw error }
        if Task.isCancelled {
            // Stopped while waiting (e.g. the app quit during the catalog): not "continuing". Close
            // here so a caller that never got an open transport has nothing to clean up.
            Diagnostics.imageCapture.info("ImageCaptureCore content catalog wait cancelled after \(waited, privacy: .public)")
            await close()
            throw .cancelled
        }
        if complete {
            Diagnostics.imageCapture.info("ImageCaptureCore session open on \(self.cameraNameForLogs, privacy: .public) (content catalog ready after \(waited, privacy: .public))")
        } else {
            Diagnostics.imageCapture.notice("ImageCaptureCore session open on \(self.cameraNameForLogs, privacy: .public); content catalog still incomplete after \(waited, privacy: .public), continuing")
        }
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
        // ImageCaptureCore has no request timeout; race our own. Cancelled as soon as the request
        // settles, so at most one timer exists per in-flight request.
        let timer = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            pending.finish(.failure(.transport(.timedOut(operation: command.code.description, after: timeout))))
        }
        defer { timer.cancel() }

        let result: Result<PTPTransactionResult, PTPError> = await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                pending.install(cont)
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
                // Cancellation is not sticky: it means the caller stopped waiting (a capture stop
                // landing during a frame poll), not that the camera failed. Failing the session here
                // made teardown's EVF restore and remote-mode exit fail with "operation cancelled",
                // leaving the camera's screen dark (seen on a 7D, 1 stop in 3).
                switch t {
                case .timedOut, .disconnected, .notOpen:
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
    /// Set once ImageCaptureCore reports the content catalog complete for this session.
    private(set) var isReady = false
    var onReady: (@MainActor () -> Void)?
    /// Observes `contentCatalogPercentCompleted` while a catalog wait is in progress.
    var catalogObservation: NSKeyValueObservation?

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
    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        MainActor.assumeIsolated {
            isReady = true
            onReady?()
        }
    }
    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}

struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
