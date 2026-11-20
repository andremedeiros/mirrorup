import MirrorupDiagnostics
import Synchronization

/// Shared, lock-protected engine state: the state machine, status, metrics and status subscribers.
/// The capture loop updates it synchronously (no actor hop per frame); the engine actor reads it.
///
/// Every loop runs under a `generation`. `stop()` bumps the generation before the loop has finished
/// tearing down, so late events from a dying loop are ignored instead of resurrecting its state.
final class CaptureCore: Sendable {
    private struct State {
        var machine = CaptureStateMachine()
        var generation: UInt64 = 0
        var camera: CameraIdentity?
        /// Backend of the session in progress, so metadata can be requested on demand.
        var backend: (any CameraBackend)?
        var lastRecoverableError: CameraError?
        var reconnectCount = 0
        var disconnectCount = 0
        var settingsRevision: UInt64 = 0
        var metrics = FrameMetrics()
        /// Host time of the failure that started the recovery in progress.
        var recoveryStartedAt: UInt64?
        var lastSequence: UInt64 = 0
        var lastBroadcast: UInt64 = 0
        var nextSubscriberID = 0
        var subscribers: [Int: AsyncStream<CaptureStatus>.Continuation] = [:]
    }

    private static let metricsInterval = HostTime.ticks(nanoseconds: 250_000_000)

    private let state = Mutex(State())
    /// Separate from `state` so the per-frame read never contends with status updates. Survives runs.
    private let orientationState = Mutex(FrameOrientation.normal)
    private let enhanceState = Mutex(false)
    private let cameraScreenState = Mutex(false)
    private let frames: LatestFrameBuffer

    init(frames: LatestFrameBuffer) {
        self.frames = frames
    }

    var generation: UInt64 { state.withLock { $0.generation } }

    var isActive: Bool { state.withLock { $0.machine.state.isActive } }

    /// Whether frames decoded after it is set go through the super-resolution scaler.
    var enhance: Bool {
        get { enhanceState.withLock { $0 } }
        set { enhanceState.withLock { $0 = newValue } }
    }

    /// Orientation applied to every frame decoded after it is set.
    var orientation: FrameOrientation {
        get { orientationState.withLock { $0 } }
        set { orientationState.withLock { $0 = newValue } }
    }

    /// Whether the camera keeps live view on its own screen; the capture loop applies it.
    var showsLiveViewOnCamera: Bool {
        get { cameraScreenState.withLock { $0 } }
        set { cameraScreenState.withLock { $0 = newValue } }
    }

    /// Begins a new run (idle/failed -> discovering) and returns its generation.
    func beginRun(maxAttemptsBeforeFailing: Int?) -> UInt64 {
        state.withLock { state in
            state.generation += 1
            state.machine = CaptureStateMachine(maxAttemptsBeforeFailing: maxAttemptsBeforeFailing)
            _ = state.machine.handle(.start)
            state.recoveryStartedAt = nil
            let generation = state.generation
            Diagnostics.capture.info("Capture starting (run \(generation))")
            broadcast(&state)
            return generation
        }
    }

    /// Detaches the current loop: its later events are ignored.
    func invalidateRun() {
        state.withLock { $0.generation += 1 }
    }

    /// Completes `stop()`: whatever the state, the engine is idle.
    func finishStop() {
        state.withLock { state in
            _ = state.machine.handle(.stop)
            state.camera = nil
            state.backend = nil
            state.recoveryStartedAt = nil
            Diagnostics.capture.info("Capture stopped")
            broadcast(&state)
        }
    }

