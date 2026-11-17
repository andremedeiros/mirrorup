import CoreMedia
public import CoreVideo
import Foundation
import MirrorupDiagnostics
import Synchronization
import VideoToolbox

/// Decodes live-view JPEGs into IOSurface-backed pixel buffers of the configured output format.
///
/// One `VTDecompressionSession` (hardware decoder when available) decodes and, through its pixel
/// transfer stage, scales with aspect-fill and centre-crops (`kVTScalingMode_Trim`) straight into
/// buffers from the session's own pool, which VideoToolbox sizes from the destination attributes.
/// The session is recreated whenever the JPEG dimensions change.
///
/// `enhance` (Apple's low-latency super-resolution scaler, Apple silicon, macOS 26) replaces the
/// decoder's scaling: the session then decodes into the 16:9 centre crop at camera resolution
/// (e.g. 960×540), the scaler enlarges that 1.5× with a machine-learning model, and one pixel
/// transfer scales the result down to the output size. Loading the model takes about a second, so
/// the scaler is built on a background queue while frames keep flowing through plain scaling; the
/// decompression session is rebuilt once it is ready. Crop sizes the scaler rejects stay on plain
/// scaling.
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
    /// The scaler the current session decodes for; nil when the session decodes to the output size.
    private var enhancer: FrameEnhancer?
    /// A scaler being built in the background for `pendingBuild.crop`.
    private var pendingBuild: EnhancerBuild?
    /// Crop size the scaler rejected; not retried until `invalidate()`.
    private var rejectedCrop: CropSize?

    /// Whether the orientation stage (rotation session and its pool) currently exists. For tests.
    var isOrienting: Bool { orienter != nil }
    /// Whether frames are currently going through the super-resolution scaler (enhance requested,
    /// supported, and the source size accepted).
    public var isEnhancing: Bool { enhancer != nil }
    /// Whether a scaler is still being built in the background. For tests.
    var isEnhancePending: Bool { pendingBuild != nil }

    /// Whether this Mac can enhance at all (Apple silicon with the macOS 26 scaler).
    public static var isEnhanceSupported: Bool { VTLowLatencySuperResolutionScalerConfiguration.isSupported }

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

    /// Decodes `frame`, optionally enhances it, applies `orientation` and stamps it with `sequence`.
    /// Throws `.invalidFrame` for anything that does not decode; the session stays usable for the
    /// next frame.
    public func decode(
        _ frame: CameraFrame, sequence: UInt64, orientation: FrameOrientation = .normal, enhance: Bool = false
    ) throws(CameraError) -> DecodedFrame {
        guard let dimensions = JPEGInfo.dimensions(of: frame.jpeg) else {
            throw CameraError(.invalidFrame, "The camera sent an unreadable frame.", detail: "No JPEG SOF marker in \(frame.jpeg.count) bytes")
        }
        let stage = enhance && Self.isEnhanceSupported
            ? enhancerForCrop(Self.outputAspectCrop(width: dimensions.width, height: dimensions.height, output: output))
            : nil
        if sourceSize?.width != dimensions.width || sourceSize?.height != dimensions.height || session == nil
            || stage !== enhancer {
            try makeSession(width: dimensions.width, height: dimensions.height, enhancer: stage)
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

        let scaledBuffer = try enhancer?.enhance(decodedBuffer) ?? decodedBuffer

        let pixelBuffer: CVPixelBuffer
        if orientation == .normal {
            orienter = nil
            pixelBuffer = scaledBuffer
        } else {
            let stage: FrameOrienter
            if let orienter {
                stage = orienter
            } else {
                stage = try FrameOrienter(bufferAttributes: destinationAttributes)
                orienter = stage
            }
            pixelBuffer = try stage.orient(scaledBuffer, to: orientation)
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
        pendingBuild = nil
        rejectedCrop = nil
    }

    private func invalidateSession() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        formatDescription = nil
        sourceSize = nil
        enhancer = nil
    }

    /// The scaler to use for `crop` right now: the current one, a background build that just
    /// finished, or nil (plain scaling) while one is being built or after the scaler rejected `crop`.
    private func enhancerForCrop(_ crop: CropSize) -> FrameEnhancer? {
        if let enhancer, enhancer.crop == crop { return enhancer }
        if rejectedCrop == crop { return nil }
        guard let build = pendingBuild, build.crop == crop else {
            pendingBuild = EnhancerBuild(crop: crop, output: output, outputAttributes: destinationAttributes)
            return nil
        }
        guard let result = build.result else { return nil }
        pendingBuild = nil
        switch result {
        case .success(let stage):
            return stage
        case .failure(let error):
            rejectedCrop = crop
            Diagnostics.capture.notice("Enhance unavailable for a \(crop.width)x\(crop.height) crop: \(error.description, privacy: .public); using plain scaling")
            return nil
        }
    }

    /// The orientation stage does not depend on the JPEG size, so it survives a source-size change.
    /// With an `enhancer`, the session decodes into the scaler's source format at crop size.
    private func makeSession(width: Int, height: Int, enhancer newEnhancer: FrameEnhancer?) throws(CameraError) {
        invalidateSession()
        let imageBufferAttributes = newEnhancer?.sourceAttributes ?? destinationAttributes
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
            imageBufferAttributes: imageBufferAttributes, outputCallback: nil, decompressionSessionOut: &newSession
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
        enhancer = newEnhancer
        if let newEnhancer {
            Diagnostics.capture.info("Decoder configured for \(width)x\(height) JPEG -> \(newEnhancer.description, privacy: .public)")
        } else {
            Diagnostics.capture.info("Decoder configured for \(width)x\(height) JPEG -> \(self.output.width)x\(self.output.height)")
        }
    }

    /// The largest centre crop of a `width`×`height` source with the output's aspect ratio, in even
    /// dimensions (4:2:0): what aspect-fill (`kVTScalingMode_Trim`) keeps. 960×640 → 960×540.
    static func outputAspectCrop(width: Int, height: Int, output: VideoFormat) -> CropSize {
        let even = { (value: Int) in value & ~1 }
        if width * output.height > height * output.width {
            return CropSize(width: even(height * output.width / output.height), height: even(height))
        }
        return CropSize(width: even(width), height: even(width * output.height / output.width))
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

struct CropSize: Sendable, Equatable {
    var width: Int
    var height: Int
}

/// Builds a `FrameEnhancer` on a background queue (model loading takes ~1 s) and holds the result
/// until the decoder picks it up.
private final class EnhancerBuild: Sendable {
    let crop: CropSize
    private let state = Mutex<Result<FrameEnhancer, CameraError>?>(nil)

    init(crop: CropSize, output: VideoFormat, outputAttributes: CFDictionary) {
        self.crop = crop
        let attributes = UncheckedSendable(outputAttributes)
        // Holds the build itself, not just its lock: a decoder that drops the build early simply lets
        // the finished scaler be released here.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Result { () throws(CameraError) in
                try FrameEnhancer(crop: crop, output: output, outputAttributes: attributes.value)
            }
            state.withLock { $0 = result }
        }
    }

    var result: Result<FrameEnhancer, CameraError>? { state.withLock { $0 } }
}

