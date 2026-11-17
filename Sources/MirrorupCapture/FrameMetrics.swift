public import MirrorupDiagnostics

/// Frame pipeline counters and timing distributions. Memory is bounded: every distribution is a
/// fixed-capacity `SampleWindow` and every rate a sliding-window `RateMeter`.
public struct FrameMetrics: Sendable {
    public struct Snapshot: Sendable, Equatable {
        public var framesAcquired: Int
        public var framesDecoded: Int
        public var framesDelivered: Int
        /// Frames replaced in the latest-frame slot before any consumer took them.
        public var framesDropped: Int
        public var invalidFrames: Int
        public var cameraFPS: Double
        public var deliveredFPS: Double
        /// Milliseconds from frame request to last byte received.
        public var acquisition: SampleWindow.Summary?
        /// Milliseconds from JPEG to published buffer: decode, scaling or enhance, and orientation.
        public var decode: SampleWindow.Summary?
        /// Milliseconds from capture (last byte received) to hand-off to the consumer's sink.
        public var frameAgeAtDelivery: SampleWindow.Summary?
        /// Milliseconds between consecutive acquired frames within one live-view session.
        public var interFrameInterval: SampleWindow.Summary?
        public var recoveryAttempts: Int
        /// Time from the failure that started the last completed recovery to the first new frame.
        public var lastRecoveryDuration: Duration?
        public var sourceWidth: Int?
        public var sourceHeight: Int?

        public init(
            framesAcquired: Int = 0, framesDecoded: Int = 0, framesDelivered: Int = 0, framesDropped: Int = 0,
            invalidFrames: Int = 0, cameraFPS: Double = 0, deliveredFPS: Double = 0,
            acquisition: SampleWindow.Summary? = nil, decode: SampleWindow.Summary? = nil,
            frameAgeAtDelivery: SampleWindow.Summary? = nil, interFrameInterval: SampleWindow.Summary? = nil,
            recoveryAttempts: Int = 0, lastRecoveryDuration: Duration? = nil,
            sourceWidth: Int? = nil, sourceHeight: Int? = nil
        ) {
            self.framesAcquired = framesAcquired
            self.framesDecoded = framesDecoded
            self.framesDelivered = framesDelivered
            self.framesDropped = framesDropped
            self.invalidFrames = invalidFrames
            self.cameraFPS = cameraFPS
            self.deliveredFPS = deliveredFPS
            self.acquisition = acquisition
            self.decode = decode
            self.frameAgeAtDelivery = frameAgeAtDelivery
            self.interFrameInterval = interFrameInterval
            self.recoveryAttempts = recoveryAttempts
            self.lastRecoveryDuration = lastRecoveryDuration
            self.sourceWidth = sourceWidth
            self.sourceHeight = sourceHeight
        }
    }

    public private(set) var framesAcquired = 0
    public private(set) var framesDecoded = 0
    public private(set) var framesDelivered = 0
    public private(set) var invalidFrames = 0
    public private(set) var recoveryAttempts = 0
    public private(set) var lastRecoveryDuration: Duration?
    public private(set) var sourceWidth: Int?
    public private(set) var sourceHeight: Int?

    private var acquisition: SampleWindow
    private var decode: SampleWindow
    private var frameAge: SampleWindow
    private var interFrame: SampleWindow
    private var cameraRate = RateMeter()
    private var deliveredRate = RateMeter()
    private var lastAcquisitionEnd: UInt64?

    public init(windowCapacity: Int = 600) {
        acquisition = SampleWindow(capacity: windowCapacity)
        decode = SampleWindow(capacity: windowCapacity)
        frameAge = SampleWindow(capacity: windowCapacity)
        interFrame = SampleWindow(capacity: windowCapacity)
    }

    public mutating func recordAcquisition(_ frame: CameraFrame) {
        framesAcquired += 1
        acquisition.add(HostTime.milliseconds(from: frame.acquisitionStart, to: frame.acquisitionEnd))
        if let last = lastAcquisitionEnd { interFrame.add(HostTime.milliseconds(from: last, to: frame.acquisitionEnd)) }
        lastAcquisitionEnd = frame.acquisitionEnd
        cameraRate.record(at: frame.acquisitionEnd)
    }

    public mutating func recordInvalidFrame() {
        invalidFrames += 1
    }

    /// Records a successful decode that started at host time `decodeStart`.
    public mutating func recordDecoded(_ frame: DecodedFrame, decodeStart: UInt64) {
        framesDecoded += 1
        decode.add(HostTime.milliseconds(from: decodeStart, to: frame.decodedHostTime))
        sourceWidth = frame.sourceWidth
        sourceHeight = frame.sourceHeight
    }

    public mutating func recordDelivered(_ frame: DecodedFrame, at hostTime: UInt64) {
        framesDelivered += 1
        frameAge.add(HostTime.milliseconds(from: frame.captureHostTime, to: hostTime))
        deliveredRate.record(at: hostTime)
    }

    public mutating func recordRecoveryAttempt() {
        recoveryAttempts += 1
    }

    public mutating func recordRecoveryCompleted(duration: Duration) {
        lastRecoveryDuration = duration
    }

    /// A new live-view session begins: the gap since the previous session is not an inter-frame interval.
    public mutating func beginSession() {
        lastAcquisitionEnd = nil
    }

    public func snapshot(framesDropped: Int, now: UInt64 = HostTime.now()) -> Snapshot {
        var cameraRate = cameraRate
        var deliveredRate = deliveredRate
        return Snapshot(
            framesAcquired: framesAcquired, framesDecoded: framesDecoded, framesDelivered: framesDelivered,
            framesDropped: framesDropped, invalidFrames: invalidFrames,
            cameraFPS: cameraRate.rate(now: now), deliveredFPS: deliveredRate.rate(now: now),
            acquisition: acquisition.summary(), decode: decode.summary(),
            frameAgeAtDelivery: frameAge.summary(), interFrameInterval: interFrame.summary(),
            recoveryAttempts: recoveryAttempts, lastRecoveryDuration: lastRecoveryDuration,
            sourceWidth: sourceWidth, sourceHeight: sourceHeight
        )
    }
}
