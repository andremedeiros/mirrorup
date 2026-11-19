import AppKit
import AVFoundation
import Foundation
import ServiceManagement
import Observation
import MirrorupCapture
import MirrorupCameras
import MirrorupDevices
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
        static let lastCameraName = "lastCameraName"
        static let mirrored = "mirrored"
        static let upsideDown = "upsideDown"
        static let enhance = "enhanceDetail"
        /// Launch argument (`-MirrorupAfterExtensionUpgrade YES`) of the instance started by
        /// `relaunchAfterExtensionUpgrade`.
        static let afterExtensionUpgrade = "MirrorupAfterExtensionUpgrade"
    }

    var source: CameraSource {
        didSet {
            let newSource = source
            guard newSource != oldValue else { return }
            UserDefaults.standard.set(newSource.rawValue, forKey: Keys.source)
            sourceBox.withLock { $0 = newSource }
            Diagnostics.app.info("Source changed to \(newSource.rawValue, privacy: .public)")
            updateVirtualCameraName()
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
    /// One line for the popover: shooting mode and lens (`summary(_:)`), derived when camera info is
    /// read (never per frame).
    private(set) var cameraSummary: CameraSummary?
    /// Changes when the camera reports a setting change (mode dial, exposure...); views that show
    /// camera info or controls re-read them on change. Assigned only on change, not per status.
    private(set) var settingsRevision: UInt64 = 0

    /// Camera controls as of the last read (popover opened, or after a change). Never polled.
    private(set) var controlState: CameraControlState?
    private(set) var isApplyingControl = false
    /// Last control or photo outcome for the popover ("Saved IMG_0042.JPG", or what went wrong).
    private(set) var controlMessage: ControlMessage?

    struct ControlMessage: Equatable {
        enum Kind: Equatable { case success, failure }
        let kind: Kind
        let text: String
        /// Set when the message refers to a saved file that can be revealed in Finder.
        let fileURL: URL?
    }

    /// What the preview shows for the autofocus in progress or just finished; cleared shortly after.
    private(set) var focusFeedback: FocusFeedback?

    struct FocusFeedback: Equatable {
        enum State: Equatable { case focusing, focused, notFocused, unconfirmed, failed }
        let id: UUID
        /// Where the user clicked, normalized to the preview; nil for the Focus button (whole frame).
        let point: CGPoint?
        var state: State
    }

    /// App-side orientation of the stream (preview and Mirrorup Camera), persisted.
    var mirrored: Bool {
        didSet { applyOrientation(); UserDefaults.standard.set(mirrored, forKey: Keys.mirrored) }
    }
    var upsideDown: Bool {
        didSet { applyOrientation(); UserDefaults.standard.set(upsideDown, forKey: Keys.upsideDown) }
    }

    /// Sharpen frames with Apple's machine-learning super-resolution scaler. Persisted; hidden and
    /// ignored on Macs without it (`isEnhanceSupported`).
    var enhance: Bool {
        didSet { engine.setEnhance(enhance); UserDefaults.standard.set(enhance, forKey: Keys.enhance) }
    }

    let isEnhanceSupported = CaptureEngine.isEnhanceSupported

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
        let source = defaults.string(forKey: Keys.source).flatMap(CameraSource.init(rawValue:)) ?? .camera
        self.source = source
        autoStartStreaming = defaults.bool(forKey: Keys.autoStart)
        mirrored = defaults.bool(forKey: Keys.mirrored)
        upsideDown = defaults.bool(forKey: Keys.upsideDown)
        enhance = defaults.bool(forKey: Keys.enhance)
        cameraAccess = AVCaptureDevice.authorizationStatus(for: .video)
        let box = OSAllocatedUnfairLock(initialState: source)
        sourceBox = box
        // One engine for the app's lifetime; the source is read each time a backend is needed, so a
        // source change is just stop + start.
        engine = CaptureEngine(makeBackend: { () async throws(CameraError) -> any CameraBackend in
            try await box.withLock { $0 }.makeBackend()
        })
        applyOrientation()
        engine.setEnhance(enhance)
        extensionManager.isDeviceMissing = { [weak self] in self?.sinkState == .deviceNotFound }
        extensionManager.onReplaced = { [weak self] in self?.relaunchAfterExtensionUpgrade() }
        if defaults.bool(forKey: Keys.afterExtensionUpgrade) {
            extensionManager.verifyDeviceAfterUpgrade()
            extensionUpdateToAnnounce = true
        }
        updateVirtualCameraName()
        Task { await launch() }
    }

    private func applyOrientation() {
        engine.setOrientation(FrameOrientation(mirrored: mirrored, upsideDown: upsideDown))
    }

    // MARK: Lifecycle

    /// Re-reads permissions the user can change in System Settings while Mirrorup runs. Called when
    /// the popover or Settings opens; macOS sends no notification for either.
    func refreshSystemPermissions() {
        cameraAccess = AVCaptureDevice.authorizationStatus(for: .video)
        loginItemStatus = SMAppService.mainApp.status
    }

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

    /// A process that was connected to the extension never sees the process that replaces it, so
    /// after an upgrade this app can't feed the camera until it relaunches. Waits for the new
    /// extension to start, releases the camera and the sink (one process owns the camera), then
    /// opens a fresh instance and quits.
    private func relaunchAfterExtensionUpgrade() {
        Diagnostics.app.notice("Camera extension upgraded; relaunching to connect to it")
        Task {
            try? await Task.sleep(for: .seconds(3))
            await shutdown()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.activates = false
            configuration.arguments = ["-\(Keys.afterExtensionUpgrade)", "YES"]
            do {
                try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
                // Not from this main-actor job: `terminate` waits in a nested run loop for the
                // delegate's shutdown task, which can't run until this job returns.
                RunLoop.main.perform { MainActor.assumeIsolated { NSApplication.shared.terminate(nil) } }
            } catch {
                Diagnostics.app.error("Relaunch after the extension upgrade failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func setStreaming(_ on: Bool) {
        guard on != wantsStreaming else { return }
        wantsStreaming = on
        updatePresentation()
        Diagnostics.app.info("Streaming \(on ? "enabled" : "disabled", privacy: .public)")
        enqueueTransition(stop: !on, start: on)
    }

    /// The source of the engine run in progress; nil while stopping or stopped. Statuses from a run
    /// being torn down still arrive after `source` changes, so the camera's name is only remembered
    /// from a run that really is the camera.
    @ObservationIgnored private var runningSource: CameraSource?

    /// Serializes engine start/stop so rapid toggles and source changes apply in order.
    private func enqueueTransition(stop: Bool, start: Bool) {
        let previous = transition
        let engine = engine
        let sourceBox = sourceBox
        runningSource = nil
        transition = Task {
            await previous?.value
            if stop { await engine.stop() }
            if start {
                runningSource = sourceBox.withLock { $0 }
                await engine.start()
            }
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

    }

    /// Samples CPU, memory and sink counters once a second for as long as the caller (the Diagnostics
    /// window's `.task`) runs; nothing samples while no one is looking.
    func monitorResources() async {
        var previous = ProcessResources.snapshot()
        sinkCounters = sink.counterSnapshot
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
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

    // MARK: Camera controls (all on demand)

    func refreshControls() async {
        controlState = await engine.controls()?.controlState()
    }

    func set(_ setting: CameraSetting, to option: CameraSettingOption) {
        runControl("set \(setting.rawValue)=\(option.title)") { controls in
            self.controlState = try await controls.set(setting, to: option.value)
        }
    }

    /// Picker binding: `$model[setting: .aperture]`. Writing a value the camera offers applies it.
    subscript(setting setting: CameraSetting) -> UInt32? {
        get { controlState?.settings[setting]?.current?.value }
        set {
            guard let newValue,
                  let option = controlState?.settings[setting]?.options.first(where: { $0.value == newValue }),
                  option.value != controlState?.settings[setting]?.current?.value
            else { return }
            set(setting, to: option)
        }
    }

    /// Zoom picker binding (`$model.zoomSelection`).
    var zoomSelection: CameraZoom {
        get { controlState?.zoom ?? .x1 }
        set { if newValue != controlState?.zoom { setZoom(newValue) } }
    }

    func autofocus() {
        runFocus(at: nil) { try await $0.autofocus() }
    }

    /// Shows the focusing indicator, runs the AF command, then shows its outcome for a moment.
    private func runFocus(at previewPoint: CGPoint?,
                          _ body: @escaping @MainActor (any CameraControlling) async throws -> AutofocusResult) {
        let id = UUID()
        runControl(previewPoint == nil ? "autofocus" : "focus at point") { controls in
            self.focusFeedback = FocusFeedback(id: id, point: previewPoint, state: .focusing)
            let state: FocusFeedback.State
            do {
                state = switch try await body(controls) {
                case .focused: .focused
                case .notFocused: .notFocused
                case .unconfirmed: .unconfirmed
                }
            } catch {
                self.finishFocus(id, .failed)
                throw error
            }
            self.finishFocus(id, state)
        }
    }

    private func finishFocus(_ id: UUID, _ state: FocusFeedback.State) {
        guard focusFeedback?.id == id else { return }
        focusFeedback?.state = state
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            if focusFeedback?.id == id { focusFeedback = nil }
        }
    }

    func setZoom(_ zoom: CameraZoom) {
        runControl("zoom \(zoom.title)") { controls in
            self.controlState = try await controls.setZoom(zoom, center: nil)
        }
    }

    /// A click on the preview: focus there, or, while zoomed in, move the magnified area there.
    /// `point` is normalized to the displayed preview, (0, 0) top-left.
    func previewClicked(at point: CGPoint) {
        guard !isApplyingControl else { return }
        guard let state = controlState else { return }
        let cameraPoint = cameraFramePoint(fromPreview: point)
        if let zoom = state.zoom, zoom != .x1 {
            runControl("move zoom") { controls in
                self.controlState = try await controls.setZoom(zoom, center: cameraPoint)
            }
        } else if state.canFocusAtPoint {
            runFocus(at: point) { try await $0.focus(at: cameraPoint) }
        }
    }

    func capturePhoto() {
        runControl("take photo") { controls in
            let photo = try await controls.capturePhoto()
            let url = try await Self.savePhoto(photo)
            let message = ControlMessage(kind: .success, text: "Saved \(url.lastPathComponent)", fileURL: url)
            self.controlMessage = message
            // Success is news, not state: clear it after a while unless something replaced it.
            Task {
                try? await Task.sleep(for: .seconds(8))
                if self.controlMessage == message { self.controlMessage = nil }
            }
        }
    }

    private func runControl(_ action: String, _ body: @escaping @MainActor (any CameraControlling) async throws -> Void) {
        guard let controls = engine.controls(), !isApplyingControl else {
            Diagnostics.app.notice("Camera control \(action, privacy: .public) ignored (no controls or another in progress)")
            return
        }
        isApplyingControl = true
        controlMessage = nil
        Task {
            defer { isApplyingControl = false }
            let start = ContinuousClock.now
            do {
                try await body(controls)
                Diagnostics.app.notice("Camera control \(action, privacy: .public) done in \(start.duration(to: .now).milliseconds, format: .fixed(precision: 0)) ms")
            } catch let error as CameraError {
                controlMessage = ControlMessage(kind: .failure, text: error.message, fileURL: nil)
                Diagnostics.app.error("Camera control \(action, privacy: .public) failed: \(error.description, privacy: .public)")
            } catch {
                controlMessage = ControlMessage(kind: .failure, text: error.localizedDescription, fileURL: nil)
                Diagnostics.app.error("Camera control \(action, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
            if controlState == nil || controlMessage?.kind == .failure {
                await refreshControls()
            }
        }
    }

    /// Maps a point in the preview (the 16:9 output, after orientation) to the camera's live-view
    /// frame: undo mirror/rotation, then undo the centre crop that fitted the camera image to 16:9.
    private func cameraFramePoint(fromPreview point: CGPoint) -> CGPoint {
        var p = FrameOrientation(mirrored: mirrored, upsideDown: upsideDown).cameraPoint(fromDisplayed: point)
        guard let width = status.metrics.sourceWidth, let height = status.metrics.sourceHeight, width > 0, height > 0 else {
            return p
        }
        let sourceAspect = Double(width) / Double(height)
        let outputAspect = Double(VideoFormat.virtualCamera.width) / Double(VideoFormat.virtualCamera.height)
        if sourceAspect > outputAspect {
            let visible = outputAspect / sourceAspect
            p.x = (1 - visible) / 2 + p.x * visible
        } else {
            let visible = sourceAspect / outputAspect
            p.y = (1 - visible) / 2 + p.y * visible
        }
        return p
    }

    /// Saves into ~/Pictures/Mirrorup, never overwriting an existing file. Off the main actor: a
    /// full-resolution file is several megabytes.
    @concurrent nonisolated private static func savePhoto(_ photo: CapturedPhoto) async throws -> URL {
        let folder = URL.picturesDirectory.appending(path: "Mirrorup", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = (photo.filename as NSString).deletingPathExtension
        let ext = (photo.filename as NSString).pathExtension
        var url = folder.appending(path: photo.filename)
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: ext.isEmpty ? "\(name) \(index)" : "\(name) \(index).\(ext)")
            index += 1
        }
        try photo.data.write(to: url, options: .withoutOverwriting)
        return url
    }

    /// The popover's subtitle: shooting mode and lens ("P · 18-55mm").
    struct CameraSummary: Equatable {
        /// The mode as on the dial ("P"); the dial's icon replaces it when the camera has one.
        let mode: String?
        /// The mode's full name ("P (Program AE)"), for VoiceOver and the tooltip.
        let modeName: String?
        let modeSymbol: CameraSymbol?
        let lens: String?
    }

    private static func summary(_ info: CameraMetadata) -> CameraSummary? {
        // Shooting mode as on the dial, then the lens, which may truncate. Drivers write explained
        // values as "P (Program AE)"; the part before the parenthesis is what the dial says.
        // Exposure values read "Auto" outside an exposure and say nothing.
        let modeItem = info.item(.exposureMode).flatMap { $0.value.isEmpty ? nil : $0 }
        let lens = info.item(.lensName)?.value
        let summary = CameraSummary(
            mode: modeItem?.value.split(separator: " (").first.map(String.init),
            modeName: modeItem?.value,
            modeSymbol: modeItem?.symbol,
            lens: lens?.isEmpty == false ? lens : nil
        )
        return summary.mode == nil && summary.lens == nil ? nil : summary
    }

    // MARK: Derived UI state

    enum MenuBarIcon {
        case stopped
        case streamingToVirtualCamera
        case streaming
        case failed
        case working

        /// The iris is closed while the camera is off, swings half open while connecting, and is
        /// fully open while live; the dot means the picture is going out to other apps.
        var glyph: MenuBarSymbol.Glyph {
            switch self {
            case .stopped: MenuBarSymbol.Glyph(opening: 0, lit: false, badge: .none)
            case .working: MenuBarSymbol.Glyph(opening: 0.5, lit: false, badge: .ellipsis)
            case .streaming: MenuBarSymbol.Glyph(opening: 1, lit: false, badge: .none)
            case .streamingToVirtualCamera: MenuBarSymbol.Glyph(opening: 1, lit: true, badge: .none)
            case .failed: MenuBarSymbol.Glyph(opening: 0, lit: false, badge: .exclamation)
            }
        }

        var accessibilityValue: String {
            switch self {
            case .stopped: "Off"
            case .streamingToVirtualCamera: "Live on the Mirrorup camera"
            case .streaming: "Live"
            case .failed: "Problem"
            case .working: "Connecting"
            }
        }
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
    /// Name of the last camera that connected, remembered across launches so the camera can be
    /// called by its name ("Canon EOS Rebel SL2") even while it is off.
    private(set) var lastCameraName = UserDefaults.standard.string(forKey: Keys.lastCameraName)

    /// What to call a camera source in the UI.
    func title(for source: CameraSource) -> String {
        switch source {
        case .camera: lastCameraName ?? "USB Camera"
        case .testPattern: "Test Pattern"
        }
    }
    /// The extension is active and receiving frames, so other apps can pick `virtualCameraName`.
    private(set) var isVirtualCameraAvailable = false
    /// What other apps list the Mirrorup device as: named after the selected source.
    private(set) var virtualCameraName = VirtualCameraConfig.defaultDeviceName

    /// The camera source keeps the last camera's name while it is off or reconnecting, so USB
    /// dropouts never rename the device; only a different camera or source does.
    private func updateVirtualCameraName() {
        let name = switch source {
        case .camera: lastCameraName.map(VirtualCameraConfig.deviceName(forCamera:)) ?? VirtualCameraConfig.defaultDeviceName
        case .testPattern: VirtualCameraConfig.deviceName(forCamera: title(for: .testPattern))
        }
        if name != virtualCameraName { virtualCameraName = name }
        // Sent even when unchanged at launch: the extension may still carry another source's name.
        sink.setDeviceName(name)
    }

    /// Something worth telling the user that isn't a failure, shown in the popover until dismissed.
    enum Notice: Equatable {
        /// The connection dropped `drops` times in `ConnectionStability.window`; `throughHub`: the
        /// camera is plugged in through a hub (adapters and docks contain one), nil when unknown.
        case unstableConnection(drops: Int, throughHub: Bool?)
        /// The Camera Extension was replaced; video apps that were open don't see the new one.
        case extensionUpdated
    }

    private(set) var notice: Notice?
    @ObservationIgnored private var stability = ConnectionStability()
    /// Disconnect count when the unstable-connection notice was dismissed: it returns only after
    /// another drop.
    @ObservationIgnored private var unstableDismissedAt: Int?
    @ObservationIgnored private var throughHub: Bool?
    /// Set by the instance relaunched after an extension upgrade, until the notice is dismissed.
    @ObservationIgnored private var extensionUpdateToAnnounce = false

    func dismissNotice() {
        switch notice {
        case .unstableConnection: unstableDismissedAt = status.disconnectCount
        case .extensionUpdated: extensionUpdateToAnnounce = false
        case nil: break
        }
        updateNotice()
    }

    private func updateNotice() {
        let unstable = stability.update(disconnectCount: status.disconnectCount, at: .now)
        let newNotice: Notice?
        if unstable, unstableDismissedAt.map({ status.disconnectCount > $0 }) ?? true {
            if case .unstableConnection = notice {} else {
                // Read once per episode: enumerating USB is cheap but not free.
                throughHub = CameraRegistry.builtIn.supportedUSBCameras().first?.usbHubCount.map { $0 > 0 }
            }
            newNotice = .unstableConnection(drops: stability.recentDrops, throughHub: throughHub)
        } else if extensionUpdateToAnnounce, sinkState == .connected {
            newNotice = .extensionUpdated
        } else {
            newNotice = nil
        }
        if newNotice != notice { notice = newNotice }
    }

    private func updatePresentation() {
        let newPhase: Phase
        if !wantsStreaming {
            newPhase = .off
        } else {
            switch status.state {
            case .streaming:
                newPhase = .live
            case .failed(let error):
                newPhase = .unavailable(message: error.message)
            case .recovering:
                newPhase = .reconnecting(reason: status.lastRecoverableError?.message)
            case .idle, .discovering, .connecting, .initializing, .ready:
                // Stay "reconnecting" through the intermediate states of a recovery so the UI
                // doesn't flicker; a fresh start shows "connecting".
                if case .reconnecting = phase { newPhase = phase } else { newPhase = .connecting }
            }
        }
        let wasLive = phase == .live
        phase = newPhase
        cameraName = status.camera?.name
        if status.settingsRevision != settingsRevision {
            let revision = status.settingsRevision
            settingsRevision = revision
            Diagnostics.app.debug("Camera reported a settings change (revision \(revision))")
        }
        if runningSource == .camera, let name = cameraName, name != lastCameraName {
            lastCameraName = name
            UserDefaults.standard.set(name, forKey: Keys.lastCameraName)
            updateVirtualCameraName()
        }
        isVirtualCameraAvailable = sinkState == .connected
        updateNotice()
        if newPhase != .live { controlState = nil }
        if newPhase == .live && !wasLive {
            // A failure from the previous connection says nothing about this one.
            controlMessage = nil
            // Once per connection, so the popover is ready; never on a timer.
            Task {
                await refreshCameraInfo()
                await refreshControls()
            }
        }

        menuBarIcon = switch newPhase {
        case .off: .stopped
        case .live: sinkState == .connected ? .streamingToVirtualCamera : .streaming
        case .unavailable: .failed
        case .connecting, .reconnecting: .working
        }
    }
}
