/// Tells a flaky camera connection from a one-off unplug: `threshold` drops within `window` means
/// the cable, adapter or port is at fault, not the user. Fed with `CaptureStatus.disconnectCount`.
public struct ConnectionStability: Sendable, Equatable {
    public static let threshold = 3
    public static let window: Duration = .seconds(600)

    private var drops: [ContinuousClock.Instant] = []
    private var lastCount = 0

    public init() {}

    /// Records drops since the last call (`count` is cumulative; a smaller value means a new engine
    /// and starts over) and returns whether the connection counts as unstable at `now`.
    public mutating func update(disconnectCount count: Int, at now: ContinuousClock.Instant) -> Bool {
        if count < lastCount { lastCount = 0 }
        for _ in lastCount..<count { drops.append(now) }
        lastCount = count
        drops.removeAll { now - $0 > Self.window }
        return drops.count >= Self.threshold
    }

    /// Drops within the window at the last update.
    public var recentDrops: Int { drops.count }
}
