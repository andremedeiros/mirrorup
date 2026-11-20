import CoreVideo
@testable import MirrorupCapture
import MirrorupDiagnostics
import Synchronization
import Testing

/// Small geometry keeps decoding fast: 3:2 source like the SL2, 16:9 output like the virtual camera.
let testSource = (width: 192, height: 128)
let testOutput = VideoFormat(width: 128, height: 72, frameRate: 30)

func testConfiguration(
    initialDelay: Duration = .milliseconds(20),
    maxDelay: Duration = .milliseconds(100),
    maxAttempts: Int? = nil,
    stallTimeout: Duration = .seconds(5),
    cameraRecheckInterval: Duration = .milliseconds(100)
) -> CaptureConfiguration {
    CaptureConfiguration(
        output: testOutput,
        recovery: RecoveryPolicy(initialDelay: initialDelay, maxDelay: maxDelay, maxAttemptsBeforeFailing: maxAttempts),
        stallTimeout: stallTimeout,
        operationTimeout: .seconds(5),
        cameraRecheckInterval: cameraRecheckInterval
    )
}

/// Camera arrivals the test triggers with `arrive()`.
final class TestArrivals: CameraArrivals {
    private struct State {
        var count: UInt64 = 0
        var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
        var nextWaiter: UInt64 = 0
    }
    private let state = Mutex(State())

    var arrivalCount: UInt64 { get async { state.withLock { $0.count } } }

    func waitForArrival(after count: UInt64) async {
        let id = state.withLock { s -> UInt64 in
            s.nextWaiter += 1
            return s.nextWaiter
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { s -> Bool in
                    if s.count > count || Task.isCancelled { return true }
                    s.waiters[id] = cont
                    return false
                }
                if resumeNow { cont.resume() }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: id) }?.resume()
        }
    }

    func arrive() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.count += 1
            defer { s.waiters.removeAll() }
            return Array(s.waiters.values)
        }
        for waiter in waiters { waiter.resume() }
    }
}

func syntheticConfiguration(frameRate: Int = 60) -> SyntheticCamera.Configuration {
    SyntheticCamera.Configuration(width: testSource.width, height: testSource.height, frameRate: frameRate, ringSize: 4)
}

struct TimedOut: Error, CustomStringConvertible {
    var what: String
    var description: String { "Timed out waiting for \(what)" }
}

/// Runs `operation`, returning `nil` if it does not finish within `timeout` (the operation is cancelled).
func withTimeout<T: Sendable>(_ timeout: Duration, _ operation: @escaping @Sendable () async -> T?) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// Polls the engine status until `predicate` holds.
@discardableResult
func waitForStatus(
    _ engine: CaptureEngine,
    timeout: Duration = .seconds(10),
    _ what: String = "status",
    _ predicate: (CaptureStatus) -> Bool
) async throws -> CaptureStatus {
    let deadline = ContinuousClock.now + timeout
    while true {
        let status = await engine.status
        if predicate(status) { return status }
        guard ContinuousClock.now < deadline else {
            throw TimedOut(what: "\(what); last status: \(status.state), reconnects \(status.reconnectCount)")
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

func waitUntil(timeout: Duration = .seconds(5), _ what: String, _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw TimedOut(what: what) }
        try await Task.sleep(for: .milliseconds(2))
    }
}

/// Measures how long `operation` takes.
func elapsed(_ operation: () async -> Void) async -> Duration {
    let start = ContinuousClock.now
    await operation()
    return ContinuousClock.now - start
}

/// The bound for "stop is prompt" tests, which stop the engine during a 30 s connect, frame wait,
/// stall or backoff: far below what they'd take if stop waited, with room for a loaded CI runner.
let promptStop: Duration = .seconds(5)

/// Records every distinct state an engine passes through, via `statusStream()`.
final class StateRecorder: Sendable {
    private let states = Mutex<[CaptureState]>([])

    /// Starts observing; cancel the returned task when done.
    func start(_ engine: CaptureEngine) -> Task<Void, Never> {
        let stream = engine.statusStream()
        return Task {
            for await status in stream {
                states.withLock { list in
                    if list.last != status.state { list.append(status.state) }
                }
            }
        }
    }

    var observed: [CaptureState] { states.withLock { $0 } }
}

func makePixelBuffer(width: Int = 16, height: Int = 16) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary
    let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &buffer)
    precondition(status == kCVReturnSuccess && buffer != nil)
    return buffer!
}

func makeDecodedFrame(sequence: UInt64, pixelBuffer: CVPixelBuffer = makePixelBuffer()) -> DecodedFrame {
    let now = HostTime.now()
    return DecodedFrame(pixelBuffer: pixelBuffer, sequence: sequence, captureHostTime: now, decodedHostTime: now,
                        sourceWidth: 16, sourceHeight: 16)
}

/// Counts backend creations and remembers every backend it made.
final class BackendFactory: Sendable {
    private let made = Mutex<[SyntheticCamera]>([])
    let configuration: SyntheticCamera.Configuration

    init(configuration: SyntheticCamera.Configuration = syntheticConfiguration()) {
        self.configuration = configuration
    }

    var count: Int { made.withLock { $0.count } }
    var cameras: [SyntheticCamera] { made.withLock { $0 } }

    func make() async throws(CameraError) -> any CameraBackend {
        let camera = SyntheticCamera(configuration: configuration)
        made.withLock { $0.append(camera) }
        return camera
    }
}
