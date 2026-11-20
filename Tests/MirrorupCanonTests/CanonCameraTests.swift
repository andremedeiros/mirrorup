import CoreVideo
import Foundation
import Synchronization
import Testing
import MirrorupCapture
import MirrorupPTP
@testable import MirrorupCanon

/// Simulates the SL2 at the PTP level using the real DeviceInfo/GetEvent/EVF captures.
final class SimulatedSL2: PTPTransport, Sendable {
    let sessionOwnership = PTPSessionOwnership.system

    struct State {
        var evfOutput: UInt32 = 1
        var pendingEvents: [Data] = []
        var log: [UInt16] = []
        var propertyWrites: [(UInt32, UInt32)] = []
        var viewfinderScript: [UInt16] = []  // response codes to return before frames flow
        var neverReady = false
        var disconnected = false
        var gvdDelay: Duration = .zero
        /// Every command with its parameters, for control tests.
        var commands: [(UInt16, [UInt32])] = []
        /// Response codes to answer instead of OK, per opcode (one-shot).
        var refusals: [UInt16: UInt16] = [:]
        /// When false, SetDevicePropValueEx is acknowledged but never echoed.
        var echoesPropertyWrites = true
        /// The next N writes that turn PC output on are echoed, then dropped again (0xD1B0 back to
        /// 0), as an SL2 does for a second or two after power-on.
        var dropsPCOutput = 0
        var storageIDs: [UInt32] = [0x0002_0001]
        /// First response parameter of a RemoteReleaseOn full press (0 = released).
        var releaseResult: UInt32 = 0
        /// GetEvent data queued when the full press is released (an ObjectAddedEx record).
        var objectEventOnRelease: Data?
        var objects: [UInt32: Data] = [:]
    }

    let state: Mutex<State>
    let deviceInfo: Data
    let evf: Data

    init(initialEvents: Data, deviceInfo: Data, evf: Data) {
        state = Mutex(State(pendingEvents: [initialEvents]))
        self.deviceInfo = deviceInfo
        self.evf = evf
    }

    func open() async throws(PTPTransportError) {}
    func close() async {}

