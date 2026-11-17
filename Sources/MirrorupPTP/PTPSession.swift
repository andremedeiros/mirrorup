public import Foundation
import MirrorupDiagnostics
import Synchronization

/// FIFO async mutex. Actor methods are reentrant across `await`, so an actor alone cannot keep two
/// PTP transactions from interleaving on the wire; this gate does. Waiting is cancellable.
public final class AsyncSerialGate: Sendable {
    private struct State {
        var held = false
        var nextTicket: UInt64 = 0
        var waiters: [(ticket: UInt64, continuation: CheckedContinuation<Void, any Error>)] = []
    }

    private let state = Mutex(State())

    public init() {}

    public func acquire() async throws(CancellationError) {
        let ticket: UInt64? = state.withLock { s in
            if !s.held {
                s.held = true
                return nil
            }
            s.nextTicket += 1
            return s.nextTicket
        }
        guard let ticket else { return }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                    let cancelled = state.withLock { s -> Bool in
                        if Task.isCancelled { return true }
                        s.waiters.append((ticket, c))
                        return false
                    }
                    if cancelled { c.resume(throwing: CancellationError()) }
                }
            } onCancel: {
                let waiter = state.withLock { s -> CheckedContinuation<Void, any Error>? in
                    guard let i = s.waiters.firstIndex(where: { $0.ticket == ticket }) else { return nil }
                    return s.waiters.remove(at: i).continuation
                }
                waiter?.resume(throwing: CancellationError())
            }
        } catch {
            throw CancellationError()
        }
    }

    /// Hands the gate to the next waiter, or frees it.
    public func release() {
        let next = state.withLock { s -> CheckedContinuation<Void, any Error>? in
            precondition(s.held, "release() without acquire()")
            if s.waiters.isEmpty {
                s.held = false
                return nil
            }
            return s.waiters.removeFirst().continuation
        }
        next?.resume()
    }
}

/// One PTP session on one device. All transactions are serialized through the gate, transaction IDs
/// are assigned here, and non-OK responses become typed errors.
public actor PTPSession {
    public let transport: any PTPTransport
    public let defaultTimeout: Duration

    private let gate = AsyncSerialGate()
    private var nextTransactionID: UInt32 = 1
    private var isOpen = false
    private let sessionID: UInt32

    public init(transport: any PTPTransport, sessionID: UInt32 = 1, defaultTimeout: Duration = .seconds(5)) {
        self.transport = transport
        self.sessionID = sessionID
        self.defaultTimeout = defaultTimeout
    }

    public var opened: Bool { isOpen }

    /// Opens the transport and, when the host owns the session, sends OpenSession.
    public func open() async throws(PTPError) {
        guard !isOpen else { return }
        do {
            try await transport.open()
        } catch {
            throw .transport(error)
        }
        if transport.sessionOwnership == .host {
            // OpenSession is the one operation issued with transaction ID 0 (ISO 15740 §9.3.1).
            let result = try await locked { () async throws(PTPError) -> PTPTransactionResult in
                try await transport.execute(PTPCommand(.openSession, [sessionID]), transactionID: 0, dataOut: nil, timeout: defaultTimeout)
            }
            switch result.response.code {
            case .ok:
                break
            case .sessionAlreadyOpen:
                // A previous host process died without CloseSession; the device keeps that session.
                Diagnostics.ptp.notice("device reported SessionAlreadyOpen; reusing it")
            default:
                await transport.close()
                throw .response(result.response.code, operation: .openSession)
            }
            nextTransactionID = 1
        }
        isOpen = true
    }

    /// Closes the session (best effort) and the transport. Safe to call repeatedly.
    public func close() async {
        if isOpen, transport.sessionOwnership == .host {
            do {
                _ = try await transact(PTPCommand(.closeSession), timeout: .seconds(2))
            } catch {
                Diagnostics.ptp.notice("CloseSession failed during close: \(error.description, privacy: .public)")
            }
        }
        isOpen = false
        await transport.close()
    }

    /// Runs a transaction and returns the raw result, whatever the response code.
    public func transact(_ command: PTPCommand, dataOut: Data? = nil, timeout: Duration? = nil) async throws(PTPError) -> PTPTransactionResult {
        guard isOpen || command.code == .getDeviceInfo else { throw .sessionNotOpen }
        let timeout = timeout ?? defaultTimeout
        return try await locked { () async throws(PTPError) -> PTPTransactionResult in
            let tid = takeTransactionID()
            let signpostID = Diagnostics.signposter.makeSignpostID()
            let state = Diagnostics.signposter.beginInterval("PTPTransaction", id: signpostID, "\(command.code.rawValue, format: .hex)")
            defer { Diagnostics.signposter.endInterval("PTPTransaction", state) }
            let result = try await transport.execute(command, transactionID: tid, dataOut: dataOut, timeout: timeout)
            Diagnostics.ptp.debug("\(command.description, privacy: .public) -> \(result.response.description, privacy: .public) data=\(result.data.count)")
            return result
        }
    }

    /// Runs a transaction and throws `PTPError.response` unless the device answered OK.
    @discardableResult
    public func execute(_ command: PTPCommand, dataOut: Data? = nil, timeout: Duration? = nil) async throws(PTPError) -> PTPTransactionResult {
        let result = try await transact(command, dataOut: dataOut, timeout: timeout)
        guard result.response.code == .ok else { throw .response(result.response.code, operation: command.code) }
        return result
    }

    public func deviceInfo() async throws(PTPError) -> PTPDeviceInfo {
        let result = try await execute(PTPCommand(.getDeviceInfo))
        guard !result.data.isEmpty else { throw .missingDataPhase(operation: .getDeviceInfo) }
        return try PTPDeviceInfo(decoding: result.data)
    }

    private func takeTransactionID() -> UInt32 {
        let tid = nextTransactionID
        // 0 is reserved for OpenSession and 0xFFFFFFFF is invalid; wrap within 1...0xFFFFFFFE.
        nextTransactionID = tid >= 0xFFFF_FFFE ? 1 : tid + 1
        return tid
    }

    private func locked<T: Sendable>(_ body: () async throws(PTPError) -> T) async throws(PTPError) -> T {
        do {
            try await gate.acquire()
        } catch {
            throw .transport(.cancelled)
        }
        defer { gate.release() }
        return try await body()
    }
}
