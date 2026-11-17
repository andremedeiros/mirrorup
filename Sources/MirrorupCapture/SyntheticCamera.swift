import CoreGraphics
import Foundation
import ImageIO
import MirrorupDiagnostics

/// A software camera for tests and the "test source" option: streams pre-encoded JPEGs (moving colour
/// bars plus a frame counter) and can inject the faults a real USB camera produces. Deterministic for a
/// given `seed`. All waits honour task cancellation, and `stopLiveView`/`disconnect`/`simulateRemoval`
/// interrupt a pending `nextFrame` immediately.
public actor SyntheticCamera: CameraBackend {
    public struct Stall: Sendable, Equatable {
        /// Every `every`-th frame is delayed by `duration`.
        public var every: Int
        public var duration: Duration
        public init(every: Int, duration: Duration) {
            precondition(every > 0)
            self.every = every
            self.duration = duration
        }
    }

    public struct Removal: Sendable, Equatable {
        public enum Trigger: Sendable, Equatable {
            /// After this many `nextFrame` calls (across sessions).
            case afterFrames(Int)
            /// This long after live view first started.
            case afterTime(Duration)
        }
        public var trigger: Trigger
        /// Automatically reinsert after this long; `nil` waits for `reinsert()`.
        public var reinsertAfter: Duration?
        public init(trigger: Trigger, reinsertAfter: Duration? = nil) {
            self.trigger = trigger
            self.reinsertAfter = reinsertAfter
        }
    }

    public struct InvalidFrames: Sendable, Equatable {
        public enum Style: Sendable, Equatable {
            /// `nextFrame` throws `.invalidFrame`.
            case error
            /// `nextFrame` returns bytes that are not a decodable JPEG.
            case corruptData
        }
        /// Every `every`-th frame is invalid.
        public var every: Int
        public var style: Style
        public init(every: Int, style: Style = .corruptData) {
            precondition(every > 0)
            self.every = every
            self.style = style
        }
    }

    public struct Configuration: Sendable, Equatable {
        public var width: Int
        public var height: Int
        public var frameRate: Int
        /// Minimum time between a frame request and its delivery.
        public var acquisitionDelay: Duration
        /// Uniform random variation (±) of each frame interval.
        public var jitter: Duration
        /// Delay before the first frame of each live-view session.
        public var firstFrameDelay: Duration
        /// Time `connect()` takes.
        public var connectDelay: Duration
        /// Time `disconnect()` takes (a slow USB session close).
        public var disconnectDelay: Duration
        public var stall: Stall?
        /// The first `connectFailures` connect attempts fail with `connectFailureKind`.
        public var connectFailures: Int
        /// Probability that any later connect attempt fails.
        public var connectFailureProbability: Double
        public var connectFailureKind: CameraError.Kind
        public var removal: Removal?
        public var invalidFrames: InvalidFrames?
        /// Number of distinct pre-encoded frames.
        public var ringSize: Int
        public var seed: UInt64

        public init(
            width: Int = 960, height: Int = 640, frameRate: Int = 30,
            acquisitionDelay: Duration = .zero, jitter: Duration = .zero, firstFrameDelay: Duration = .zero,
            connectDelay: Duration = .zero, disconnectDelay: Duration = .zero, stall: Stall? = nil,
            connectFailures: Int = 0, connectFailureProbability: Double = 0, connectFailureKind: CameraError.Kind = .notFound,
            removal: Removal? = nil, invalidFrames: InvalidFrames? = nil,
            ringSize: Int = 8, seed: UInt64 = 0x5EED
        ) {
            precondition(width > 0 && height > 0 && frameRate > 0 && ringSize > 0)
            precondition((0...1).contains(connectFailureProbability))
            self.width = width
            self.height = height
            self.frameRate = frameRate
            self.acquisitionDelay = acquisitionDelay
            self.jitter = jitter
            self.firstFrameDelay = firstFrameDelay
            self.connectDelay = connectDelay
            self.disconnectDelay = disconnectDelay
            self.stall = stall
            self.connectFailures = connectFailures
            self.connectFailureProbability = connectFailureProbability
            self.connectFailureKind = connectFailureKind
            self.removal = removal
            self.invalidFrames = invalidFrames
            self.ringSize = ringSize
            self.seed = seed
        }
    }

    private enum Session { case disconnected, connected, live }

    public nonisolated let identity: CameraIdentity
    public nonisolated let configuration: Configuration

    private let jpegs: Result<[Data], CameraError>
    private var random: SplitMix64
    private var session = Session.disconnected
    private var removed = false
    private var reinsertAt: ContinuousClock.Instant?
    private var removalTriggered = false
    private var firstLiveViewAt: ContinuousClock.Instant?
    private var lastFrameAt: ContinuousClock.Instant?
    private var sequence: UInt64 = 0
    /// Bumped whenever the session is torn down, so a pending wait knows its session is gone.
    private var epoch = 0
    private var pendingWait: Task<Void, any Error>?

    public private(set) var connectAttempts = 0
    public private(set) var connectCount = 0
    public private(set) var disconnectCount = 0
    /// `nextFrame` calls so far, across sessions (successful or not).
    public private(set) var frameRequests = 0
    public private(set) var framesDelivered = 0

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
        identity = CameraIdentity(name: "Synthetic Camera", model: "\(configuration.width)x\(configuration.height)",
                                  transport: "Synthetic")
        random = SplitMix64(seed: configuration.seed)
        jpegs = Result { () throws(CameraError) in
            try (0..<configuration.ringSize).map { index throws(CameraError) in
                try SyntheticImage.jpeg(width: configuration.width, height: configuration.height,
                                        index: index, count: configuration.ringSize)
            }
        }
    }

    public var isConnected: Bool { session != .disconnected }
    public var isLiveViewActive: Bool { session == .live }
    public var isRemoved: Bool { refreshPresence(); return removed }

    // MARK: Fault injection

    /// Simulates unplugging the camera: the session drops, a pending `nextFrame` fails with
    /// `.disconnected`, and every call fails until `reinsert()` (or `reinsertAfter` elapses).
    public func simulateRemoval(reinsertAfter: Duration? = nil) {
        removed = true
        reinsertAt = reinsertAfter.map { .now + $0 }
        endSession(to: .disconnected)
        Diagnostics.capture.info("Synthetic camera removed")
    }

    public func reinsert() {
        removed = false
        reinsertAt = nil
        Diagnostics.capture.info("Synthetic camera reinserted")
    }

    // MARK: CameraBackend

    public func connect() async throws(CameraError) {
        _ = try jpegs.get() // surfaces a test-pattern encoding failure
        connectAttempts += 1
        let attempt = connectAttempts
        if configuration.connectDelay > .zero {
            try await wait(until: .now + configuration.connectDelay, epoch: epoch)
        }
        guard refreshPresence() else { throw CameraError(.notFound, "No camera is connected.", detail: "Synthetic camera removed") }
        if session != .disconnected { return }
        let failsByCount = attempt <= configuration.connectFailures
        let failsByChance = configuration.connectFailureProbability > 0 && random.nextUnit() < configuration.connectFailureProbability
        if failsByCount || failsByChance {
            throw CameraError(configuration.connectFailureKind, "The camera could not be opened.",
                              detail: "Synthetic connect failure (attempt \(attempt))")
        }
        session = .connected
        connectCount += 1
    }

    public func startLiveView() async throws(CameraError) {
        try requirePresent()
        guard session != .disconnected else { throw CameraError(.protocolViolation, "The camera is not connected.") }
        if session == .live { return }
        session = .live
        sequence = 0
        lastFrameAt = nil
        if firstLiveViewAt == nil { firstLiveViewAt = .now }
    }

    public func nextFrame() async throws(CameraError) -> CameraFrame {
        try requirePresent()
        guard session == .live else { throw CameraError(.liveViewUnavailable, "Live view is not running.") }
        frameRequests += 1
        let number = frameRequests
        if shouldTriggerRemoval(frameNumber: number) {
            simulateRemoval(reinsertAfter: configuration.removal?.reinsertAfter)
            throw CameraError(.disconnected, "The camera was disconnected.", detail: "Synthetic USB removal")
        }

        let acquisitionStart = HostTime.now()
        let begin = ContinuousClock.now
        let period = Duration.seconds(1) / configuration.frameRate
        var due = lastFrameAt.map { $0 + period } ?? begin + configuration.firstFrameDelay
        if configuration.jitter > .zero {
            due += configuration.jitter * (2 * random.nextUnit() - 1)
        }
        due = max(due, begin + configuration.acquisitionDelay)
        if let stall = configuration.stall, number % stall.every == 0 {
            due += stall.duration
        }
        try await wait(until: due, epoch: epoch)
        lastFrameAt = .now

        let jpeg: Data
        if let invalid = configuration.invalidFrames, number % invalid.every == 0 {
            switch invalid.style {
            case .error:
                throw CameraError(.invalidFrame, "The camera sent a malformed frame.", detail: "Synthetic invalid frame \(number)")
            case .corruptData:
                jpeg = SyntheticImage.corruptJPEG
            }
        } else {
            let ring = try jpegs.get()
            jpeg = ring[(number - 1) % ring.count]
        }
        sequence += 1
        framesDelivered += 1
        return CameraFrame(sequence: sequence, jpeg: jpeg, acquisitionStart: acquisitionStart, acquisitionEnd: HostTime.now())
    }

    public func stopLiveView() async throws(CameraError) {
        try requirePresent()
        if session == .live { endSession(to: .connected) }
    }

    public func disconnect() async {
        if session != .disconnected || pendingWait != nil { endSession(to: .disconnected) }
        if configuration.disconnectDelay > .zero {
            // Not cancellable: disconnect must complete. The session is already unusable meanwhile.
            try? await Task.sleep(for: configuration.disconnectDelay)
        }
        disconnectCount += 1
    }

    // MARK: Internals

    private func endSession(to newSession: Session) {
        session = newSession
        epoch += 1
        pendingWait?.cancel()
    }

    /// Sleeps until `deadline`; fails if the calling task is cancelled or the session ends meanwhile.
    private func wait(until deadline: ContinuousClock.Instant, epoch startEpoch: Int) async throws(CameraError) {
        let sleeper = Task { try await Task.sleep(until: deadline, clock: .continuous) }
        pendingWait = sleeper
        _ = await withTaskCancellationHandler {
            await sleeper.result
        } onCancel: {
            sleeper.cancel()
        }
        if pendingWait == sleeper { pendingWait = nil }
        if Task.isCancelled { throw CameraError(.cancelled, "The request was cancelled.") }
        if epoch != startEpoch {
            try requirePresent()
            throw CameraError(.liveViewUnavailable, "Live view was stopped.", detail: "Synthetic session ended while waiting")
        }
    }

    @discardableResult
    private func refreshPresence() -> Bool {
        if removed, let reinsertAt, ContinuousClock.now >= reinsertAt {
            reinsert()
        }
        return !removed
    }

    private func requirePresent() throws(CameraError) {
        guard refreshPresence() else {
            throw CameraError(.disconnected, "The camera was disconnected.", detail: "Synthetic camera removed")
        }
    }

    private func shouldTriggerRemoval(frameNumber: Int) -> Bool {
        guard let removal = configuration.removal, !removalTriggered else { return false }
        let due: Bool = switch removal.trigger {
        case .afterFrames(let count): frameNumber > count
        case .afterTime(let delay): firstLiveViewAt.map { ContinuousClock.now >= $0 + delay } ?? false
        }
        if due { removalTriggered = true }
        return due
    }
}

