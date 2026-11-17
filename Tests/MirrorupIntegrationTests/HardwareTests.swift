import CoreVideo
import Foundation
import Testing
import MirrorupCanon
import MirrorupCapture
import MirrorupPTP

/// Opt-in tests against a physically connected, powered-on Canon EOS camera.
/// Run with `make test-hardware` (sets MIRRORUP_HARDWARE_TESTS=1). Skipped otherwise.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MIRRORUP_HARDWARE_TESTS"] == "1"), .serialized)
struct Hardware {
    @Test func deviceInfoOverImageCapture() async throws {
        let camera = try await CanonBackendFactory.makeCamera(transport: .imageCapture)
        try await camera.session.open()
        let info = try await camera.session.deviceInfo()
        await camera.session.close()
        #expect(info.manufacturer.lowercased().hasPrefix("canon"))
        #expect(info.supports(CanonOperation.getViewfinderData))
    }

    @Test func liveViewStartsStreamsAndStopsCleanly() async throws {
        let camera = try await CanonBackendFactory.makeCamera(transport: .imageCapture)
        try await camera.connect()
        try await camera.startLiveView()
        var last: UInt64 = 0
        for _ in 0..<30 {
            let frame = try await camera.nextFrame()
            #expect(frame.sequence > last)
            #expect(frame.jpeg.prefix(2) == Data([0xFF, 0xD8]))
            last = frame.sequence
        }
        try await camera.stopLiveView()
        await camera.disconnect()
        // A second full cycle proves resources were released and the body returned to idle state.
        let again = try await CanonBackendFactory.makeCamera(transport: .imageCapture)
        try await again.connect()
        try await again.startLiveView()
        _ = try await again.nextFrame()
        try await again.stopLiveView()
        await again.disconnect()
    }

    @Test func captureEngineStreamsDecodedFrames() async throws {
        let engine = CaptureEngine { () async throws(CameraError) -> any CameraBackend in
            try await CanonBackendFactory.makeBackend(transport: .imageCapture)
        }
        await engine.start()
        var frame: DecodedFrame?
        var after: UInt64 = 0
        for _ in 0..<60 {
            guard let f = await engine.frames.next(after: after) else { break }
            frame = f
            after = f.sequence
        }
        await engine.stop()
        let f = try #require(frame)
        #expect(f.sourceWidth > 0 && f.sourceHeight > 0)
        #expect(CVPixelBufferGetWidth(f.pixelBuffer) == VideoFormat.virtualCamera.width)
    }

    @Test func directUSBReportsOwnerWhenSystemHoldsInterface() async throws {
        do {
            _ = try await CanonBackendFactory.makeCamera(transport: .usb)
            // The interface happened to be free (e.g. ptpcamerad not running): that's also valid.
        } catch {
            #expect(error.kind == .inUseByAnotherApplication)
            #expect(error.detail?.contains("ptpcamerad") == true)
        }
    }
}

