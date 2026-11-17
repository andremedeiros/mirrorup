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
/// A non-normal `FrameOrientation` adds one `VTPixelRotationSession` pass into a second
/// IOSurface-backed pool of the same format and size. Both are created on the first oriented frame
/// and released on the first `.normal` frame, so `.normal` costs nothing: the decoder's own buffer is
/// returned as is.
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
    private var orienter: FrameOrienter?

    /// Whether the orientation stage (rotation session and its pool) currently exists. For tests.
    var isOrienting: Bool { orienter != nil }

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

    /// Decodes `frame`, applies `orientation` and stamps it with `sequence`. Throws `.invalidFrame` for
    /// anything that does not decode; the session stays usable for the next frame.
    public func decode(
        _ frame: CameraFrame, sequence: UInt64, orientation: FrameOrientation = .normal
    ) throws(CameraError) -> DecodedFrame {
        guard let dimensions = JPEGInfo.dimensions(of: frame.jpeg) else {
            throw CameraError(.invalidFrame, "The camera sent an unreadable frame.", detail: "No JPEG SOF marker in \(frame.jpeg.count) bytes")
        }
        if sourceSize?.width != dimensions.width || sourceSize?.height != dimensions.height || session == nil {
            try makeSession(width: dimensions.width, height: dimensions.height)
        }
        guard let session, let formatDescription else {
            throw CameraError(.invalidFrame, "The video decoder is unavailable.", detail: "No decompression session")
        }

        let decodedBuffer = try frame.jpeg.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws(CameraError) -> CVPixelBuffer in
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

        let pixelBuffer: CVPixelBuffer
        if orientation == .normal {
            orienter = nil
            pixelBuffer = decodedBuffer
        } else {
            let stage: FrameOrienter
            if let orienter {
                stage = orienter
            } else {
                stage = try FrameOrienter(bufferAttributes: destinationAttributes)
                orienter = stage
            }
            pixelBuffer = try stage.orient(decodedBuffer, to: orientation)
        }

        return DecodedFrame(
            pixelBuffer: pixelBuffer, sequence: sequence, captureHostTime: frame.acquisitionEnd,
            decodedHostTime: HostTime.now(), sourceWidth: dimensions.width, sourceHeight: dimensions.height
        )
    }

    /// Releases the decompression session and the orientation stage; the next `decode` recreates
    /// what it needs.
    public func invalidate() {
        invalidateSession()
        orienter = nil
    }

    private func invalidateSession() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        formatDescription = nil
        sourceSize = nil
    }

    /// The orientation stage does not depend on the JPEG size, so it survives a source-size change.
    private func makeSession(width: Int, height: Int) throws(CameraError) {
        invalidateSession()
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

    fileprivate static func failure(_ step: String, _ status: OSStatus) -> CameraError {
        CameraError(.invalidFrame, "A frame could not be decoded.", detail: "\(step) failed: OSStatus \(status)")
    }
}

/// Mirrors and/or rotates decoded frames by 180° with one `VTPixelRotationSession` pass into buffers
/// from its own IOSurface-backed pool (same format and size as the decoder output, so consumers
/// cannot tell the two apart). Owned by one `FrameDecoder`; same threading rules.
private final class FrameOrienter {
    private let session: VTPixelRotationSession
    private let pool: CVPixelBufferPool
    /// Orientation the session's properties are set for; nil until the first frame.
    private var configured: FrameOrientation?

    init(bufferAttributes: CFDictionary) throws(CameraError) {
        var newSession: VTPixelRotationSession?
        var status = VTPixelRotationSessionCreate(kCFAllocatorDefault, &newSession)
        guard status == noErr, let newSession else { throw FrameDecoder.failure("VTPixelRotationSessionCreate", status) }
        var newPool: CVPixelBufferPool?
        status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, bufferAttributes, &newPool)
        guard status == kCVReturnSuccess, let newPool else {
            VTPixelRotationSessionInvalidate(newSession)
            throw FrameDecoder.failure("CVPixelBufferPoolCreate", status)
        }
        session = newSession
        pool = newPool
        Diagnostics.capture.info("Frame orientation stage created")
    }

    deinit {
        VTPixelRotationSessionInvalidate(session)
        Diagnostics.capture.info("Frame orientation stage released")
    }

    func orient(_ source: CVPixelBuffer, to orientation: FrameOrientation) throws(CameraError) -> CVPixelBuffer {
        if configured != orientation {
            try configure(for: orientation)
        }
        var destination: CVPixelBuffer?
        var status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination)
        guard status == kCVReturnSuccess, let destination else {
            throw FrameDecoder.failure("CVPixelBufferPoolCreatePixelBuffer", status)
        }
        let signpost = Diagnostics.signposter.beginInterval("Orient")
        status = VTPixelRotationSessionRotateImage(session, source, destination)
        Diagnostics.signposter.endInterval("Orient", signpost)
        guard status == noErr else { throw FrameDecoder.failure("VTPixelRotationSessionRotateImage", status) }
        return destination
    }

    /// Upside down is a 180° rotation; mirrored is a horizontal flip; both together cancel the
    /// horizontal part of the rotation and leave a vertical flip.
    private func configure(for orientation: FrameOrientation) throws(CameraError) {
        configured = nil
        let rotation = orientation.upsideDown && !orientation.mirrored ? kVTRotation_180 : kVTRotation_0
        let flipHorizontal = orientation.mirrored && !orientation.upsideDown
        let flipVertical = orientation.mirrored && orientation.upsideDown
        let properties: [(CFString, CFTypeRef)] = [
            (kVTPixelRotationPropertyKey_Rotation, rotation),
            (kVTPixelRotationPropertyKey_FlipHorizontalOrientation, flipHorizontal ? kCFBooleanTrue : kCFBooleanFalse),
            (kVTPixelRotationPropertyKey_FlipVerticalOrientation, flipVertical ? kCFBooleanTrue : kCFBooleanFalse),
        ]
        for (key, value) in properties {
            let status = VTSessionSetProperty(session, key: key, value: value)
            guard status == noErr else { throw FrameDecoder.failure("VTSessionSetProperty(\(key))", status) }
        }
        configured = orientation
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
