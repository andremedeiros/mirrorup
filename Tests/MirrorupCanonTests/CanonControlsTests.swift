import CoreGraphics
import Foundation
import Testing
import MirrorupCapture
import MirrorupPTP
@testable import MirrorupCanon

private func controlsFixture(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
        throw CocoaError(.fileNoSuchFile)
    }
    return try Data(contentsOf: url)
}

/// SL2 simulator fed with the real fw 1.1.0 EVF capture (16:9 frame, zoom rect 0,298 5976×3356) and
/// the initial GetEvent dump taken in Scene Intelligent Auto (most allowed lists empty).
private func makeControlledCamera() throws -> (CanonCamera, SimulatedSL2) {
    let sim = SimulatedSL2(
        initialEvents: try controlsFixture("getevent-initial-sl2.bin"),
        deviceInfo: try controlsFixture("deviceinfo-sl2.bin"),
        evf: try controlsFixture("evf-sl2-fw110.bin"))
    var options = CanonCamera.Options()
    options.settingConfirmationTimeout = .milliseconds(100)
    options.frameConfirmationTimeout = .milliseconds(30)
    options.autofocusTimeout = .milliseconds(50)
    options.photoTimeout = .milliseconds(300)
    let camera = CanonCamera(session: PTPSession(transport: sim), identity: CameraIdentity(name: "SL2", transport: "Simulated"), options: options)
    return (camera, sim)
}

private func streaming() async throws -> (CanonCamera, SimulatedSL2) {
    let (camera, sim) = try makeControlledCamera()
    try await camera.connect()
    try await camera.startLiveView()
    _ = try await camera.nextFrame()
    return (camera, sim)
}

/// The fixture was captured with the power switch on movie mode (0xD1C2 = 1) and 0 shots left; this
/// reports what the body sends with the switch on ON and a card with room.
private func readyForStills(_ camera: CanonCamera, _ sim: SimulatedSL2) async {
    sim.state.withLock {
        $0.pendingEvents.append(events([(CanonEvent.propValueChanged, [0xD1C2, 0]), (CanonEvent.propValueChanged, [0xD11B, 5221])]))
    }
    _ = await camera.controlState()
}

private func events(_ records: [(code: UInt32, body: [UInt32])]) -> Data {
    var w = PTPDataWriter()
    for record in records {
        w.u32(UInt32(8 + 4 * record.body.count))
        w.u32(record.code)
        record.body.forEach { w.u32($0) }
    }
    w.u32(8); w.u32(0)
    return w.data
}

/// ObjectAddedEx record as libgphoto2 ptp-pack.c lays it out (offsets from the record start).
private func objectAddedRecord(handle: UInt32, storage: UInt32, format: UInt16, size: UInt32, name: String) -> Data {
    var body = Data(count: 0x20)
    func put(_ v: UInt32, at offset: Int) { withUnsafeBytes(of: v.littleEndian) { body.replaceSubrange(offset..<offset + 4, with: $0) } }
    put(handle, at: 0x00)
    put(storage, at: 0x04)
    put(UInt32(format), at: 0x08)
    put(size, at: 0x14)
    put(0x0010_0000, at: 0x18)  // parent folder
    body.append(contentsOf: Array(name.utf8) + [0])
    var w = PTPDataWriter()
    w.u32(UInt32(8 + body.count))
    w.u32(CanonEvent.objectAddedEx)
    var data = w.data
    data.append(body)
    data.append(contentsOf: [8, 0, 0, 0, 0, 0, 0, 0])
    return data
}

