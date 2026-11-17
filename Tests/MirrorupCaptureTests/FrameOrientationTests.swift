import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
@testable import MirrorupCapture
import MirrorupDiagnostics
import Synchronization
import Testing

/// Quadrant positions in a frame, in reading order.
private enum Quadrant: Int, CaseIterable, CustomStringConvertible {
    case topLeft, topRight, bottomLeft, bottomRight

    /// Normalized centre, (0, 0) top-left.
    var centre: CGPoint {
        switch self {
        case .topLeft: CGPoint(x: 0.25, y: 0.25)
        case .topRight: CGPoint(x: 0.75, y: 0.25)
        case .bottomLeft: CGPoint(x: 0.25, y: 0.75)
        case .bottomRight: CGPoint(x: 0.75, y: 0.75)
        }
    }

    init(containing point: CGPoint) {
        switch (point.x >= 0.5, point.y >= 0.5) {
        case (false, false): self = .topLeft
        case (true, false): self = .topRight
        case (false, true): self = .bottomLeft
        case (true, true): self = .bottomRight
        }
    }

    var description: String { ["topLeft", "topRight", "bottomLeft", "bottomRight"][rawValue] }
}

/// Test images with known asymmetric content.
private enum OrientationImage {
    /// Same aspect as `testOutput`, so the decoder scales without cropping.
    static let size = (width: testOutput.width * 2, height: testOutput.height * 2)

    /// Grey level of each source quadrant: all distinct, so every quadrant is identifiable.
    static let grey: [Quadrant: CGFloat] = [.topLeft: 1.0, .topRight: 0.7, .bottomLeft: 0.4, .bottomRight: 0.1]

    static func quadrants() throws -> Data {
        try encode { context, w, h in
            for (quadrant, level) in grey {
                context.setFillColor(red: level, green: level, blue: level, alpha: 1)
                context.fill(rect(quadrant, w, h))
            }
        }
    }

    /// Left half red, right half blue: tells the chroma plane's orientation apart.
    static func redLeftBlueRight() throws -> Data {
        try encode { context, w, h in
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
            context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            context.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h))
        }
    }

    /// `quadrant` in Core Graphics coordinates (origin bottom-left).
    private static func rect(_ quadrant: Quadrant, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        let x: CGFloat = quadrant == .topLeft || quadrant == .bottomLeft ? 0 : w / 2
        let y: CGFloat = quadrant == .topLeft || quadrant == .topRight ? h / 2 : 0
        return CGRect(x: x, y: y, width: w / 2, height: h / 2)
    }

    private static func encode(_ draw: (CGContext, CGFloat, CGFloat) -> Void) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        draw(context, CGFloat(size.width), CGFloat(size.height))
        let data = NSMutableData()
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

/// Mean of a 5x5 block of plane `plane` (component `component` of `components` interleaved) at `point`.
private func sample(_ buffer: CVPixelBuffer, plane: Int, component: Int = 0, components: Int = 1, at point: CGPoint) -> Int {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
    let cx = Int(point.x * CGFloat(CVPixelBufferGetWidthOfPlane(buffer, plane)))
    let cy = Int(point.y * CGFloat(CVPixelBufferGetHeightOfPlane(buffer, plane)))
    var sum = 0
    for y in (cy - 2)...(cy + 2) {
        for x in (cx - 2)...(cx + 2) { sum += Int(base[y * stride + x * components + component]) }
    }
    return sum / 25
}

/// Which source quadrant is shown at each displayed quadrant, identified by luma rank.
private func displayedQuadrants(_ buffer: CVPixelBuffer) -> [Quadrant: Quadrant] {
    let luma = Dictionary(uniqueKeysWithValues: Quadrant.allCases.map { ($0, sample(buffer, plane: 0, at: $0.centre)) })
    let displayedByBrightness = Quadrant.allCases.sorted { luma[$0]! > luma[$1]! }
    let sourceByBrightness = Quadrant.allCases.sorted { OrientationImage.grey[$0]! > OrientationImage.grey[$1]! }
    let sorted = displayedByBrightness.map { luma[$0]! }
    for (brighter, darker) in zip(sorted, sorted.dropFirst()) {
        #expect(brighter - darker > 20, "quadrants must be distinguishable: \(luma)")
    }
    return Dictionary(uniqueKeysWithValues: zip(displayedByBrightness, sourceByBrightness))
}