    func execute(_ command: PTPCommand, transactionID: UInt32, dataOut: Data?, timeout: Duration) async throws(PTPError) -> PTPTransactionResult {
        let (disconnected, delay, refusal) = state.withLock { s -> (Bool, Duration?, PTPResponseCode?) in
            s.log.append(command.code.rawValue)
            s.commands.append((command.code.rawValue, command.parameters))
            if let refusal = s.refusals.removeValue(forKey: command.code.rawValue) {
                return (s.disconnected, Duration?.none, PTPResponseCode(refusal))
            }
            return (s.disconnected, command.code.rawValue == 0x9153 ? s.gvdDelay : .zero, PTPResponseCode?.none)
        }
        if disconnected { throw .transport(.disconnected("unplugged")) }
        if let refusal { return PTPTransactionResult(response: PTPResponse(code: refusal, transactionID: transactionID), data: Data()) }
        if let delay, delay > .zero { try? await Task.sleep(for: delay) }
        func ok(_ data: Data = Data()) -> PTPTransactionResult {
            PTPTransactionResult(response: PTPResponse(code: .ok, transactionID: transactionID), data: data)
        }
        switch command.code.rawValue {
        case 0x1001: return ok(deviceInfo)
        case 0x9114, 0x9115, 0x911D, 0x9154, 0x9160, 0x9158, 0x9159, 0x9117: return ok()
        case 0x9101:
            var w = PTPDataWriter()
            let ids = state.withLock { $0.storageIDs }
            w.u32(UInt32(ids.count))
            ids.forEach { w.u32($0) }
            return ok(w.data)
        case 0x9128:
            let result: UInt32 = command.parameters.first == 2 ? state.withLock { $0.releaseResult } : 0
            return PTPTransactionResult(response: PTPResponse(code: .ok, transactionID: transactionID, parameters: [result]), data: Data())
        case 0x9129:
            if command.parameters.first == 2 {
                state.withLock { s in
                    if s.releaseResult == 0, let event = s.objectEventOnRelease { s.pendingEvents.append(event) }
                }
            }
            return ok()
        case 0x1009:
            let handle = command.parameters.first ?? 0
            guard let data = state.withLock({ $0.objects[handle] }) else {
                return PTPTransactionResult(response: PTPResponse(code: .invalidObjectHandle, transactionID: transactionID), data: Data())
            }
            return ok(data)
        case 0x9116:
            let next = state.withLock { s in s.pendingEvents.isEmpty ? nil : s.pendingEvents.removeFirst() }
            return ok(next ?? Data([8, 0, 0, 0, 0, 0, 0, 0]))
        case 0x9110:
            var r = PTPDataReader(dataOut ?? Data())
            _ = try r.u32()
            let prop = try r.u32()
            let value = try r.u32()
            state.withLock { s in
                s.propertyWrites.append((prop, value))
                if prop == 0xD1B0 { s.evfOutput = value }
                guard s.echoesPropertyWrites else { return }
                var w = PTPDataWriter()
                w.u32(16); w.u32(0xC189); w.u32(prop); w.u32(value)
                w.u32(8); w.u32(0)
                s.pendingEvents.append(w.data)
                if prop == 0xD1B0, value & 2 != 0, s.dropsPCOutput > 0 {
                    s.dropsPCOutput -= 1
                    s.evfOutput = 0
                    var drop = PTPDataWriter()
                    drop.u32(16); drop.u32(0xC189); drop.u32(0xD1B0); drop.u32(0); drop.u32(8); drop.u32(0)
                    s.pendingEvents.append(drop.data)
                }
            }
            return ok()
        case 0x9153:
            let code: UInt16 = state.withLock { s in
                if s.evfOutput & 2 == 0 || s.neverReady { return 0xA102 }
                return s.viewfinderScript.isEmpty ? 0x2001 : s.viewfinderScript.removeFirst()
            }
            if code == 0x2001 { return ok(evf) }
            return PTPTransactionResult(response: PTPResponse(code: PTPResponseCode(code), transactionID: transactionID), data: Data())
        default:
            return PTPTransactionResult(response: PTPResponse(code: .operationNotSupported, transactionID: transactionID), data: Data())
        }
    }
}

private func fixture(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
        throw CocoaError(.fileNoSuchFile)
    }
    return try Data(contentsOf: url)
}

private func makeCamera(options: CanonCamera.Options = .init()) throws -> (CanonCamera, SimulatedSL2) {
    let sim = SimulatedSL2(
        initialEvents: try fixture("getevent-initial-sl2.bin"),
        deviceInfo: try fixture("deviceinfo-sl2.bin"),
        evf: try fixture("evf-sl2.bin")
    )
    let camera = CanonCamera(session: PTPSession(transport: sim), identity: CameraIdentity(name: "SL2", transport: "Simulated"), options: options)
    return (camera, sim)
}

@Suite struct CanonCameraTests {
    @Test func connectStartStreamStopFollowsVerifiedSequence() async throws {
        let (camera, sim) = try makeCamera()
        try await camera.connect()
        #expect(await camera.identity.model == "Canon EOS Rebel SL2")
        try await camera.startLiveView()
        let f1 = try await camera.nextFrame()
        let f2 = try await camera.nextFrame()
        #expect(f1.sequence == 1 && f2.sequence == 2)
        #expect(f1.jpeg.prefix(2) == Data([0xFF, 0xD8]))
        #expect(f1.acquisitionEnd >= f1.acquisitionStart)
        try await camera.stopLiveView()
        await camera.disconnect()

        let s = sim.state.withLock { $0 }
        // EVFOutputDevice: PC on start, restored to the idle value (rear LCD) on stop.
        #expect(s.propertyWrites.map { $0.0 } == [0xD1B0, 0xD1B0])
        #expect(s.propertyWrites.map { $0.1 } == [2, 1])
        // InitiateViewfinder/TerminateViewfinder are not listed by the SL2 and must not be sent.
        #expect(!s.log.contains(0x9151) && !s.log.contains(0x9152))
        #expect(s.log.prefix(3) == [0x1001, 0x9114, 0x9115])
        // Hand-back: SetEventMode(0), SetRemoteMode(0), then SetRemoteMode(1) to give the body its
        // display and buttons back (without it a 7D stays "Busy").
        let handBack = s.commands.suffix(3).map { "\(String($0.0, radix: 16))(\($0.1.first ?? 99))" }
        #expect(handBack == ["9115(0)", "9114(0)", "9114(1)"])
    }

