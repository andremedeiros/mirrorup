import MirrorupDiagnostics

/// Owns the capture pipeline: one capture loop at a time pulls frames from a `CameraBackend`,
/// decodes them and publishes them to `frames`, recovering from failures with backoff, and waiting
/// for a camera (without backoff) while none is attached.
public actor CaptureEngine {
    /// Newest decoded frame; consumers pull from here at their own pace.
    public nonisolated let frames: LatestFrameBuffer

    private let configuration: CaptureConfiguration
    private let makeBackend: @Sendable () async throws(CameraError) -> any CameraBackend
    private let arrivals: (any CameraArrivals)?
    private nonisolated let core: CaptureCore
    /// The loop started by the latest `start()`, until `stop()` cancels it.
    private var running: Task<Void, Never>?
    /// The most recently started loop, kept until it has fully torn down so `stop()` and the next
    /// `start()` can wait for it (two loops must never talk to the camera at once).
    private var lastLoop: Task<Void, Never>?

    /// - Parameter arrivals: when cameras appear on the transport `makeBackend` discovers on; nil
    ///   when it can't tell, and the engine then re-checks every `cameraRecheckInterval` while it
    ///   waits for a camera.
    public init(
        configuration: CaptureConfiguration = .init(),
        arrivals: (any CameraArrivals)? = nil,
        makeBackend: @escaping @Sendable () async throws(CameraError) -> any CameraBackend
    ) {
        self.configuration = configuration
        self.arrivals = arrivals
        self.makeBackend = makeBackend
        let frames = LatestFrameBuffer()
        self.frames = frames
        core = CaptureCore(frames: frames)
    }

    deinit {
        running?.cancel()
        frames.close()
    }

    /// Starts capturing. Idempotent: while a loop is active, further calls do nothing.
    public func start() {
        if running != nil, core.isActive { return }
        let generation = core.beginRun(maxAttemptsBeforeFailing: configuration.recovery.maxAttemptsBeforeFailing)
        let loop = CaptureLoop(
            configuration: configuration, makeBackend: makeBackend, arrivals: arrivals, core: core, frames: frames,
            generation: generation
        )
        let previous = lastLoop
        let task = Task {
            // A loop that ended on its own (failure) or is still tearing down must release the camera first.
            await previous?.value
            await loop.run()
        }
        running = task
        lastLoop = task
    }

    /// Stops capturing and returns once live view is stopped and the backend disconnected. Idempotent.
    public func stop() async {
        if let running {
            running.cancel()
            self.running = nil
            core.invalidateRun()
        }
        guard let loop = lastLoop else { return }
        let generation = core.generation
        await loop.value
        // A `start()` that ran while we waited owns the state now.
        guard core.generation == generation else { return }
        core.finishStop()
        frames.clear()
        lastLoop = nil
    }

    /// A stream of status updates: the current status immediately, then every state change and
    /// metrics refreshes at most ~4 Hz. Slow readers only see the newest status.
    public nonisolated func statusStream() -> AsyncStream<CaptureStatus> {
        core.subscribe()
    }

    public var status: CaptureStatus { core.currentStatus() }

    /// Called by the consumer after it handed `frame` to its sink at host time `hostTime`.
    public func reportDelivered(_ frame: DecodedFrame, at hostTime: UInt64) {
        core.recordDelivered(frame, at: hostTime)
    }

    /// Whether a capture loop exists (running or still tearing down). For tests.
    var hasLoop: Bool { lastLoop != nil }

    /// Whether the loop started by the latest `start()` has not been stopped. For tests.
    var isRunning: Bool { running != nil }

    /// Decoded metadata of the camera in the current session, or nil when no camera is connected.
    /// Computed on request (it formats every property), so call it when the user asks for it.
    public nonisolated func cameraMetadata() async -> CameraMetadata? {
        guard let backend = core.backend else { return nil }
        return await backend.metadata()
    }

    /// The current session's backend if it supports user controls; nil when no camera is connected
    /// or the backend has no controls.
    public nonisolated func controls() -> (any CameraControlling)? {
        core.backend as? any CameraControlling
    }

    /// Mirrors and/or flips every frame from the next decoded one on, for the preview and the virtual
    /// camera alike. Safe from any thread; persists across `stop()`/`start()`.
    public nonisolated func setOrientation(_ orientation: FrameOrientation) {
        core.orientation = orientation
    }

    public nonisolated var orientation: FrameOrientation { core.orientation }

    /// Requests sharpening with Apple's machine-learning super-resolution scaler, where the Mac
    /// supports it (`isEnhanceSupported`). The scaler loads in the background (~1 s); frames use plain
    /// scaling until it is ready, and for frame sizes it rejects. Safe from any thread; persists
    /// across `stop()`/`start()`.
    public nonisolated func setEnhance(_ enabled: Bool) {
        core.enhance = enabled
    }

    public nonisolated static var isEnhanceSupported: Bool { FrameDecoder.isEnhanceSupported }

    /// Keeps live view on the camera's own screen while streaming, where the camera can
    /// (`canShowLiveViewOnCamera`). Applied before live view starts and, while streaming, before the
    /// next frame. Safe from any thread; persists across `stop()`/`start()`.
    public nonisolated func setShowsLiveViewOnCamera(_ shows: Bool) {
        core.showsLiveViewOnCamera = shows
    }

    /// Whether the current session's camera can keep live view on its own screen; false when no
    /// camera is connected.
    public nonisolated var canShowLiveViewOnCamera: Bool {
        core.backend is any CameraScreenSharing
    }
}