    /// Feeds `event` from the loop of `generation` to the state machine and applies the side effects.
    /// Returns `nil` if the loop is stale or the event is invalid in the current state.
    @discardableResult
    func apply(_ event: CaptureEvent, generation: UInt64) -> CaptureStateMachine.Transition? {
        state.withLock { state -> CaptureStateMachine.Transition? in
            guard state.generation == generation, let transition = state.machine.handle(event) else { return nil }
            let now = HostTime.now()
            if case .failed(let error) = event {
                switch transition.to {
                case .recovering(let attempt, _):
                    state.lastRecoverableError = error
                    if error.kind == .disconnected, transition.from == .streaming { state.disconnectCount += 1 }
                    state.metrics.recordRecoveryAttempt()
                    if state.recoveryStartedAt == nil { state.recoveryStartedAt = now }
                    Diagnostics.capture.error("Capture recovering (attempt \(attempt)): \(error.description, privacy: .public)")
                case .failed:
                    state.recoveryStartedAt = nil
                    Diagnostics.capture.fault("Capture failed: \(error.description, privacy: .public)")
                case .idle:
                    Diagnostics.capture.info("Capture cancelled by the backend: \(error.description, privacy: .public)")
                case .waitingForCamera:
                    // No usable camera attached: not a failure, so no attempt and no recovery timer.
                    Diagnostics.capture.debug("No camera to connect to: \(error.description, privacy: .public)")
                default: // skipped frame; the session continues
                    state.lastRecoverableError = error
                    state.metrics.recordInvalidFrame()
                    Diagnostics.capture.debug("Skipped invalid frame: \(error.description, privacy: .public)")
                }
            }
            if transition.completedRecovery {
                state.reconnectCount += 1
                if let started = state.recoveryStartedAt {
                    let duration = Duration.nanoseconds(Int64(HostTime.nanoseconds(now &- started)))
                    state.metrics.recordRecoveryCompleted(duration: duration)
                    Diagnostics.capture.info("Capture recovered after \(duration.milliseconds, format: .fixed(precision: 0)) ms")
                }
                state.recoveryStartedAt = nil
            }
            if case .preparing = transition.from, case .preparing = transition.to {
                // Progress within one preparation: throttled like metrics; the end is always broadcast.
                Diagnostics.capture.debug("Capture state: \(String(describing: transition.to), privacy: .public)")
                broadcastIfDue(&state, now: now)
            } else if transition.from != transition.to {
                Diagnostics.capture.info("Capture state: \(String(describing: transition.to), privacy: .public)")
                broadcast(&state, now: now)
            } else {
                broadcastIfDue(&state, now: now)
            }
            return transition
        }
    }

    func setCamera(_ camera: CameraIdentity, generation: UInt64) {
        state.withLock { state in
            guard state.generation == generation else { return }
            state.camera = camera
        }
    }

    /// Records the backend of `generation`'s current session (nil once it is torn down).
    func setBackend(_ backend: (any CameraBackend)?, generation: UInt64) {
        state.withLock { state in
            guard state.generation == generation else { return }
            state.backend = backend
        }
    }

    var backend: (any CameraBackend)? { state.withLock { $0.backend } }

    func beginSession() {
        state.withLock { $0.metrics.beginSession() }
    }

    /// Sequence numbers for decoded frames, monotonic across sessions and runs so consumers waiting
    /// on `next(after:)` never miss frames after a reconnect.
    func nextSequence() -> UInt64 {
        state.withLock { state in
            state.lastSequence += 1
            return state.lastSequence
        }
    }

    func recordAcquisition(_ frame: CameraFrame) {
        state.withLock { state in
            state.metrics.recordAcquisition(frame)
            state.settingsRevision = frame.settingsRevision
        }
    }

    func recordDecoded(_ frame: DecodedFrame, decodeStart: UInt64) {
        state.withLock { state in
            state.metrics.recordDecoded(frame, decodeStart: decodeStart)
            broadcastIfDue(&state, now: frame.decodedHostTime)
        }
    }

    func recordDelivered(_ frame: DecodedFrame, at hostTime: UInt64) {
        state.withLock { $0.metrics.recordDelivered(frame, at: hostTime) }
    }

    func currentStatus() -> CaptureStatus {
        state.withLock { state in
            makeStatus(state, now: HostTime.now())
        }
    }

    func subscribe() -> AsyncStream<CaptureStatus> {
        let (stream, continuation) = AsyncStream.makeStream(of: CaptureStatus.self, bufferingPolicy: .bufferingNewest(1))
        let id = state.withLock { state in
            let id = state.nextSubscriberID
            state.nextSubscriberID += 1
            state.subscribers[id] = continuation
            // Yielded under the lock so no newer status can overtake it.
            continuation.yield(makeStatus(state, now: HostTime.now()))
            return id
        }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    // MARK: - Status broadcasting (called with the lock held)

    private func makeStatus(_ state: State, now: UInt64) -> CaptureStatus {
        CaptureStatus(
            state: state.machine.state,
            camera: state.camera,
            metrics: state.metrics.snapshot(framesDropped: frames.droppedCount, now: now),
            lastRecoverableError: state.lastRecoverableError,
            reconnectCount: state.reconnectCount,
            disconnectCount: state.disconnectCount,
            settingsRevision: state.settingsRevision
        )
    }

    private func broadcast(_ state: inout State, now: UInt64 = HostTime.now()) {
        let status = makeStatus(state, now: now)
        state.lastBroadcast = now
        // Yielding under the lock keeps every subscriber's sequence in order. `yield` never calls
        // `onTermination` synchronously, so this cannot re-enter the lock.
        for continuation in state.subscribers.values { continuation.yield(status) }
    }

    private func broadcastIfDue(_ state: inout State, now: UInt64) {
        guard !state.subscribers.isEmpty, now &- state.lastBroadcast >= Self.metricsInterval else { return }
        broadcast(&state, now: now)
    }
}
