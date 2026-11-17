public import CoreGraphics
import Foundation
public import MirrorupCapture
import MirrorupDiagnostics
import MirrorupPTP

// User camera controls on Canon EOS bodies. Command sequences, provenance and what was verified on the
// SL2: docs/canon-eos-ptp.md §11. Nothing here runs unless the user opens the controls or acts.

/// Properties and values behind the user controls (docs/canon-eos-ptp.md §8, §11).
extension CanonProperty {
    public static let focusMode: UInt32 = 0xD108
    public static let colorTemperature: UInt32 = 0xD10A
    public static let pictureStyle: UInt32 = 0xD110
    /// LvAfSystem (EDSDK Evf_AFMode); labels in `CanonValueTables.liveViewAFMethod`.
    public static let liveViewAFMethod: UInt32 = 0xD1BA

    /// Evf_AFMode 1, "1-point AF (Live Mode)": the AF frame is the magnifier and follows ZoomPosition.
    public static let afMethodOnePoint: UInt32 = 0x01
    /// Evf_AFMode 2, "Face + Tracking": the SL2 answers Zoom with DeviceBusy in this mode.
    public static let afMethodFaceTracking: UInt32 = 0x02
    /// EdsWhiteBalance 9, the only white balance that uses Color Temperature (0xD10A).
    public static let whiteBalanceColorTemperature: UInt32 = 0x09
    /// EDSDK AFMode 3: the lens AF/MF switch is at MF.
    public static let focusModeManual: UInt32 = 0x03
    /// LensStatus 0: no lens attached.
    public static let lensNotAttached: UInt32 = 0x00

    /// The property a user setting writes.
    public static func code(for setting: CameraSetting) -> UInt32 {
        switch setting {
        case .aperture: aperture
        case .shutterSpeed: shutterSpeed
        case .iso: isoSpeed
        case .exposureCompensation: exposureCompensation
        case .whiteBalance: whiteBalance
        case .colorTemperature: colorTemperature
        case .pictureStyle: pictureStyle
        case .autofocusMethod: liveViewAFMethod
        }
    }
}

/// Why a RemoteReleaseOn full press did not fire, from its first response parameter. Codes 1, 3, 7 and
/// 8 are libgphoto2's EOS capture results (library.c camera_trigger_canon_eos_capture); 6 follows the
/// same numbering in Canon's EDSDK TakePicture errors (EDS_ERR_TAKE_PICTURE_*, 0x8D01 + n − 1).
public enum CanonReleaseFailure: UInt32, Sendable {
    case focusFailed = 1
    case mirrorUp = 3
    case noCard = 6
    case cardError = 7
    case cardWriteProtected = 8

    var message: String {
        switch self {
        case .focusFailed: "The camera could not focus, so it did not take the photo."
        case .mirrorUp: "The camera's mirror is locked up. Turn off mirror lockup to take photos."
        case .noCard: "Insert a memory card to take photos."
        case .cardError: "The camera could not write to its memory card. Check the card's free space."
        case .cardWriteProtected: "The memory card is locked. Unlock it to take photos."
        }
    }
}

extension CanonCamera: CameraControlling {
    // MARK: State

    public func controlState() async -> CameraControlState {
        guard isConnected else { return CameraControlState() }
        do {
            try await drainEvents()
        } catch {
            Diagnostics.canon.notice("GetEvent before control state failed: \(error.description, privacy: .public)")
        }
        return currentControlState()
    }

