import Synchronization
import Testing
@testable import MirrorupPTP

private final class Recorder: Sendable {
    private let reports = Mutex<[PTPPreparation?]>([])
    var handler: PTPPreparationHandler { { [self] report in reports.withLock { $0.append(report) } } }
    var all: [PTPPreparation?] { reports.withLock { $0 } }

    func waitFor(count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while all.count < count {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

@Suite struct PTPPreparationReporterTests {
    /// A warm start or a small card: the wait ends inside the grace period, so nothing shows.
    @Test func preparationEndingWithinGraceReportsNothing() async throws {
        let recorder = Recorder()
        let reporter = PTPPreparationReporter(grace: .seconds(10), handler: recorder.handler)
        reporter.report(.indexingStorage(percentComplete: 0))
        reporter.finish()
        #expect(recorder.all.isEmpty)
    }

    /// A long catalog: after the grace period the latest held-back progress goes out, then changes,
    /// then the closing nil.
    @Test func preparationOutlastingGraceReportsLatestThenChangesThenEnd() async throws {
        let recorder = Recorder()
        let reporter = PTPPreparationReporter(grace: .milliseconds(20), handler: recorder.handler)
        reporter.report(.indexingStorage(percentComplete: 0))
        reporter.report(.indexingStorage(percentComplete: 5))
        try await recorder.waitFor(count: 1)
        reporter.report(.indexingStorage(percentComplete: 5))
        reporter.report(.indexingStorage(percentComplete: 40))
        reporter.finish()
        reporter.report(.indexingStorage(percentComplete: 90))
        #expect(recorder.all == [.indexingStorage(percentComplete: 5), .indexingStorage(percentComplete: 40), nil])
    }
}
