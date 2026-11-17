import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import MirrorupDiagnostics
import VideoToolbox

/// The frame shown while the Mirrorup app is not feeding the sink stream. Rendered once at startup;
/// every tick reuses the same immutable pixel buffer.
struct FallbackFrame: @unchecked Sendable {
    // Immutable after `render()` returns: nothing writes to the buffer once it has been published.
    let pixelBuffer: CVPixelBuffer
    let formatDescription: CMVideoFormatDescription

    enum RenderError: Error, CustomStringConvertible {
        case pixelBuffer(CVReturn, String)
        case context
        case transfer(OSStatus)
        case formatDescription(OSStatus)

        var description: String {
            switch self {
            case let .pixelBuffer(status, what): "CVPixelBufferCreate(\(what)) failed: \(status)"
            case .context: "CGContext creation failed"
            case let .transfer(status): "VTPixelTransferSession failed: \(status)"
            case let .formatDescription(status): "CMVideoFormatDescriptionCreateForImageBuffer failed: \(status)"
            }
        }
    }

    static func render(
        width: Int = Int(VirtualCameraConfig.width),
        height: Int = Int(VirtualCameraConfig.height)
    ) throws(RenderError) -> FallbackFrame {
        let bgra = try makeBuffer(width: width, height: height, format: kCVPixelFormatType_32BGRA)
        try draw(into: bgra)

        let yuv = try makeBuffer(width: width, height: height, format: VirtualCameraConfig.pixelFormat)
        CVBufferSetAttachment(yuv, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(yuv, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(yuv, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)

        var session: VTPixelTransferSession?
        var status = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)
        guard status == noErr, let session else { throw .transfer(status) }
        defer { VTPixelTransferSessionInvalidate(session) }
        status = VTPixelTransferSessionTransferImage(session, from: bgra, to: yuv)
        guard status == noErr else { throw .transfer(status) }

        var description: CMVideoFormatDescription?
        status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: yuv, formatDescriptionOut: &description
        )
        guard status == noErr, let description else { throw .formatDescription(status) }
        return FallbackFrame(pixelBuffer: yuv, formatDescription: description)
    }

    private static func makeBuffer(width: Int, height: Int, format: OSType) throws(RenderError) -> CVPixelBuffer {
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
            kCVPixelBufferCGBitmapContextCompatibilityKey: format == kCVPixelFormatType_32BGRA,
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw .pixelBuffer(status, String(format: "%08x", format))
        }
        return buffer
    }

    private static func draw(into buffer: CVPixelBuffer) throws(RenderError) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { throw .context }

        context.setFillColor(CGColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Drawn mirrored: the frame tells the local user to open Mirrorup, and the self-views they see
        // it in (Photo Booth, FaceTime, Zoom, browsers' call previews) mirror the picture, which would
        // otherwise show the text reversed. Live frames are never mirrored here.
        context.translateBy(x: CGFloat(width), y: 0)
        context.scaleBy(x: -1, y: 1)

        let scale = CGFloat(height) / 720
        drawCentered("Mirrorup Camera", in: context, width: width, baselineY: CGFloat(height) * 0.52,
                     font: CTFontCreateUIFontForLanguage(.emphasizedSystem, 64 * scale, nil),
                     color: CGColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1))
        drawCentered("Camera not connected \u{2014} open Mirrorup", in: context, width: width, baselineY: CGFloat(height) * 0.42,
                     font: CTFontCreateUIFontForLanguage(.system, 32 * scale, nil),
                     color: CGColor(srgbRed: 0.65, green: 0.67, blue: 0.70, alpha: 1))
    }

    private static func drawCentered(_ text: String, in context: CGContext, width: Int, baselineY: CGFloat, font: CTFont?, color: CGColor) {
        var attributes: [CFString: Any] = [kCTForegroundColorAttributeName: color]
        if let font { attributes[kCTFontAttributeName] = font }
        // Nil only on allocation failure; the frame then lacks this line rather than crashing.
        guard let string = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attributes as CFDictionary) else { return }
        let line = CTLineCreateWithAttributedString(string)
        let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.textPosition = CGPoint(x: (CGFloat(width) - CGFloat(lineWidth)) / 2, y: baselineY)
        CTLineDraw(line, context)
    }
}