    @Test func notReadyResponsesAreRetriedUntilAFrameArrives() async throws {
        let (camera, sim) = try makeCamera()
        try await camera.connect()
        try await camera.startLiveView()
        sim.state.withLock { $0.viewfinderScript = [0xA102, 0xA102, 0x2019, 0xA102] }
        let frame = try await camera.nextFrame()
        #expect(frame.sequence == 1)
        #expect(sim.state.withLock { $0.log.filter { $0 == 0x9153 }.count } == 5)
    }

    @Test func liveViewThatNeverBecomesReadyTimesOut() async throws {
        var options = CanonCamera.Options()
        options.frameTimeout = .milliseconds(150)
        let (camera, sim) = try makeCamera(options: options)
        try await camera.connect()
        try await camera.startLiveView()
        sim.state.withLock { $0.neverReady = true }
        let start = ContinuousClock.now
        await #expect(throws: CameraError.self) { try await camera.nextFrame() }
        do { _ = try await camera.nextFrame() } catch { #expect(error.kind == .timeout) }
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    /// The 7D in movie mode: EVFOutputDevice = PC is acknowledged but never echoed, and
    /// GetViewfinderData answers 0xA102 forever. (The SL2 fixture is already in movie mode, 0xD1C2 = 1.)
    @Test func liveViewThatNeverStartsInMovieModeNamesTheSwitch() async throws {
        var options = CanonCamera.Options()
        options.frameTimeout = .milliseconds(150)
        let (camera, sim) = try makeCamera(options: options)
        try await camera.connect()
        sim.state.withLock { s in
            s.echoesPropertyWrites = false
            s.neverReady = true
        }
        try await camera.startLiveView()
        do {
            _ = try await camera.nextFrame()
            Issue.record("expected failure")
        } catch {
            #expect(error.kind == .liveViewUnavailable)
            #expect(error.message.contains("Live View/Movie switch"))
            #expect(error.detail?.contains("0xD1C2 = 1") == true)
        }
    }

    @Test func unexpectedViewfinderResponseIsLiveViewUnavailable() async throws {
        let (camera, sim) = try makeCamera()
        try await camera.connect()
        try await camera.startLiveView()
        sim.state.withLock { $0.viewfinderScript = [0xA005] }
        do {
            _ = try await camera.nextFrame()
            Issue.record("expected failure")
        } catch {
            #expect(error.kind == .liveViewUnavailable)
            #expect(error.detail?.contains("Canon_OperationRefused") == true)
        }
    }

    @Test func unplugMapsToDisconnected() async throws {
        let (camera, sim) = try makeCamera()
        try await camera.connect()
        try await camera.startLiveView()
        sim.state.withLock { $0.disconnected = true }
        do {
            _ = try await camera.nextFrame()
            Issue.record("expected failure")
        } catch {
            #expect(error.kind == .disconnected)
            #expect(error.disposition == .waitForDevice)
        }
        await camera.disconnect()  // must not hang or throw on a dead camera
    }

    @Test func stopLiveViewWhileFrameRequestIsPendingEndsTheRequest() async throws {
        let (camera, sim) = try makeCamera()
        try await camera.connect()
        try await camera.startLiveView()
        sim.state.withLock { $0.neverReady = true }
        let pending = Task { try await camera.nextFrame() }
        try await Task.sleep(for: .milliseconds(30))
        try await camera.stopLiveView()
        do {
            _ = try await pending.value
            Issue.record("expected cancellation")
        } catch let error as CameraError {
            #expect(error.kind == .cancelled)
        }
    }

    @Test func cameraLeavingPCLiveViewIsReArmed() async throws {
        var options = CanonCamera.Options()
        options.eventPollInterval = .zero
        let (camera, sim) = try makeCamera(options: options)
        try await camera.connect()
        try await camera.startLiveView()
        _ = try await camera.nextFrame()
        // User opens the menu: body reports EVFOutputDevice back to TFT only. Re-arming restores the
        // user's routing (PC only by default), not whatever the body switched to.
        sim.state.withLock { s in
            s.evfOutput = 1
            var w = PTPDataWriter()
            w.u32(16); w.u32(0xC189); w.u32(0xD1B0); w.u32(1); w.u32(8); w.u32(0)
            s.pendingEvents.append(w.data)
        }
        _ = try await camera.nextFrame()
        #expect(sim.state.withLock { $0.propertyWrites.map(\.1) } == [2, 2])
    }

    /// Observed on the SL2: while powering down it keeps reporting EVFOutputDevice=0. Live view must
    /// be re-armed once, not on every event poll, and the frame timeout then ends the session.
    @Test func poweringDownBodyIsReArmedOnlyOnce() async throws {
        var options = CanonCamera.Options()
        options.eventPollInterval = .zero
        options.frameTimeout = .milliseconds(200)
        let (camera, sim) = try makeCamera(options: options)
        try await camera.connect()
        try await camera.startLiveView()
        _ = try await camera.nextFrame()
        sim.state.withLock { s in
            s.neverReady = true
            for _ in 0..<50 {
                var w = PTPDataWriter()
                w.u32(16); w.u32(0xC189); w.u32(0xD1B0); w.u32(0); w.u32(8); w.u32(0)
                s.pendingEvents.append(w.data)
            }
        }
        do {
            _ = try await camera.nextFrame()
            Issue.record("expected timeout")
        } catch {
            #expect(error.kind == .timeout)
        }
        #expect(sim.state.withLock { $0.propertyWrites.map(\.1) } == [2, 2])
    }

    /// Observed on the SL2 right after power-on (docs/canon-eos-ptp.md §9.2): the body echoes each
    /// 0xD1B0 write, then drops PC output again until it has settled (four writes on 2026-11-19).
    /// Before the first frame, live view is re-armed until a write sticks.
    @Test func bodySettlingAfterPowerOnIsReArmedUntilLiveViewSticks() async throws {
        var options = CanonCamera.Options()
        options.eventPollInterval = .zero
        let (camera, sim) = try makeCamera(options: options)
        sim.state.withLock { $0.dropsPCOutput = 3 }
        try await camera.connect()
        try await camera.startLiveView()
        _ = try await camera.nextFrame()
        #expect(sim.state.withLock { $0.propertyWrites.map(\.1) } == [2, 2, 2, 2])
    }

    @Test func reArmsBeforeTheFirstFrameAreBounded() async throws {
        var options = CanonCamera.Options()
        options.eventPollInterval = .zero
        options.frameTimeout = .milliseconds(200)
        options.startupRearmLimit = 3
        let (camera, sim) = try makeCamera(options: options)
        sim.state.withLock { $0.dropsPCOutput = .max }
        try await camera.connect()
        try await camera.startLiveView()
        // Gives up once the re-arms run out (the fixture body is in movie mode, so the error names it).
        await #expect(throws: CameraError.self) { _ = try await camera.nextFrame() }
        #expect(sim.state.withLock { $0.propertyWrites.map(\.1) } == [2, 2, 2, 2])
    }

    /// A body that never echoes the write (a 7D in movie mode) is not "settling": one re-arm, and the
    /// first-frame wait is not extended, so the movie-mode message arrives on time.
    @Test func bodyIgnoringTheWriteIsReArmedOnceBeforeTheFirstFrame() async throws {
        var options = CanonCamera.Options()
        options.eventPollInterval = .zero
        options.frameTimeout = .milliseconds(200)
        let (camera, sim) = try makeCamera(options: options)
        try await camera.connect()
        sim.state.withLock { s in
            s.echoesPropertyWrites = false
            s.neverReady = true
        }
        try await camera.startLiveView()
        let start = ContinuousClock.now
        await #expect(throws: CameraError.self) { _ = try await camera.nextFrame() }
        #expect(ContinuousClock.now - start < .seconds(1))
        // One re-arm, writing the user's routing (PC only by default), not the cached idle value | PC.
        #expect(sim.state.withLock { $0.propertyWrites.map(\.1) } == [2, 2])
    }

    @Test func savedOutputOfZeroRestoresRearLCD() async throws {
        let (camera, sim) = try makeCamera()
        sim.state.withLock { s in
            var w = PTPDataWriter()
            w.u32(16); w.u32(0xC189); w.u32(0xD1B0); w.u32(0); w.u32(8); w.u32(0)
            s.pendingEvents.append(w.data)
        }
        try await camera.connect()
        try await camera.startLiveView()
        try await camera.stopLiveView()
        #expect(sim.state.withLock { $0.propertyWrites.map(\.1) } == [2, 1])
    }

    /// A previous host died mid-stream and left the PC bit set (observed as 0x3 on the SL2): start
    /// routes live view as the user chose (PC only by default), and stop hands it back to the rear LCD.
    @Test func leftoverPCOutputIsClearedOnStop() async throws {
        let (camera, sim) = try makeCamera()
        sim.state.withLock { s in
            s.evfOutput = 3
            var w = PTPDataWriter()
            w.u32(16); w.u32(0xC189); w.u32(0xD1B0); w.u32(3); w.u32(8); w.u32(0)
            s.pendingEvents.append(w.data)
        }
        try await camera.connect()
        try await camera.startLiveView()
        _ = try await camera.nextFrame()
        try await camera.stopLiveView()
        #expect(sim.state.withLock { $0.propertyWrites.map(\.1) } == [2, 1])
    }

    /// Verified on the SL2 (docs/canon-eos-ptp.md §3.1): 0x3 streams to the PC and keeps the rear LCD on.
    @Test func cameraScreenPreferenceRoutesLiveViewToRearLCDToo() async throws {
        let (camera, sim) = try makeCamera()
        try await camera.connect()
        try await camera.setShowsLiveViewOnCamera(true)
        #expect(sim.state.withLock { $0.propertyWrites.isEmpty })  // applied when live view starts
        try await camera.startLiveView()
        _ = try await camera.nextFrame()
        try await camera.setShowsLiveViewOnCamera(false)
        _ = try await camera.nextFrame()
        try await camera.setShowsLiveViewOnCamera(true)
        _ = try await camera.nextFrame()
        try await camera.stopLiveView()
        #expect(sim.state.withLock { $0.propertyWrites.map(\.1) } == [3, 2, 3, 1])
    }

    @Test func bodyRefusingRearLCDAndPCStillStreamsToPC() async throws {
        let (camera, sim) = try makeCamera()
        try await camera.connect()
        try await camera.setShowsLiveViewOnCamera(true)
        sim.state.withLock { $0.refusals[0x9110] = 0x2005 }
        try await camera.startLiveView()
        _ = try await camera.nextFrame()
        let s = sim.state.withLock { $0 }
        #expect(s.commands.filter { $0.0 == 0x9110 }.count == 2)
        #expect(s.propertyWrites.map(\.1) == [2])
    }

    /// Every property the camera reports ends up in the metadata: none dropped, magic values decoded.
    @Test func metadataReportsEveryPropertyInHumanTerms() async throws {
        let (camera, _) = try makeCamera()
        try await camera.connect()
        let metadata = await camera.metadata()
        let reported = await camera.properties.values.count
        let propertyItems = metadata.sections.flatMap(\.items).filter {
            switch $0.kind {
            case .supportedOperations, .supportedEvents, .supportedProperties, .supportedCaptureFormats,
                 .supportedImageFormats, .transport, .manufacturer, .model, .firmwareVersion, .protocolVersion,
                 .vendorExtension:
                false
            case .serialNumber:
                $0.raw.count == 32  // DeviceInfo serial (hex string), not the 0xD1AF property
            default:
                true
            }
        }
        #expect(propertyItems.count >= reported)
        #expect(metadata.item(.lensName)?.value == "EF-S18-55mm f/4-5.6 IS STM")
        #expect(metadata.section(.lens)?.items.contains { $0.kind == .lensName } == true)
        #expect(metadata.item(.firmwareVersion)?.value == "1.0.1")
        #expect(metadata.item(.autoPowerOff)?.value == "2 min")
        #expect(metadata.item(.iso)?.value == "Auto")
        let formats = try #require(metadata.item(.supportedImageFormats)?.value)
        #expect(formats.contains("EXIF/JPEG"))
        // Undocumented codes are kept (flagged), and the documented view drops them.
        let allItems = metadata.sections.flatMap(\.items)
        let shownItems = metadata.documentedOnly.sections.flatMap(\.items)
        #expect(allItems.contains { !$0.isDocumented })
        #expect(shownItems.allSatisfy { $0.isDocumented })
    }

    @Test func latestFrameMetadataIsFormattedOnlyWhenAsked() async throws {
        let (camera, _) = try makeCamera()
        try await camera.connect()
        #expect(await camera.metadata().section(.frame) == nil)
        try await camera.startLiveView()
        _ = try await camera.nextFrame()
        let frame = try #require(await camera.metadata().section(.frame))
        #expect(frame.items.contains { $0.kind == .frameSize && $0.value.contains("960") })
        #expect(frame.items.contains { $0.kind == .sensorSize })
        try await camera.stopLiveView()
        #expect(await camera.metadata().section(.frame) == nil)
    }

    /// Unsupported bodies stop the engine (`.fatal`) with the model's name instead of reconnecting forever.
    @Test func bodiesWithoutEOSLiveViewAreUnsupported() throws {
        var info = try PTPDeviceInfo(decoding: fixture("deviceinfo-sl2.bin"))
        info.manufacturer = "Nikon Corporation"
        #expect(throws: CameraError(.unsupported, "Canon EOS Rebel SL2 is not a Canon EOS camera.",
                                    detail: "manufacturer Nikon Corporation")) { try CanonCamera.validate(info) }
        info.manufacturer = "Canon.Inc"
        info.operationsSupported.removeAll { $0 == 0x9153 }
        do {
            try CanonCamera.validate(info)
            Issue.record("expected an error")
        } catch {
            #expect(error.kind == .unsupported)
            #expect(error.disposition == .fatal)
            #expect(error.message == "Canon EOS Rebel SL2 can't stream live view over USB.")
        }
    }
}

@Suite struct CanonCaptureEngineTests {
    @Test func engineDecodesRealSL2FramesIntoVirtualCameraFormat() async throws {
        let engine = CaptureEngine { () async throws(CameraError) -> any CameraBackend in
            do { return try makeCamera().0 } catch { throw CameraError(.notFound, "fixtures missing") }
        }
        await engine.start()
        var after: UInt64 = 0
        var last: DecodedFrame?
        for _ in 0..<5 {
            guard let f = await engine.frames.next(after: after) else { break }
            after = f.sequence
            last = f
        }
        let status = await engine.status
        await engine.stop()
        let frame = try #require(last)
        #expect(frame.sourceWidth == 960 && frame.sourceHeight == 640)  // size of the captured fixture
        #expect(CVPixelBufferGetWidth(frame.pixelBuffer) == 1280)
        #expect(CVPixelBufferGetHeight(frame.pixelBuffer) == 720)
        #expect(CVPixelBufferGetPixelFormatType(frame.pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        #expect(CVPixelBufferGetIOSurface(frame.pixelBuffer) != nil)
        #expect(status.state == .streaming)
        #expect(status.metrics.framesDecoded >= 5)
    }
}