@Suite struct CanonControlsTests {
    @Test func autoModeFixtureOffersOnlyTheFocusMode() async throws {
        let (camera, _) = try makeControlledCamera()
        try await camera.connect()
        let state = await camera.controlState()

        // Scene Intelligent Auto: the body sends empty lists for exposure, WB and picture style.
        for setting: CameraSetting in [.aperture, .shutterSpeed, .iso, .exposureCompensation, .whiteBalance, .imageStyle] {
            let s = try #require(state.settings[setting], "\(setting)")
            #expect(!s.isAdjustable, "\(setting)")
            #expect(state.adjustable(setting) == nil)
        }
        #expect(state.settings[.aperture]?.current?.title == "Auto")
        #expect(state.settings[.imageStyle]?.current?.title == "Auto")
        #expect(state.settings[.imageStyle]?.title == "Picture Style")  // Canon's name for the setting
        #expect(state.hint == "Set the camera's mode dial to P, Av, Tv or M for exposure and color controls.")
        // A Kelvin list arrives, but white balance is Auto, so color temperature is not a choice.
        let kelvin = try #require(state.settings[.colorTemperature])
        #expect(!kelvin.isAdjustable)
        #expect(kelvin.current == CameraSettingOption(value: 5200, title: "5200 K"))

        let af = try #require(state.adjustable(.autofocusMethod))
        #expect(af.options.map(\.value) == [2, 4, 1])  // camera order
        #expect(af.options.map(\.title) == ["Face + Tracking", "Zone AF", "1-point AF (Live Mode)"])
        #expect(af.current?.value == 2)

        #expect(state.battery == "100%")
        #expect(!state.batteryIsLow)
        #expect(state.shotsRemaining == 0)
        #expect(!state.canCapturePhoto)
        #expect(state.photoUnavailableReason == "The camera's power switch is on movie mode. Move it to ON to take photos.")
        // Not streaming: no AF, no zoom.
        #expect(!state.canAutofocus && !state.canFocusAtPoint)
        #expect(state.zoom == nil)
        #expect(state.zoomLevels.isEmpty)
    }

    @Test func streamingInFaceTrackingCanFocusButNotZoomOrPoint() async throws {
        let (camera, _) = try await streaming()
        let state = await camera.controlState()
        #expect(state.canAutofocus)
        #expect(!state.canFocusAtPoint)
        #expect(state.zoom == nil)
    }

    @Test func setSendsFourByteSlotAndReturnsTheEchoedValue() async throws {
        let (camera, sim) = try await streaming()
        let state = try await camera.set(.autofocusMethod, to: 1)
        #expect(state.settings[.autofocusMethod]?.current?.value == 1)
        #expect(state.canFocusAtPoint)
        #expect(state.zoom == .x1)
        let write = try #require(sim.state.withLock { $0.propertyWrites.last })
        #expect(write.0 == 0xD1BA && write.1 == 1)
        #expect(CanonPropertyEncoding.integerPayload(property: 0xD1BA, value: 1) == Data([12, 0, 0, 0, 0xBA, 0xD1, 0, 0, 1, 0, 0, 0]))
    }

    @Test func setRejectsValuesOutsideTheOptionsWithoutSending() async throws {
        let (camera, sim) = try makeControlledCamera()
        try await camera.connect()
        let writesBefore = sim.state.withLock { $0.propertyWrites.count }
        await #expect(throws: CameraError.self) { try await camera.set(.imageStyle, to: 0x81) }
        await #expect(throws: CameraError.self) { try await camera.set(.autofocusMethod, to: 0) }
        #expect(sim.state.withLock { $0.propertyWrites.count } == writesBefore)
    }

    @Test func setMapsBusyToAPlainMessage() async throws {
        let (camera, sim) = try makeControlledCamera()
        try await camera.connect()
        sim.state.withLock { $0.refusals[0x9110] = 0x2019 }
        do {
            _ = try await camera.set(.autofocusMethod, to: 1)
            Issue.record("expected a refusal")
        } catch {
            #expect(error.kind == .protocolViolation)
            #expect(error.message == "The camera is busy or doesn't allow this change in its current mode.")
            #expect(error.detail?.contains("0x2019") == true)
        }
    }

    @Test func setWithoutEchoTimesOut() async throws {
        let (camera, sim) = try makeControlledCamera()
        try await camera.connect()
        sim.state.withLock { $0.echoesPropertyWrites = false }
        do {
            _ = try await camera.set(.autofocusMethod, to: 1)
            Issue.record("expected a timeout")
        } catch {
            #expect(error.kind == .timeout)
        }
    }

    @Test func autofocusDrivesAFThenReleasesTheHold() async throws {
        let (camera, sim) = try await streaming()
        try await camera.autofocus()
        let log = sim.state.withLock { $0.log }
        let doAF = try #require(log.lastIndex(of: 0x9154))
        let cancel = try #require(log.lastIndex(of: 0x9160))
        #expect(doAF < cancel)
    }

