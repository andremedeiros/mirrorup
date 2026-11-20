import CoreVideo
import Foundation
import MirrorupDevices
import MirrorupCapture
import MirrorupDiagnostics

/// `mirrorup liveview benchmark`: streams real live view and reports what was measured. Nothing here
/// reflects requested settings; every number comes from timestamps taken around actual transfers.
enum Benchmark {
    struct Report: Codable {
        var model: String
        var transport: String
        var durationSeconds: Double
        var timeToFirstFrameMs: Double
        var frames: Int
        var cameraFPS: Double
        var viewfinderRequests: Int
        var notReadyResponses: Int
        var invalidFrames: Int
        var meanFrameBytes: Int
        /// Whether frames went through the super-resolution scaler (`--enhance`), not merely requested.
        var enhanced: Bool
        var sourceWidth: Int?
        var sourceHeight: Int?
        var acquisitionMs: Stats?
        var interFrameMs: Stats?
        var decodeMs: Stats?
        var captureToDecodedMs: Stats?
        var cpuPercentOfOneCore: Double?
        var peakFootprintMB: Double?
        var errors: [String]
    }

    struct Stats: Codable {
        var count: Int, min: Double, p50: Double, p95: Double?, p99: Double?, max: Double, mean: Double
        init?(_ s: SampleWindow.Summary?) {
            guard let s else { return nil }
            count = s.count; min = s.min; p50 = s.p50; max = s.max; mean = s.mean
            p95 = s.hasTailPercentiles ? s.p95 : nil
            p99 = s.hasTailPercentiles ? s.p99 : nil
        }
    }

    static func run(duration: Duration, decode: Bool, enhance: Bool, jsonPath: String?,
                    transport: CameraTransport) async throws {
        if enhance && !FrameDecoder.isEnhanceSupported {
            throw CLIError("--enhance needs Apple silicon with macOS 26's super-resolution scaler")
        }
        let camera = try await Commands.openCamera(transport)
        let capacity = 1 << 16  // enough to keep every sample of a 30-minute run at 30 fps
        var acquisition = SampleWindow(capacity: capacity)
        var interFrame = SampleWindow(capacity: capacity)
        var decodeTimes = SampleWindow(capacity: capacity)
        var captureToDecoded = SampleWindow(capacity: capacity)
        var frames = 0
        var bytes = 0
        var errors: [String] = []
        var sourceSize: (Int, Int)?
        var peakFootprint: UInt64 = 0
        let decoder = decode ? FrameDecoder(output: .virtualCamera) : nil
        var enhanced = false

        do {
            try await camera.connect(progress: PreparationNotice.camera)
            let identity = await camera.identity
            print("benchmarking \(identity.model ?? identity.name) via \(identity.transport) for \(duration) (decode: \(decode ? "on" : "off"), enhance: \(enhance ? "on" : "off"))")
            let resourcesStart = ProcessResources.snapshot()
            let armStart = ContinuousClock.now
            try await camera.startLiveView()
            var first = try await camera.nextFrame()
            let timeToFirstFrame = ContinuousClock.now - armStart
            let streamStart = ContinuousClock.now
            var previousEnd = first.acquisitionEnd
            var lastProgress = ContinuousClock.now

            func account(_ frame: CameraFrame) {
                frames += 1
                bytes += frame.jpeg.count
                acquisition.add(HostTime.milliseconds(from: frame.acquisitionStart, to: frame.acquisitionEnd))
                if let decoder {
                    let t0 = HostTime.now()
                    do {
                        let decoded = try decoder.decode(frame, sequence: frame.sequence, enhance: enhance)
                        enhanced = enhanced || decoder.isEnhancing
                        decodeTimes.add(HostTime.milliseconds(from: t0, to: decoded.decodedHostTime))
                        captureToDecoded.add(HostTime.milliseconds(from: frame.acquisitionEnd, to: decoded.decodedHostTime))
                        sourceSize = (decoded.sourceWidth, decoded.sourceHeight)
                    } catch {
                        errors.append("decode #\(frame.sequence): \(error.description)")
                    }
                } else if sourceSize == nil {
                    sourceSize = jpegDimensions(frame.jpeg)
                }
            }

            account(first)
            while ContinuousClock.now - streamStart < duration {
                do {
                    first = try await camera.nextFrame()
                } catch where error.kind == .invalidFrame {
                    errors.append(error.description)
                    continue
                }
                interFrame.add(HostTime.milliseconds(from: previousEnd, to: first.acquisitionEnd))
                previousEnd = first.acquisitionEnd
                account(first)
                if ContinuousClock.now - lastProgress >= .seconds(10) {
                    lastProgress = .now
                    let elapsed = (ContinuousClock.now - streamStart).milliseconds / 1000
                    if let snap = ProcessResources.snapshot() { peakFootprint = max(peakFootprint, snap.physicalFootprint) }
                    print(String(format: "  %5.0fs  %6d frames  %5.1f fps  acq p50 %.1f ms", elapsed, frames, Double(frames) / elapsed, acquisition.summary()?.p50 ?? 0))
                }
            }
            let elapsed = (ContinuousClock.now - streamStart).milliseconds / 1000
            let resourcesEnd = ProcessResources.snapshot()
            if let r = resourcesEnd { peakFootprint = max(peakFootprint, r.physicalFootprint) }
            let stats = await (camera as? any LiveViewPolling)?.pollStatistics ?? LiveViewPollStatistics()
            try await camera.stopLiveView()
            await camera.disconnect()

            let report = Report(
                model: identity.model ?? identity.name,
                transport: identity.transport,
                durationSeconds: elapsed,
                timeToFirstFrameMs: timeToFirstFrame.milliseconds,
                frames: frames,
                cameraFPS: Double(frames - 1) / elapsed,
                viewfinderRequests: stats.requests,
                notReadyResponses: stats.notReady,
                invalidFrames: stats.invalidPayloads,
                meanFrameBytes: frames > 0 ? bytes / frames : 0,
                enhanced: enhanced,
                sourceWidth: sourceSize?.0,
                sourceHeight: sourceSize?.1,
                acquisitionMs: Stats(acquisition.summary()),
                interFrameMs: Stats(interFrame.summary()),
                decodeMs: Stats(decodeTimes.summary()),
                captureToDecodedMs: Stats(captureToDecoded.summary()),
                cpuPercentOfOneCore: zip2(resourcesStart, resourcesEnd).map { ProcessResources.cpuUsage(from: $0.0, to: $0.1) * 100 },
                peakFootprintMB: peakFootprint > 0 ? Double(peakFootprint) / 1_048_576 : nil,
                errors: errors
            )
            printReport(report, acquisition: acquisition, interFrame: interFrame, decode: decodeTimes, captureToDecoded: captureToDecoded)
            if let jsonPath {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(report).write(to: URL(fileURLWithPath: jsonPath))
                print("wrote \(jsonPath)")
            }
        } catch {
            await camera.disconnect()
            throw error
        }
    }

