import CoreVideo
@testable import MirrorupCapture
import MirrorupDiagnostics
import Synchronization
import Testing

@Suite("Capture engine", .timeLimit(.minutes(1)))
struct CaptureEngineTests {
    @Test func happyPathStreamsDecodedFrames() async throws {
        let camera = SyntheticCamera(configuration: syntheticConfiguration())
        let engine = CaptureEngine(configuration: testConfiguration()) { camera }
        let recorder = StateRecorder()
        let observing = recorder.start(engine)
        defer { observing.cancel() }

        await engine.start()
        let frame = try #require(await withTimeout(.seconds(10)) { await engine.frames.next(after: 0) })
        #expect(CVPixelBufferGetWidth(frame.pixelBuffer) == testOutput.width)
        #expect(CVPixelBufferGetHeight(frame.pixelBuffer) == testOutput.height)
        #expect(CVPixelBufferGetPixelFormatType(frame.pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        #expect(CVPixelBufferGetIOSurface(frame.pixelBuffer) != nil)
        #expect(frame.sourceWidth == testSource.width && frame.sourceHeight == testSource.height)

        let next = try #require(await withTimeout(.seconds(5)) { await engine.frames.next(after: frame.sequence) })
        #expect(next.sequence > frame.sequence)

        let status = try await waitForStatus(engine, "streaming with metrics") {
            $0.state == .streaming && $0.metrics.framesDecoded >= 5
        }
        #expect(status.camera?.transport == "Synthetic")
        #expect(status.metrics.framesAcquired >= status.metrics.framesDecoded)
        #expect(status.metrics.decode != nil && status.metrics.acquisition != nil)
        #expect(status.metrics.sourceWidth == testSource.width)
        #expect(status.reconnectCount == 0 && status.metrics.recoveryAttempts == 0)

        await engine.stop()
        #expect(await engine.status.state == .idle)
        #expect(await engine.status.camera == nil)
        #expect(engine.frames.latest == nil)
        #expect(await camera.disconnectCount >= 1)
        #expect(await !camera.isConnected)
        #expect(await !engine.hasLoop)
        try await waitUntil("idle observed") { recorder.observed.last == .idle }
        // The stream keeps only the newest status, so the initial `.idle` may be superseded before it is read.
        #expect(Array(recorder.observed.drop { $0 == .idle }.prefix(6)) == [.discovering, .connecting, .initializing, .ready, .streaming, .idle])
    }

    @Test func statusStreamYieldsCurrentStatusToEverySubscriber() async throws {
        let engine = CaptureEngine(configuration: testConfiguration()) { SyntheticCamera(configuration: syntheticConfiguration()) }
        var first = engine.statusStream().makeAsyncIterator()
        var second = engine.statusStream().makeAsyncIterator()
        #expect(await first.next()?.state == .idle)
        #expect(await second.next()?.state == .idle)
        await engine.start()
        #expect(await first.next()?.state != .idle)
        #expect(await second.next()?.state != .idle)
        await engine.stop()
    }

    @Test func connectionFailuresRecoverWithBackoff() async throws {
        var configuration = syntheticConfiguration()
        configuration.connectFailures = 2
        let camera = SyntheticCamera(configuration: configuration)
        let engine = CaptureEngine(configuration: testConfiguration(initialDelay: .milliseconds(60), maxDelay: .milliseconds(200))) { camera }
        let recorder = StateRecorder()
        let observing = recorder.start(engine)
        defer { observing.cancel() }

        let started = ContinuousClock.now
        await engine.start()
        let status = try await waitForStatus(engine, "streaming after connect failures") { $0.state == .streaming }
        // Backoff 60 ms then 120 ms, each within ±20 %.
        #expect(ContinuousClock.now - started >= .milliseconds(140))
        #expect(await camera.connectAttempts == 3)
        #expect(status.metrics.recoveryAttempts == 2)
        #expect(status.reconnectCount == 1)
        #expect(status.lastRecoverableError?.kind == .notFound)
        #expect(status.metrics.lastRecoveryDuration != nil)
        let recovering = recorder.observed.compactMap { state -> Int? in
            if case .recovering(let attempt, let reason) = state, !reason.isEmpty { return attempt }
            return nil
        }
        #expect(recovering == [1, 2])
        await engine.stop()
    }

