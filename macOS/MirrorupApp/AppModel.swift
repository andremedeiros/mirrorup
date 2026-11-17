import AVFoundation
import Foundation
import ServiceManagement
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
    /// The streaming switch's binding (`$model.isStreaming`).
    var isStreaming: Bool {
        get { wantsStreaming }
        set { setStreaming(newValue) }
    }
    /// Replaced up to four times a second (metrics). Views that only need the coarse state read
    /// `phase` / `menuBarIcon`, which change only when the state does.
    private(set) var status = CaptureStatus()
    private(set) var sinkState: VirtualCameraSink.State = .inactive
    private(set) var sinkCounters = VirtualCameraSink.Counters()
    private(set) var cameraAccess: AVAuthorizationStatus
    private(set) var resources: ResourceUsage?
    /// Camera metadata, display-ready, as of the last time the user asked for it (popover or Camera
    /// Info window opened, Refresh). Deliberately not kept current: formatting and diffing hundreds
    /// of rows continuously is costly.
    private(set) var cameraInfoDisplay: CameraInfoDisplay?
    /// Bumped with every read: a constant-time change key for views reacting to new camera info.
    private(set) var cameraInfoRevision = 0
    private(set) var cameraInfoReadAt: Date?
    private(set) var isReadingCameraInfo = false
    /// One line for the popover, e.g. "EF-S18-55mm f/4-5.6 IS STM · f/5.6 · 1/60 s · ISO 400",
    /// derived when camera info is read (never per frame).
    private(set) var cameraSummary: String?

    /// Registered with launchd as a login item (System Settings › General › Login Items).
    var opensAtLogin: Bool {
        get { loginItemStatus == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                loginItemError = nil
            } catch {
                loginItemError = error.localizedDescription
                Diagnostics.app.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
            }
            loginItemStatus = SMAppService.mainApp.status
        }
    }
    private(set) var loginItemStatus = SMAppService.mainApp.status
    private(set) var loginItemError: String?

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
        updatePresentation()
        await transition?.value
        await engine.stop()
        sink.deactivate()
        for task in backgroundTasks { task.cancel() }
        backgroundTasks.removeAll()
    }

    func setStreaming(_ on: Bool) {
        guard on != wantsStreaming else { return }
        wantsStreaming = on
        updatePresentation()
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
                self.status = status
                updatePresentation()
            }
        })

        backgroundTasks.append(Task { [weak self] in
            for await state in sink.states {
                guard let self else { return }
                sinkState = state
                updatePresentation()
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
                    resources = ResourceUsage(
                        cpuPercent: ProcessResources.cpuUsage(from: previous, to: current) * 100,
                        memoryBytes: current.physicalFootprint
                    )
                }
                previous = current
                sinkCounters = sink.counterSnapshot
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

    func refreshCameraInfo() async {
        guard !isReadingCameraInfo else { return }
        isReadingCameraInfo = true
        defer { isReadingCameraInfo = false }
        let info = await engine.cameraMetadata()
        cameraInfoDisplay = info.map(CameraInfoDisplay.init)
        cameraInfoRevision += 1
        cameraInfoReadAt = Date()
        cameraSummary = info.flatMap(Self.summary)
    }

    /// Lens and the exposure triangle, in the order photographers read them.
    private static func summary(_ info: CameraMetadata) -> String? {
        let kinds: [CameraMetadata.ItemKind] = [.lensName, .aperture, .shutterSpeed, .iso]
        let parts = kinds.compactMap { info.item($0)?.value }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Derived UI state

    enum MenuBarIcon: String {
        case stopped = "video.slash"
        case streamingToVirtualCamera = "video.fill"
        case streaming = "video"
        case failed = "exclamationmark.triangle"
        case working = "video.badge.ellipsis"
    }

    /// Stored and assigned only on change: the menu-bar label must not observe `status`, which is
    /// replaced four times a second, or AppKit re-snapshots the status item on every update.
    private(set) var menuBarIcon = MenuBarIcon.stopped

    /// What the user should understand at a glance. Stored, assigned only on change.
    enum Phase: Equatable {
        case off
        case connecting
        case live
        case reconnecting(reason: String?)
        case unavailable(message: String)
    }

    private(set) var phase = Phase.off
    /// Connected camera's name; nil when none.
    private(set) var cameraName: String?
    /// The extension is active and receiving frames, so other apps can pick "Mirrorup Camera".
    private(set) var isVirtualCameraAvailable = false

    private func updatePresentation() {
        let newPhase: Phase
        if !wantsStreaming {
            newPhase = .off
        } else {
            switch status.state {
            case .streaming:
                newPhase = .live
            case .failed(let error):
                newPhase = .unavailable(message: UserFacingText.message(for: error))
            case .recovering:
                newPhase = .reconnecting(reason: status.lastRecoverableError.map(UserFacingText.message(for:)))
            case .idle, .discovering, .connecting, .initializing, .ready:
                // Stay "reconnecting" through the intermediate states of a recovery so the UI
                // doesn't flicker; a fresh start shows "connecting".
                if case .reconnecting = phase { newPhase = phase } else { newPhase = .connecting }
            }
        }
        let wasLive = phase == .live
        phase = newPhase
        cameraName = status.camera?.name
        isVirtualCameraAvailable = sinkState == .connected
        if newPhase == .live && !wasLive {
            // Once per connection, so the popover summary is ready; never on a timer.
            Task { await refreshCameraInfo() }
        }

        menuBarIcon = switch newPhase {
        case .off: .stopped
        case .live: sinkState == .connected ? .streamingToVirtualCamera : .streaming
        case .unavailable: .failed
        case .connecting, .reconnecting: .working
        }
    }
}
