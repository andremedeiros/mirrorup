@testable import MirrorupCapture
import Testing

@Suite("Capture state machine")
struct CaptureStateMachineTests {
    static let reconnectError = CameraError(.timeout, "Timed out")
    static let absentError = CameraError(.disconnected, "Unplugged")
    static let notFoundError = CameraError(.notFound, "No camera found. Connect your camera with a USB cable and turn it on.")
    static let fatalError = CameraError(.accessDenied, "Denied")
    static let invalidError = CameraError(.invalidFrame, "Bad frame")
    static let cancelledError = CameraError(.cancelled, "Cancelled")
    static let reading = CameraPreparation.readingStorage(percentComplete: 10)
    static let preparing = CaptureState.preparing(reading)

    /// A machine driven along the happy path up to `state`.
    static func machine(at state: CaptureState, maxAttempts: Int? = nil) -> CaptureStateMachine {
        var machine = CaptureStateMachine(maxAttemptsBeforeFailing: maxAttempts)
        let path: [CaptureEvent] = switch state {
        case .idle: []
        case .discovering: [.start]
        case .connecting: [.start, .backendCreated]
        case .preparing(let preparation): [.start, .backendCreated, .preparing(preparation)]
        case .initializing: [.start, .backendCreated, .connected]
        case .ready: [.start, .backendCreated, .connected, .liveViewStarted]
        case .streaming: [.start, .backendCreated, .connected, .liveViewStarted, .framePublished]
        case .recovering: [.start, .failed(reconnectError)]
        case .waitingForCamera: [.start, .failed(notFoundError)]
        case .failed: [.start, .failed(fatalError)]
        }
        for event in path { _ = machine.handle(event) }
        #expect(machine.state.matchesCase(of: state))
        return machine
    }

    static let allStates: [CaptureState] = [
        .idle, .discovering, .waitingForCamera(reason: notFoundError.message), .connecting, preparing, .initializing,
        .ready, .streaming, .recovering(attempt: 1, reason: reconnectError.message), .failed(fatalError),
    ]

    @Test func happyPath() {
        var machine = CaptureStateMachine()
        let expected: [(CaptureEvent, CaptureState)] = [
            (.start, .discovering), (.backendCreated, .connecting), (.connected, .initializing),
            (.liveViewStarted, .ready), (.framePublished, .streaming), (.framePublished, .streaming),
        ]
        var previous = machine.state
        for (event, state) in expected {
            let transition = machine.handle(event)
            #expect(transition == .init(from: previous, to: state, completedRecovery: false))
            previous = state
        }
    }

    @Test(arguments: allStates)
    func stopFromAnyStateGoesIdle(_ state: CaptureState) {
        var machine = Self.machine(at: state)
        let transition = machine.handle(.stop)
        #expect(transition?.to == .idle)
        #expect(machine.state == .idle)
        #expect(machine.consecutiveFailures == 0)
    }

    @Test(arguments: [CaptureState.idle, .failed(fatalError)])
    func startFromRestingStates(_ state: CaptureState) {
        var machine = Self.machine(at: state)
        #expect(machine.handle(.start)?.to == .discovering)
        #expect(machine.consecutiveFailures == 0)
    }

    @Test(arguments: [CaptureState.discovering, .waitingForCamera(reason: notFoundError.message), .connecting, preparing,
                      .initializing, .ready, .streaming, .recovering(attempt: 1, reason: "")])
    func startIsIgnoredWhileActive(_ state: CaptureState) {
        var machine = Self.machine(at: state)
        let before = machine.state
        #expect(machine.handle(.start) == nil)
        #expect(machine.state == before)
    }

    @Test(arguments: [CaptureState.discovering, .connecting, preparing, .initializing, .ready, .streaming])
    func reconnectFailureEntersRecovering(_ state: CaptureState) {
        var machine = Self.machine(at: state)
        let transition = machine.handle(.failed(Self.reconnectError))
        #expect(transition?.to == .recovering(attempt: 1, reason: Self.reconnectError.message))
        #expect(machine.consecutiveFailures == 1)
    }

    @Test(arguments: [CaptureState.discovering, .connecting, preparing, .initializing, .ready, .streaming])
    func absentDeviceEntersRecovering(_ state: CaptureState) {
        var machine = Self.machine(at: state)
        #expect(machine.handle(.failed(Self.absentError))?.to == .recovering(attempt: 1, reason: Self.absentError.message))
    }

    @Test(arguments: [CaptureState.discovering, .connecting, preparing, .initializing, .ready, .streaming])
    func fatalFailureFails(_ state: CaptureState) {
        var machine = Self.machine(at: state)
        #expect(machine.handle(.failed(Self.fatalError))?.to == .failed(Self.fatalError))
    }

