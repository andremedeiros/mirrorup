import CoreVideo
import Foundation
@testable import MirrorupCapture
import MirrorupDiagnostics
import Testing

@Suite("Frame decoder")
struct FrameDecoderTests {
    static func cameraFrame(_ jpeg: Data, sequence: UInt64 = 1) -> CameraFrame {
        let now = HostTime.now()
        return CameraFrame(sequence: sequence, jpeg: jpeg, acquisitionStart: now, acquisitionEnd: now)
    }

    @Test func decodesIntoIOSurfaceBackedOutputBuffers() throws {
        let decoder = FrameDecoder(output: testOutput)
        let jpeg = try SyntheticImage.jpeg(width: 960, height: 640, index: 0, count: 1)
        let frame = Self.cameraFrame(jpeg)
        let decoded = try decoder.decode(frame, sequence: 42)
        #expect(CVPixelBufferGetWidth(decoded.pixelBuffer) == testOutput.width)
        #expect(CVPixelBufferGetHeight(decoded.pixelBuffer) == testOutput.height)
        #expect(CVPixelBufferGetPixelFormatType(decoded.pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        #expect(CVPixelBufferGetIOSurface(decoded.pixelBuffer) != nil)
        #expect(decoded.sequence == 42)
        #expect(decoded.sourceWidth == 960 && decoded.sourceHeight == 640)
        #expect(decoded.captureHostTime == frame.acquisitionEnd)
        #expect(decoded.decodedHostTime >= frame.acquisitionEnd)
    }

    @Test func defaultOutputIsTheVirtualCameraFormat() throws {
        let decoder = FrameDecoder(output: .virtualCamera)
        let decoded = try decoder.decode(Self.cameraFrame(try SyntheticImage.jpeg(width: 960, height: 640, index: 1, count: 4)), sequence: 1)
        #expect(CVPixelBufferGetWidth(decoded.pixelBuffer) == 1280)
        #expect(CVPixelBufferGetHeight(decoded.pixelBuffer) == 720)
    }

    @Test(arguments: [
        Data(), Data([0x00, 0x01, 0x02]), SyntheticImage.corruptJPEG,
        Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) }),
        Data([0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x00, 0x00, 0x00]), // SOF with zero dimensions
    ])
    func rejectsGarbageAsInvalidFrame(_ bytes: Data) {
        let decoder = FrameDecoder(output: testOutput)
        #expect(throws: CameraError.self) { try decoder.decode(Self.cameraFrame(bytes), sequence: 1) }
        do {
            _ = try decoder.decode(Self.cameraFrame(bytes), sequence: 1)
        } catch {
            #expect(error.kind == .invalidFrame)
            #expect(error.disposition == .skipFrame)
        }
    }

    @Test func rejectsCorruptScanDataAndRecovers() throws {
        let decoder = FrameDecoder(output: testOutput)
        let good = try SyntheticImage.jpeg(width: testSource.width, height: testSource.height, index: 0, count: 1)
        // A valid header followed by a scan that is cut short and overwritten with markers.
        var broken = good
        let headerEnd = broken.count / 3
        broken.replaceSubrange(headerEnd..<broken.count, with: Data(repeating: 0xFF, count: 16))
        do {
            _ = try decoder.decode(Self.cameraFrame(broken), sequence: 1)
        } catch {
            #expect(error.kind == .invalidFrame)
        }
        // Whatever the decoder made of the broken frame, the next good frame decodes.
        let decoded = try decoder.decode(Self.cameraFrame(good), sequence: 2)
        #expect(CVPixelBufferGetWidth(decoded.pixelBuffer) == testOutput.width)
    }

    @Test func handlesSourceDimensionChange() throws {
        let decoder = FrameDecoder(output: testOutput)
        let sizes = [(192, 128), (320, 240), (320, 240), (192, 128)]
        for (index, size) in sizes.enumerated() {
            let jpeg = try SyntheticImage.jpeg(width: size.0, height: size.1, index: index, count: sizes.count)
            let decoded = try decoder.decode(Self.cameraFrame(jpeg), sequence: UInt64(index + 1))
            #expect(decoded.sourceWidth == size.0 && decoded.sourceHeight == size.1)
            #expect(CVPixelBufferGetWidth(decoded.pixelBuffer) == testOutput.width)
            #expect(CVPixelBufferGetHeight(decoded.pixelBuffer) == testOutput.height)
        }
    }

    /// 3:2 -> 16:9 aspect-fill keeps 1.5/1.78 = 84.4 % of the height, cropping 7.8 % from the top and from the bottom. A dark band covering
    /// the top 4 % must disappear entirely (it would survive a stretch); one covering 15 % must remain.
    @Test func scalesWithAspectFillAndCentreCrop() throws {
        let decoder = FrameDecoder(output: testOutput)
        func topAndCentreLuma(bandFraction: Double) throws -> (top: Int, centre: Int) {
            let jpeg = try SyntheticImage.bandedJPEG(width: 384, height: 256, bandFraction: bandFraction,
                                                     bandColor: (0, 0, 0), fill: (1, 1, 1))
            let decoded = try decoder.decode(Self.cameraFrame(jpeg), sequence: 1)
            let buffer = decoded.pixelBuffer
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
            let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
            func rowMean(_ row: Int) -> Int { (0..<width).reduce(0) { $0 + Int(base[row * stride + $1]) } / width }
            return (rowMean(0), rowMean(height / 2))
        }
        let cropped = try topAndCentreLuma(bandFraction: 0.04)
        #expect(cropped.centre > 200, "white body")
        #expect(abs(cropped.top - cropped.centre) < 20, "top band removed by the centre crop (top \(cropped.top), centre \(cropped.centre))")
        let kept = try topAndCentreLuma(bandFraction: 0.15)
        #expect(kept.top < 60, "band larger than the crop remains visible (top \(kept.top))")
    }

    @Test func jpegHeaderParser() throws {
        let jpeg = try SyntheticImage.jpeg(width: 200, height: 100, index: 0, count: 1)
        let size = try #require(JPEGInfo.dimensions(of: jpeg))
        #expect(size.width == 200 && size.height == 100)
        // Works on a slice of a larger payload (as vendor containers deliver it).
        let payload = Data([1, 2, 3, 4]) + jpeg + Data([9, 9])
        let slice = payload[4..<(4 + jpeg.count)]
        #expect(JPEGInfo.dimensions(of: slice)?.width == 200)
        #expect(JPEGInfo.dimensions(of: jpeg.prefix(20)) == nil)
    }

    @Test func decodesJPEGSlicesWithoutCopying() throws {
        let decoder = FrameDecoder(output: testOutput)
        let jpeg = try SyntheticImage.jpeg(width: testSource.width, height: testSource.height, index: 0, count: 1)
        let payload = Data(repeating: 0xAB, count: 37) + jpeg + Data(repeating: 0xCD, count: 11)
        let decoded = try decoder.decode(Self.cameraFrame(payload[37..<(37 + jpeg.count)]), sequence: 1)
        #expect(decoded.sourceWidth == testSource.width)
    }
}
