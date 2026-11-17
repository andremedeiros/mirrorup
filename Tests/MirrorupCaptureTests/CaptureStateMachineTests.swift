@testable import MirrorupCapture
import Testing

@Suite("Capture state machine")
struct CaptureStateMachineTests {
    static let reconnectError = CameraError(.timeout, "Timed out")
    static let absentError = CameraError(.disconnected, "Unplugged")
    static let fatalError = CameraError(.accessDenied, "Denied")
    static let invalidError = CameraError(.invalidFrame, "Bad frame")
    static let cancelledError = CameraError(.cancelled, "Cancelled")

    /// A machine driven along the happy path up to `state`.
    static func machine(at state: CaptureState, maxAttempts: Int? = nil) -> CaptureStateMachine {
        var machine = CaptureStateMachine(maxAttemptsBeforeFailing: maxAttempts)
        let path: [CaptureEvent] = switch state {
        case .idle: []
        case .discovering: [.start]
        case .connecting: [.start, .backendCreated]
        case .initializing: [.start, .backendCreated, .connected]
        case .ready: [.start, .backendCreated, .connected, .liveViewStarted]
        case .streaming: [.start, .backendCreated, .connected, .liveViewStarted, .framePublished]
        case .recovering: [.start, .failed(reconnectError)]
        case .failed: [.start, .failed(fatalError)]
        }
        for event in path { _ = machine.handle(event) }
        #expect(machine.state.matchesCase(of: state))
        return machine
    }

    static let allStates: [CaptureState] = [
        .idle, .discovering, .connecting, .initializing, .ready, .streaming,
        .recovering(attempt: 1, reason: reconnectError.message), .failed(fatalError),
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

    @Test(arguments: [CaptureState.discovering, .connecting, .initializing, .ready, .streaming, .recovering(attempt: 1, reason: "")])
    func startIsIgnoredWhileActive(_ state: CaptureState) {
        var machine = Self.machine(at: state)
        let before = machine.state
        #expect(machine.handle(.start) == nil)
        #expect(machine.state == before)
    }

    @Test(arguments: [CaptureState.discovering, .connecting, .initializing, .ready, .streaming])
    func reconnectFailureEntersRecovering(_ state: CaptureState) {
        var machine = Self.machine(at: state)
        let transition = machine.handle(.failed(Self.reconnectError))
        #expect(transition?.to == .recovering(attempt: 1, reason: Self.reconnectError.message))
        #expect(machine.consecutiveFailures == 1)
    }

    @Test(arguments: [CaptureState.discovering, .connecting, .initializing, .ready, .streaming])
    func absentDeviceEntersRecovering(_ state: CaptureState) {
        var machine = Self.machine(at: state)
        #expect(machine.handle(.failed(Self.absentError))?.to == .recovering(attempt: 1, reason: Self.absentError.message))
    }

    @Test(arguments: [CaptureState.discovering, .connecting, .initializing, .ready, .streaming])
    func fatalFailureFails(_ state: CaptureState) {
        var machine = Self.machine(at: state)
        #expect(machine.handle(.failed(Self.fatalError))?.to == .failed(Self.fatalError))
    }

    @Test(arguments: [CaptureState.discovering, .connecting, .initializing, .ready, .streaming])
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

    @Test(arguments: [CaptureState.discovering, .connecting, .initializing])
    func invalidFrameOutsideLiveViewReconnects(_ state: CaptureState) {
        var machine = Self.machine(at: state)
        #expect(machine.handle(.failed(Self.invalidError))?.to == .recovering(attempt: 1, reason: Self.invalidError.message))
    }

    @Test func retryLeavesRecoveringForDiscovering() {
        var machine = Self.machine(at: .recovering(attempt: 1, reason: ""))
        #expect(machine.handle(.retry)?.to == .discovering)
        #expect(machine.consecutiveFailures == 1, "attempt count survives the retry")
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
        let reconnectError = Self.reconnectError, fatalError = Self.fatalError
        let cases: [(CaptureState, CaptureEvent)] = [
            (.idle, .backendCreated), (.idle, .connected), (.idle, .liveViewStarted), (.idle, .framePublished),
            (.idle, .failed(reconnectError)), (.idle, .retry),
            (.discovering, .connected), (.discovering, .framePublished), (.discovering, .retry),
            (.connecting, .backendCreated), (.connecting, .liveViewStarted), (.connecting, .retry),
            (.initializing, .framePublished), (.initializing, .retry),
            (.ready, .connected), (.ready, .retry),
            (.streaming, .liveViewStarted), (.streaming, .retry),
            (.recovering(attempt: 1, reason: ""), .backendCreated), (.recovering(attempt: 1, reason: ""), .framePublished),
            (.recovering(attempt: 1, reason: ""), .failed(reconnectError)),
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
        case (.recovering, .recovering), (.failed, .failed): true
        default: self == other
        }
    }
}