    @Test(arguments: [CaptureState.discovering, .connecting, preparing, .initializing, .ready, .streaming])
    func cancelledFailureGoesIdle(_ state: CaptureState) {
        var machine = Self.machine(at: state)
        #expect(machine.handle(.failed(Self.cancelledError))?.to == .idle)
    }

    @Test(arguments: [CaptureState.ready, .streaming])
    func invalidFrameKeepsStreamingState(_ state: CaptureState) {
        var machine = Self.machine(at: state)
        let transition = machine.handle(.failed(Self.invalidError))
        #expect(transition?.from == state)
        #expect(transition?.to == state)
        #expect(machine.consecutiveFailures == 0)
    }

    @Test(arguments: [CaptureState.discovering, .connecting, preparing, .initializing])
    func invalidFrameOutsideLiveViewReconnects(_ state: CaptureState) {
        var machine = Self.machine(at: state)
        #expect(machine.handle(.failed(Self.invalidError))?.to == .recovering(attempt: 1, reason: Self.invalidError.message))
    }

    @Test func preparingWhileConnecting() {
        var machine = CaptureStateMachine()
        let later = CameraPreparation.readingStorage(percentComplete: 60)
        let expected: [(CaptureEvent, CaptureState)] = [
            (.start, .discovering), (.backendCreated, .connecting),
            (.preparing(Self.reading), Self.preparing), (.preparing(later), .preparing(later)),
            (.preparationFinished, .connecting), (.connected, .initializing),
        ]
        var previous = machine.state
        for (event, state) in expected {
            #expect(machine.handle(event) == .init(from: previous, to: state, completedRecovery: false))
            previous = state
        }
    }

    @Test func connectedEndsAPreparationThatWasNotReportedOver() {
        var machine = Self.machine(at: Self.preparing)
        #expect(machine.handle(.connected)?.to == .initializing)
    }

    @Test func preparingIsNotAFailure() {
        var machine = Self.machine(at: .ready)
        _ = machine.handle(.failed(Self.reconnectError))
        _ = machine.handle(.retry)
        _ = machine.handle(.backendCreated)
        #expect(machine.handle(.preparing(Self.reading))?.to == Self.preparing)
        #expect(machine.consecutiveFailures == 1, "preparing neither adds nor clears failures")
        _ = machine.handle(.preparationFinished)
        _ = machine.handle(.connected)
        _ = machine.handle(.liveViewStarted)
        #expect(machine.handle(.framePublished)?.completedRecovery == true)
    }

    @Test(arguments: [CaptureState.idle, .discovering, .initializing, .ready, .streaming,
                      .recovering(attempt: 1, reason: ""), .failed(fatalError)])
    func preparingOnlyWhileConnecting(_ state: CaptureState) {
        var machine = Self.machine(at: state)
        let before = machine
        #expect(machine.handle(.preparing(Self.reading)) == nil)
        #expect(machine.handle(.preparationFinished) == nil)
        #expect(machine == before)
    }

    @Test func preparationTextHidesAStuckZeroAndSaysPhotosAreNotCopied() {
        #expect(CameraPreparation.readingStorage(percentComplete: nil).displayedPercent == nil)
        #expect(CameraPreparation.readingStorage(percentComplete: 0).displayedPercent == nil)
        #expect(CameraPreparation.readingStorage(percentComplete: 45).displayedPercent == 45)
        #expect(CameraPreparation.readingStorage(percentComplete: 0).summary == "The camera is getting ready…")
        #expect(CameraPreparation.readingStorage(percentComplete: 45).summary == "The camera is getting ready (45%)…")
        #expect(Self.reading.explanation.contains("Mirrorup doesn't copy or upload your photos."))
    }

    @Test func retryLeavesRecoveringForDiscovering() {
        var machine = Self.machine(at: .recovering(attempt: 1, reason: ""))
        #expect(machine.handle(.retry)?.to == .discovering)
        #expect(machine.consecutiveFailures == 1, "attempt count survives the retry")
    }

    /// No usable camera attached is not a failure: no attempt counted, no limit, no backoff state.
    @Test func noCameraWhileDiscoveringWaitsWithoutCountingAttempts() {
        var machine = Self.machine(at: .discovering, maxAttempts: 2)
        for _ in 1...5 {
            #expect(machine.handle(.failed(Self.notFoundError))?.to == .waitingForCamera(reason: Self.notFoundError.message))
            #expect(machine.consecutiveFailures == 0)
            #expect(machine.handle(.retry)?.to == .discovering)
        }
        _ = machine.handle(.backendCreated)
        _ = machine.handle(.connected)
        _ = machine.handle(.liveViewStarted)
        #expect(machine.handle(.framePublished) == .init(from: .ready, to: .streaming, completedRecovery: false))
    }

