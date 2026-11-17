import Synchronization

/// Single-slot frame hand-off: the newest frame wins and nothing ever queues, so a slow consumer
/// sees fresh frames instead of a growing backlog. Memory is bounded by construction (one frame
/// plus whatever consumers still hold).
public final class LatestFrameBuffer: Sendable {
    private struct Waiter {
        var after: UInt64
        var continuation: CheckedContinuation<DecodedFrame?, Never>
    }

    private struct State {
        var latest: DecodedFrame?
        /// Whether some consumer took `latest` through `next(after:)`.
        var latestConsumed = false
        var dropped = 0
        var closed = false
        var nextWaiterID: UInt64 = 0
        var waiters: [UInt64: Waiter] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    /// Publishes `frame`, replacing any frame no consumer has taken yet (which counts as a drop), and
    /// wakes every consumer waiting for a frame older than it. Ignored once closed.
    public func publish(_ frame: DecodedFrame) {
        let woken: [CheckedContinuation<DecodedFrame?, Never>] = state.withLock { state in
            guard !state.closed else { return [] }
            if state.latest != nil && !state.latestConsumed { state.dropped += 1 }
            state.latest = frame
            state.latestConsumed = false
            var woken: [CheckedContinuation<DecodedFrame?, Never>] = []
            for (id, waiter) in state.waiters where waiter.after < frame.sequence {
                woken.append(waiter.continuation)
                state.waiters[id] = nil
            }
            if !woken.isEmpty { state.latestConsumed = true }
            return woken
        }
        for continuation in woken { continuation.resume(returning: frame) }
    }

    /// Returns the newest frame with a sequence greater than `sequence`, waiting for one if needed.
    /// Returns `nil` once the buffer is closed or when the calling task is cancelled.
    public func next(after sequence: UInt64) async -> DecodedFrame? {
        if let frame = takeIfNewer(than: sequence) { return frame }
        let id = state.withLock { state in
            defer { state.nextWaiterID += 1 }
            return state.nextWaiterID
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<DecodedFrame?, Never>) in
                let immediate: DecodedFrame?? = state.withLock { state in
                    if state.closed || Task.isCancelled { return .some(nil) }
                    if let latest = state.latest, latest.sequence > sequence {
                        state.latestConsumed = true
                        return .some(latest)
                    }
                    state.waiters[id] = Waiter(after: sequence, continuation: continuation)
                    return .none
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: {
            let continuation = state.withLock { $0.waiters.removeValue(forKey: id)?.continuation }
            continuation?.resume(returning: nil)
        }
    }

    /// The newest published frame, without marking it consumed.
    public var latest: DecodedFrame? { state.withLock { $0.latest } }

    /// Frames replaced before any consumer took them.
    public var droppedCount: Int { state.withLock { $0.dropped } }

    /// Permanently closes the buffer: pending and future `next(after:)` calls return `nil`.
    public func close() {
        let waiters = state.withLock { state in
            state.closed = true
            state.latest = nil
            defer { state.waiters.removeAll() }
            return state.waiters.values.map(\.continuation)
        }
        for continuation in waiters { continuation.resume(returning: nil) }
    }

    /// Forgets the current frame (e.g. when capture stops) so stale video is never served as `latest`.
    func clear() {
        state.withLock { state in
            state.latest = nil
            state.latestConsumed = false
        }
    }

    private func takeIfNewer(than sequence: UInt64) -> DecodedFrame? {
        state.withLock { state in
            guard !state.closed, let latest = state.latest, latest.sequence > sequence else { return nil }
            state.latestConsumed = true
            return latest
        }
    }

    /// Number of consumers currently waiting (for tests and diagnostics).
    var waiterCount: Int { state.withLock { $0.waiters.count } }
}
