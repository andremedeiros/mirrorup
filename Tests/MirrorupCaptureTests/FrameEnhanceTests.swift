import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
@testable import MirrorupCapture
import MirrorupDiagnostics
import Testing

/// A JPEG of `width`×`height` with four distinct grey quadrants inside the output-aspect centre crop
/// and a white band in what the crop discards, so a wrong crop shows up as a wrong quadrant level.
private func croppedQuadrantsJPEG(width: Int, height: Int) throws -> Data {
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let crop = FrameDecoder.outputAspectCrop(width: width, height: height, output: .virtualCamera)
    let origin = CGPoint(x: (width - crop.width) / 2, y: (height - crop.height) / 2)
    let w = CGFloat(crop.width) / 2, h = CGFloat(crop.height) / 2
    // Core Graphics origin is bottom-left: top-left 0.8, top-right 0.6, bottom-left 0.4, bottom-right 0.2.
    for (x, y, level) in [(0.0, h, 0.8), (w, h, 0.6), (0.0, 0.0, 0.4), (w, 0.0, 0.2)] {
        context.setFillColor(red: level, green: level, blue: level, alpha: 1)
        context.fill(CGRect(x: origin.x + x, y: origin.y + y, width: w, height: h))
    }
    let data = NSMutableData()
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
    try #require(CGImageDestinationFinalize(destination))
    return data as Data
}

/// Mean luma of a 9×9 block at a normalized point.
private func luma(_ buffer: CVPixelBuffer, at point: CGPoint) -> Int {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let cx = Int(point.x * CGFloat(CVPixelBufferGetWidth(buffer)))
    let cy = Int(point.y * CGFloat(CVPixelBufferGetHeight(buffer)))
    var sum = 0
    for y in (cy - 4)...(cy + 4) { for x in (cx - 4)...(cx + 4) { sum += Int(base[y * stride + x]) } }
    return sum / 81
}

private let quadrantCentres = [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.75, y: 0.25),
                               CGPoint(x: 0.25, y: 0.75), CGPoint(x: 0.75, y: 0.75)]

private func frame(_ jpeg: Data, _ sequence: UInt64 = 1) -> CameraFrame {
    let now = HostTime.now()
    return CameraFrame(sequence: sequence, jpeg: jpeg, acquisitionStart: now, acquisitionEnd: now)
}

/// Decodes `jpeg` with enhance on until the background-built scaler takes over (or 5 s pass, as in
/// the capture loop, where frames keep flowing through plain scaling meanwhile).
private func decodeEnhanced(_ decoder: FrameDecoder, _ jpeg: Data, orientation: FrameOrientation = .normal) throws -> CVPixelBuffer {
    let deadline = ContinuousClock.now + .seconds(5)
    var sequence: UInt64 = 0
    while true {
        sequence += 1
        let buffer = try decoder.decode(frame(jpeg, sequence), sequence: sequence, orientation: orientation, enhance: true).pixelBuffer
        // Settled: the scaler took over, or the build finished and the crop was rejected.
        let settled = decoder.isEnhancing || (sequence > 1 && !decoder.isEnhancePending)
        if settled || ContinuousClock.now > deadline { return buffer }
        Thread.sleep(forTimeInterval: 0.02)
    }
}

/// Whether the scaler really enhances here. GitHub's macOS runners are virtual machines: they report
/// `isEnhanceSupported`, but every frame fails (VTFrameProcessor -19730; the VM has no
/// AppleM2ScalerParavirtDriver), and the decoder drops the scaler for plain scaling as designed.
/// Tests of the enhanced picture need the real thing.
private let enhanceWorksOnThisMac: Bool = {
    guard FrameDecoder.isEnhanceSupported, let jpeg = try? croppedQuadrantsJPEG(width: 960, height: 640) else { return false }
    let decoder = FrameDecoder(output: .virtualCamera)
    return (try? decodeEnhanced(decoder, jpeg)) != nil && decoder.isEnhancing
}()

@Suite("Frame enhance")
struct FrameEnhanceTests {
    @Test func outputAspectCropKeepsTheLargestEvenCentreCrop() {
        let output = VideoFormat.virtualCamera
        func crop(_ w: Int, _ h: Int) -> CropSize { FrameDecoder.outputAspectCrop(width: w, height: h, output: output) }
        #expect(crop(960, 640) == CropSize(width: 960, height: 540))  // SL2 stills
        #expect(crop(1024, 576) == CropSize(width: 1024, height: 576))  // SL2 movie
        #expect(crop(640, 480) == CropSize(width: 640, height: 360))
        #expect(crop(1200, 500) == CropSize(width: 888, height: 500))  // wider than 16:9
        #expect(crop(999, 999) == CropSize(width: 998, height: 560))  // odd sizes round down to even
    }

