public import CoreVideo
import Foundation
import MirrorupDiagnostics

/// Pixel dimensions and nominal frame rate of a video stream.
public struct VideoFormat: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var frameRate: Int

    public init(width: Int, height: Int, frameRate: Int) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
    }

    /// The format published by the Mirrorup virtual camera.
    public static let virtualCamera = VideoFormat(width: 1280, height: 720, frameRate: 30)
}

/// How the engine retries after a recoverable failure.
public struct RecoveryPolicy: Sendable, Equatable {
    /// Backoff before the first retry.
    public var initialDelay: Duration
    /// Upper bound for every backoff, jitter included.
    public var maxDelay: Duration
    /// Growth factor applied per consecutive failed attempt.
    public var multiplier: Double
    /// Random spread around the nominal delay, as a fraction of it (0.2 = ±20 %).
    public var jitter: Double
    /// Consecutive failed attempts tolerated before giving up with `.failed`;
    /// `nil` keeps trying for as long as the camera stays absent or unhealthy.
    public var maxAttemptsBeforeFailing: Int?

    public init(
        initialDelay: Duration = .milliseconds(250),
        maxDelay: Duration = .seconds(5),
        multiplier: Double = 2,
        jitter: Double = 0.2,
        maxAttemptsBeforeFailing: Int? = nil
    ) {
        precondition(initialDelay >= .zero && maxDelay >= initialDelay, "RecoveryPolicy delays must satisfy 0 <= initialDelay <= maxDelay")
        precondition(multiplier >= 1, "RecoveryPolicy multiplier must be >= 1")
        precondition((0...1).contains(jitter), "RecoveryPolicy jitter must be within 0...1")
        precondition(maxAttemptsBeforeFailing.map { $0 >= 1 } ?? true, "maxAttemptsBeforeFailing must be >= 1")
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.multiplier = multiplier
        self.jitter = jitter
        self.maxAttemptsBeforeFailing = maxAttemptsBeforeFailing
    }

    /// Nominal (jitter-free) delay before retry number `attempt` (1-based), capped at `maxDelay`.
    public func nominalDelay(forAttempt attempt: Int) -> Duration {
        let initial = initialDelay.milliseconds
        let exponent = Double(max(0, attempt - 1))
        let grown = initial * pow(multiplier, exponent)
        return .milliseconds(min(grown, maxDelay.milliseconds))
    }

    /// Jittered delay before retry number `attempt`. `unitRandom` must be in `0..<1`; 0.5 yields the nominal delay.
    /// The result stays within `±jitter` of the nominal delay and never exceeds `maxDelay`.
    public func delay(forAttempt attempt: Int, unitRandom: Double) -> Duration {
        let nominal = nominalDelay(forAttempt: attempt).milliseconds
        let spread = jitter * (2 * min(max(unitRandom, 0), 1) - 1)
        let jittered = min(max(nominal * (1 + spread), 0), maxDelay.milliseconds)
        return .microseconds(Int64((jittered * 1_000).rounded()))
    }

    public func delay(forAttempt attempt: Int, using generator: inout some RandomNumberGenerator) -> Duration {
        delay(forAttempt: attempt, unitRandom: Double.random(in: 0..<1, using: &generator))
    }
}

/// Engine configuration. Values are read once per `start()`.
public struct CaptureConfiguration: Sendable {
    /// Output geometry; the decoder scales with aspect-fill and centre-crops into it.
    public var output: VideoFormat
    /// Output pixel format (IOSurface-backed buffers).
    public var pixelFormat: OSType
    public var recovery: RecoveryPolicy
    /// Stall watchdog: with no valid frame for this long, the session is treated as timed out and reconnected.
    public var stallTimeout: Duration
    /// Deadline for `connect`, `startLiveView` and `stopLiveView`.
    public var operationTimeout: Duration

    public init(
        output: VideoFormat = .virtualCamera,
        pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        recovery: RecoveryPolicy = .init(),
        stallTimeout: Duration = .seconds(5),
        operationTimeout: Duration = .seconds(10)
    ) {
        precondition(output.width > 0 && output.height > 0 && output.width % 2 == 0 && output.height % 2 == 0,
                     "Output dimensions must be positive and even")
        precondition(stallTimeout > .zero && operationTimeout > .zero, "Timeouts must be positive")
        self.output = output
        self.pixelFormat = pixelFormat
        self.recovery = recovery
        self.stallTimeout = stallTimeout
        self.operationTimeout = operationTimeout
    }
}