private func cameraFrame(_ jpeg: Data, sequence: UInt64 = 1) -> CameraFrame {
    let now = HostTime.now()
    return CameraFrame(sequence: sequence, jpeg: jpeg, acquisitionStart: now, acquisitionEnd: now)
}

private let allOrientations: [FrameOrientation] = [
    .normal, FrameOrientation(mirrored: true), FrameOrientation(upsideDown: true),
    FrameOrientation(mirrored: true, upsideDown: true),
]

@Suite("Frame orientation", .timeLimit(.minutes(1)))
struct FrameOrientationTests {
    /// Displayed quadrant -> source quadrant, written out independently of `cameraPoint`.
    private static let expected: [(FrameOrientation, [Quadrant: Quadrant])] = [
        (.normal, [.topLeft: .topLeft, .topRight: .topRight, .bottomLeft: .bottomLeft, .bottomRight: .bottomRight]),
        (FrameOrientation(mirrored: true),
         [.topLeft: .topRight, .topRight: .topLeft, .bottomLeft: .bottomRight, .bottomRight: .bottomLeft]),
        (FrameOrientation(upsideDown: true),
         [.topLeft: .bottomRight, .topRight: .bottomLeft, .bottomLeft: .topRight, .bottomRight: .topLeft]),
        (FrameOrientation(mirrored: true, upsideDown: true),
         [.topLeft: .bottomLeft, .topRight: .bottomRight, .bottomLeft: .topLeft, .bottomRight: .topRight]),
    ]

    @Test(arguments: 0..<expected.count)
    func orientsLumaOfEveryQuadrant(_ index: Int) throws {
        let (orientation, mapping) = Self.expected[index]
        let decoder = FrameDecoder(output: testOutput)
        let decoded = try decoder.decode(cameraFrame(try OrientationImage.quadrants()), sequence: 7, orientation: orientation)
        let shown = displayedQuadrants(decoded.pixelBuffer)
        #expect(shown == mapping, "\(orientation)")
        // The displayed image and `cameraPoint(fromDisplayed:)` agree on where every point came from.
        for displayed in Quadrant.allCases {
            #expect(shown[displayed] == Quadrant(containing: orientation.cameraPoint(fromDisplayed: displayed.centre)))
        }
        #expect(decoder.isOrienting == (orientation != .normal))

        // Same format, size and IOSurface backing as the decoder's own output; frame fields untouched.
        let buffer = decoded.pixelBuffer
        #expect(CVPixelBufferGetWidth(buffer) == testOutput.width && CVPixelBufferGetHeight(buffer) == testOutput.height)
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        #expect(CVPixelBufferGetIOSurface(buffer) != nil)
        #expect(decoded.sequence == 7)
        #expect(decoded.sourceWidth == OrientationImage.size.width && decoded.sourceHeight == OrientationImage.size.height)
    }

    /// Cr (the second byte of each interleaved CbCr pair) is high for red and low for blue.
    @Test(arguments: allOrientations)
    func orientsChroma(_ orientation: FrameOrientation) throws {
        let decoder = FrameDecoder(output: testOutput)
        let decoded = try decoder.decode(cameraFrame(try OrientationImage.redLeftBlueRight()), sequence: 1, orientation: orientation)
        let left = sample(decoded.pixelBuffer, plane: 1, component: 1, components: 2, at: CGPoint(x: 0.25, y: 0.5))
        let right = sample(decoded.pixelBuffer, plane: 1, component: 1, components: 2, at: CGPoint(x: 0.75, y: 0.5))
        let redOnLeft = orientation.cameraPoint(fromDisplayed: CGPoint(x: 0.25, y: 0.5)).x < 0.5
        if redOnLeft {
            #expect(left > right + 60, "Cr left \(left) right \(right)")
        } else {
            #expect(right > left + 60, "Cr left \(left) right \(right)")
        }
    }