    /// SL2 photo mode (3:2, cropped) and movie mode (16:9, not cropped): enhancing must keep the same
    /// framing, size, format and IOSurface backing as plain scaling.
    @Test(.enabled(if: enhanceWorksOnThisMac), arguments: [(960, 640), (1024, 576)])
    func enhancedFramesMatchPlainScalingFraming(_ size: (Int, Int)) throws {
        let jpeg = try croppedQuadrantsJPEG(width: size.0, height: size.1)
        let plain = try FrameDecoder(output: .virtualCamera).decode(frame(jpeg), sequence: 1).pixelBuffer
        let decoder = FrameDecoder(output: .virtualCamera)
        let enhanced = try decodeEnhanced(decoder, jpeg)

        #expect(decoder.isEnhancing)
        #expect(CVPixelBufferGetWidth(enhanced) == 1280 && CVPixelBufferGetHeight(enhanced) == 720)
        #expect(CVPixelBufferGetPixelFormatType(enhanced) == CVPixelBufferGetPixelFormatType(plain))
        #expect(CVPixelBufferGetIOSurface(enhanced) != nil)
        for point in quadrantCentres {
            #expect(abs(luma(enhanced, at: point) - luma(plain, at: point)) <= 12, "at \(point)")
        }
        // The discarded band must not leak in: every quadrant is darker than white.
        #expect(quadrantCentres.allSatisfy { luma(enhanced, at: $0) < 200 })
    }

    @Test(.enabled(if: FrameDecoder.isEnhanceSupported))
    func sourcesTheScalerCannotTakeFallBackToPlainScaling() throws {
        // Larger than the scaler's 1280-pixel source limit.
        let jpeg = try croppedQuadrantsJPEG(width: 1920, height: 1280)
        let decoder = FrameDecoder(output: .virtualCamera)
        let buffer = try decodeEnhanced(decoder, jpeg)
        #expect(!decoder.isEnhancing)
        #expect(CVPixelBufferGetWidth(buffer) == 1280 && CVPixelBufferGetHeight(buffer) == 720)
        #expect(luma(buffer, at: quadrantCentres[0]) > luma(buffer, at: quadrantCentres[3]))
    }

    @Test(.enabled(if: enhanceWorksOnThisMac))
    func turningEnhanceOffReleasesTheStageAndOnRecreatesIt() throws {
        let jpeg = try croppedQuadrantsJPEG(width: 960, height: 640)
        let decoder = FrameDecoder(output: .virtualCamera)
        let first = try decoder.decode(frame(jpeg, 1), sequence: 1, enhance: true).pixelBuffer
        // The scaler loads in the background; the first frames are plainly scaled, not dropped.
        #expect(!decoder.isEnhancing)
        #expect(CVPixelBufferGetWidth(first) == 1280)
        _ = try decodeEnhanced(decoder, jpeg)
        #expect(decoder.isEnhancing)
        let plain = try decoder.decode(frame(jpeg, 100), sequence: 100, enhance: false).pixelBuffer
        #expect(!decoder.isEnhancing)
        #expect(CVPixelBufferGetWidth(plain) == 1280)
        _ = try decodeEnhanced(decoder, jpeg)
        #expect(decoder.isEnhancing)
        decoder.invalidate()
        #expect(!decoder.isEnhancing)
    }

    @Test(.enabled(if: enhanceWorksOnThisMac))
    func enhanceComposesWithOrientation() throws {
        let jpeg = try croppedQuadrantsJPEG(width: 960, height: 640)
        let decoder = FrameDecoder(output: .virtualCamera)
        let mirrored = try decodeEnhanced(decoder, jpeg, orientation: FrameOrientation(mirrored: true))
        #expect(decoder.isEnhancing)
        // Top-left now shows the source's top-right (0.6) and top-right shows top-left (0.8).
        #expect(luma(mirrored, at: quadrantCentres[1]) > luma(mirrored, at: quadrantCentres[0]))
        #expect(luma(mirrored, at: quadrantCentres[0]) > luma(mirrored, at: quadrantCentres[2]))
    }
}
