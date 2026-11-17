import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import MirrorupDiagnostics
import os

/// Hands frames from the sink stream (fed by the Mirrorup app) to the source stream (read by
/// FaceTime, Zoom, browsers...).
///
/// Live frames are forwarded the moment the sink receives them (no copy: the pixel buffer is
/// IOSurface-backed), so the extension adds no frame-interval quantisation to latency. A 30 Hz
/// host-time timer runs while at least one client is streaming and only fills gaps: if nothing was
/// sent for 1.5 frame intervals it repeats the newest live frame (while still fresh) or sends the
/// pre-rendered fallback frame once the app has not delivered anything for
/// `VirtualCameraConfig.sinkFreshnessNanoseconds`. Clients therefore always receive a steady stream.
final class FrameRelay: @unchecked Sendable {
    private struct SinkSlot {
        var sampleBuffer: CMSampleBuffer?
        var arrivalHostTime: UInt64 = 0
        var received = 0
        var rejected = 0
    }

    private struct LiveFrame {
        let pixelBuffer: CVPixelBuffer
        let formatDescription: CMFormatDescription
        let captureHostTime: UInt64
        /// Sink arrival counter; identifies the frame so it is forwarded live exactly once.
        let serial: Int
    }

    /// Statistics for one source streaming session; confined to `queue`.
    private struct SessionStats {
        var startedAt: UInt64 = 0
        var liveFrames = 0
        var repeatedLiveFrames = 0
        var fallbackFrames = 0
        var sendFailures = 0
        var lastSent: UInt64 = 0
        var lastLiveSerial = 0
        var frameAge = SampleWindow(capacity: 512)
        var sendInterval = SampleWindow(capacity: 512)
    }

    private let log = Diagnostics.virtualCamera
    private let fallback: FallbackFrame?
    private let freshnessTicks = HostTime.ticks(nanoseconds: VirtualCameraConfig.sinkFreshnessNanoseconds)
    private let frameDuration = CMTime(value: 1, timescale: VirtualCameraConfig.frameRate)
    private let gapTicks = HostTime.ticks(nanoseconds: 1_500_000_000 / UInt64(VirtualCameraConfig.frameRate))
    private let sink = OSAllocatedUnfairLock(uncheckedState: SinkSlot())

    // Everything below is confined to `queue`.
    private let queue = DispatchQueue(label: "cool.andre.Mirrorup.CameraExtension.relay", qos: .userInteractive)
    private var timer: (any DispatchSourceTimer)?
    private var stats = SessionStats()
    private var sourceStream: CMIOExtensionStream?

    init(fallback: FallbackFrame?) {
        self.fallback = fallback
    }

    // MARK: Source side

