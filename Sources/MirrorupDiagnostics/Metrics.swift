import Darwin

/// Fixed-capacity sample window for timing distributions. Old samples are overwritten, so memory is
/// bounded no matter how long a stream runs; percentiles describe the most recent `capacity` samples.
public struct SampleWindow: Sendable {
    public let capacity: Int
    private var storage: [Double]
    private var next = 0
    public private(set) var totalCount = 0

    public init(capacity: Int = 2048) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = []
        storage.reserveCapacity(capacity)
    }

    public mutating func add(_ value: Double) {
        if storage.count < capacity {
            storage.append(value)
        } else {
            storage[next] = value
        }
        next = (next + 1) % capacity
        totalCount += 1
    }

    public mutating func reset() {
        storage.removeAll(keepingCapacity: true)
        next = 0
        totalCount = 0
    }

    public var count: Int { storage.count }

    public func summary() -> Summary? {
        guard !storage.isEmpty else { return nil }
        let sorted = storage.sorted()
        func percentile(_ p: Double) -> Double {
            // Nearest-rank percentile: the smallest value with at least p% of samples at or below it.
            let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
            return sorted[max(0, min(sorted.count - 1, rank - 1))]
        }
        let mean = sorted.reduce(0, +) / Double(sorted.count)
        return Summary(
            count: sorted.count, min: sorted[0], p50: percentile(50), p95: percentile(95),
            p99: percentile(99), max: sorted[sorted.count - 1], mean: mean
        )
    }

    public struct Summary: Sendable, Equatable {
        public let count: Int
        public let min: Double
        public let p50: Double
        public let p95: Double
        public let p99: Double
        public let max: Double
        public let mean: Double

        /// p95/p99 are only meaningful with enough samples; callers should hide them below this.
        public var hasTailPercentiles: Bool { count >= 100 }

        public func formatted(unit: String = "ms") -> String {
            func f(_ v: Double) -> String { String(format: "%.2f", v) }
            var s = "n=\(count) min=\(f(min)) p50=\(f(p50))"
            if hasTailPercentiles { s += " p95=\(f(p95)) p99=\(f(p99))" }
            s += " max=\(f(max)) mean=\(f(mean)) \(unit)"
            return s
        }
    }
}

/// Events-per-second over a sliding window of host times.
public struct RateMeter: Sendable {
    private var times: [UInt64] = []
    private let windowTicks: UInt64

    public init(windowSeconds: Double = 2) {
        windowTicks = HostTime.ticks(nanoseconds: UInt64(windowSeconds * 1_000_000_000))
    }

    public mutating func record(at time: UInt64 = HostTime.now()) {
        times.append(time)
        trim(now: time)
    }

    public mutating func rate(now: UInt64 = HostTime.now()) -> Double {
        trim(now: now)
        guard times.count >= 2, let first = times.first, let last = times.last, last > first else { return 0 }
        return Double(times.count - 1) / HostTime.seconds(last - first)
    }

    private mutating func trim(now: UInt64) {
        let cutoff = now > windowTicks ? now - windowTicks : 0
        if let idx = times.firstIndex(where: { $0 >= cutoff }), idx > 0 {
            times.removeFirst(idx)
        } else if let last = times.last, last < cutoff {
            times.removeAll(keepingCapacity: true)
        }
    }
}

/// Process resource usage, read from the kernel (no sampling thread).
public enum ProcessResources {
    public struct Snapshot: Sendable {
        /// Physical footprint in bytes (what Activity Monitor reports as "Memory").
        public let physicalFootprint: UInt64
        /// Total user+system CPU time consumed by the process so far.
        public let cpuTime: Duration
        public let hostTime: UInt64
    }

    public static func snapshot() -> Snapshot? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        guard rc == 0 else { return nil }
        // ri_user_time/ri_system_time are in mach absolute time units.
        let cpuNanos = HostTime.nanoseconds(info.ri_user_time + info.ri_system_time)
        return Snapshot(
            physicalFootprint: info.ri_phys_footprint,
            cpuTime: .nanoseconds(Int64(cpuNanos)),
            hostTime: HostTime.now()
        )
    }

    /// Average CPU utilisation between two snapshots, where 1.0 is one fully busy core.
    public static func cpuUsage(from a: Snapshot, to b: Snapshot) -> Double {
        let wall = HostTime.seconds(b.hostTime &- a.hostTime)
        guard wall > 0 else { return 0 }
        return (b.cpuTime - a.cpuTime).milliseconds / 1000 / wall
    }
}