    /// The control state from the property cache and the latest live-view frame, without talking to
    /// the camera.
    func currentControlState() -> CameraControlState {
        var settings: [CameraSetting: CameraSettingState] = [:]
        for setting in CameraSetting.allCases {
            if let state = settingState(setting) { settings[setting] = state }
        }
        let battery = propertyValue(CanonProperty.batteryPower)
        let shots = propertyValue(CanonProperty.availableShots)
        var zoom: CameraZoom?
        if isLiveView, supports(CanonOperation.zoom),
           propertyValue(CanonProperty.liveViewAFMethod) != CanonProperty.afMethodFaceTracking {
            // 10× set on the camera body streams the same image as 5×.
            zoom = latestFrame?.metadata.magnification.map { CameraZoom(rawValue: Int($0)) ?? .x5 } ?? .x1
        }
        return CameraControlState(
            settings: settings,
            canAutofocus: canAutofocus,
            canFocusAtPoint: canFocusAtPoint,
            zoom: zoom,
            canCapturePhoto: isConnected && supports(CanonOperation.remoteReleaseOn) && supports(CanonOperation.remoteReleaseOff)
                && shots.map { $0 > 0 } ?? true,
            battery: battery.flatMap { CanonCatalog.optionTitle(property: CanonProperty.batteryPower, value: $0) },
            batteryIsLow: battery == CanonValueTables.batteryLevelLow,
            shotsRemaining: shots.map(Int.init))
    }

    /// Current value and the camera's allowed values for one setting; nil when the camera never
    /// reported the property. Undocumented values are not offered (they could only be shown as codes).
    func settingState(_ setting: CameraSetting) -> CameraSettingState? {
        let code = CanonProperty.code(for: setting)
        let current = propertyValue(code)
        var allowed = properties.allowedValues[code] ?? []
        // The body sends a Kelvin list even when another white balance is active; it applies only to
        // the Color Temperature white balance.
        if setting == .colorTemperature,
           propertyValue(CanonProperty.whiteBalance) != CanonProperty.whiteBalanceColorTemperature {
            allowed = []
        }
        guard current != nil || !allowed.isEmpty else { return nil }
        let mask = CanonCatalog.propertySpecs[code]?.width.mask ?? .max
        let options = allowed.compactMap { value in
            CanonCatalog.optionTitle(property: code, value: value).map { CameraSettingOption(value: value, title: $0) }
        }
        let currentOption = current.flatMap { value in
            options.first { $0.value & mask == value }
                ?? CanonCatalog.optionTitle(property: code, value: value).map { CameraSettingOption(value: value, title: $0) }
        }
        return CameraSettingState(setting: setting, current: currentOption, options: options)
    }

    // MARK: Settings

    public func set(_ setting: CameraSetting, to value: UInt32) async throws(CameraError) -> CameraControlState {
        guard isConnected else { throw CameraError(.disconnected, "The camera is not connected.") }
        let code = CanonProperty.code(for: setting)
        guard let state = settingState(setting), state.options.contains(where: { $0.value == value }) else {
            throw CameraError(.protocolViolation, "The camera doesn't offer that \(setting.title) value right now.",
                              detail: "\(CanonCatalog.describe(CanonCatalog.propertyName(code), code: code)) = \(Self.hex(value)) is not in the allowed list")
        }
        let mask = CanonCatalog.propertySpecs[code]?.width.mask ?? .max
        do {
            // Integers of 32 bits or fewer always travel in a 4-byte slot (docs §3.4).
            let result = try await session.transact(
                PTPCommand(CanonOperation.setDevicePropValueEx),
                dataOut: CanonPropertyEncoding.integerPayload(property: code, value: value),
                timeout: options.commandTimeout)
            guard result.response.code == .ok else {
                throw Self.refusal(result.response.code, action: .changeSetting, context: "set \(setting.rawValue)")
            }
            // The SL2 echoes the new value in the next GetEvent (~10 ms); bounded wait.
            let deadline = ContinuousClock.now + options.settingConfirmationTimeout
            while propertyValue(code) != value & mask {
                guard ContinuousClock.now < deadline else {
                    throw CameraError(.timeout, "The camera did not confirm the new \(setting.title).",
                                      detail: "no PropValueChanged for \(Self.hex(code)) = \(Self.hex(value)) within \(options.settingConfirmationTimeout)")
                }
                try await Task.sleep(for: .milliseconds(20))
                try await drainEvents()
            }
        } catch {
            throw Self.controlError(error, context: "set \(setting.rawValue)")
        }
        return currentControlState()
    }

    // MARK: Focus

