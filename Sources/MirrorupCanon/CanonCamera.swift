public import Foundation
public import MirrorupPTP
public import MirrorupCapture
import MirrorupDevices
import MirrorupDiagnostics

/// Canon EOS live-view backend. Owns the PTP session and all Canon-specific state; serializes
/// device access by being an actor (and through `PTPSession`'s transaction gate).
public actor CanonCamera: CameraBackend, LiveViewPolling, RawPayloadRecording, CameraScreenSharing {
    public struct Options: Sendable {
        /// Pause between GetViewfinderData polls while the camera answers "not ready".
        public var notReadyRetryInterval: Duration = .milliseconds(3)
        /// Live view is considered lost if no frame arrives for this long (covers the mirror-up delay
        /// before the first frame, ~1.2 s on similar bodies).
        public var frameTimeout: Duration = .seconds(3)
        /// How often GetEvent is drained while streaming.
        public var eventPollInterval: Duration = .milliseconds(250)
        /// KeepDeviceOn cadence (only if the camera lists 0x911D).
        public var keepAliveInterval: Duration = .seconds(10)
        public var commandTimeout: Duration = .seconds(5)
        /// GetViewfinderData parameters (docs/canon-eos-ptp.md §4).
        public var viewfinderParameters: [UInt32] = [0x0020_0000, 0, 0]
        /// Longest wait for a property write to come back as a PropValueChanged event.
        public var settingConfirmationTimeout: Duration = .seconds(1)
        /// Longest wait for live-view frames to show a moved AF point or a new magnification.
        public var frameConfirmationTimeout: Duration = .seconds(1)
        /// Longest DoAf hold before AfCancel releases it (the SL2 rejects other writes while AF is held).
        public var autofocusTimeout: Duration = .seconds(2)
        /// Longest wait for the shutter to produce a new file on the card.
        public var photoTimeout: Duration = .seconds(15)
        /// GetObject budget for a full-resolution file (several to tens of MB over USB 2).
        public var photoDownloadTimeout: Duration = .seconds(60)

        public init() {}
    }

    enum State {
        case disconnected
        case connected
        case liveView(savedOutput: UInt32, savedEVFMode: UInt32?)
    }

    public nonisolated let session: PTPSession
    let options: Options
    private var baseIdentity: CameraIdentity
    private(set) var state = State.disconnected
    private(set) var deviceInfo: PTPDeviceInfo?
    public private(set) var properties = CanonPropertyCache()
    private(set) var sequence: UInt64 = 0
    private var lastFrameTime = ContinuousClock.now
    private var lastEventPoll = ContinuousClock.now
    private var lastKeepAlive = ContinuousClock.now
    private var keepAliveRequested = false
    /// Set when live view was re-armed after the body left PC output; cleared by the next frame.
    private var rearmedSinceLastFrame = false
    /// The user's choice to keep live view on the rear LCD while it streams to the PC.
    private var showsLiveViewOnCamera = false
    /// Typed metadata and JPEG of the latest live-view frame. Kept as parsed (no formatting) so the
    /// capture path stays cheap; `metadata()` formats it when someone asks.
    private(set) var latestFrame: CanonViewfinderFrame?
    /// True while the shutter cycle of `capturePhoto()` runs: the mirror drops and live view pauses, so
    /// frame polling and the frame timeout are suspended. The timeout restarts when it ends.
    var shutterCycleActive = false {
        didSet {
            lastFrameTime = .now
            if oldValue && !shutterCycleActive { shutterCycleEnded = .now }
        }
    }
    private var shutterCycleEnded: ContinuousClock.Instant?

    public var lastFramePause: ContinuousClock.Instant? { shutterCycleActive ? .now : shutterCycleEnded }
    /// Objects the camera announced (ObjectAddedEx / RequestObjectTransfer) while a capture collects
    /// them; nil when nobody is waiting for one, so a user shooting on the body costs nothing.
    var collectedObjects: [CanonObjectInfo]?
    /// Incremented by stopLiveView/disconnect so a suspended nextFrame notices it was superseded.
    private var epoch: UInt64 = 0
    /// GetViewfinderData accounting for benchmarks and diagnostics.
    public private(set) var pollStatistics = LiveViewPollStatistics()
    /// The first GetEvent data phase ("getevent-initial") and the latest GetViewfinderData payload
    /// ("evf"), as received, for `mirrorup ptp dump`. Bounded: one of each; the EVF buffer is the
    /// one `latestFrame` already references.
    public private(set) var rawPayloads: [String: Data] = [:]

    public init(session: PTPSession, identity: CameraIdentity, options: Options = Options()) {
        self.session = session
        self.baseIdentity = identity
        self.options = options
    }

    public var identity: CameraIdentity {
        var id = baseIdentity
        if let info = deviceInfo {
            id.model = info.model
            // The camera's own model string ("Canon EOS Rebel SL2") beats the USB product string
            // ("Canon Digital Camera") used before connecting.
            if !info.model.isEmpty { id.name = info.model }
            id.serialNumber = info.serialNumber.isEmpty ? nil : info.serialNumber
        }
        return id
    }

    public var info: PTPDeviceInfo? { deviceInfo }

    // MARK: Metadata

    /// Identity and capabilities from DeviceInfo plus every property the camera has reported through
    /// GetEvent, each decoded by `CanonCatalog`. Nothing the camera reports is left out; codes no
    /// public source documents are included with `isDocumented == false`.
    public func metadata() -> CameraMetadata {
        var sections: [CameraMetadata.SectionKind: [CameraMetadata.Item]] = [:]
        func add(_ item: CameraMetadata.Item, to section: CameraMetadata.SectionKind) {
            sections[section, default: []].append(item)
        }

        let id = identity
        add(.init(.transport, value: id.transport, raw: id.transport), to: .device)
        if let info = deviceInfo {
            add(.init(.manufacturer, value: info.manufacturer, raw: info.manufacturer), to: .device)
            add(.init(.model, value: info.model, raw: info.model), to: .device)
            add(.init(.firmwareVersion, value: Self.firmwareVersion(info.deviceVersion), raw: info.deviceVersion), to: .device)
            if !info.serialNumber.isEmpty {
                add(.init(.serialNumber, value: info.serialNumber, raw: info.serialNumber), to: .device)
            }
            let ptpVersion = String(format: "%d.%02d", info.standardVersion / 100, info.standardVersion % 100)
            add(.init(.protocolVersion, value: ptpVersion, raw: String(info.standardVersion)), to: .device)
            let vendor = info.vendorExtensionName ?? "Vendor \(Self.hex(info.vendorExtensionID))"
            let vendorValue = info.vendorExtensionDescription.isEmpty ? "\(vendor), version \(info.vendorExtensionVersion)"
                : "\(vendor), version \(info.vendorExtensionVersion): \(info.vendorExtensionDescription)"
            add(.init(.vendorExtension, value: vendorValue, raw: Self.hex(info.vendorExtensionID)), to: .device)

            func list(_ kind: CameraMetadata.ItemKind, _ codes: [UInt16], name: (UInt16) -> String?) {
                let names = codes.map { code in name(code).map { "\($0) (\(Self.hex(code)))" } ?? Self.hex(code) }
                add(.init(kind, value: names.isEmpty ? "None" : names.joined(separator: ", "),
                          raw: codes.map { Self.hex($0) }.joined(separator: " ")), to: .capabilities)
            }
            list(.supportedOperations, info.operationsSupported, name: CanonCatalog.operationName)
            list(.supportedEvents, info.eventsSupported) { CanonCatalog.eventName(UInt32($0)) }
            list(.supportedProperties, info.devicePropertiesSupported, name: PTPCatalog.propertyName)
            list(.supportedCaptureFormats, info.captureFormats, name: CanonCatalog.objectFormatName)
            list(.supportedImageFormats, info.imageFormats, name: CanonCatalog.objectFormatName)
        }

        for (code, value) in properties.values.sorted(by: { $0.key < $1.key }) {
            var item = CanonCatalog.describe(property: code, value: value)
            if let allowed = properties.allowedValues[code], !allowed.isEmpty {
                item.allowedValues = CanonCatalog.describeAllowedValues(property: code, values: allowed)
            }
            add(item, to: CanonCatalog.section(forProperty: code))
        }

        if let frame = latestFrame {
            let size = CanonViewfinderParser.jpegDimensions(frame.jpeg)
            for item in frame.metadata.items(frameWidth: size?.width, frameHeight: size?.height) {
                add(item, to: .frame)
            }
        }

        return CameraMetadata(sections: sections
            .sorted { $0.key < $1.key }
            .map { CameraMetadata.Section($0.key, items: $0.value) })
    }

    /// DeviceInfo reports e.g. "3-1.1.0"; the user-facing firmware version is the part after the dash.
    static func firmwareVersion(_ deviceVersion: String) -> String {
        guard let dash = deviceVersion.firstIndex(of: "-") else { return deviceVersion }
        return String(deviceVersion[deviceVersion.index(after: dash)...])
    }

    static func hex<T: BinaryInteger>(_ value: T) -> String {
        "0x" + String(value, radix: 16, uppercase: true)
    }

    // MARK: Connection

    public func connect() async throws(CameraError) {
        guard case .disconnected = state else { return }
        do {
            try await session.open()
            let info = try await session.deviceInfo()
            deviceInfo = info
            try Self.validate(info)
            Diagnostics.canon.info("connected: \(info.model, privacy: .public) fw \(info.deviceVersion, privacy: .public)")

            if info.supports(CanonOperation.setRemoteMode) {
                try await session.execute(PTPCommand(CanonOperation.setRemoteMode, [1]), timeout: options.commandTimeout)
            }
            try await session.execute(PTPCommand(CanonOperation.setEventMode, [1]), timeout: options.commandTimeout)
            try await drainEvents()
            // EVFOutputDevice must be known before live view can be armed; the body reports it in
            // its initial event dump, sometimes a little later (docs §2, step 7).
            var attempts = 0
            while properties[CanonProperty.evfOutputDevice] == nil && attempts < 10 {
                attempts += 1
                try await Task.sleep(for: .milliseconds(50))
                try await drainEvents()
            }
            guard properties[CanonProperty.evfOutputDevice] != nil else {
                throw CameraError(.liveViewUnavailable, "The camera did not report its live-view settings.",
                                  detail: "EVFOutputDevice (0xD1B0) missing from GetEvent after 10 drains")
            }
            state = .connected
            lastKeepAlive = .now
        } catch let error as CameraError {
            await session.close()
            throw error
        } catch let error as PTPError {
            await session.close()
            throw Self.map(error, context: "connect")
        } catch {
            await session.close()
            throw CameraError(.cancelled, "Connection cancelled.")
        }
    }

    public func disconnect() async {
        epoch &+= 1
        if case .liveView = state {
            do { try await stopLiveView() } catch {
                Diagnostics.canon.notice("stopLiveView during disconnect failed: \(error.description, privacy: .public)")
            }
        }
        if case .disconnected = state {
            await session.close()
            return
        }
        // Hand the camera back to local control. Short timeouts: the camera may already be gone.
        // The final SetRemoteMode(1) is libgphoto2's "switch the display back on" step for every
        // regular EOS body: without it a 7D stays "Busy" (MENU refused) after PC live view
        // (docs §9.4, §12).
        let handBack: [(PTPOperationCode, UInt32)] = [
            (CanonOperation.setEventMode, 0), (CanonOperation.setRemoteMode, 0), (CanonOperation.setRemoteMode, 1),
        ]
        for (op, param) in handBack {
            do {
                try await session.execute(PTPCommand(op, [param]), timeout: .seconds(1))
            } catch {
                Diagnostics.canon.notice("\(op.description, privacy: .public)(\(param)) during disconnect failed: \(error.description, privacy: .public)")
                if error.transportError != nil { break }
            }
        }
        state = .disconnected
        await session.close()
        Diagnostics.canon.info("disconnected")
    }

    // MARK: Live view

    public func startLiveView() async throws(CameraError) {
        switch state {
        case .disconnected:
            throw CameraError(.disconnected, "The camera is not connected.")
        case .liveView:
            return
        case .connected:
            break
        }
        do {
            let savedOutput = properties[CanonProperty.evfOutputDevice]?.integer ?? 0
            let savedMode = properties[CanonProperty.evfMode]?.integer
            if savedMode == 0 {
                // EVF disabled on the body; enable it. DeviceBusy is accepted (docs §3.2).
                let r = try await session.transact(
                    PTPCommand(CanonOperation.setDevicePropValueEx),
                    dataOut: CanonPropertyEncoding.integerPayload(property: CanonProperty.evfMode, value: 1),
                    timeout: options.commandTimeout)
                guard r.response.code == .ok || r.response.code == .deviceBusy else {
                    throw PTPError.response(r.response.code, operation: CanonOperation.setDevicePropValueEx)
                }
            }
            if savedOutput & CanonProperty.evfOutputRouting != liveViewOutput {
                try await applyLiveViewOutput()
            }
            if let info = deviceInfo, info.supports(CanonOperation.initiateViewfinder) {
                try await session.execute(PTPCommand(CanonOperation.initiateViewfinder), timeout: options.commandTimeout)
            }
            try await drainEvents()
            state = .liveView(savedOutput: savedOutput, savedEVFMode: savedMode == 0 ? 0 : nil)
            sequence = 0
            lastFrameTime = .now
            lastEventPoll = .now
            Diagnostics.canon.info("live view armed (saved EVFOutputDevice=0x\(String(savedOutput, radix: 16), privacy: .public))")
        } catch let error as PTPError {
            throw Self.map(error, context: "start live view", liveView: true)
        } catch {
            throw CameraError(.cancelled, "Live view start cancelled.")
        }
    }

    public func stopLiveView() async throws(CameraError) {
        guard case .liveView(let savedOutput, let savedMode) = state else { return }
        epoch &+= 1
        latestFrame = nil
        state = .connected
        do {
            if let info = deviceInfo, info.supports(CanonOperation.terminateViewfinder) {
                try await session.execute(PTPCommand(CanonOperation.terminateViewfinder), timeout: options.commandTimeout)
            }
            // Hand output back to the camera: clear the PC bit, keep the rest of the user's routing.
            // The saved value can already contain PC (a previous host process died mid-stream; seen as
            // 0x3 on the SL2) or be 0 (we connected while the body was powering down). Neither may be
            // restored verbatim, so fall back to the rear LCD, the body's idle value.
            let restore = savedOutput & ~CanonProperty.evfOutputPC
            try await setEVFOutput(restore == 0 ? CanonProperty.evfOutputTFT : restore)
            if let savedMode {
                _ = try await session.transact(
                    PTPCommand(CanonOperation.setDevicePropValueEx),
                    dataOut: CanonPropertyEncoding.integerPayload(property: CanonProperty.evfMode, value: savedMode),
                    timeout: options.commandTimeout)
            }
            try await drainEvents()
            Diagnostics.canon.info("live view stopped")
        } catch {
            throw Self.map(error, context: "stop live view")
        }
    }

    public func nextFrame() async throws(CameraError) -> CameraFrame {
        guard case .liveView = state else {
            throw CameraError(.liveViewUnavailable, "Live view is not running.")
        }
        let myEpoch = epoch
        do {
            while true {
                try Task.checkCancellation()
                guard epoch == myEpoch else { throw CameraError(.cancelled, "Live view was stopped.") }
                if shutterCycleActive {
                    // The shutter owns the camera; GetViewfinderData would only answer busy.
                    try await Task.sleep(for: .milliseconds(20))
                    continue
                }
                try await housekeeping()

                let start = HostTime.now()
                let result = try await session.transact(
                    PTPCommand(CanonOperation.getViewfinderData, options.viewfinderParameters),
                    timeout: options.commandTimeout)
                let end = HostTime.now()
                pollStatistics.requests += 1
                guard epoch == myEpoch else { throw CameraError(.cancelled, "Live view was stopped.") }

                switch result.response.code {
                case .ok:
                    let parsed: CanonViewfinderFrame
                    do {
                        parsed = try CanonViewfinderParser.parse(result.data)
                    } catch {
                        pollStatistics.invalidPayloads += 1
                        lastFrameTime = .now  // the camera is delivering; only this payload is bad
                        throw CameraError(.invalidFrame, "The camera sent an unreadable frame.", detail: error.description)
                    }
                    sequence += 1
                    rearmedSinceLastFrame = false
                    pollStatistics.frames += 1
                    pollStatistics.payloadBytes += result.data.count
                    rawPayloads["evf"] = result.data
                    lastFrameTime = .now
                    latestFrame = parsed
                    return CameraFrame(sequence: sequence, jpeg: parsed.jpeg, acquisitionStart: start, acquisitionEnd: end,
                                       settingsRevision: properties.revision)
                case CanonResponse.objectNotReady, .deviceBusy:
                    pollStatistics.notReady += 1
                    if ContinuousClock.now - lastFrameTime > options.frameTimeout {
                        let detail = "no frame for \(options.frameTimeout); last response \(CanonResponse.describe(result.response.code))"
                        // The 7D in movie mode acknowledges EVFOutputDevice = PC but never echoes it
                        // and never serves a frame (docs §12). The SL2 streams in movie mode and
                        // echoes the write, so all three conditions must hold.
                        let pcConfirmed = (properties[CanonProperty.evfOutputDevice]?.integer ?? 0) & CanonProperty.evfOutputPC != 0
                        if sequence == 0, isInMovieMode, !pcConfirmed {
                            throw CameraError(.liveViewUnavailable, Self.movieModeLiveViewMessage,
                                              detail: "\(detail); FixedMovie 0xD1C2 = 1")
                        }
                        throw CameraError(.timeout, "The camera stopped sending live view.", detail: detail)
                    }
                    try await Task.sleep(for: options.notReadyRetryInterval)
                default:
                    throw CameraError(.liveViewUnavailable, "The camera refused live view.",
                                      detail: "GetViewfinderData -> \(CanonResponse.describe(result.response.code))")
                }
            }
        } catch let error as CameraError {
            throw error
        } catch let error as PTPError {
            throw Self.map(error, context: "get frame")
        } catch {
            throw CameraError(.cancelled, "Frame request cancelled.")
        }
    }

    // MARK: Internals

    /// Periodic GetEvent drain (property tracking, shutdown warnings) and KeepDeviceOn.
    private func housekeeping() async throws(PTPError) {
        let now = ContinuousClock.now
        if now - lastEventPoll >= options.eventPollInterval {
            lastEventPoll = now
            try await drainEvents()
            // The user can kick the body out of PC live view (menu, playback, mode dial).
            // Re-arm once per frame drought: a body that is powering down keeps reporting 0 and must
            // be left to the frame timeout, not rewritten on every event poll.
            if case .liveView = state, !rearmedSinceLastFrame,
               let output = properties[CanonProperty.evfOutputDevice]?.integer, output & CanonProperty.evfOutputPC == 0 {
                Diagnostics.canon.notice("camera left PC live view (EVFOutputDevice=0x\(String(output, radix: 16), privacy: .public)); re-arming")
                rearmedSinceLastFrame = true
                try await applyLiveViewOutput()
            }
        }
        if let info = deviceInfo, info.supports(CanonOperation.keepDeviceOn),
           keepAliveRequested || now - lastKeepAlive >= options.keepAliveInterval {
            lastKeepAlive = now
            keepAliveRequested = false
            let r = try await session.transact(PTPCommand(CanonOperation.keepDeviceOn), timeout: options.commandTimeout)
            if r.response.code != .ok {
                Diagnostics.canon.notice("KeepDeviceOn -> \(CanonResponse.describe(r.response.code), privacy: .public)")
            }
        }
    }

    private func setEVFOutput(_ value: UInt32) async throws(PTPError) {
        try await session.execute(
            PTPCommand(CanonOperation.setDevicePropValueEx),
            dataOut: CanonPropertyEncoding.integerPayload(property: CanonProperty.evfOutputDevice, value: value),
            timeout: options.commandTimeout)
    }

    /// EVFOutputDevice while streaming: the PC, plus the rear LCD when the user asked for it.
    private var liveViewOutput: UInt32 {
        CanonProperty.evfOutputPC | (showsLiveViewOnCamera ? CanonProperty.evfOutputTFT : 0)
    }

    /// Writes `liveViewOutput`. A body that refuses the rear LCD next to the PC streams to the PC only
    /// (the SL2 accepts 0x3; docs/canon-eos-ptp.md §3.1).
    private func applyLiveViewOutput() async throws(PTPError) {
        let wanted = liveViewOutput
        do {
            try await setEVFOutput(wanted)
        } catch {
            guard wanted != CanonProperty.evfOutputPC, case .response(let code, _) = error else { throw error }
            Diagnostics.canon.notice("EVFOutputDevice=0x\(String(wanted, radix: 16), privacy: .public) refused (\(CanonResponse.describe(code), privacy: .public)); streaming to the PC only")
            try await setEVFOutput(CanonProperty.evfOutputPC)
        }
    }

    public func setShowsLiveViewOnCamera(_ shows: Bool) async throws(CameraError) {
        showsLiveViewOnCamera = shows
        guard case .liveView = state else { return }
        do {
            try await applyLiveViewOutput()
            try await drainEvents()
        } catch {
            throw Self.map(error, context: shows ? "show live view on the rear LCD" : "hide live view on the rear LCD")
        }
    }

    /// GetEvent until the camera reports nothing new (bounded).
    func drainEvents() async throws(PTPError) {
        for _ in 0..<50 {
            let result = try await session.execute(PTPCommand(CanonOperation.getEvent), timeout: options.commandTimeout)
            if rawPayloads["getevent-initial"] == nil { rawPayloads["getevent-initial"] = result.data }
            let events = try CanonEventParser.parse(result.data)
            if events.isEmpty { return }
            properties.apply(events)
            for event in events {
                switch event {
                case .willSoonShutdown, .shutdownTimerUpdated:
                    keepAliveRequested = true
                case .cameraStatusChanged(let status):
                    Diagnostics.canon.debug("camera status \(status)")
                case .objectAdded(let object), .objectTransferRequested(let object):
                    // Bounded: a capture takes the first file; RAW+JPEG adds a second.
                    if var list = collectedObjects, list.count < 8 {
                        list.append(object)
                        collectedObjects = list
                    }
                default:
                    break
                }
            }
        }
        Diagnostics.canon.notice("GetEvent drain hit its iteration bound")
    }

    /// Movie mode is the Live View/Movie switch on bodies that have one (7D), the power switch on others.
    static let movieModeLiveViewMessage =
        "The camera is in movie mode and isn't sending live view. Set its Live View/Movie switch (or power switch) to the stills position."

    static func validate(_ info: PTPDeviceInfo) throws(CameraError) {
        // Canon bodies report either Canon's or Microsoft's vendor extension ID (the SL2 reports
        // Microsoft's), so identify by manufacturer and the operations live view needs.
        guard info.manufacturer.lowercased().hasPrefix("canon") else {
            throw CameraError(.unsupported, "\(info.model.isEmpty ? "This camera" : info.model) is not a Canon EOS camera.",
                              detail: "manufacturer \(info.manufacturer)")
        }
        let required = [CanonOperation.getViewfinderData, CanonOperation.setDevicePropValueEx, CanonOperation.getEvent, CanonOperation.setEventMode]
        let missing = required.filter { !info.supports($0) }
        guard missing.isEmpty else {
            throw CameraError(.unsupported, "\(info.model.isEmpty ? "This camera" : info.model) can't stream live view over USB.",
                              detail: "missing operations: \(missing.map(\.description).joined(separator: ", "))")
        }
    }

    static func map(_ error: PTPError, context: String, liveView: Bool = false) -> CameraError {
        if liveView, case .response(let code, _) = error {
            return CameraError(.liveViewUnavailable, "The camera could not enter live view. Check that it is in a shooting mode and not showing a menu.",
                               detail: "\(context): \(CanonResponse.describe(code))")
        }
        return CameraError(ptp: error, context: context, describeResponse: CanonResponse.describe)
    }
}