/// Deterministic 64-bit generator (SplitMix64).
struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `0..<1`.
    mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

/// Test-pattern JPEG generator.
enum SyntheticImage {
    /// Starts like a JPEG but has no frame header: never decodable.
    static let corruptJPEG = Data([0xFF, 0xD8, 0xFF, 0xFE, 0x00, 0x04, 0x00, 0x00, 0xFF, 0xD9])

    private static let bars: [(CGFloat, CGFloat, CGFloat)] = [
        (0.75, 0.75, 0.75), (0.75, 0.75, 0), (0, 0.75, 0.75), (0, 0.75, 0),
        (0.75, 0, 0.75), (0.75, 0, 0), (0, 0, 0.75),
    ]

    /// Colour bars shifted by `index / count` of the width, with `index` drawn as seven-segment digits.
    static func jpeg(width: Int, height: Int, index: Int, count: Int, quality: Double = 0.8) throws(CameraError) -> Data {
        try encode(width: width, height: height, quality: quality) { context in
            let w = CGFloat(width), h = CGFloat(height)
            let barWidth = w / CGFloat(bars.count)
            let shift = w * CGFloat(index) / CGFloat(max(count, 1))
            for (i, bar) in bars.enumerated() {
                context.setFillColor(red: bar.0, green: bar.1, blue: bar.2, alpha: 1)
                var x = (CGFloat(i) * barWidth + shift).truncatingRemainder(dividingBy: w)
                context.fill(CGRect(x: x, y: 0, width: barWidth, height: h))
                x -= w
                context.fill(CGRect(x: x, y: 0, width: barWidth, height: h))
            }
            drawCounter(index, in: context, height: h)
        }
    }