    @discardableResult
    public func autofocus() async throws(CameraError) -> AutofocusResult {
        guard canAutofocus else { throw autofocusUnavailable() }
        do {
            return try await runAutofocus()
        } catch {
            throw Self.controlError(error, context: "autofocus")
        }
    }

    @discardableResult
    public func focus(at point: CGPoint) async throws(CameraError) -> AutofocusResult {
        guard canFocusAtPoint, let metadata = latestFrame?.metadata,
              let origin = Self.magnifierOrigin(centeredAt: point, metadata: metadata,
                                                size: Self.magnifierSize(metadata: metadata))
        else {
            if !canAutofocus { throw autofocusUnavailable() }
            throw CameraError(.protocolViolation, "Click to focus needs the 1-point AF focus mode.",
                              detail: "LvAfSystem \(propertyValue(CanonProperty.liveViewAFMethod).map { Self.hex($0) } ?? "unknown"), ZoomPosition listed: \(supports(CanonOperation.zoomPosition)), frame geometry: \(latestFrame?.metadata.zoomRect != nil)")
        }
        do {
            // In 1-point AF the AF frame is the magnifier, so ZoomPosition moves it (SL2: verified).
            // When magnified, the view itself pans so the point becomes its centre.
            try await moveMagnifier(to: origin, from: metadata.magnifierRect, action: .focus)
            return try await runAutofocus()
        } catch {
            throw Self.controlError(error, context: "focus at point")
        }
    }

    /// ZoomPosition, then wait for the frames to show the magnifier (and 1-point AF frame) moved. The SL2
    /// silently ignores a ZoomPosition sent a few milliseconds after AfCancel, so an unmoved
    /// magnifier gets the command once more.
    private func moveMagnifier(to origin: (x: UInt32, y: UInt32), from before: CanonViewfinderMetadata.Rect?,
                               action: ControlAction) async throws {
        for attempt in 1...2 {
            let result = try await session.transact(PTPCommand(CanonOperation.zoomPosition, [origin.x, origin.y]),
                                                    timeout: options.commandTimeout)
            guard result.response.code == .ok else {
                throw Self.refusal(result.response.code, action: action, context: "ZoomPosition \(origin.x),\(origin.y)")
            }
            // The frames show the move ~100 ms later; AF before that would focus at the old point.
            let moved = await waitForFrame(timeout: options.frameConfirmationTimeout) { m in
                guard let rect = m.magnifierRect else { return false }
                return rect != before || Self.isNear(rect, origin)
            }
            if moved { return }
            Diagnostics.canon.notice("ZoomPosition \(origin.x),\(origin.y) not reflected in frames (attempt \(attempt))")
        }
    }

    /// DoAf, wait for the AF result, then AfCancel. DoAf returns on acceptance; the body then holds AF
    /// (and answers DeviceBusy to property writes, zoom and release) until AfCancel (SL2: verified).
    private func runAutofocus() async throws -> AutofocusResult {
        let startSequence = sequence
        let hadResult = latestFrame.map { Self.showsAutofocusResult($0.metadata) } ?? false
        let result = try await session.transact(PTPCommand(CanonOperation.doAF), timeout: options.commandTimeout)
        guard result.response.code == .ok else {
            throw Self.refusal(result.response.code, action: .focus, context: "DoAf")
        }
        // Done when a frame taken after DoAf shows the AF frame's result (1-point AF: 0.3–0.6 s on the
        // SL2). A result still showing from an earlier AF must clear first. Face + Tracking reports no
        // per-frame result, so it uses the whole bound.
        var sawNoResult = false
        var outcome = AutofocusResult.unconfirmed
        await waitForFrame(after: startSequence, timeout: options.autofocusTimeout) { m in
            let done = Self.showsAutofocusResult(m)
            if !done { sawNoResult = true }
            guard done && (!hadResult || sawNoResult) else { return false }
            outcome = Self.autofocusOutcome(m)
            return true
        }
        if supports(CanonOperation.afCancel) {
            let cancel = try await session.transact(PTPCommand(CanonOperation.afCancel), timeout: options.commandTimeout)
            if cancel.response.code != .ok {
                Diagnostics.canon.notice("AfCancel -> \(CanonResponse.describe(cancel.response.code), privacy: .public)")
            }
        }
        try await drainEvents()
        return outcome
    }

