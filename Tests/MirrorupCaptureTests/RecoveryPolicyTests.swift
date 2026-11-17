@testable import MirrorupCapture
import MirrorupDiagnostics
import Testing

@Suite("Recovery policy")
struct RecoveryPolicyTests {
    let policy = RecoveryPolicy(initialDelay: .milliseconds(250), maxDelay: .seconds(5), multiplier: 2, jitter: 0.2)

    @Test func nominalDelayGrowsThenCaps() {
        let expected: [Double] = [250, 500, 1_000, 2_000, 4_000, 5_000, 5_000]
        let actual = (1...7).map { policy.nominalDelay(forAttempt: $0).milliseconds }
        #expect(actual == expected)
        #expect(policy.nominalDelay(forAttempt: 10_000) == .seconds(5), "huge attempt numbers must not overflow")
    }

    @Test func midpointRandomGivesNominalDelay() {
        for attempt in 1...8 {
            #expect(abs(policy.delay(forAttempt: attempt, unitRandom: 0.5).milliseconds - policy.nominalDelay(forAttempt: attempt).milliseconds) < 0.001)
        }
    }

    @Test func jitteredDelaysStayWithinFractionAndBound() {
        var generator = SplitMix64(seed: 42)
        var sawBelow = false, sawAbove = false
        for attempt in 1...30 {
            let nominal = policy.nominalDelay(forAttempt: attempt).milliseconds
            for unit in [0, 0.25, 0.5, 0.75, 0.999_999] + (0..<50).map({ _ in generator.nextUnit() }) {
                let delay = policy.delay(forAttempt: attempt, unitRandom: unit).milliseconds
                #expect(delay <= policy.maxDelay.milliseconds)
                #expect(delay >= nominal * (1 - policy.jitter) - 0.001)
                #expect(delay <= nominal * (1 + policy.jitter) + 0.001)
                if delay < nominal - 1 { sawBelow = true }
                if delay > nominal + 1 { sawAbove = true }
            }
        }
        #expect(sawBelow && sawAbove, "jitter spreads in both directions")
    }

    @Test func seededGeneratorIsDeterministic() {
        var a = SplitMix64(seed: 7), b = SplitMix64(seed: 7)
        let first = (1...10).map { policy.delay(forAttempt: $0, using: &a) }
        let second = (1...10).map { policy.delay(forAttempt: $0, using: &b) }
        #expect(first == second)
    }

    @Test func zeroJitterIsExact() {
        let exact = RecoveryPolicy(initialDelay: .milliseconds(100), maxDelay: .seconds(1), jitter: 0)
        #expect(exact.delay(forAttempt: 3, unitRandom: 0) == .milliseconds(400))
        #expect(exact.delay(forAttempt: 3, unitRandom: 0.99) == .milliseconds(400))
    }
}
