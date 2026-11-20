import MirrorupDiagnostics
import Synchronization

/// One capture run: discover -> connect -> live view -> frames, with recovery between sessions, and
/// a wait for a camera (no backoff, no attempt counted) while none is attached.
/// Runs off the engine actor so decoding never blocks status queries or `stop()`.
struct CaptureLoop: Sendable {
    let configuration: CaptureConfiguration
    let makeBackend: @Sendable () async throws(CameraError) -> any CameraBackend
    let arrivals: (any CameraArrivals)?
    let core: CaptureCore
    let frames: LatestFrameBuffer
    let generation: UInt64

    @concurrent
    func run() async {
        let decoder = FrameDecoder(output: configuration.output, pixelFormat: configuration.pixelFormat)
        defer { decoder.invalidate() }
        var random = SystemRandomNumberGenerator()

        while !Task.isCancelled {
            // Read before discovery, so a camera that appears while discovery gives up is not missed.
            let arrivalsBefore = await arrivals?.arrivalCount
            let error = await runSession(decoder: decoder)
            guard !Task.isCancelled, let transition = core.apply(.failed(error), generation: generation) else { return }
            switch transition.to {
            case .recovering(let attempt, _):
                let delay = configuration.recovery.delay(forAttempt: attempt, using: &random)
                Diagnostics.capture.info("Retrying in \(delay.milliseconds, format: .fixed(precision: 0)) ms")
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            case .waitingForCamera:
                await waitForCamera(arrivalsBefore: arrivalsBefore)
                if Task.isCancelled { return }
            default:
                return // failed (user must act) or cancelled by the backend
            }
            guard core.apply(.retry, generation: generation) != nil else { return }
        }
    }

    /// Returns when a camera appears (`arrivals`), after `cameraRecheckInterval`, or on cancellation.
    private func waitForCamera(arrivalsBefore: UInt64?) async {
        let recheck = configuration.cameraRecheckInterval
        await withTaskGroup(of: Void.self) { group in
            if let arrivals, let arrivalsBefore {
                group.addTask { await arrivals.waitForArrival(after: arrivalsBefore) }
            }
            group.addTask { try? await Task.sleep(for: recheck) }
            await group.next()
            group.cancelAll()
        }
    }

    /// Runs one backend session until it fails or the task is cancelled; always disconnects the backend.
    /// Returns the error that ended the session (`.cancelled` when the task was cancelled).
    private func runSession(decoder: FrameDecoder) async -> CameraError {
        let backend: any CameraBackend
        do {
            backend = try await makeBackend()
        } catch {
            return Task.isCancelled ? .cancellation : error
        }

        var liveViewRequested = false
        var sessionError: CameraError
        do throws(CameraError) {
            if Task.isCancelled { throw .cancellation }
            core.setCamera(await backend.identity, generation: generation)
            core.setBackend(backend, generation: generation)
            core.apply(.backendCreated, generation: generation)

            // A camera that reports it is preparing (e.g. its card is being indexed, 10-24 s on a 7D
            // with 479 files) gets `preparationTimeout` instead of failing the connect deadline.
            let deadline = ConnectDeadline(operationTimeout: configuration.operationTimeout,
                                           preparationTimeout: configuration.preparationTimeout)
            let core = core, generation = generation
            try await withDeadline(deadline, "connect") { () throws(CameraError) in
                try await backend.connect { preparation in
                    if let preparation {
                        deadline.preparing(preparation)
                        core.apply(.preparing(preparation), generation: generation)
                    } else {
                        deadline.preparationFinished()
                        core.apply(.preparationFinished, generation: generation)
                    }
                }
            }
            core.apply(.connected, generation: generation)
            // Backends can name the camera more precisely once connected.
            core.setCamera(await backend.identity, generation: generation)

            liveViewRequested = true
            // The only writer of the camera-screen preference to the camera, so a toggle can't race a connect.
            let screen = backend as? any CameraScreenSharing
            let showsOnCamera = core.showsLiveViewOnCamera
            if let screen {
                try await withDeadline(after: configuration.operationTimeout, "setShowsLiveViewOnCamera") { () throws(CameraError) in
                    try await screen.setShowsLiveViewOnCamera(showsOnCamera)
                }
            }
            try await withDeadline(after: configuration.operationTimeout, "startLiveView") { () throws(CameraError) in
                try await backend.startLiveView()
            }
            core.apply(.liveViewStarted, generation: generation)

            try await stream(from: backend, screen: screen, showsOnCamera: showsOnCamera, decoder: decoder)
        } catch {
            sessionError = error
        }
        core.setBackend(nil, generation: generation)
        await shutDown(backend, stopLiveView: liveViewRequested)
        return Task.isCancelled ? .cancellation : sessionError
    }

