import Synchronization

/// Forwards a transport's preparation reports to a `PTPPreparationHandler`: only changes, the closing
/// `nil` only if something was reported, nothing after `finish()`.
///
/// Reports are held back for `grace` after creation. A preparation that ends sooner reports nothing,
/// so a short wait never shows as a state of its own: a warm start (catalog done 3 ms after the
/// session opened) or a card with few files (0.43 s on an SL2). Once `grace` has passed, the latest
/// held-back report goes out, then every change.
///
/// The handler runs under the reporter's lock, so reports arrive in order and `nil` is always last;
/// it must not call back into the reporter.
public final class PTPPreparationReporter: Sendable {
    private struct State {
        var latest: PTPPreparation?
        var sent: PTPPreparation?
        var reported = false
        var released = false
        var finished = false
        var graceTimer: Task<Void, Never>?
    }

    private let state = Mutex(State())
    private let handler: PTPPreparationHandler

    public init(grace: Duration, handler: @escaping PTPPreparationHandler) {
        self.handler = handler
        guard grace > .zero else {
            state.withLock { $0.released = true }
            return
        }
        let timer = Task { [weak self] in
            do { try await Task.sleep(for: grace) } catch { return }
            self?.release()
        }
        state.withLock { $0.graceTimer = timer }
    }

    deinit {
        state.withLock { $0.graceTimer?.cancel() }
    }

    public var isFinished: Bool { state.withLock { $0.finished } }

    public func report(_ preparation: PTPPreparation) {
        state.withLock { s in
            guard !s.finished else { return }
            s.latest = preparation
            if s.released { sendLatest(&s) }
        }
    }

    /// Ends the preparation: reports `nil` if anything was reported, then ignores further calls.
    public func finish() {
        state.withLock { s in
            guard !s.finished else { return }
            s.finished = true
            s.graceTimer?.cancel()
            if s.reported { handler(nil) }
        }
    }

    private func release() {
        state.withLock { s in
            guard !s.finished, !s.released else { return }
            s.released = true
            sendLatest(&s)
        }
    }

    private func sendLatest(_ s: inout State) {
        guard let latest = s.latest, !s.reported || s.sent != latest else { return }
        s.reported = true
        s.sent = latest
        handler(latest)
    }
}
