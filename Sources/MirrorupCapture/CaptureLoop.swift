import MirrorupDiagnostics

/// One capture run: discover -> connect -> live view -> frames, with recovery between sessions.
/// Runs off the engine actor so decoding never blocks status queries or `stop()`.
struct CaptureLoop: Sendable {
    let configuration: CaptureConfiguration
    let makeBackend: @Sendable () async throws(CameraError) -> any CameraBackend
    let core: CaptureCore
    let frames: LatestFrameBuffer
    let generation: UInt64

    @concurrent
    func run() async {
        let decoder = FrameDecoder(output: configuration.output, pixelFormat: configuration.pixelFormat)
        defer { decoder.invalidate() }
        var random = SystemRandomNumberGenerator()

        while !Task.isCancelled {
            let error = await runSession(decoder: decoder)
            guard !Task.isCancelled, let transition = core.apply(.failed(error), generation: generation) else { return }
            guard case .recovering(let attempt, _) = transition.to else {
                return // failed (user must act) or cancelled by the backend
            }
            let delay = configuration.recovery.delay(forAttempt: attempt, using: &random)
            Diagnostics.capture.info("Retrying in \(delay.milliseconds, format: .fixed(precision: 0)) ms")
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard core.apply(.retry, generation: generation) != nil else { return }
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
            core.apply(.backendCreated, generation: generation)

            try await withDeadline(after: configuration.operationTimeout, "connect") { () throws(CameraError) in
                try await backend.connect()
            }
            core.apply(.connected, generation: generation)

            liveViewRequested = true
            try await withDeadline(after: configuration.operationTimeout, "startLiveView") { () throws(CameraError) in
                try await backend.startLiveView()
            }
            core.apply(.liveViewStarted, generation: generation)

            try await stream(from: backend, decoder: decoder)
        } catch {
            sessionError = error
        }
        await shutDown(backend, stopLiveView: liveViewRequested)
        return Task.isCancelled ? .cancellation : sessionError
    }

    /// Pulls, decodes and publishes frames until an error that is not a skippable frame.
    private func stream(from backend: any CameraBackend, decoder: FrameDecoder) async throws(CameraError) -> Never {
        core.beginSession()
        let stallTimeout = configuration.stallTimeout
        // The watchdog measures time since the last *valid* frame, so a camera that only sends
        // garbage is reconnected just like one that sends nothing.
        var lastValidFrame = ContinuousClock.now
        var publishedAny = false
        while true {
            if Task.isCancelled { throw .cancellation }
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
            }
            core.recordAcquisition(frame)

            let decodeStart = HostTime.now()
            let signpost = Diagnostics.signposter.beginInterval("Decode")
            let decoded: DecodedFrame
            do {
                decoded = try decoder.decode(frame, sequence: core.nextSequence())
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
                try await Task.sleep(until: deadline, clock: .continuous)
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