/// Lifecycle of the capture engine.
public enum CaptureState: Sendable, Equatable {
    case idle
    /// Creating the backend (finding the camera).
    case discovering
    case connecting
    /// Connected; entering live view.
    case initializing
    /// Live view running; waiting for the first frame.
    case ready
    case streaming
    /// Waiting out the backoff before retry `attempt` after `reason`.
    case recovering(attempt: Int, reason: String)
    /// Retrying cannot help; the user has to act. `start()` tries again.
    case failed(CameraError)
}

/// Everything the UI needs to describe the capture pipeline.
public struct CaptureStatus: Sendable, Equatable {
    public var state: CaptureState
    public var camera: CameraIdentity?
    public var metrics: FrameMetrics.Snapshot
    public var lastRecoverableError: CameraError?
    /// Number of completed recoveries (a recovery completes when a frame is published after it).
    public var reconnectCount: Int

    public init(
        state: CaptureState = .idle,
        camera: CameraIdentity? = nil,
        metrics: FrameMetrics.Snapshot = .init(),
        lastRecoverableError: CameraError? = nil,
        reconnectCount: Int = 0
    ) {
        self.state = state
        self.camera = camera
        self.metrics = metrics
        self.lastRecoverableError = lastRecoverableError
        self.reconnectCount = reconnectCount
    }
}

/// Inputs to the capture state machine.
enum CaptureEvent: Sendable, Equatable {
    case start
    case backendCreated
    case connected
    case liveViewStarted
    case framePublished
    case failed(CameraError)
    /// Backoff elapsed; try again.
    case retry
    case stop
}

/// Pure capture state machine. Every engine state change goes through `handle(_:)`.
struct CaptureStateMachine: Sendable, Equatable {
    struct Transition: Sendable, Equatable {
        var from: CaptureState
        var to: CaptureState
        /// The first frame after one or more failed attempts was published.
        var completedRecovery: Bool = false
    }

    private(set) var state: CaptureState = .idle
    /// Failed attempts since the last published frame (or since `start`).
    private(set) var consecutiveFailures = 0
    let maxAttemptsBeforeFailing: Int?

    init(maxAttemptsBeforeFailing: Int? = nil) {
        self.maxAttemptsBeforeFailing = maxAttemptsBeforeFailing
    }

    /// Applies `event`. Returns `nil` when the event is not valid in the current state (the state is unchanged).
    mutating func handle(_ event: CaptureEvent) -> Transition? {
        let from = state
        guard let (to, completedRecovery) = next(for: event) else { return nil }
        state = to
        return Transition(from: from, to: to, completedRecovery: completedRecovery)
    }

    private mutating func next(for event: CaptureEvent) -> (CaptureState, Bool)? {
        switch (state, event) {
        case (_, .stop):
            consecutiveFailures = 0
            return (.idle, false)

        case (.idle, .start), (.failed, .start):
            consecutiveFailures = 0
            return (.discovering, false)

        case (.discovering, .backendCreated):
            return (.connecting, false)
        case (.connecting, .connected):
            return (.initializing, false)
        case (.initializing, .liveViewStarted):
            return (.ready, false)

        case (.ready, .framePublished):
            let recovered = consecutiveFailures > 0
            consecutiveFailures = 0
            return (.streaming, recovered)
        case (.streaming, .framePublished):
            return (.streaming, false)

        case (.recovering, .retry):
            return (.discovering, false)

        case (.discovering, .failed(let error)), (.connecting, .failed(let error)), (.initializing, .failed(let error)),
             (.ready, .failed(let error)), (.streaming, .failed(let error)):
            return failure(error)

        default:
            return nil
        }
    }

    private mutating func failure(_ error: CameraError) -> (CaptureState, Bool)? {
        switch error.disposition {
        case .skipFrame where state == .ready || state == .streaming:
            return (state, false)
        case .skipFrame, .reconnect, .waitForDevice:
            consecutiveFailures += 1
            if let limit = maxAttemptsBeforeFailing, consecutiveFailures > limit {
                return (.failed(error), false)
            }
            return (.recovering(attempt: consecutiveFailures, reason: error.message), false)
        case .fatal:
            return (.failed(error), false)
        case .stop:
            consecutiveFailures = 0
            return (.idle, false)
        }
    }
}

extension CaptureState {
    /// States in which a capture loop is (or should be) running.
    var isActive: Bool {
        switch self {
        case .idle, .failed: false
        default: true
        }
    }
}