    /// Pulls, decodes and publishes frames until an error that is not a skippable frame. Applies a
    /// changed camera-screen preference before the next frame.
    private func stream(
        from backend: any CameraBackend, screen: (any CameraScreenSharing)?, showsOnCamera: Bool, decoder: FrameDecoder
    ) async throws(CameraError) -> Never {
        core.beginSession()
        let stallTimeout = configuration.stallTimeout
        // The watchdog measures time since the last *valid* frame, so a camera that only sends
        // garbage is reconnected just like one that sends nothing.
        var lastValidFrame = ContinuousClock.now
        var publishedAny = false
        var appliedShowsOnCamera = showsOnCamera
        while true {
            if Task.isCancelled { throw .cancellation }
            if let screen, core.showsLiveViewOnCamera != appliedShowsOnCamera {
                let wanted = !appliedShowsOnCamera
                try await withDeadline(after: configuration.operationTimeout, "setShowsLiveViewOnCamera") { () throws(CameraError) in
                    try await screen.setShowsLiveViewOnCamera(wanted)
                }
                appliedShowsOnCamera = wanted
            }
            let frame: CameraFrame
            do {
                frame = try await withDeadline(lastValidFrame + stallTimeout, "nextFrame") { () throws(CameraError) in
                    try await backend.nextFrame()
                } timeoutError: {
                    CameraError(.timeout, "The camera stopped sending frames.",
                                detail: "No valid frame for \(stallTimeout.milliseconds) ms")
                }
            } catch where error.disposition == .skipFrame {
                core.apply(.failed(error), generation: generation)
                continue
            } catch where error.kind == .timeout {
                // A photo can hold frames for longer than the stall timeout; that is not a stall. The
                // camera gets a full stall window after the pause, as after a valid frame.
                guard let pause = await backend.lastFramePause, pause > lastValidFrame else { throw error }
                lastValidFrame = pause
                continue
            }
            core.recordAcquisition(frame)

            // Includes the enhance and orientation passes, so decode metrics cover everything before publish.
            let decodeStart = HostTime.now()
            let signpost = Diagnostics.signposter.beginInterval("Decode")
            let decoded: DecodedFrame
            do {
                decoded = try decoder.decode(frame, sequence: core.nextSequence(), orientation: core.orientation,
                                             enhance: core.enhance)
            } catch {
                Diagnostics.signposter.endInterval("Decode", signpost)
                core.apply(.failed(error), generation: generation)
                continue
            }
            Diagnostics.signposter.endInterval("Decode", signpost)
            core.recordDecoded(decoded, decodeStart: decodeStart)
            frames.publish(decoded)
            lastValidFrame = .now
            if !publishedAny {
                publishedAny = true
                core.apply(.framePublished, generation: generation)
            }
        }
    }

    /// Stops live view (best effort, bounded) and disconnects. Runs in an unstructured task so it
    /// completes even though the calling task may be cancelled; it is awaited, never orphaned.
    private func shutDown(_ backend: any CameraBackend, stopLiveView: Bool) async {
        let timeout = configuration.operationTimeout
        await Task {
            if stopLiveView {
                do throws(CameraError) {
                    try await withDeadline(after: timeout, "stopLiveView") { () throws(CameraError) in
                        try await backend.stopLiveView()
                    }
                } catch {
                    Diagnostics.capture.debug("stopLiveView during teardown failed: \(error.description, privacy: .public)")
                }
            }
            await backend.disconnect()
        }.value
    }
}

extension CameraError {
    static let cancellation = CameraError(.cancelled, "Capture was stopped.")
}

private enum DeadlineOutcome<T: Sendable>: Sendable {
    case finished(Result<T, CameraError>)
    case timedOut
    case cancelled
}

/// Runs `body`, failing with `timeoutError` if it has not finished by `deadline`. The loser of the
/// race is cancelled and awaited (task group), so nothing outlives the call.
func withDeadline<T: Sendable>(
    _ deadline: ContinuousClock.Instant,
    _ operation: String,
    _ body: @escaping @Sendable () async throws(CameraError) -> T,
    timeoutError: @Sendable () -> CameraError = { CameraError(.timeout, "The camera did not respond in time.") }
) async throws(CameraError) -> T {
    try await race(operation, body, timeoutError: timeoutError) {
        try await Task.sleep(until: deadline, clock: .continuous)
    }
}