    @Test func autofocusNeedsLiveView() async throws {
        let (camera, sim) = try makeControlledCamera()
        try await camera.connect()
        do {
            try await camera.autofocus()
            Issue.record("expected an error")
        } catch {
            #expect(error.kind == .liveViewUnavailable)
        }
        #expect(!sim.state.withLock { $0.log.contains(0x9154) })
    }

    @Test func focusAtPointMovesTheAFFrameThenFocuses() async throws {
        let (camera, sim) = try await streaming()
        _ = try await camera.set(.autofocusMethod, to: 1)
        try await camera.focus(at: CGPoint(x: 0.5, y: 0.5))
        let commands = sim.state.withLock { $0.commands }
        let position = try #require(commands.last { $0.0 == 0x9159 })
        // Centre of 0,298 5976×3356 is (2988, 1976); the magnifier is a fifth of 5976×3952.
        #expect(position.1 == [2391, 1581])
        let codes = commands.map(\.0)
        let p = try #require(codes.lastIndex(of: 0x9159))
        #expect(codes[p...].contains(0x9154) && codes[p...].contains(0x9160))
    }

    @Test func focusAtPointNeedsOnePointAF() async throws {
        let (camera, sim) = try await streaming()  // fixture is in Face + Tracking
        await #expect(throws: CameraError.self) { try await camera.focus(at: CGPoint(x: 0.5, y: 0.5)) }
        #expect(!sim.state.withLock { $0.log.contains(0x9159) })
    }

    @Test func zoomPositionsThenMagnifies() async throws {
        let (camera, sim) = try await streaming()
        _ = try await camera.set(.autofocusMethod, to: 1)
        _ = try await camera.setZoom(CameraZoom(value: 5, title: "5×"), center: CGPoint(x: 0.25, y: 0.5))
        let commands = sim.state.withLock { $0.commands }.filter { $0.0 == 0x9159 || $0.0 == 0x9158 }
        // Nothing streams here, so no frame contradicts the camera's OK: each command is sent once.
        #expect(commands.map(\.0) == [0x9159, 0x9158])
        #expect(commands.first?.1 == [897, 1581])
        #expect(commands.last?.0 == 0x9158 && commands.last?.1 == [5])
    }

    @Test func zoomIgnoredByTheCameraIsResentOnceThenReported() async throws {
        let (camera, sim) = try await streaming()
        _ = try await camera.set(.autofocusMethod, to: 1)
        // Frames keep flowing, but the simulator never magnifies (its frames always report 1×).
        let frames = Task { while !Task.isCancelled { _ = try? await camera.nextFrame(); try? await Task.sleep(for: .milliseconds(5)) } }
        defer { frames.cancel() }
        do {
            _ = try await camera.setZoom(CameraZoom(value: 5, title: "5×"), center: nil)
            Issue.record("expected an error")
        } catch {
            #expect(error.message == "The camera did not change the zoom. Try again in a moment.")
        }
        #expect(sim.state.withLock { $0.log.filter { $0 == 0x9158 }.count } == 2)
    }

    @Test func onePointAFOffersOneAndFiveTimesZoomAndRefusesOthersWithoutSending() async throws {
        let (camera, sim) = try await streaming()
        let state = try await camera.set(.autofocusMethod, to: 1)
        #expect(state.zoomLevels == [.x1, CameraZoom(value: 5, title: "5×")])
        #expect(state.zoom == .x1)
        do {
            _ = try await camera.setZoom(CameraZoom(value: 10, title: "10×"), center: nil)
            Issue.record("expected an error")
        } catch {
            #expect(error.message == "The camera can't zoom to 10×.")
        }
        #expect(!sim.state.withLock { $0.log.contains(0x9158) })
    }

    @Test func zoomIsRefusedInFaceTrackingWithoutSending() async throws {
        let (camera, sim) = try await streaming()
        await #expect(throws: CameraError.self) { _ = try await camera.setZoom(CameraZoom(value: 5, title: "5×"), center: nil) }
        #expect(!sim.state.withLock { $0.log.contains(0x9158) })
    }