    @Test func absentCameraBackoffNeverSpins() async throws {
        let factory = Mutex(0)
        let engine = CaptureEngine(configuration: testConfiguration(initialDelay: .milliseconds(20), maxDelay: .milliseconds(80))) { () throws(CameraError) -> any CameraBackend in
            factory.withLock { $0 += 1 }
            throw CameraError(.notFound, "No camera is connected.")
        }
        await engine.start()
        try await Task.sleep(for: .milliseconds(600))
        let status = await engine.status
        guard case .recovering = status.state else {
            Issue.record("expected recovering, got \(status.state)")
            return
        }
        // 20 + 40 + 80 + 80 + ... ms: at most ~10 attempts in 600 ms, never hundreds.
        let attempts = factory.withLock { $0 }
        #expect(attempts >= 3 && attempts <= 12, "\(attempts) discovery attempts")
        #expect(status.metrics.recoveryAttempts == attempts)
        await engine.stop()
        #expect(await engine.status.state == .idle)
    }

    @Test func removalRecoversAfterReinsertion() async throws {
        var configuration = syntheticConfiguration()
        configuration.removal = .init(trigger: .afterFrames(10), reinsertAfter: .milliseconds(300))
        let camera = SyntheticCamera(configuration: configuration)
        let engine = CaptureEngine(configuration: testConfiguration()) { camera }
        let recorder = StateRecorder()
        let observing = recorder.start(engine)
        defer { observing.cancel() }

        await engine.start()
        let status = try await waitForStatus(engine, "recovered after removal") { $0.reconnectCount == 1 && $0.state == .streaming }
        #expect(status.metrics.recoveryAttempts >= 1)
        #expect([.disconnected, .notFound].contains(status.lastRecoverableError?.kind))
        let recovery = try #require(status.metrics.lastRecoveryDuration)
        #expect(recovery >= .milliseconds(250), "recovery spans the removal (\(recovery))")
        #expect(recorder.observed.contains { if case .recovering = $0 { true } else { false } })
        // Frames flow again after the reconnect, with sequences that keep increasing.
        let latest = try #require(engine.frames.latest)
        let fresh = try #require(await withTimeout(.seconds(5)) { await engine.frames.next(after: latest.sequence) })
        #expect(fresh.sequence > latest.sequence)
        await engine.stop()
    }

