@testable import MirrorupCapture
import Testing

@Suite("Synthetic camera", .timeLimit(.minutes(1)))
struct SyntheticCameraTests {
    @Test func sequencesRestartPerLiveViewSession() async throws {
        let camera = SyntheticCamera(configuration: syntheticConfiguration(frameRate: 120))
        try await camera.connect()
        try await camera.startLiveView()
        #expect(try await camera.nextFrame().sequence == 1)
        #expect(try await camera.nextFrame().sequence == 2)
        try await camera.stopLiveView()
        try await camera.startLiveView()
        let frame = try await camera.nextFrame()
        #expect(frame.sequence == 1)
        #expect(frame.acquisitionEnd >= frame.acquisitionStart)
        #expect(JPEGInfo.dimensions(of: frame.jpeg)?.width == testSource.width)
        await camera.disconnect()
        #expect(await !camera.isConnected)
    }

    @Test func pacesFramesAtTheConfiguredRate() async throws {
        let camera = SyntheticCamera(configuration: syntheticConfiguration(frameRate: 50))
        try await camera.connect()
        try await camera.startLiveView()
        _ = try await camera.nextFrame()
        let duration = try await { () async throws -> Duration in
            let start = ContinuousClock.now
            for _ in 0..<10 { _ = try await camera.nextFrame() }
            return ContinuousClock.now - start
        }()
        #expect(duration >= .milliseconds(180), "10 frames at 50 fps take ~200 ms, got \(duration)")
        await camera.disconnect()
    }

    @Test func seededConnectFailuresAreDeterministic() async {
        func pattern(seed: UInt64) async -> [Bool] {
            var configuration = syntheticConfiguration()
            configuration.connectFailureProbability = 0.5
            configuration.seed = seed
            let camera = SyntheticCamera(configuration: configuration)
            var results: [Bool] = []
            for _ in 0..<16 {
                do {
                    try await camera.connect()
                    results.append(true)
                    await camera.disconnect()
                } catch {
                    results.append(false)
                }
            }
            return results
        }
        let a = await pattern(seed: 1), b = await pattern(seed: 1), c = await pattern(seed: 2)
        #expect(a == b)
        #expect(a != c)
        #expect(a.contains(true) && a.contains(false))
    }

    @Test func stopLiveViewInterruptsPendingFrame() async throws {
        var configuration = syntheticConfiguration()
        configuration.firstFrameDelay = .seconds(30)
        let camera = SyntheticCamera(configuration: configuration)
        try await camera.connect()
        try await camera.startLiveView()
        let pending = Task { try await camera.nextFrame() }
        try await waitUntil("frame requested") { await camera.frameRequests == 1 }
        let start = ContinuousClock.now
        try await camera.stopLiveView()
        let result = await pending.result
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(throws: CameraError.self) { try result.get() }
        await camera.disconnect()
    }

    @Test func cancellationInterruptsPendingFrame() async throws {
        var configuration = syntheticConfiguration()
        configuration.firstFrameDelay = .seconds(30)
        let camera = SyntheticCamera(configuration: configuration)
        try await camera.connect()
        try await camera.startLiveView()
        let pending = Task { try await camera.nextFrame() }
        try await waitUntil("frame requested") { await camera.frameRequests == 1 }
        pending.cancel()
        switch await pending.result {
        case .success: Issue.record("expected cancellation")
        case .failure(let error): #expect((error as? CameraError)?.kind == .cancelled)
        }
        await camera.disconnect()
    }

    @Test func removalFailsCallsUntilReinserted() async throws {
        let camera = SyntheticCamera(configuration: syntheticConfiguration())
        try await camera.connect()
        try await camera.startLiveView()
        await camera.simulateRemoval()
        await #expect(throws: CameraError(.disconnected, "The camera was disconnected.", detail: "Synthetic camera removed")) {
            try await camera.nextFrame()
        }
        do {
            try await camera.connect()
            Issue.record("connect must fail while removed")
        } catch {
            #expect(error.kind == .notFound)
        }
        await camera.reinsert()
        try await camera.connect()
        try await camera.startLiveView()
        _ = try await camera.nextFrame()
        await camera.disconnect()
    }

    @Test func automaticReinsertion() async throws {
        let camera = SyntheticCamera(configuration: syntheticConfiguration())
        await camera.simulateRemoval(reinsertAfter: .milliseconds(50))
        #expect(await camera.isRemoved)
        try await Task.sleep(for: .milliseconds(80))
        #expect(await !camera.isRemoved)
        try await camera.connect()
        await camera.disconnect()
    }

    @Test func invalidFramesEveryN() async throws {
        var configuration = syntheticConfiguration(frameRate: 240)
        configuration.invalidFrames = .init(every: 2, style: .error)
        let camera = SyntheticCamera(configuration: configuration)
        try await camera.connect()
        try await camera.startLiveView()
        _ = try await camera.nextFrame()
        do {
            _ = try await camera.nextFrame()
            Issue.record("frame 2 must be invalid")
        } catch {
            #expect(error.kind == .invalidFrame)
        }
        _ = try await camera.nextFrame()
        await camera.disconnect()
    }
}