    /// 0x11 in any AF frame is a lock; the SL2's other result state (0x12) appears when it gives up,
    /// e.g. on a blank wall (observed on hardware; no reference names it).
    static func autofocusOutcome(_ metadata: CanonViewfinderMetadata) -> AutofocusResult {
        metadata.focusFrames?.contains { $0.state == .focused } == true ? .focused : .notFocused
    }

    /// Whether an AF frame left its resting state after DoAf: 0x11 (in focus, FC.SDK), or a state no
    /// source names that the SL2 shows only as an AF outcome (0x12, seen on low-contrast targets).
    /// Face-detection/tracking states and the SL2's 0 (Face + Tracking grid) are not results.
    static func showsAutofocusResult(_ metadata: CanonViewfinderMetadata) -> Bool {
        metadata.focusFrames?.contains { frame in
            switch frame.state {
            case .focused: true
            case .undocumented(let code): code != 0
            case .resting, .faceTracking, .tracking: false
            }
        } ?? false
    }

    // MARK: Zoom

    public func setZoom(_ zoom: CameraZoom, center: CGPoint?) async throws(CameraError) -> CameraControlState {
        guard isLiveView else { throw CameraError(.liveViewUnavailable, "Zoom needs live view.") }
        guard supports(CanonOperation.zoom) else {
            throw CameraError(.protocolViolation, "This camera can't zoom live view over USB.", detail: "Zoom (0x9158) not listed")
        }
        if propertyValue(CanonProperty.liveViewAFMethod) == CanonProperty.afMethodFaceTracking {
            throw CameraError(.protocolViolation, "Zoom isn't available in the Face + Tracking focus mode.",
                              detail: "the SL2 answers Zoom with DeviceBusy while LvAfSystem = Face + Tracking")
        }
        do {
            // Position first (it moves the magnifier the zoom opens on, at the current magnifier size),
            // then magnify; the magnified view is centred on the magnifier.
            if let center, zoom != .x1, supports(CanonOperation.zoomPosition), let metadata = latestFrame?.metadata,
               let origin = Self.magnifierOrigin(centeredAt: center, metadata: metadata,
                                                 size: Self.magnifierSize(metadata: metadata)) {
                try await moveMagnifier(to: origin, from: metadata.magnifierRect, action: .zoom)
            }
            let r = try await session.transact(PTPCommand(CanonOperation.zoom, [UInt32(zoom.rawValue)]),
                                               timeout: options.commandTimeout)
            guard r.response.code == .ok else {
                throw Self.refusal(r.response.code, action: .zoom, context: "Zoom \(zoom.rawValue)")
            }
            // The live-view JPEG changes size with the magnification (1024×576 → 1200×800 on the SL2).
            await waitForFrame(timeout: options.frameConfirmationTimeout) { $0.magnification == UInt32(zoom.rawValue) }
            try await drainEvents()
        } catch {
            throw Self.controlError(error, context: "zoom \(zoom.rawValue)x")
        }
        return currentControlState()
    }

    // MARK: Photo