    /// Starts the gap-filling timer. CoreMediaIO calls `startStream` once for the first client and
    /// shares the stream between clients, but this is idempotent regardless.
    func startSource(on stream: CMIOExtensionStream) {
        queue.sync {
            sourceStream = stream
            guard timer == nil else { return }
            stats = SessionStats()
            stats.startedAt = HostTime.now()
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            let interval = 1_000_000_000 / Int(VirtualCameraConfig.frameRate)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(interval), leeway: .milliseconds(1))
            timer.setEventHandler { [unowned self] in self.fillGap() }
            self.timer = timer
            timer.resume()
            log.info("Source stream started")
        }
    }

    func stopSource() {
        queue.sync {
            guard let timer else { return }
            timer.cancel()
            self.timer = nil
            sourceStream = nil
            log.info("Source stream stopped: \(self.summary(), privacy: .public)")
        }
    }

    /// Forwards the newest sink frame if it has not been sent live yet. Runs on `queue`.
    private func forwardLive() {
        guard sourceStream != nil, let live = newestLiveFrame(now: HostTime.now()), live.serial != stats.lastLiveSerial else { return }
        stats.lastLiveSerial = live.serial
        stats.liveFrames += 1
        send(live.pixelBuffer, live.formatDescription, captureHostTime: live.captureHostTime)
    }

    /// Timer handler: keeps clients fed when live frames are late or absent.
    private func fillGap() {
        let now = HostTime.now()
        guard sourceStream != nil, now &- stats.lastSent >= gapTicks else { return }
        if let live = newestLiveFrame(now: now) {
            if live.serial == stats.lastLiveSerial {
                stats.repeatedLiveFrames += 1
            } else {
                stats.lastLiveSerial = live.serial
                stats.liveFrames += 1
            }
            send(live.pixelBuffer, live.formatDescription, captureHostTime: live.captureHostTime)
        } else if let fallback {
            stats.fallbackFrames += 1
            send(fallback.pixelBuffer, fallback.formatDescription, captureHostTime: nil)
        }
    }

    private func newestLiveFrame(now: UInt64) -> LiveFrame? {
        sink.withLockUnchecked { slot in
            guard let sampleBuffer = slot.sampleBuffer,
                  now &- slot.arrivalHostTime <= freshnessTicks,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                  let description = CMSampleBufferGetFormatDescription(sampleBuffer)
            else { return nil }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            return LiveFrame(
                pixelBuffer: pixelBuffer,
                formatDescription: description,
                captureHostTime: pts.isValid ? CMClockConvertHostTimeToSystemUnits(pts) : slot.arrivalHostTime,
                serial: slot.received
            )
        }
    }

    private func send(_ pixelBuffer: CVPixelBuffer, _ description: CMFormatDescription, captureHostTime: UInt64?) {
        guard let stream = sourceStream else { return }
        var now = HostTime.now()
        // Presentation times must strictly increase for clients.
        if now <= stats.lastSent { now = stats.lastSent + 1 }
        if stats.lastSent != 0 { stats.sendInterval.add(HostTime.milliseconds(from: stats.lastSent, to: now)) }
        stats.lastSent = now
        if let captureHostTime { stats.frameAge.add(HostTime.milliseconds(from: captureHostTime, to: now)) }

        var timing = CMSampleTimingInfo(
            duration: frameDuration,
            presentationTimeStamp: CMClockMakeHostTimeFromSystemUnits(now),
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
        guard status == noErr, let sampleBuffer else {
            stats.sendFailures += 1
            if stats.sendFailures == 1 || stats.sendFailures % 300 == 0 {
                log.error("CMSampleBufferCreateReadyWithImageBuffer failed: \(status) (\(self.stats.sendFailures) failures)")
            }
            return
        }
        stream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: HostTime.nanoseconds(now))

        let sent = stats.liveFrames + stats.repeatedLiveFrames + stats.fallbackFrames
        if sent % (Int(VirtualCameraConfig.frameRate) * 10) == 0 {
            log.info("Source stream: \(self.summary(), privacy: .public)")
        }
    }

    private func summary() -> String {
        let (received, rejected) = sink.withLockUnchecked { ($0.received, $0.rejected) }
        var parts = [
            "live=\(stats.liveFrames)",
            "repeated=\(stats.repeatedLiveFrames)",
            "fallback=\(stats.fallbackFrames)",
            "sendFailures=\(stats.sendFailures)",
            "sinkReceived=\(received)",
            "sinkRejected=\(rejected)",
        ]
        if let age = stats.frameAge.summary() { parts.append("frameAge[\(age.formatted())]") }
        if let interval = stats.sendInterval.summary() { parts.append("sendInterval[\(interval.formatted())]") }
        return parts.joined(separator: " ")
    }

    // MARK: Sink side

    /// Replaces the newest sink frame. Buffers that do not match the advertised format are rejected
    /// rather than forwarded, so clients never see a format they did not negotiate.
    func storeSinkSample(_ sampleBuffer: CMSampleBuffer) {
        let now = HostTime.now()
        let valid: Bool
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            valid = CVPixelBufferGetWidth(pixelBuffer) == Int(VirtualCameraConfig.width)
                && CVPixelBufferGetHeight(pixelBuffer) == Int(VirtualCameraConfig.height)
                && CVPixelBufferGetPixelFormatType(pixelBuffer) == VirtualCameraConfig.pixelFormat
        } else {
            valid = false
        }
        let rejected: Int? = sink.withLockUnchecked { slot in
            guard valid else {
                slot.rejected += 1
                return slot.rejected
            }
            slot.sampleBuffer = sampleBuffer
            slot.arrivalHostTime = now
            slot.received += 1
            return nil
        }
        if let rejected {
            if rejected == 1 || rejected % 300 == 0 {
                log.error("Rejected sink sample that does not match 1280x720 '420v' (\(rejected) rejected)")
            }
            return
        }
        queue.async { [weak self] in self?.forwardLive() }
    }

    /// Forgets the newest sink frame so the source falls back immediately when the app stops feeding.
    func clearSink() {
        sink.withLockUnchecked { slot in
            slot.sampleBuffer = nil
            slot.arrivalHostTime = 0
        }
    }
}
