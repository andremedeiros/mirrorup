import Testing
@testable import MirrorupCapture

@Suite("Connection stability")
struct ConnectionStabilityTests {
    let start = ContinuousClock.now

    /// Feeds `(cumulative count, seconds after start)` pairs; returns the verdict after each.
    private func verdicts(_ updates: [(Int, Int64)], into stability: inout ConnectionStability) -> [Bool] {
        updates.map { count, seconds in stability.update(disconnectCount: count, at: start + .seconds(seconds)) }
    }

    @Test func threeDropsWithinTenMinutesAreUnstableUntilTheyAge() {
        var stability = ConnectionStability()
        // Three drops in two minutes, then no new drops: unstable while three remain in the window.
        let results = verdicts([(1, 0), (2, 60), (3, 120), (3, 590), (3, 601)], into: &stability)
        #expect(results == [false, false, true, true, false])
        #expect(stability.recentDrops == 2)
    }

    @Test func occasionalUnplugsNeverCount() {
        var stability = ConnectionStability()
        let results = verdicts((1...5).map { ($0, Int64($0) * 400) }, into: &stability)
        #expect(!results.contains(true))
    }

    @Test func severalDropsReportedAtOnceAllCount() {
        var stability = ConnectionStability()
        // Status arrives at most four times a second; a burst can land in one update.
        #expect(verdicts([(3, 0)], into: &stability) == [true])
    }

    @Test func aRestartedCounterStartsOver() {
        var stability = ConnectionStability()
        // Seven old drops, then a new engine whose counter starts again at 1.
        let results = verdicts([(7, -3600), (1, 0)], into: &stability)
        #expect(results == [true, false])
        #expect(stability.recentDrops == 1)
    }
}