    @Test func runtimeRemovalAndManualReinsertion() async throws {
        let camera = SyntheticCamera(configuration: syntheticConfiguration())
        let engine = CaptureEngine(configuration: testConfiguration()) { camera }
        await engine.start()
        try await waitForStatus(engine, "streaming") { $0.state == .streaming }
        await camera.simulateRemoval()
        try await waitForStatus(engine, "recovering") { if case .recovering = $0.state { true } else { false } }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await engine.status.reconnectCount == 0, "no recovery while the camera is absent")
        await camera.reinsert()
        let status = try await waitForStatus(engine, "streaming after reinsertion") { $0.state == .streaming && $0.reconnectCount == 1 }
        #expect(status.metrics.recoveryAttempts >= 2)
        await engine.stop()
    }

    @Test func stallTriggersWatchdogReconnect() async throws {
        var configuration = syntheticConfiguration()
        configuration.stall = .init(every: 15, duration: .seconds(30))
        let camera = SyntheticCamera(configuration: configuration)
        let engine = CaptureEngine(configuration: testConfiguration(stallTimeout: .milliseconds(300))) { camera }
        await engine.start()
        let status = try await waitForStatus(engine, "recovered from stall") { $0.reconnectCount >= 1 && $0.state == .streaming }
        #expect(status.lastRecoverableError?.kind == .timeout)
        #expect(await camera.connectCount >= 2)
        let duration = await elapsed { await engine.stop() }
        #expect(duration < .seconds(2))
    }

    @Test(arguments: [SyntheticCamera.InvalidFrames.Style.corruptData, .error])
    func invalidFramesAreSkippedWithoutReconnect(_ style: SyntheticCamera.InvalidFrames.Style) async throws {
        var configuration = syntheticConfiguration()
        configuration.invalidFrames = .init(every: 3, style: style)
        let camera = SyntheticCamera(configuration: configuration)
        let engine = CaptureEngine(configuration: testConfiguration()) { camera }
        await engine.start()
        let status = try await waitForStatus(engine, "frames with skips") { $0.metrics.framesDecoded >= 20 }
        #expect(status.state == .streaming)
        #expect(status.metrics.invalidFrames >= 9)
        #expect(status.reconnectCount == 0)
        #expect(status.metrics.recoveryAttempts == 0)
        #expect(status.lastRecoverableError?.kind == .invalidFrame)
        #expect(await camera.connectCount == 1)
        await engine.stop()
    }

    @Test func slowConsumerGetsFreshFramesAndDrops() async throws {
        let camera = SyntheticCamera(configuration: syntheticConfiguration(frameRate: 60))
        let engine = CaptureEngine(configuration: testConfiguration()) { camera }
        await engine.start()
        var ages: [Double] = []
        var last: UInt64 = 0
        for _ in 0..<12 {
            let after = last
            guard let frame = await withTimeout(.seconds(5), { await engine.frames.next(after: after) }) else {
                Issue.record("no frame")
                break
            }
            let now = HostTime.now()
            ages.append(HostTime.milliseconds(from: frame.captureHostTime, to: now))
            await engine.reportDelivered(frame, at: now)
            last = frame.sequence
            try await Task.sleep(for: .milliseconds(100)) // a consumer 6x slower than the camera
        }
        let status = await engine.status
        #expect(status.metrics.framesDropped >= 30, "\(status.metrics.framesDropped) drops")
        #expect(status.metrics.framesDelivered == ages.count)
        // A queue would age frames by ~80 ms per iteration (≈ 1 s by the end); a latest-frame slot keeps
        // every frame within a couple of frame periods plus decode time.
        let laterAges = ages.dropFirst(2)
        #expect(laterAges.allSatisfy { $0 < 150 }, "ages: \(ages)")
        #expect((laterAges.max() ?? 0) < (ages.first ?? 0) + 150)
        #expect(status.metrics.frameAgeAtDelivery?.count == ages.count)
        await engine.stop()
    }

    @Test func concurrentStartCreatesOneLoop() async throws {
        let factory = BackendFactory()
        let engine = CaptureEngine(configuration: testConfiguration()) { () throws(CameraError) in try await factory.make() }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { await engine.start() } }
        }
        try await waitForStatus(engine, "streaming") { $0.state == .streaming }
        await engine.start()
        try await Task.sleep(for: .milliseconds(50))
        #expect(factory.count == 1)
        await engine.stop()
        #expect(await factory.cameras.first?.disconnectCount == 1)
    }

    @Test func stopDuringConnectIsPrompt() async throws {
        var configuration = syntheticConfiguration()
        configuration.connectDelay = .seconds(30)
        let camera = SyntheticCamera(configuration: configuration)
        let engine = CaptureEngine(configuration: testConfiguration()) { camera }
        await engine.start()
        try await waitForStatus(engine, "connecting") { $0.state == .connecting }
        try await Task.sleep(for: .milliseconds(20))
        let duration = await elapsed { await engine.stop() }
        #expect(duration < .seconds(1), "stop took \(duration)")
        #expect(await camera.disconnectCount == 1)
        #expect(await engine.status.state == .idle)
        #expect(await !engine.hasLoop)
    }

    @Test func stopDuringPendingNextFrameIsPrompt() async throws {
        var configuration = syntheticConfiguration()
        configuration.firstFrameDelay = .seconds(30)
        let camera = SyntheticCamera(configuration: configuration)
        let engine = CaptureEngine(configuration: testConfiguration(stallTimeout: .seconds(60))) { camera }
        await engine.start()
        try await waitForStatus(engine, "ready") { $0.state == .ready }
        try await waitUntil("frame requested") { await camera.frameRequests == 1 }
        let duration = await elapsed { await engine.stop() }
        #expect(duration < .seconds(1), "stop took \(duration)")
        #expect(await camera.disconnectCount == 1)
        #expect(await !camera.isLiveViewActive)
        #expect(await engine.status.state == .idle)
    }

    @Test func stopDuringRecoveryIsPrompt() async throws {
        var configuration = syntheticConfiguration()
        configuration.connectFailures = 1_000
        let camera = SyntheticCamera(configuration: configuration)
        let engine = CaptureEngine(configuration: testConfiguration(initialDelay: .seconds(30), maxDelay: .seconds(30))) { camera }
        await engine.start()
        try await waitForStatus(engine, "recovering") { if case .recovering(1, _) = $0.state { true } else { false } }
        let duration = await elapsed { await engine.stop() }
        #expect(duration < .seconds(1), "stop took \(duration)")
        #expect(await camera.disconnectCount == 1, "the failed session was disconnected")
        #expect(await camera.connectAttempts == 1)
        #expect(await engine.status.state == .idle)
    }

    @Test func repeatedStartStopCyclesLeaveNothingRunning() async throws {
        let factory = BackendFactory()
        let engine = CaptureEngine(configuration: testConfiguration()) { () throws(CameraError) in try await factory.make() }
        var random = SplitMix64(seed: 99)
        for cycle in 0..<50 {
            await engine.start()
            // Stop at varying points: before discovery, mid-connect, while streaming.
            let pause = Int(random.next() % 25)
            if pause > 0 { try await Task.sleep(for: .milliseconds(pause)) }
            if cycle.isMultiple(of: 2) {
                await engine.stop()
            } else {
                async let a: Void = engine.stop()
                async let b: Void = engine.stop()
                _ = await (a, b)
            }
            #expect(await engine.status.state == .idle)
            #expect(await !engine.hasLoop)
        }
        #expect(factory.count <= 50)
        for camera in factory.cameras {
            #expect(await camera.disconnectCount >= 1)
            #expect(await !camera.isConnected)
        }
    }

    @Test func restartAfterStopStreamsAgainWithIncreasingSequences() async throws {
        let factory = BackendFactory()
        let engine = CaptureEngine(configuration: testConfiguration()) { () throws(CameraError) in try await factory.make() }
        await engine.start()
        let first = try #require(await withTimeout(.seconds(5)) { await engine.frames.next(after: 0) })
        await engine.stop()
        await engine.start()
        let second = try #require(await withTimeout(.seconds(5)) { await engine.frames.next(after: first.sequence) })
        #expect(second.sequence > first.sequence)
        #expect(factory.count == 2)
        await engine.stop()
    }

    @Test func startDuringStopWaitsForTeardown() async throws {
        var configuration = syntheticConfiguration()
        configuration.disconnectDelay = .milliseconds(400)
        let factory = BackendFactory(configuration: configuration)
        let engine = CaptureEngine(configuration: testConfiguration()) { () throws(CameraError) in try await factory.make() }
        await engine.start()
        try await waitForStatus(engine, "streaming") { $0.state == .streaming }
        let stopping = Task { await engine.stop() }
        try await waitUntil("stop in progress") { await !engine.isRunning }
        await engine.start()
        try await Task.sleep(for: .milliseconds(150))
        #expect(factory.count == 1, "the new loop must not open a camera while the old one is still disconnecting")
        await stopping.value
        try await waitForStatus(engine, "streaming again") { $0.state == .streaming }
        #expect(factory.count == 2)
        #expect(await factory.cameras[0].disconnectCount == 1)
        #expect(await !factory.cameras[0].isConnected)
        await engine.stop()
    }

    @Test func fatalErrorFailsAndStartRetries() async throws {
        var configuration = syntheticConfiguration()
        configuration.connectFailures = 1
        configuration.connectFailureKind = .accessDenied
        let camera = SyntheticCamera(configuration: configuration)
        let engine = CaptureEngine(configuration: testConfiguration()) { camera }
        await engine.start()
        let failed = try await waitForStatus(engine, "failed") { if case .failed = $0.state { true } else { false } }
        #expect(failed.state == .failed(CameraError(.accessDenied, "The camera could not be opened.", detail: "Synthetic connect failure (attempt 1)")))
        #expect(await camera.disconnectCount == 1)
        await engine.start()
        try await waitForStatus(engine, "streaming after restart") { $0.state == .streaming }
        await engine.stop()
    }

    @Test func maxAttemptsBeforeFailingIsHonoured() async throws {
        var configuration = syntheticConfiguration()
        configuration.connectFailures = 100
        let camera = SyntheticCamera(configuration: configuration)
        let engine = CaptureEngine(configuration: testConfiguration(initialDelay: .milliseconds(5), maxDelay: .milliseconds(10), maxAttempts: 3)) { camera }
        await engine.start()
        try await waitForStatus(engine, "failed") { if case .failed = $0.state { true } else { false } }
        #expect(await camera.connectAttempts == 4)
        #expect(await engine.status.metrics.recoveryAttempts == 3)
        await engine.stop()
        #expect(await engine.status.state == .idle)
    }

    @Test func deadlineCancelsTheLoser() async throws {
        let started = ContinuousClock.now
        do {
            _ = try await withDeadline(after: .milliseconds(50), "sleep") { () throws(CameraError) -> Int in
                do { try await Task.sleep(for: .seconds(30)) } catch { throw CameraError(.cancelled, "cancelled") }
                return 1
            }
            Issue.record("expected a timeout")
        } catch {
            #expect(error.kind == .timeout)
        }
        #expect(ContinuousClock.now - started < .seconds(2))
        let value = try await withDeadline(after: .seconds(5), "fast") { () throws(CameraError) -> Int in 7 }
        #expect(value == 7)
    }
}