    /// A solid image with a band of `bandColor` covering the top `bandFraction` of its height (for crop tests).
    static func bandedJPEG(width: Int, height: Int, bandFraction: Double,
                           bandColor: (CGFloat, CGFloat, CGFloat), fill: (CGFloat, CGFloat, CGFloat)) throws(CameraError) -> Data {
        try encode(width: width, height: height, quality: 0.95) { context in
            context.setFillColor(red: fill.0, green: fill.1, blue: fill.2, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let band = CGFloat(height) * bandFraction
            context.setFillColor(red: bandColor.0, green: bandColor.1, blue: bandColor.2, alpha: 1)
            // CoreGraphics' origin is bottom-left: the top band ends at the image's top edge.
            context.fill(CGRect(x: 0, y: CGFloat(height) - band, width: CGFloat(width), height: band))
        }
    }

    private static func encode(width: Int, height: Int, quality: Double,
                               draw: (CGContext) -> Void) throws(CameraError) -> Data {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw CameraError(.protocolViolation, "The test pattern could not be drawn.", detail: "CGContext creation failed")
        }
        draw(context)
        let data = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)
        else {
            throw CameraError(.protocolViolation, "The test pattern could not be encoded.", detail: "ImageIO setup failed")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CameraError(.protocolViolation, "The test pattern could not be encoded.", detail: "CGImageDestinationFinalize failed")
        }
        return data as Data
    }

    /// Seven-segment rendering of `value` in the top-left corner.
    private static func drawCounter(_ value: Int, in context: CGContext, height: CGFloat) {
        // Segments a...g as (x, y, w, h) in a 4x7 digit cell, y measured downwards from the top.
        let segments: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (1, 0, 2, 1), (3, 1, 1, 2), (3, 4, 1, 2), (1, 6, 2, 1), (0, 4, 1, 2), (0, 1, 1, 2), (1, 3, 2, 1),
        ]
        let digitMasks: [UInt8] = [0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F]
        let digits = String(value).compactMap(\.wholeNumberValue)
        let unit = max(1, (height / 6 / 7).rounded(.down))
        let margin = unit * 2
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: height - (7 * unit + 2 * margin), width: CGFloat(digits.count) * 5 * unit + 2 * margin,
                            height: 7 * unit + 2 * margin))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        for (position, digit) in digits.enumerated() {
            let originX = margin + CGFloat(position) * 5 * unit
            for (bit, segment) in segments.enumerated() where digitMasks[digit] & (1 << bit) != 0 {
                let top = margin + segment.1 * unit
                context.fill(CGRect(x: originX + segment.0 * unit, y: height - top - segment.3 * unit,
                                    width: segment.2 * unit, height: segment.3 * unit))
            }
        }
    }
}