/// CFDictionary is immutable here; carries it into the build queue.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Enlarges the decoder's crop 1.5× with `VTLowLatencySuperResolutionScaler`, then scales the result
/// to the output size with one `VTPixelTransferSession` pass into an IOSurface-backed pool matching
/// the decoder's normal output. Built for one crop size on a background queue, then owned and used
/// by one `FrameDecoder` only (hence `@unchecked Sendable`: it crosses threads once, at hand-off).
private final class FrameEnhancer: @unchecked Sendable {
    let crop: CropSize
    /// Attributes the decoder must produce: the scaler's source format, size and padding.
    let sourceAttributes: CFDictionary
    let description: String
    private let processor = VTFrameProcessor()
    private let scaledPool: CVPixelBufferPool
    private let outputPool: CVPixelBufferPool
    private let transfer: VTPixelTransferSession
    private var frameIndex: Int64 = 0

    static let scaleFactor: Float = 1.5

    init(crop source: CropSize, output: VideoFormat, outputAttributes: CFDictionary) throws(CameraError) {
        crop = source
        typealias Configuration = VTLowLatencySuperResolutionScalerConfiguration
        let factors = Configuration.supportedScaleFactors(frameWidth: source.width, frameHeight: source.height)
        guard factors.contains(Self.scaleFactor) else {
            throw CameraError(.invalidFrame, "This frame size can't be enhanced.",
                              detail: "\(source.width)x\(source.height) supports scale factors \(factors)")
        }
        let configuration = Configuration(frameWidth: source.width, frameHeight: source.height, scaleFactor: Self.scaleFactor)
        do {
            try processor.startSession(configuration: configuration)
        } catch {
            throw CameraError(.invalidFrame, "The enhancer could not start.", detail: "VTFrameProcessor.startSession: \(error)")
        }
        var scaled: CVPixelBufferPool?
        var output: CVPixelBufferPool?
        var status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, configuration.destinationPixelBufferAttributes as CFDictionary, &scaled)
        guard status == kCVReturnSuccess, let scaled else {
            processor.endSession()
            throw FrameDecoder.failure("CVPixelBufferPoolCreate(enhanced)", status)
        }
        status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, outputAttributes, &output)
        guard status == kCVReturnSuccess, let output else {
            processor.endSession()
            throw FrameDecoder.failure("CVPixelBufferPoolCreate(output)", status)
        }
        var newTransfer: VTPixelTransferSession?
        status = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &newTransfer)
        guard status == noErr, let newTransfer else {
            processor.endSession()
            throw FrameDecoder.failure("VTPixelTransferSessionCreate", status)
        }
        _ = VTSessionSetProperty(newTransfer, key: kVTPixelTransferPropertyKey_RealTime, value: kCFBooleanTrue)
        sourceAttributes = configuration.sourcePixelBufferAttributes as CFDictionary
        scaledPool = scaled
        outputPool = output
        transfer = newTransfer
        let enlarged = (Int(Float(source.width) * Self.scaleFactor), Int(Float(source.height) * Self.scaleFactor))
        description = "\(source.width)x\(source.height) crop, enhanced to \(enlarged.0)x\(enlarged.1), scaled to \(outputAttributesSize(outputAttributes))"
        Diagnostics.capture.info("Enhance stage created")
    }

    deinit {
        processor.endSession()
        VTPixelTransferSessionInvalidate(transfer)
        Diagnostics.capture.info("Enhance stage released")
    }

    /// Runs on the capture loop's thread, which already blocks on the hardware decoder. Measured on an
    /// M1 Pro with SL2 frames: ~9 ms for the scaler (960×540 → 1440×810) plus ~2.3 ms to scale down
    /// (benchmarks/sl2-30s-imagecapture-enhance.json).
    func enhance(_ source: CVPixelBuffer) throws(CameraError) -> CVPixelBuffer {
        var scaled: CVPixelBuffer?
        var status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, scaledPool, &scaled)
        guard status == kCVReturnSuccess, let scaled else { throw FrameDecoder.failure("CVPixelBufferPoolCreatePixelBuffer(enhanced)", status) }
        frameIndex += 1
        let time = CMTime(value: frameIndex, timescale: 30)
        guard let sourceFrame = VTFrameProcessorFrame(buffer: source, presentationTimeStamp: time),
              let destinationFrame = VTFrameProcessorFrame(buffer: scaled, presentationTimeStamp: time)
        else {
            throw CameraError(.invalidFrame, "A frame could not be enhanced.", detail: "VTFrameProcessorFrame rejected a buffer")
        }
        let parameters = VTLowLatencySuperResolutionScalerParameters(sourceFrame: sourceFrame, destinationFrame: destinationFrame)
        let signpost = Diagnostics.signposter.beginInterval("Enhance")
        let completion = EnhanceCompletion()
        processor.process(parameters: parameters) { _, error in
            completion.error = error
            completion.done.signal()
        }
        completion.done.wait()
        Diagnostics.signposter.endInterval("Enhance", signpost)
        if let error = completion.error {
            throw CameraError(.invalidFrame, "A frame could not be enhanced.", detail: "VTFrameProcessor.process: \(error)")
        }

        var output: CVPixelBuffer?
        status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, outputPool, &output)
        guard status == kCVReturnSuccess, let output else { throw FrameDecoder.failure("CVPixelBufferPoolCreatePixelBuffer(output)", status) }
        status = VTPixelTransferSessionTransferImage(transfer, from: scaled, to: output)
        guard status == noErr else { throw FrameDecoder.failure("VTPixelTransferSessionTransferImage", status) }
        return output
    }
}

private func outputAttributesSize(_ attributes: CFDictionary) -> String {
    let dictionary = attributes as NSDictionary
    let width = dictionary[kCVPixelBufferWidthKey] as? Int ?? 0
    let height = dictionary[kCVPixelBufferHeightKey] as? Int ?? 0
    return "\(width)x\(height)"
}

/// Hand-off from the scaler's completion handler, which runs on a VideoToolbox queue. `error` is
/// written before `done` is signalled and read only after the wait returns.
private final class EnhanceCompletion: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    var error: (any Error)?
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
