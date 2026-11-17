import CoreMedia
public import CoreVideo
import Foundation
import MirrorupDiagnostics
import VideoToolbox

/// Decodes live-view JPEGs into IOSurface-backed pixel buffers of the configured output format.
///
/// One `VTDecompressionSession` (hardware decoder when available) decodes and, through its pixel
/// transfer stage, scales with aspect-fill and centre-crops (`kVTScalingMode_Trim`) straight into
/// buffers from the session's own pool, which VideoToolbox sizes from the destination attributes.
/// The session is recreated whenever the JPEG dimensions change.
///
/// Not thread-safe and deliberately not `Sendable`: create, use and drop it from a single owner
/// (one capture loop or one benchmark); never share it between tasks.
public final class FrameDecoder {
    public let output: VideoFormat
    public let pixelFormat: OSType

    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var sourceSize: (width: Int, height: Int)?
    private let destinationAttributes: CFDictionary

    public init(output: VideoFormat, pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        self.output = output
        self.pixelFormat = pixelFormat
        destinationAttributes = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferWidthKey: output.width,
            kCVPixelBufferHeightKey: output.height,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        ] as CFDictionary
    }

    deinit {
        invalidate()
    }

    /// Decodes `frame` and stamps it with `sequence`. Throws `.invalidFrame` for anything that does
    /// not decode; the session stays usable for the next frame.
    public func decode(_ frame: CameraFrame, sequence: UInt64) throws(CameraError) -> DecodedFrame {
        guard let dimensions = JPEGInfo.dimensions(of: frame.jpeg) else {
            throw CameraError(.invalidFrame, "The camera sent an unreadable frame.", detail: "No JPEG SOF marker in \(frame.jpeg.count) bytes")
        }
        if sourceSize?.width != dimensions.width || sourceSize?.height != dimensions.height || session == nil {
            try makeSession(width: dimensions.width, height: dimensions.height)
        }
        guard let session, let formatDescription else {
            throw CameraError(.invalidFrame, "The video decoder is unavailable.", detail: "No decompression session")
        }

        let pixelBuffer = try frame.jpeg.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws(CameraError) -> CVPixelBuffer in
            guard let base = raw.baseAddress, raw.count > 0 else {
                throw CameraError(.invalidFrame, "The camera sent an empty frame.")
            }
            // Zero-copy: the block buffer references the JPEG bytes with kCFAllocatorNull (never freed or
            // copied). That is only valid while `raw` is, so decoding is synchronous and completes, including
            // VTDecompressionSessionWaitForAsynchronousFrames, before this closure returns.
            var blockBuffer: CMBlockBuffer?
            var status = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: UnsafeMutableRawPointer(mutating: base),
                blockLength: raw.count, blockAllocator: kCFAllocatorNull, customBlockSource: nil,
                offsetToData: 0, dataLength: raw.count, flags: 0, blockBufferOut: &blockBuffer
            )
            guard status == noErr, let blockBuffer else { throw Self.failure("CMBlockBufferCreateWithMemoryBlock", status) }

            var timing = CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: CMTime(value: CMTimeValue(HostTime.nanoseconds(frame.acquisitionEnd)), timescale: 1_000_000_000),
                decodeTimeStamp: .invalid
            )
            var sampleSize = raw.count
            var sampleBuffer: CMSampleBuffer?
            status = CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: formatDescription,
                sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer
            )
            guard status == noErr, let sampleBuffer else { throw Self.failure("CMSampleBufferCreateReady", status) }

            let result = DecodeResult()
            status = VTDecompressionSessionDecodeFrame(
                session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil
            ) { status, _, imageBuffer, _, _ in
                result.status = status
                result.imageBuffer = imageBuffer
            }
            guard status == noErr else { throw Self.failure("VTDecompressionSessionDecodeFrame", status) }
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            guard result.status == noErr, let imageBuffer = result.imageBuffer else {
                throw Self.failure("decode output", result.status)
            }
            return imageBuffer
        }

        return DecodedFrame(
            pixelBuffer: pixelBuffer, sequence: sequence, captureHostTime: frame.acquisitionEnd,
            decodedHostTime: HostTime.now(), sourceWidth: dimensions.width, sourceHeight: dimensions.height
        )
    }

    /// Releases the decompression session; the next `decode` creates a new one.
    public func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        formatDescription = nil
        sourceSize = nil
    }

    private func makeSession(width: Int, height: Int) throws(CameraError) {
        invalidate()
        var description: CMVideoFormatDescription?
        var status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_JPEG,
            width: Int32(width), height: Int32(height), extensions: nil, formatDescriptionOut: &description
        )
        guard status == noErr, let description else { throw Self.failure("CMVideoFormatDescriptionCreate", status) }

        let specification = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true] as CFDictionary
        var newSession: VTDecompressionSession?
        status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: description, decoderSpecification: specification,
            imageBufferAttributes: destinationAttributes, outputCallback: nil, decompressionSessionOut: &newSession
        )
        guard status == noErr, let newSession else { throw Self.failure("VTDecompressionSessionCreate", status) }

        let transfer = [kVTPixelTransferPropertyKey_ScalingMode: kVTScalingMode_Trim] as CFDictionary
        status = VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_PixelTransferProperties, value: transfer)
        guard status == noErr else {
            VTDecompressionSessionInvalidate(newSession)
            throw Self.failure("kVTDecompressionPropertyKey_PixelTransferProperties", status)
        }
        // Best effort: lowers latency where the decoder supports it.
        _ = VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        session = newSession
        formatDescription = description
        sourceSize = (width, height)
        Diagnostics.capture.info("Decoder configured for \(width)x\(height) JPEG -> \(self.output.width)x\(self.output.height)")
    }

    private static func failure(_ step: String, _ status: OSStatus) -> CameraError {
        CameraError(.invalidFrame, "A frame could not be decoded.", detail: "\(step) failed: OSStatus \(status)")
    }
}

/// Receives the synchronous decoder output. Written by the output handler strictly before
/// `VTDecompressionSessionWaitForAsynchronousFrames` returns and read only after it, so it is never
/// accessed concurrently.
private final class DecodeResult: @unchecked Sendable {
    var status: OSStatus = noErr
    var imageBuffer: CVImageBuffer?
}

/// Minimal JPEG header reader.
enum JPEGInfo {
    /// Image dimensions from the first SOF segment, or `nil` if `data` is not a well-formed JPEG header.
    static func dimensions(of data: Data) -> (width: Int, height: Int)? {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> (width: Int, height: Int)? in
            let count = bytes.count
            guard count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
            var index = 2
            while index + 4 <= count {
                guard bytes[index] == 0xFF else { return nil }
                let marker = bytes[index + 1]
                if marker == 0xFF { index += 1; continue } // fill byte
                if marker == 0x01 || (0xD0...0xD7).contains(marker) { index += 2; continue } // no length
                let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
                guard length >= 2, index + 2 + length <= count else { return nil }
                switch marker {
                case 0xC0...0xCF where marker != 0xC4 && marker != 0xC8 && marker != 0xCC:
                    guard length >= 8 else { return nil }
                    let height = Int(bytes[index + 5]) << 8 | Int(bytes[index + 6])
                    let width = Int(bytes[index + 7]) << 8 | Int(bytes[index + 8])
                    guard width > 0, height > 0 else { return nil }
                    return (width, height)
                case 0xDA, 0xD9: // start of scan / end of image before any SOF
                    return nil
                default:
                    index += 2 + length
                }
            }
            return nil
        }
    }
}
