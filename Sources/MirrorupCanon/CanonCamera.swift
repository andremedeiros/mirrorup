import Foundation
public import MirrorupPTP
public import MirrorupCapture
import MirrorupDiagnostics

/// Canon EOS live-view backend. Owns the PTP session and all Canon-specific state; serializes
/// device access by being an actor (and through `PTPSession`'s transaction gate).
public actor CanonCamera: CameraBackend {
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

        public init() {}
    }

    private enum State {
        case disconnected
        case connected
        case liveView(savedOutput: UInt32, savedEVFMode: UInt32?)
    }

    public nonisolated let session: PTPSession
    private let options: Options
    private var baseIdentity: CameraIdentity
    private var state = State.disconnected
    private(set) var deviceInfo: PTPDeviceInfo?
    public private(set) var properties = CanonPropertyCache()
    private var sequence: UInt64 = 0
    private var lastFrameTime = ContinuousClock.now
    private var lastEventPoll = ContinuousClock.now
    private var lastKeepAlive = ContinuousClock.now
    private var keepAliveRequested = false
    /// Set when live view was re-armed after the body left PC output; cleared by the next frame.
    private var rearmedSinceLastFrame = false
    /// Incremented by stopLiveView/disconnect so a suspended nextFrame notices it was superseded.
    private var epoch: UInt64 = 0
    public private(set) var pollStatistics = PollStatistics()

    /// GetViewfinderData accounting for benchmarks and diagnostics.
    public struct PollStatistics: Sendable, Equatable {
        public var requests = 0
        public var frames = 0
        public var notReady = 0
        public var invalidPayloads = 0
        public var payloadBytes = 0
    }

    public init(session: PTPSession, identity: CameraIdentity, options: Options = Options()) {
        self.session = session
        self.baseIdentity = identity
        self.options = options
    }

    public var identity: CameraIdentity {
        var id = baseIdentity
        if let info = deviceInfo {
            id.model = info.model
            id.serialNumber = info.serialNumber.isEmpty ? nil : info.serialNumber
        }
        return id
    }

    public var info: PTPDeviceInfo? { deviceInfo }

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
        for (op, param) in [(CanonOperation.setEventMode, UInt32(0)), (CanonOperation.setRemoteMode, UInt32(0))] {
            do {
                try await session.execute(PTPCommand(op, [param]), timeout: .seconds(1))
            } catch {
                Diagnostics.canon.notice("\(op.description, privacy: .public)(0) during disconnect failed: \(error.description, privacy: .public)")
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
            if savedOutput & CanonProperty.evfOutputPC == 0 {
                try await setEVFOutput(CanonProperty.evfOutputPC)
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
                    lastFrameTime = .now
                    return CameraFrame(sequence: sequence, jpeg: parsed.jpeg, acquisitionStart: start, acquisitionEnd: end)
                case CanonResponse.objectNotReady, .deviceBusy:
                    pollStatistics.notReady += 1
                    if ContinuousClock.now - lastFrameTime > options.frameTimeout {
                        throw CameraError(.timeout, "The camera stopped sending live view.",
                                          detail: "no frame for \(options.frameTimeout); last response \(CanonResponse.describe(result.response.code))")
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
                try await setEVFOutput(output | CanonProperty.evfOutputPC)
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

    /// GetEvent until the camera reports nothing new (bounded).
    private func drainEvents() async throws(PTPError) {
        for _ in 0..<50 {
            let result = try await session.execute(PTPCommand(CanonOperation.getEvent), timeout: options.commandTimeout)
            let events = try CanonEventParser.parse(result.data)
            if events.isEmpty { return }
            properties.apply(events)
            for event in events {
                switch event {
                case .willSoonShutdown, .shutdownTimerUpdated:
                    keepAliveRequested = true
                case .cameraStatusChanged(let status):
                    Diagnostics.canon.debug("camera status \(status)")
                default:
                    break
                }
            }
        }
        Diagnostics.canon.notice("GetEvent drain hit its iteration bound")
    }

    static func validate(_ info: PTPDeviceInfo) throws(CameraError) {
        // Canon bodies report either Canon's or Microsoft's vendor extension ID (the SL2 reports
        // Microsoft's), so identify by manufacturer and the operations live view needs.
        guard info.manufacturer.lowercased().hasPrefix("canon") else {
            throw CameraError(.liveViewUnavailable, "This camera is not a Canon EOS camera.", detail: "manufacturer \(info.manufacturer)")
        }
        let required = [CanonOperation.getViewfinderData, CanonOperation.setDevicePropValueEx, CanonOperation.getEvent, CanonOperation.setEventMode]
        let missing = required.filter { !info.supports($0) }
        guard missing.isEmpty else {
            throw CameraError(.liveViewUnavailable, "This camera does not support live view over USB.",
                              detail: "missing operations: \(missing.map(\.description).joined(separator: ", "))")
        }
    }

    static func map(_ error: PTPError, context: String, liveView: Bool = false) -> CameraError {
        let detail = "\(context): \(error.description)"
        switch error {
        case .transport(let t):
            switch t {
            case .disconnected, .notOpen:
                return CameraError(.disconnected, "The camera was disconnected.", detail: detail)
            case .timedOut:
                return CameraError(.timeout, "The camera stopped responding.", detail: detail)
            case .exclusiveAccess:
                return CameraError(.inUseByAnotherApplication, "Another application is using the camera.", detail: detail)
            case .accessDenied:
                return CameraError(.accessDenied, "Mirrorup is not allowed to control the camera.", detail: detail)
            case .cancelled:
                return CameraError(.cancelled, "Cancelled.", detail: detail)
            case .io:
                return CameraError(.protocolViolation, "Communication with the camera failed.", detail: detail)
            }
        case .response(let code, _) where liveView:
            return CameraError(.liveViewUnavailable, "The camera could not enter live view. Check that it is in a shooting mode and not showing a menu.",
                               detail: "\(context): \(CanonResponse.describe(code))")
        case .response(let code, _):
            return CameraError(.protocolViolation, "The camera rejected a command.", detail: "\(context): \(CanonResponse.describe(code))")
        case .sessionNotOpen:
            return CameraError(.disconnected, "The camera session is not open.", detail: detail)
        default:
            return CameraError(.protocolViolation, "The camera sent data Mirrorup does not understand.", detail: detail)
        }
    }
}