    @Test func captureReleasesWaitsForTheFileAndDownloadsIt() async throws {
        let (camera, sim) = try await streaming()
        await readyForStills(camera, sim)
        let jpeg = Data([0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9])
        sim.state.withLock { s in
            s.objectEventOnRelease = objectAddedRecord(handle: 0x9000_0042, storage: 0x0002_0001, format: 0x3801,
                                                       size: UInt32(jpeg.count), name: "IMG_0042.JPG")
            s.objects[0x9000_0042] = jpeg
        }
        let photo = try await camera.capturePhoto()
        #expect(photo.filename == "IMG_0042.JPG")
        #expect(photo.data == jpeg)
        let commands = sim.state.withLock { $0.commands }
        let shutter = commands.filter { [0x9101, 0x9128, 0x9129, 0x1009, 0x9117].contains($0.0) }
        #expect(shutter.map(\.0) == [0x9101, 0x9128, 0x9128, 0x9129, 0x9129, 0x1009])
        #expect(shutter.map(\.1) == [[], [1, 0], [2, 0], [2], [1], [0x9000_0042]])
        // Live view keeps working after the shutter cycle.
        _ = try await camera.nextFrame()
    }

    @Test func refusedReleaseLetsGoOfTheShutterAndReports() async throws {
        let (camera, sim) = try await streaming()
        await readyForStills(camera, sim)
        sim.state.withLock { $0.releaseResult = 0xC }
        do {
            _ = try await camera.capturePhoto()
            Issue.record("expected a refusal")
        } catch {
            // 0xC is EDSDK SPECIAL_MOVIE_MODE_NG; the SL2 kept answering it with 0xD1C2 = 0 until the
            // power switch was cycled.
            #expect(error.detail?.contains("0xC (specialMovieMode)") == true)
            #expect(error.message == "The camera refused the photo as if it were in movie mode. If its power switch is already on ON, turn it to the movie position and back to ON.")
        }
        let commands = sim.state.withLock { $0.commands }
        #expect(commands.contains { $0.0 == 0x9129 && $0.1 == [2] })
        #expect(commands.contains { $0.0 == 0x9129 && $0.1 == [1] })
        #expect(!commands.contains { $0.0 == 0x1009 })

        sim.state.withLock { $0.releaseResult = 1 }
        do {
            _ = try await camera.capturePhoto()
            Issue.record("expected a refusal")
        } catch {
            #expect(error.message == "The camera could not focus, so it did not take the photo.")
        }
    }

    @Test func movieModeBlocksCaptureBeforeThePress() async throws {
        let (camera, sim) = try await streaming()  // fixture: 0xD1C2 = 1
        do {
            _ = try await camera.capturePhoto()
            Issue.record("expected an error")
        } catch {
            #expect(error.message == "The camera's power switch is on movie mode. Move it to ON to take photos.")
        }
        #expect(!sim.state.withLock { $0.log.contains(0x9128) })
    }

    @Test func releaseResultsDecodeToSpecificMessages() {
        func failure(_ code: PTPResponseCode, _ result: UInt32, movie: Bool = false) -> CameraError? {
            CanonCamera.releaseFailure(PTPResponse(code: code, transactionID: 1, parameters: [result]), press: "full press", inMovieMode: movie)
        }
        #expect(failure(.ok, 0) == nil)
        #expect(failure(.ok, 7)?.message == "The camera could not write to its memory card. Check that the card isn't full.")
        #expect(failure(.ok, 8)?.message == "The memory card is locked. Unlock it to take photos.")
        #expect(failure(.ok, 0x0B)?.message == "Attach a lens to take photos.")
        #expect(failure(.ok, 0x0C, movie: true)?.message == "The camera's power switch is on movie mode. Move it to ON to take photos.")
        // SL2 with live view off: DeviceBusy after 5 s with result 1; the result explains it.
        #expect(failure(.deviceBusy, 1)?.message == "The camera could not focus, so it did not take the photo.")
        #expect(failure(.deviceBusy, 0)?.message == "The camera is busy and did not take the photo. Try again in a moment.")
        #expect(failure(.ok, 2)?.message == "The camera did not take the photo. Check the camera's screen for a message.")
        #expect(failure(.ok, 2)?.detail?.contains("result 0x2") == true)
    }

