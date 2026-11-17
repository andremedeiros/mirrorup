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
    stallTimeout: Duration = .seconds(5)
) -> CaptureConfiguration {
    CaptureConfiguration(
        output: testOutput,
        recovery: RecoveryPolicy(initialDelay: initialDelay, maxDelay: maxDelay, maxAttemptsBeforeFailing: maxAttempts),
        stallTimeout: stallTimeout,
        operationTimeout: .seconds(5)
    )
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