    public func capturePhoto() async throws(CameraError) -> CapturedPhoto {
        guard isConnected else { throw CameraError(.disconnected, "The camera is not connected.") }
        guard supports(CanonOperation.remoteReleaseOn), supports(CanonOperation.remoteReleaseOff) else {
            throw CameraError(.protocolViolation, "This camera can't take photos over USB.", detail: "RemoteReleaseOn/Off not listed")
        }
        guard !shutterCycleActive else {
            throw CameraError(.protocolViolation, "A photo is already being taken.")
        }
        do {
            // The capture destination is left as the user set it; the file lands on the card.
            let storage = try await session.execute(PTPCommand(CanonOperation.getStorageIDs), timeout: options.commandTimeout)
            var reader = PTPDataReader(storage.data)
            guard !(try reader.u32Array()).isEmpty else {
                throw CameraError(.protocolViolation, CanonReleaseFailure.noCard.message, detail: "GetStorageIDs returned no storage")
            }
            try await drainEvents()
            collectedObjects = []
            shutterCycleActive = true
            defer {
                collectedObjects = nil
                shutterCycleActive = false
            }
            try await releaseShutter()
            let object = try await waitForNewObject()
            let download = try await session.transact(PTPCommand(.getObject, [object.handle]), timeout: options.photoDownloadTimeout)
            guard download.response.code == .ok, !download.data.isEmpty else {
                throw CameraError(.protocolViolation, "The photo could not be copied from the camera.",
                                  detail: "GetObject \(Self.hex(object.handle)) -> \(CanonResponse.describe(download.response.code)), \(download.data.count) bytes")
            }
            if object.storageID == 0, supports(CanonOperation.transferComplete) {
                // A file held in camera RAM is released with TransferComplete (libgphoto2
                // camera_canon_eos_capture); card files stay on the card.
                _ = try await session.transact(PTPCommand(CanonOperation.transferComplete, [object.handle]),
                                               timeout: options.commandTimeout)
            }
            var filename = object.filename
            if filename.isEmpty { filename = try await objectFilename(object.handle) }
            Diagnostics.canon.info("photo \(filename, privacy: .public): \(download.data.count) bytes")
            return CapturedPhoto(data: download.data, filename: filename)
        } catch {
            throw Self.controlError(error, context: "capture photo")
        }
    }

    /// Half press (AF and metering), full press, then release both, like the shutter button
    /// (libgphoto2 camera_trigger_canon_eos_capture, regular EOS path).
    private func releaseShutter() async throws {
        let half = try await session.transact(PTPCommand(CanonOperation.remoteReleaseOn, [1, 0]), timeout: options.commandTimeout)
        guard half.response.code == .ok else {
            throw Self.refusal(half.response.code, action: .takePhoto, context: "RemoteReleaseOn half press")
        }
        var failure: (any Error)?
        do {
            // Let the half-press AF settle (the SL2 reports focus ~0.4 s after it).
            let settle = ContinuousClock.now + .milliseconds(600)
            while ContinuousClock.now < settle {
                try await drainEvents()
                try await Task.sleep(for: .milliseconds(50))
            }
            let full = try await session.transact(PTPCommand(CanonOperation.remoteReleaseOn, [2, 0]), timeout: options.commandTimeout)
            if full.response.code != .ok {
                failure = Self.refusal(full.response.code, action: .takePhoto, context: "RemoteReleaseOn full press")
            } else if let result = full.response.parameters.first, result != 0 {
                failure = Self.releaseFailure(result)
            }
            let fullOff = try await session.transact(PTPCommand(CanonOperation.remoteReleaseOff, [2]), timeout: options.commandTimeout)
            if fullOff.response.code != .ok {
                Diagnostics.canon.notice("RemoteReleaseOff(2) -> \(CanonResponse.describe(fullOff.response.code), privacy: .public)")
            }
        } catch {
            failure = error
        }
        // Always let go of the half press, even after a failure, so the body is not left half-pressed.
        let halfOff = try await session.transact(PTPCommand(CanonOperation.remoteReleaseOff, [1]), timeout: options.commandTimeout)
        if halfOff.response.code != .ok {
            Diagnostics.canon.notice("RemoteReleaseOff(1) -> \(CanonResponse.describe(halfOff.response.code), privacy: .public)")
        }
        if let failure { throw failure }
    }