/// Runs a connect `body` against a deadline that moves while the camera prepares.
func withDeadline<T: Sendable>(
    _ deadline: ConnectDeadline,
    _ operation: String,
    _ body: @escaping @Sendable () async throws(CameraError) -> T
) async throws(CameraError) -> T {
    try await race(operation, body, timeoutError: { deadline.timeoutError() }) {
        try await deadline.sleepUntilPassed()
    }
}

/// Races `body` against `sleep`, which returns when time is up and throws when cancelled.
private func race<T: Sendable>(
    _ operation: String,
    _ body: @escaping @Sendable () async throws(CameraError) -> T,
    timeoutError: @Sendable () -> CameraError,
    sleep: @escaping @Sendable () async throws -> Void
) async throws(CameraError) -> T {
    let outcome = await withTaskGroup(of: DeadlineOutcome<T>.self) { group -> DeadlineOutcome<T> in
        group.addTask {
            do throws(CameraError) {
                return .finished(.success(try await body()))
            } catch {
                return .finished(.failure(error))
            }
        }
        group.addTask {
            do {
                try await sleep()
                return .timedOut
            } catch {
                return .cancelled
            }
        }
        let first = await group.next() ?? .cancelled
        group.cancelAll()
        return first
    }
    if Task.isCancelled { throw .cancellation }
    switch outcome {
    case .finished(let result):
        return try result.get()
    case .timedOut:
        var error = timeoutError()
        if error.detail == nil { error.detail = "\(operation) exceeded its deadline" }
        throw error
    case .cancelled:
        throw .cancellation
    }
}

func withDeadline<T: Sendable>(
    after timeout: Duration,
    _ operation: String,
    _ body: @escaping @Sendable () async throws(CameraError) -> T
) async throws(CameraError) -> T {
    try await withDeadline(.now + timeout, operation, body)
}

/// The deadline of one connect attempt: `operationTimeout` from creation; while the backend reports
/// the camera preparing, `preparationTimeout` from its first report; once the preparation is over, a
/// fresh `operationTimeout` for the rest of the connect.
final class ConnectDeadline: Sendable {
    /// How often a sleeper re-reads a deadline that may have moved earlier.
    static let recheckInterval: Duration = .milliseconds(250)

    private struct State {
        var instant: ContinuousClock.Instant
        var preparingSince: ContinuousClock.Instant?
        /// The latest report while preparing; nil when not preparing.
        var preparation: CameraPreparation?
    }

    let operationTimeout: Duration
    let preparationTimeout: Duration
    private let state: Mutex<State>

    init(operationTimeout: Duration, preparationTimeout: Duration, now: ContinuousClock.Instant = .now) {
        self.operationTimeout = operationTimeout
        self.preparationTimeout = preparationTimeout
        state = Mutex(State(instant: now + operationTimeout))
    }

    var instant: ContinuousClock.Instant { state.withLock { $0.instant } }

    /// The camera is preparing (first report or progress).
    func preparing(_ preparation: CameraPreparation, now: ContinuousClock.Instant = .now) {
        state.withLock { s in
            let since = s.preparingSince ?? now
            s.preparingSince = since
            s.preparation = preparation
            s.instant = since + preparationTimeout
        }
    }

    /// The camera finished preparing; the rest of the connect gets a fresh `operationTimeout`.
    func preparationFinished(now: ContinuousClock.Instant = .now) {
        state.withLock { s in
            guard s.preparation != nil else { return }
            s.preparation = nil
            s.instant = now + operationTimeout
        }
    }

    /// Returns once the (current) deadline has passed; throws when cancelled.
    func sleepUntilPassed() async throws {
        while true {
            let now = ContinuousClock.now
            let target = instant
            if now >= target { return }
            try await Task.sleep(until: min(target, now + Self.recheckInterval), clock: .continuous)
        }
    }

    func timeoutError() -> CameraError {
        state.withLock { s in
            switch s.preparation {
            case .readingStorage:
                CameraError(.timeout, "The camera took too long to get ready: macOS was still listing the files on its memory card.",
                            detail: "preparation exceeded \(preparationTimeout)")
            case nil:
                CameraError(.timeout, "The camera did not respond in time.")
            }
        }
    }
}