    @Test func normalReturnsTheDecoderBufferWithoutAnOrientationStage() throws {
        let decoder = FrameDecoder(output: testOutput)
        let jpeg = try OrientationImage.quadrants()
        let plain = try decoder.decode(cameraFrame(jpeg), sequence: 1)
        #expect(!decoder.isOrienting, "no rotation session or pool for .normal")
        #expect(displayedQuadrants(plain.pixelBuffer) == Self.expected[0].1)

        _ = try decoder.decode(cameraFrame(jpeg), sequence: 2, orientation: FrameOrientation(mirrored: true))
        #expect(decoder.isOrienting)
        // Switching back to .normal releases the stage; the decoder's buffer is published again.
        let back = try decoder.decode(cameraFrame(jpeg), sequence: 3, orientation: .normal)
        #expect(!decoder.isOrienting)
        #expect(displayedQuadrants(back.pixelBuffer) == Self.expected[0].1)
        decoder.invalidate()
        #expect(!decoder.isOrienting)
    }

    @Test func orientationChangesBetweenFramesReconfigureTheStage() throws {
        let decoder = FrameDecoder(output: testOutput)
        let jpeg = try OrientationImage.quadrants()
        // Cycle through every non-normal orientation twice without going back to .normal.
        for (sequence, index) in [1, 2, 3, 1, 3, 2].enumerated() {
            let (orientation, mapping) = Self.expected[index]
            let decoded = try decoder.decode(cameraFrame(jpeg, sequence: UInt64(sequence + 1)), sequence: UInt64(sequence + 1),
                                             orientation: orientation)
            #expect(displayedQuadrants(decoded.pixelBuffer) == mapping, "\(orientation)")
        }
        // A source-size change recreates the decompression session but keeps orienting.
        let small = try SyntheticImage.jpeg(width: testSource.width, height: testSource.height, index: 0, count: 1)
        _ = try decoder.decode(cameraFrame(small), sequence: 10, orientation: FrameOrientation(upsideDown: true))
        let again = try decoder.decode(cameraFrame(jpeg), sequence: 11, orientation: FrameOrientation(upsideDown: true))
        #expect(displayedQuadrants(again.pixelBuffer) == Self.expected[2].1)
    }

    @Test func cameraPointMapsDisplayedPointsBackToTheCameraFrame() {
        let point = CGPoint(x: 0.2, y: 0.3)
        let expected: [(FrameOrientation, CGPoint)] = [
            (.normal, CGPoint(x: 0.2, y: 0.3)),
            (FrameOrientation(mirrored: true), CGPoint(x: 0.8, y: 0.3)),
            (FrameOrientation(upsideDown: true), CGPoint(x: 0.8, y: 0.7)),
            (FrameOrientation(mirrored: true, upsideDown: true), CGPoint(x: 0.2, y: 0.7)),
        ]
        for (orientation, camera) in expected {
            let mapped = orientation.cameraPoint(fromDisplayed: point)
            #expect(abs(mapped.x - camera.x) < 1e-9 && abs(mapped.y - camera.y) < 1e-9, "\(orientation)")
            // Every orientation is its own inverse: mapping twice returns the displayed point.
            let roundTrip = orientation.cameraPoint(fromDisplayed: mapped)
            #expect(abs(roundTrip.x - point.x) < 1e-9 && abs(roundTrip.y - point.y) < 1e-9, "\(orientation)")
            // Corners map to corners.
            #expect(orientation.cameraPoint(fromDisplayed: CGPoint(x: 0, y: 0)).x == (orientation.mirrored != orientation.upsideDown ? 1 : 0))
            #expect(orientation.cameraPoint(fromDisplayed: CGPoint(x: 0, y: 0)).y == (orientation.upsideDown ? 1 : 0))
        }
    }

    @Test func engineAppliesOrientationChangesToLaterFrames() async throws {
        let jpeg = try OrientationImage.quadrants()
        let engine = CaptureEngine(configuration: testConfiguration()) { QuadrantCamera(jpeg: jpeg) }
        #expect(engine.orientation == .normal)
        await engine.start()

        /// The first frame whose decode started after `after` was published, i.e. two frames later.
        func frame(after sequence: UInt64) async throws -> DecodedFrame {
            var latest = sequence
            while true {
                let after = latest
                let next = try #require(await withTimeout(.seconds(5)) { await engine.frames.next(after: after) })
                if next.sequence >= sequence + 2 { return next }
                latest = next.sequence
            }
        }

        var current = try #require(await withTimeout(.seconds(10)) { await engine.frames.next(after: 0) })
        #expect(displayedQuadrants(current.pixelBuffer) == Self.expected[0].1)
        for index in [1, 2, 3, 0] {
            let (orientation, mapping) = Self.expected[index]
            engine.setOrientation(orientation)
            #expect(engine.orientation == orientation)
            current = try await frame(after: current.sequence)
            #expect(displayedQuadrants(current.pixelBuffer) == mapping, "\(orientation)")
        }

        // The setting survives a restart.
        engine.setOrientation(FrameOrientation(mirrored: true))
        await engine.stop()
        #expect(engine.orientation == FrameOrientation(mirrored: true))
        await engine.start()
        let beforeRestart = current.sequence
        current = try #require(await withTimeout(.seconds(10)) { await engine.frames.next(after: beforeRestart) })
        #expect(displayedQuadrants(current.pixelBuffer) == Self.expected[1].1)
        let status = try await waitForStatus(engine, "decode metrics") { $0.metrics.decode != nil }
        #expect(status.metrics.framesDecoded > 0)
        await engine.stop()
    }