    private static func zip2<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
        guard let a, let b else { return nil }
        return (a, b)
    }

    private static func printReport(_ r: Report, acquisition: SampleWindow, interFrame: SampleWindow, decode: SampleWindow, captureToDecoded: SampleWindow) {
        print("")
        print("camera              \(r.model) via \(r.transport)")
        print("source frames       \(r.sourceWidth.map { "\($0)x\(r.sourceHeight ?? 0)" } ?? "unknown") JPEG, mean \(r.meanFrameBytes / 1024) KiB")
        print(String(format: "streamed            %.1f s, %d frames, %.2f fps measured", r.durationSeconds, r.frames, r.cameraFPS))
        print(String(format: "first frame         %.0f ms after live view start", r.timeToFirstFrameMs))
        print(String(format: "viewfinder polls    %d (%d not ready, %.0f%%), %d invalid payloads", r.viewfinderRequests, r.notReadyResponses,
                     r.viewfinderRequests > 0 ? Double(r.notReadyResponses) * 100 / Double(r.viewfinderRequests) : 0, r.invalidFrames))
        if let s = acquisition.summary() { print("acquisition         \(s.formatted())") }
        if let s = interFrame.summary() { print("inter-frame         \(s.formatted())") }
        if let s = decode.summary() { print("\(r.enhanced ? "decode+enhance" : "decode+scale  ")      \(s.formatted())") }
        if let s = captureToDecoded.summary() { print("capture->decoded    \(s.formatted())") }
        if let cpu = r.cpuPercentOfOneCore { print(String(format: "CPU                 %.1f%% of one core (whole process)", cpu)) }
        if let mem = r.peakFootprintMB { print(String(format: "memory              %.1f MB peak physical footprint", mem)) }
        if !r.errors.isEmpty { print("errors              \(r.errors.count): \(r.errors.prefix(5).joined(separator: "; "))") }
    }
}