    @Test func captureWithoutACardDoesNotPressTheShutter() async throws {
        let (camera, sim) = try makeControlledCamera()
        try await camera.connect()
        await readyForStills(camera, sim)
        sim.state.withLock { $0.storageIDs = [] }
        do {
            _ = try await camera.capturePhoto()
            Issue.record("expected an error")
        } catch {
            #expect(error.message == "Insert a memory card to take photos.")
        }
        #expect(!sim.state.withLock { $0.log.contains(0x9128) })
    }

    @Test func batteryAndShotsFollowTheEventCache() async throws {
        // Battery and shots arrive later through GetEvent; the state follows the cache on demand.
        let (camera, sim) = try makeControlledCamera()
        try await camera.connect()
        sim.state.withLock { $0.pendingEvents.append(events([(CanonEvent.propValueChanged, [0xD111, 0]), (CanonEvent.propValueChanged, [0xD11B, 812]), (CanonEvent.propValueChanged, [0xD1C2, 0])])) }
        let state = await camera.controlState()
        #expect(state.battery == "Low" && state.batteryIsLow)
        #expect(state.shotsRemaining == 812)
        #expect(state.canCapturePhoto)
    }
}

@Suite struct CanonControlGeometryTests {
    /// Blocks decoded from the real fw 1.1.0 capture.
    func fixtureMetadata() throws -> CanonViewfinderMetadata {
        try CanonViewfinderParser.parse(try controlsFixture("evf-sl2-fw110.bin")).metadata
    }

    @Test func normalizedPointsMapOntoTheZoomRect() throws {
        let m = try fixtureMetadata()
        #expect(m.zoomRect == .init(x: 0, y: 298, width: 5976, height: 3356))
        #expect(CanonCamera.sensorPoint(CGPoint(x: 0, y: 0), in: m) == CGPoint(x: 0, y: 298))
        #expect(CanonCamera.sensorPoint(CGPoint(x: 1, y: 1), in: m) == CGPoint(x: 5976, y: 3654))
        #expect(CanonCamera.sensorPoint(CGPoint(x: 0.5, y: 0.5), in: m) == CGPoint(x: 2988, y: 1976))
        #expect(CanonCamera.sensorPoint(CGPoint(x: -1, y: 2), in: m) == CGPoint(x: 0, y: 3654))  // clamped
    }

    @Test func magnifierOriginIsCentredAndClampedToTheSensor() throws {
        let m = try fixtureMetadata()
        let size = CanonCamera.magnifierSize(metadata: m)
        #expect(size == .init(width: 1195, height: 790))  // block 0xD is zero in Face + Tracking
        let origin = try #require(CanonCamera.magnifierOrigin(centeredAt: CGPoint(x: 0, y: 0), metadata: m, size: size))
        #expect(origin.x == 0 && origin.y == 0)
        let corner = CanonCamera.magnifierOrigin(centeredAt: CGPoint(x: 1, y: 1), metadata: m, size: size)!
        #expect(corner.x == 5976 - 1195 && corner.y == 3952 - 790)
    }

    @Test func fiveTimesCropMapsBackToTheVerifiedCentre() throws {
        // Hardware (SL2, fw 1.1.0, 1-point AF, 5×): frames 1200×800 with zoom rect and magnifier at
        // 2388,1576 1200×800; ZoomPosition(2388, 1576) re-centred it exactly.
        var m = try fixtureMetadata()
        m.magnification = 5
        m.zoomRect = .init(x: 2388, y: 1576, width: 1200, height: 800)
        m.magnifierRect = .init(x: 2388, y: 1576, width: 1200, height: 800)
        let origin = try #require(CanonCamera.magnifierOrigin(centeredAt: CGPoint(x: 0.5, y: 0.5), metadata: m,
                                                               size: CanonCamera.magnifierSize(metadata: m)))
        #expect(origin.x == 2388 && origin.y == 1576)
    }
}