    @Test func controlsAreNilForBackendsWithoutControls() async throws {
        let engine = CaptureEngine(configuration: testConfiguration()) { SyntheticCamera(configuration: syntheticConfiguration()) }
        #expect(engine.controls() == nil, "no session")
        await engine.start()
        _ = try #require(await withTimeout(.seconds(10)) { await engine.frames.next(after: 0) })
        #expect(engine.controls() == nil, "SyntheticCamera is not CameraControlling")
        await engine.stop()
    }

    @Test func controlsReturnTheActiveBackendWhenItHasControls() async throws {
        let jpeg = try OrientationImage.quadrants()
        let camera = ControllableQuadrantCamera(jpeg: jpeg)
        let engine = CaptureEngine(configuration: testConfiguration()) { camera }
        #expect(engine.controls() == nil, "no session")
        await engine.start()
        _ = try #require(await withTimeout(.seconds(10)) { await engine.frames.next(after: 0) })
        let controls = try #require(engine.controls())
        #expect((controls as? ControllableQuadrantCamera) === camera)
        #expect(await controls.controlState().canAutofocus)
        await engine.stop()
        #expect(engine.controls() == nil, "released with the session")
    }
}

/// Serves the same JPEG at ~200 fps.
private actor QuadrantCamera: CameraBackend {
    private let jpeg: Data
    private var sequence: UInt64 = 0

    init(jpeg: Data) {
        self.jpeg = jpeg
    }

    var identity: CameraIdentity { CameraIdentity(name: "Quadrants", transport: "Test") }
    func connect() async throws(CameraError) {}
    func startLiveView() async throws(CameraError) {}

    func nextFrame() async throws(CameraError) -> CameraFrame {
        let start = HostTime.now()
        do {
            try await Task.sleep(for: .milliseconds(5))
        } catch {
            throw CameraError(.cancelled, "Capture was stopped.")
        }
        sequence += 1
        return CameraFrame(sequence: sequence, jpeg: jpeg, acquisitionStart: start, acquisitionEnd: HostTime.now())
    }

    func stopLiveView() async throws(CameraError) {}
    func disconnect() async {}
    func metadata() async -> CameraMetadata { CameraMetadata() }
}

/// `QuadrantCamera` with controls.
private actor ControllableQuadrantCamera: CameraBackend, CameraControlling {
    private let camera: QuadrantCamera

    init(jpeg: Data) {
        camera = QuadrantCamera(jpeg: jpeg)
    }

    var identity: CameraIdentity { get async { await camera.identity } }
    func connect() async throws(CameraError) {}
    func startLiveView() async throws(CameraError) {}
    func nextFrame() async throws(CameraError) -> CameraFrame { try await camera.nextFrame() }
    func stopLiveView() async throws(CameraError) {}
    func disconnect() async {}
    func metadata() async -> CameraMetadata { CameraMetadata() }

    func controlState() async -> CameraControlState { CameraControlState(canAutofocus: true) }
    func set(_ setting: CameraSetting, to value: UInt32) async throws(CameraError) -> CameraControlState { await controlState() }
    func autofocus() async throws(CameraError) -> AutofocusResult { .unconfirmed }
    func focus(at point: CGPoint) async throws(CameraError) -> AutofocusResult { .unconfirmed }
    func setZoom(_ zoom: CameraZoom, center: CGPoint?) async throws(CameraError) -> CameraControlState { await controlState() }
    func capturePhoto() async throws(CameraError) -> CapturedPhoto {
        CapturedPhoto(data: Data(), filename: "test.jpg")
    }
}
