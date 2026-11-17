import CoreMedia
import CoreVideo
import MirrorupCapture

/// Wraps decoded frames in CMSampleBuffers without copying pixels. The format description is cached
/// and only rebuilt when a buffer's dimensions, pixel format or colour attachments change.
struct SampleBufferFactory {
    private var formatDescription: CMVideoFormatDescription?
    private let frameDuration = CMTime(value: 1, timescale: VirtualCameraConfig.frameRate)

    enum Failure: Error {
        case formatDescription(OSStatus)
        case sampleBuffer(OSStatus)
    }

    mutating func makeSampleBuffer(for frame: DecodedFrame) throws(Failure) -> CMSampleBuffer {
        let pixelBuffer = frame.pixelBuffer
        let description: CMVideoFormatDescription
        if let cached = formatDescription, CMVideoFormatDescriptionMatchesImageBuffer(cached, imageBuffer: pixelBuffer) {
            description = cached
        } else {
            var created: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &created
            )
            guard status == noErr, let created else { throw .formatDescription(status) }
            formatDescription = created
            description = created
        }

        // Presentation time is the capture host time, so the extension can measure frame age.
        var timing = CMSampleTimingInfo(
            duration: frameDuration,
            presentationTimeStamp: CMClockMakeHostTimeFromSystemUnits(frame.captureHostTime),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: description,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { throw .sampleBuffer(status) }

        // The in-app preview has no timebase; show each frame as soon as it is enqueued.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }
}