    private func waitForNewObject() async throws -> CanonObjectInfo {
        let deadline = ContinuousClock.now + options.photoTimeout
        while true {
            try await drainEvents()
            if let object = collectedObjects?.first(where: { !$0.isFolder }) { return object }
            guard ContinuousClock.now < deadline else {
                throw CameraError(.timeout, "The camera did not save a photo.",
                                  detail: "no ObjectAddedEx/RequestObjectTransfer within \(options.photoTimeout)")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// ObjectInfo filename (ISO 15740 dataset: 52 bytes of fixed fields, then the name).
    private func objectFilename(_ handle: UInt32) async throws -> String {
        let info = try await session.execute(PTPCommand(.getObjectInfo, [handle]), timeout: options.commandTimeout)
        var reader = PTPDataReader(info.data)
        try reader.skip(52)
        return try reader.string()
    }

    // MARK: Helpers

    var isConnected: Bool {
        if case .disconnected = state { return false }
        return true
    }

    var isLiveView: Bool {
        if case .liveView = state { return true }
        return false
    }

    func supports(_ op: PTPOperationCode) -> Bool { deviceInfo?.supports(op) ?? false }

    /// Cached integer value, masked to the property's width.
    func propertyValue(_ code: UInt32) -> UInt32? {
        properties[code]?.integer.map { $0 & (CanonCatalog.propertySpecs[code]?.width.mask ?? .max) }
    }

    var canAutofocus: Bool {
        isLiveView && supports(CanonOperation.doAF)
            && propertyValue(CanonProperty.lensStatus) != CanonProperty.lensNotAttached
            && propertyValue(CanonProperty.focusMode) != CanonProperty.focusModeManual
    }

    var canFocusAtPoint: Bool {
        canAutofocus && supports(CanonOperation.zoomPosition)
            && propertyValue(CanonProperty.liveViewAFMethod) == CanonProperty.afMethodOnePoint
            && latestFrame.map { Self.sensorPoint(.zero, in: $0.metadata) != nil } ?? false
    }

    private func autofocusUnavailable() -> CameraError {
        if !isLiveView { return CameraError(.liveViewUnavailable, "Autofocus needs live view.") }
        if propertyValue(CanonProperty.lensStatus) == CanonProperty.lensNotAttached {
            return CameraError(.protocolViolation, "Attach a lens to autofocus.")
        }
        if propertyValue(CanonProperty.focusMode) == CanonProperty.focusModeManual {
            return CameraError(.protocolViolation, "The lens is set to manual focus. Set its switch to AF.")
        }
        return CameraError(.protocolViolation, "This camera can't autofocus over USB.", detail: "DoAf (0x9154) not listed")
    }

    /// Polls the latest live-view frame (fed by the streaming loop) until `condition` holds or the
    /// timeout passes. Sleeping here does not block frames: actor calls interleave at each await.
    @discardableResult
    private func waitForFrame(after startSequence: UInt64? = nil, timeout: Duration,
                              _ condition: (CanonViewfinderMetadata) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        var checked = startSequence ?? sequence
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if sequence > checked, let frame = latestFrame {
                checked = sequence
                if condition(frame.metadata) { return true }
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return false
    }

    // MARK: Geometry (pure; docs/canon-eos-ptp.md §11.4)

    /// The sensor area the live-view JPEG shows. Block 0x12 is its origin plus the size of the area
    /// shown: at 1× and 5× that is the whole JPEG (0,298 5976×3356 as 1024×576; a 1200×800 crop as
    /// 1200×800 — SL2 verified). At 10× the body still sends the 5× image (EDSDK Evf_Zoom note; the SL2
    /// reports a 600×400 area with a 1200×800 JPEG), so the JPEG covers twice the reported size.
    static func frameArea(_ metadata: CanonViewfinderMetadata) -> CanonViewfinderMetadata.Rect? {
        guard var area = metadata.zoomRect, area.width > 0, area.height > 0 else { return nil }
        if let magnification = metadata.magnification, magnification > 5 {
            area.width = area.width * magnification / 5
            area.height = area.height * magnification / 5
        }
        return area
    }

    /// Sensor pixel under a normalized point of the live-view frame.
    static func sensorPoint(_ point: CGPoint, in metadata: CanonViewfinderMetadata) -> CGPoint? {
        guard let area = frameArea(metadata), metadata.sensorSize != nil else { return nil }
        let x = min(max(point.x, 0), 1), y = min(max(point.y, 0), 1)
        return CGPoint(x: Double(area.x) + x * Double(area.width), y: Double(area.y) + y * Double(area.height))
    }

    /// Magnifier (and 1-point AF frame) size: the camera's own block 0xD when it reports one, else a
    /// fifth of the sensor (EDSDK Evf_ZoomPosition note; matches the SL2's 1200×800 of 5976×3952).
    static func magnifierSize(metadata: CanonViewfinderMetadata) -> CanonViewfinderMetadata.Size {
        if let rect = metadata.magnifierRect, rect.width > 0, rect.height > 0 {
            return .init(width: rect.width, height: rect.height)
        }
        let sensor = metadata.sensorSize ?? .init(width: 0, height: 0)
        return .init(width: sensor.width / 5, height: sensor.height / 5)
    }

    /// ZoomPosition parameters (top-left of the magnifier, sensor pixels) that centre a magnifier of
    /// `size` on `point`, clamped to the sensor. Positions beyond `sensor − size` are discarded by the
    /// body rather than clamped (FC.SDK, 6D), so they are never sent; the body clamps further itself.
    static func magnifierOrigin(centeredAt point: CGPoint, metadata: CanonViewfinderMetadata,
                                size: CanonViewfinderMetadata.Size) -> (x: UInt32, y: UInt32)? {
        guard let sensor = metadata.sensorSize, let center = sensorPoint(point, in: metadata),
              size.width > 0, size.height > 0, size.width <= sensor.width, size.height <= sensor.height
        else { return nil }
        let maxX = Double(sensor.width - size.width), maxY = Double(sensor.height - size.height)
        let x = min(max(center.x - Double(size.width) / 2, 0), maxX)
        let y = min(max(center.y - Double(size.height) / 2, 0), maxY)
        return (UInt32(x.rounded()), UInt32(y.rounded()))
    }

    /// The body rounds positions to its own step (the SL2 landed 1000 on 980).
    static func isNear(_ rect: CanonViewfinderMetadata.Rect, _ origin: (x: UInt32, y: UInt32)) -> Bool {
        abs(Int(rect.x) - Int(origin.x)) <= 64 && abs(Int(rect.y) - Int(origin.y)) <= 64
    }

    // MARK: Errors

    enum ControlAction { case changeSetting, focus, zoom, takePhoto }

    /// A camera refusal as a user-facing error; the response code goes to `detail`.
    static func refusal(_ code: PTPResponseCode, action: ControlAction, context: String) -> CameraError {
        let detail = "\(context): \(CanonResponse.describe(code))"
        switch code {
        case .deviceBusy:
            let message = switch action {
            case .changeSetting: "The camera is busy or doesn't allow this change in its current mode."
            case .focus: "The camera is busy and could not focus. Try again in a moment."
            case .zoom: "The camera is busy and could not zoom. Try again in a moment."
            case .takePhoto: "The camera is busy and did not take the photo. Try again in a moment."
            }
            return CameraError(.protocolViolation, message, detail: detail)
        case CanonResponse.operationRefused:
            return CameraError(.protocolViolation, "The camera refused. Check that it is in a shooting mode and not showing a menu.", detail: detail)
        case .invalidDevicePropValue:
            return CameraError(.protocolViolation, "The camera doesn't accept that value.", detail: detail)
        case CanonResponse.lowBattery:
            return CameraError(.protocolViolation, "The camera's battery is too low.", detail: detail)
        case CanonResponse.lensCoverClosed:
            return CameraError(.protocolViolation, "The lens cover is closed.", detail: detail)
        default:
            return CameraError(.protocolViolation, "The camera rejected the command.", detail: detail)
        }
    }

    static func releaseFailure(_ result: UInt32) -> CameraError {
        let detail = "RemoteReleaseOn full press result \(hex(result))"
        if let failure = CanonReleaseFailure(rawValue: result) {
            return CameraError(.protocolViolation, failure.message, detail: detail)
        }
        // The SL2 answers 0xC in every mode tried; no reference names it (docs §11.6).
        return CameraError(.protocolViolation, "The camera did not take the photo. Check the camera's screen for a message.", detail: detail)
    }

    static func controlError(_ error: any Error, context: String) -> CameraError {
        switch error {
        case let error as CameraError: error
        case let error as PTPError: map(error, context: context)
        default: CameraError(.cancelled, "Cancelled.", detail: context)
        }
    }
}
