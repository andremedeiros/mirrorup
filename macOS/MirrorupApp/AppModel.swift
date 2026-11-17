import AVFoundation
import Foundation
import Observation
import MirrorupCapture
import MirrorupDiagnostics
import os

/// App-wide state: owns the capture engine, the virtual-camera sink and the preview, and forwards
/// every published frame to both.
@MainActor
@Observable
final class AppModel {
    struct ResourceUsage: Equatable {
        /// 100 = one fully busy core.
        var cpuPercent: Double
        var memoryBytes: UInt64
    }

    private enum Keys {
        static let source = "cameraSource"
        static let autoStart = "autoStartStreaming"
    }

    var source: CameraSource {
        didSet {
            let newSource = source
            guard newSource != oldValue else { return }
            UserDefaults.standard.set(newSource.rawValue, forKey: Keys.source)
            sourceBox.withLock { $0 = newSource }
            Diagnostics.app.info("Source changed to \(newSource.rawValue, privacy: .public)")
            if wantsStreaming { enqueueTransition(stop: true, start: true) }
        }
    }

    var autoStartStreaming: Bool {
        didSet { UserDefaults.standard.set(autoStartStreaming, forKey: Keys.autoStart) }
    }

    private(set) var wantsStreaming = false
    private(set) var status = CaptureStatus()
    /// Display-only: true from the first `.recovering` until streaming resumes (or the user stops),
    /// so the menu doesn't flicker through every intermediate reconnect state.
    private(set) var isReconnecting = false
    private(set) var sinkState: VirtualCameraSink.State = .inactive
    private(set) var sinkCounters = VirtualCameraSink.Counters()
    private(set) var cameraAccess: AVAuthorizationStatus
    private(set) var resources: ResourceUsage?

    let extensionManager = ExtensionManager()
    let preview = PreviewRenderer()

    @ObservationIgnored let engine: CaptureEngine
    @ObservationIgnored private let sink = VirtualCameraSink()
    @ObservationIgnored private let sourceBox: OSAllocatedUnfairLock<CameraSource>
    @ObservationIgnored private var transition: Task<Void, Never>?
    @ObservationIgnored private var backgroundTasks: [Task<Void, Never>] = []

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Keys.autoStart: true])
        let source = defaults.string(forKey: Keys.source).flatMap(CameraSource.init(rawValue:)) ?? .canon
        self.source = source
        autoStartStreaming = defaults.bool(forKey: Keys.autoStart)
        cameraAccess = AVCaptureDevice.authorizationStatus(for: .video)
        let box = OSAllocatedUnfairLock(initialState: source)
        sourceBox = box
        // One engine for the app's lifetime; the source is read each time a backend is needed, so a
        // source change is just stop + start.
        engine = CaptureEngine(makeBackend: { () async throws(CameraError) -> any CameraBackend in
            try await box.withLock { $0 }.makeBackend()
        })
        Task { await launch() }
    }

    // MARK: Lifecycle

    private func launch() async {
        let source = source.rawValue
        let autoStart = autoStartStreaming
        Diagnostics.app.info("Mirrorup launched (source=\(source, privacy: .public), autoStart=\(autoStart))")
        extensionManager.activateIfNeeded()
        startBackgroundTasks()

        if cameraAccess == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            cameraAccess = AVCaptureDevice.authorizationStatus(for: .video)
        }
        sink.activate()
        if autoStartStreaming { setStreaming(true) }
    }

    /// Called when the app is about to quit: releases the camera and the virtual-camera sink.
    func shutdown() async {
        wantsStreaming = false
        await transition?.value
        await engine.stop()
        sink.deactivate()
        for task in backgroundTasks { task.cancel() }
        backgroundTasks.removeAll()
    }

    func setStreaming(_ on: Bool) {
        guard on != wantsStreaming else { return }
        wantsStreaming = on
        Diagnostics.app.info("Streaming \(on ? "enabled" : "disabled", privacy: .public)")
        enqueueTransition(stop: !on, start: on)
    }

    /// Serializes engine start/stop so rapid toggles and source changes apply in order.
    private func enqueueTransition(stop: Bool, start: Bool) {
        let previous = transition
        let engine = engine
        transition = Task {
            await previous?.value
            if stop { await engine.stop() }
            if start { await engine.start() }
        }
    }

    private func startBackgroundTasks() {
        let engine = engine
        let sink = sink
        let preview = preview

        backgroundTasks.append(Task { [weak self] in
            for await status in engine.statusStream() {
                guard let self else { return }
                switch status.state {
                case .recovering: self.isReconnecting = true
                case .streaming, .idle, .failed: self.isReconnecting = false
                default: break
                }
                self.status = status
            }
        })

        backgroundTasks.append(Task { [weak self] in
            for await state in sink.states {
                guard let self else { return }
                self.sinkState = state
            }
        })

        backgroundTasks.append(Task.detached(priority: .userInitiated) {
            await Self.forwardFrames(engine: engine, sink: sink, preview: preview)
        })

        backgroundTasks.append(Task { [weak self] in
            var previous = ProcessResources.snapshot()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let current = ProcessResources.snapshot()
                if let previous, let current {
                    self.resources = ResourceUsage(
                        cpuPercent: ProcessResources.cpuUsage(from: previous, to: current) * 100,
                        memoryBytes: current.physicalFootprint
                    )
                }
                previous = current
                self.sinkCounters = sink.counterSnapshot
            }
        })
    }

    /// Hands every new frame to the virtual camera and the preview. Runs off the main actor; never
    /// waits on either consumer, so a slow consumer costs frames, not latency.
    nonisolated private static func forwardFrames(engine: CaptureEngine, sink: VirtualCameraSink, preview: PreviewRenderer) async {
        var factory = SampleBufferFactory()
        var lastSequence: UInt64 = 0
        var failures = 0
        while let frame = await engine.frames.next(after: lastSequence) {
            lastSequence = frame.sequence
            let sampleBuffer: CMSampleBuffer
            do {
                sampleBuffer = try factory.makeSampleBuffer(for: frame)
            } catch {
                failures += 1
                if failures == 1 || failures % 300 == 0 {
                    Diagnostics.app.error("Sample buffer creation failed (\(failures) total): \(String(describing: error), privacy: .public)")
                }
                continue
            }
            if sink.enqueue(sampleBuffer) {
                await engine.reportDelivered(frame, at: HostTime.now())
            }
            preview.submit(sampleBuffer)
        }
    }

    // MARK: Derived UI state

    var menuBarSymbol: String {
        guard wantsStreaming else { return "video.slash" }
        switch status.state {
        case .streaming: return sinkState == .connected ? "video.fill" : "video"
        case .failed: return "exclamationmark.triangle"
        default: return "video.badge.ellipsis"
        }
    }

    var headline: String {
        guard wantsStreaming else { return "Stopped" }
        return isReconnecting ? "Reconnecting…" : UserFacingText.headline(for: status.state)
    }

    var explanation: String? {
        guard wantsStreaming else { return nil }
        if isReconnecting { return status.lastRecoverableError.map(UserFacingText.message(for:)) }
        return UserFacingText.explanation(for: status)
    }

    var cameraAccessMessage: String? {
        switch cameraAccess {
        case .denied, .restricted:
            "Mirrorup doesn't have permission to use the camera. Allow it in System Settings › Privacy & Security › Camera."
        default:
            nil
        }
    }
}