    /// A camera that dropped mid-stream and isn't back yet: the wait keeps the recovery's attempt
    /// count, so its return completes the recovery.
    @Test func waitingAfterADropStillCompletesTheRecovery() {
        var machine = Self.machine(at: .streaming)
        #expect(machine.handle(.failed(Self.absentError))?.to == .recovering(attempt: 1, reason: Self.absentError.message))
        _ = machine.handle(.retry)
        #expect(machine.handle(.failed(Self.notFoundError))?.to == .waitingForCamera(reason: Self.notFoundError.message))
        #expect(machine.consecutiveFailures == 1)
        _ = machine.handle(.retry)
        _ = machine.handle(.backendCreated)
        _ = machine.handle(.connected)
        _ = machine.handle(.liveViewStarted)
        #expect(machine.handle(.framePublished) == .init(from: .ready, to: .streaming, completedRecovery: true))
    }

    /// Only discovery can find "no camera": a backend that reports `.notFound` while connecting lost
    /// a camera it had, which is a recovery.
    @Test func notFoundWhileConnectingRecovers() {
        var machine = Self.machine(at: .connecting)
        #expect(machine.handle(.failed(Self.notFoundError))?.to == .recovering(attempt: 1, reason: Self.notFoundError.message))
    }

    @Test func attemptsGrowUntilAFrameIsPublished() {
        var machine = Self.machine(at: .discovering)
        for attempt in 1...4 {
            #expect(machine.handle(.failed(Self.absentError))?.to == .recovering(attempt: attempt, reason: Self.absentError.message))
            #expect(machine.handle(.retry)?.to == .discovering)
        }
        _ = machine.handle(.backendCreated)
        _ = machine.handle(.connected)
        _ = machine.handle(.liveViewStarted)
        let transition = machine.handle(.framePublished)
        #expect(transition == .init(from: .ready, to: .streaming, completedRecovery: true))
        #expect(machine.consecutiveFailures == 0)
        #expect(machine.handle(.failed(Self.reconnectError))?.to == .recovering(attempt: 1, reason: Self.reconnectError.message))
    }

    @Test func liveViewWithoutFrameDoesNotResetAttempts() {
        var machine = Self.machine(at: .ready)
        _ = machine.handle(.failed(Self.reconnectError))
        _ = machine.handle(.retry)
        _ = machine.handle(.backendCreated)
        _ = machine.handle(.connected)
        _ = machine.handle(.liveViewStarted)
        #expect(machine.handle(.failed(Self.reconnectError))?.to == .recovering(attempt: 2, reason: Self.reconnectError.message))
    }

    @Test func exceedingMaxAttemptsFails() {
        var machine = Self.machine(at: .discovering, maxAttempts: 2)
        #expect(machine.handle(.failed(Self.absentError))?.to == .recovering(attempt: 1, reason: Self.absentError.message))
        _ = machine.handle(.retry)
        #expect(machine.handle(.failed(Self.absentError))?.to == .recovering(attempt: 2, reason: Self.absentError.message))
        _ = machine.handle(.retry)
        #expect(machine.handle(.failed(Self.absentError))?.to == .failed(Self.absentError))
    }

    @Test func invalidEventsAreRejected() {
        let reconnectError = Self.reconnectError, fatalError = Self.fatalError, preparing = Self.preparing
        let cases: [(CaptureState, CaptureEvent)] = [
            (.idle, .backendCreated), (.idle, .connected), (.idle, .liveViewStarted), (.idle, .framePublished),
            (.idle, .failed(reconnectError)), (.idle, .retry),
            (.discovering, .connected), (.discovering, .framePublished), (.discovering, .retry),
            (.connecting, .backendCreated), (.connecting, .liveViewStarted), (.connecting, .retry),
            (.connecting, .preparationFinished),
            (preparing, .backendCreated), (preparing, .liveViewStarted), (preparing, .framePublished), (preparing, .retry),
            (.initializing, .framePublished), (.initializing, .retry),
            (.ready, .connected), (.ready, .retry),
            (.streaming, .liveViewStarted), (.streaming, .retry),
            (.recovering(attempt: 1, reason: ""), .backendCreated), (.recovering(attempt: 1, reason: ""), .framePublished),
            (.recovering(attempt: 1, reason: ""), .failed(reconnectError)),
            (.waitingForCamera(reason: ""), .backendCreated), (.waitingForCamera(reason: ""), .framePublished),
            (.waitingForCamera(reason: ""), .failed(reconnectError)),
            (.failed(fatalError), .retry), (.failed(fatalError), .framePublished), (.failed(fatalError), .failed(reconnectError)),
        ]
        for (state, event) in cases {
            var machine = Self.machine(at: state)
            let before = machine
            #expect(machine.handle(event) == nil, "\(event) must be rejected in \(state)")
            #expect(machine == before)
        }
    }
}

extension CaptureState {
    func matchesCase(of other: CaptureState) -> Bool {
        switch (self, other) {
        case (.recovering, .recovering), (.failed, .failed), (.waitingForCamera, .waitingForCamera): true
        default: self == other
        }
    }
}