@Suite struct CanonControlFrameAreaTests {
    @Test func tenTimesStillShowsTheFiveTimesImage() throws {
        // Hardware (SL2, fw 1.1.0, 10×): JPEG 1200×800, block 0x12 600×400 at (2964, 1384), magnifier
        // 600×400 at (3264, 1584) — the centre quarter of the 5× crop.
        var m = try CanonViewfinderParser.parse(try controlsFixture("evf-sl2-fw110.bin")).metadata
        m.magnification = 10
        m.zoomRect = .init(x: 2964, y: 1384, width: 600, height: 400)
        m.magnifierRect = .init(x: 3264, y: 1584, width: 600, height: 400)
        #expect(CanonCamera.frameArea(m) == .init(x: 2964, y: 1384, width: 1200, height: 800))
        let origin = try #require(CanonCamera.magnifierOrigin(centeredAt: CGPoint(x: 0.5, y: 0.5), metadata: m,
                                                               size: CanonCamera.magnifierSize(metadata: m)))
        #expect(origin.x == 3264 && origin.y == 1584)
    }

    @Test func autofocusResultIgnoresRestingAndFaceGridStatesAndReportsLock() throws {
        var m = CanonViewfinderMetadata()
        let rect = CanonViewfinderMetadata.Rect(x: 0, y: 0, width: 1, height: 1)
        func frames(_ states: [CanonViewfinderMetadata.FocusFrame.State]) -> [CanonViewfinderMetadata.FocusFrame] {
            states.map { .init(state: $0, unidentified: 1, rect: rect) }
        }
        m.focusFrames = frames([.resting])
        #expect(!CanonCamera.showsAutofocusResult(m))
        m.focusFrames = frames(Array(repeating: .undocumented(0), count: 49))  // Face + Tracking grid
        #expect(!CanonCamera.showsAutofocusResult(m))
        m.focusFrames = frames([.focused])
        #expect(CanonCamera.showsAutofocusResult(m))
        #expect(CanonCamera.autofocusOutcome(m) == .focused)
        m.focusFrames = frames([.undocumented(0x12)])  // seen after AF on a blank wall
        #expect(CanonCamera.showsAutofocusResult(m))
        #expect(CanonCamera.autofocusOutcome(m) == .notFocused)
        m.focusFrames = frames([.undocumented(0x12), .focused])  // any locked frame wins
        #expect(CanonCamera.autofocusOutcome(m) == .focused)
    }
}

@Suite struct CanonObjectEventTests {
    @Test func objectAddedCarriesHandleStorageFormatSizeAndName() throws {
        let data = objectAddedRecord(handle: 0x9000_0042, storage: 0x0002_0001, format: 0x3801, size: 6_543_210, name: "IMG_0042.JPG")
        let events = try CanonEventParser.parse(data)
        #expect(events == [.objectAdded(CanonObjectInfo(handle: 0x9000_0042, storageID: 0x0002_0001, format: 0x3801,
                                                         size: 6_543_210, filename: "IMG_0042.JPG"))])
    }

    @Test func requestObjectTransferHasNoStorage() throws {
        var body = Data(count: 0x14)
        func put(_ v: UInt32, at offset: Int) { withUnsafeBytes(of: v.littleEndian) { body.replaceSubrange(offset..<offset + 4, with: $0) } }
        put(0x42, at: 0)
        put(0x3801, at: 0x04)
        put(1234, at: 0x0C)
        body.append(contentsOf: Array("capt0000.jpg".utf8) + [0])
        var w = PTPDataWriter()
        w.u32(UInt32(8 + body.count)); w.u32(CanonEvent.requestObjectTransfer)
        var data = w.data
        data.append(body)
        let events = try CanonEventParser.parse(data)
        #expect(events == [.objectTransferRequested(CanonObjectInfo(handle: 0x42, storageID: 0, format: 0x3801, size: 1234, filename: "capt0000.jpg"))])
    }

    @Test func truncatedObjectRecordIsRejected() {
        var w = PTPDataWriter()
        w.u32(16); w.u32(CanonEvent.objectAddedEx); w.u32(1); w.u32(2)
        #expect(throws: PTPError.self) { try CanonEventParser.parse(w.data) }
    }
}
