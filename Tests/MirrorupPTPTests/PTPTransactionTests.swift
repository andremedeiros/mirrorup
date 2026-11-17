import Foundation
import Testing
@testable import MirrorupPTP

@Suite struct PTPContainerAssemblerTests {
    @Test func reassemblesAContainerSplitAtEveryByteBoundary() throws {
        let payload = Data((0..<1500).map { UInt8($0 & 0xFF) })
        let container = Bytes.container(type: .data, code: 0x9153, tid: 4, payload: payload)
        for split in 1..<container.count {
            var a = PTPContainerAssembler(maxContainerLength: 4096)
            #expect(try a.append(container.prefix(split)).isEmpty)
            let out = try a.append(container.dropFirst(split))
            #expect(out.count == 1)
            #expect(out.first?.payload == payload)
            #expect(a.bufferedByteCount == 0)
        }
    }

    @Test func reassemblesOneBytePerTransfer() throws {
        let container = Bytes.container(type: .data, code: 0x1001, tid: 1, payload: Data(repeating: 0xAB, count: 37))
        var a = PTPContainerAssembler(maxContainerLength: 4096)
        var out: [PTPContainerAssembler.Container] = []
        for byte in container { out += try a.append(Data([byte])) }
        #expect(out.count == 1)
        #expect(out[0].payload == Data(repeating: 0xAB, count: 37))
    }

    @Test func splitsMultipleContainersInOneTransfer() throws {
        let data = Bytes.container(type: .data, code: 0x1001, tid: 3, payload: Data([1, 2, 3]))
        let resp = Bytes.response(tid: 3)
        var a = PTPContainerAssembler(maxContainerLength: 4096)
        let out = try a.append(data + resp + resp.prefix(5))
        #expect(out.map(\.header.type) == [2, 3])
        #expect(a.bufferedByteCount == 5)
        #expect(try a.append(resp.dropFirst(5)).count == 1)
    }

    @Test func headerOnlyContainerCompletesImmediately() throws {
        var a = PTPContainerAssembler(maxContainerLength: 64)
        let resp = Bytes.response(tid: 9)
        #expect(try a.append(resp.prefix(6)).isEmpty)
        let out = try a.append(resp.suffix(6))
        #expect(out.count == 1)
        #expect(out[0].payload.isEmpty)
    }

    @Test func oversizedDeclaredLengthFailsFast() {
        var w = PTPDataWriter()
        w.u32(10_000_000); w.u16(2); w.u16(0x9153); w.u32(1)
        var a = PTPContainerAssembler(maxContainerLength: 1 << 20)
        #expect(throws: PTPError.containerTooLarge(declared: 10_000_000, limit: 1 << 20)) { try a.append(w.data) }
    }

    @Test func oversizedLengthInSplitHeaderFailsOnceHeaderCompletes() throws {
        var w = PTPDataWriter()
        w.u32(10_000_000); w.u16(2); w.u16(0x9153); w.u32(1)
        var a = PTPContainerAssembler(maxContainerLength: 1 << 20)
        #expect(try a.append(w.data.prefix(7)).isEmpty)
        #expect(throws: PTPError.self) { try a.append(w.data.dropFirst(7)) }
    }
}

@Suite struct PTPUSBTransportTests {
    @Test func dataInTransactionAcrossManyTransfers() async throws {
        let payload = Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 * 7) })
        let data = Bytes.container(type: .data, code: 0x1001, tid: 5, payload: payload)
        // Device delivers 512-byte packets grouped into odd transfer sizes, then the response.
        var chunks: [Data] = []
        var rest = data[...]
        for size in [512, 1024, 3, 509, 2048] where !rest.isEmpty {
            chunks.append(Data(rest.prefix(size)))
            rest = rest.dropFirst(size)
        }
        if !rest.isEmpty { chunks.append(Data(rest)) }
        chunks.append(Bytes.response(tid: 5))
        let pipe = ScriptedPipe(reads: chunks.map { .success($0) })
        let transport = PTPUSBTransport(pipe: pipe, readChunkSize: 4096)

        let result = try await transport.execute(PTPCommand(.getDeviceInfo), transactionID: 5, dataOut: nil, timeout: .seconds(1))
        #expect(result.response.code == .ok)
        #expect(result.data == payload)
        let writes = await pipe.writes
        #expect(writes == [try PTPCommand(.getDeviceInfo).encodedContainer(transactionID: 5)])
    }

    @Test func dataOutSendsContainerAndZeroLengthPacketOnPacketBoundary() async throws {
        let pipe = ScriptedPipe(maxPacketSize: 16, reads: [.success(Bytes.response(tid: 2))])
        let transport = PTPUSBTransport(pipe: pipe, readChunkSize: 64)
        let payload = Data(repeating: 1, count: 20)  // 12 + 20 = 32 bytes = 2 full packets
        _ = try await transport.execute(PTPCommand(PTPOperationCode(0x9110)), transactionID: 2, dataOut: payload, timeout: .seconds(1))
        let writes = await pipe.writes
        #expect(writes.count == 3)
        #expect(writes[1] == Bytes.container(type: .data, code: 0x9110, tid: 2, payload: payload))
        #expect(writes[2].isEmpty)
    }

    @Test func noZeroLengthPacketWhenNotOnBoundary() async throws {
        let pipe = ScriptedPipe(maxPacketSize: 512, reads: [.success(Bytes.response(tid: 2))])
        let transport = PTPUSBTransport(pipe: pipe, readChunkSize: 512)
        _ = try await transport.execute(PTPCommand(PTPOperationCode(0x9110)), transactionID: 2, dataOut: Data(repeating: 0, count: 12), timeout: .seconds(1))
        #expect(await pipe.writes.count == 2)
    }

    @Test func responseWithWrongTransactionIDPoisonsTransport() async throws {
        let pipe = ScriptedPipe(reads: [.success(Bytes.response(tid: 99))])
        let transport = PTPUSBTransport(pipe: pipe, readChunkSize: 512)
        await #expect(throws: PTPError.transactionIDMismatch(expected: 3, actual: 99)) {
            try await transport.execute(PTPCommand(.getDeviceInfo), transactionID: 3, dataOut: nil, timeout: .seconds(1))
        }
        await #expect(throws: PTPError.transport(.notOpen)) {
            try await transport.execute(PTPCommand(.getDeviceInfo), transactionID: 4, dataOut: nil, timeout: .seconds(1))
        }
    }

    @Test func dataContainerForAnotherOperationIsRejected() async {
        let pipe = ScriptedPipe(reads: [.success(Bytes.container(type: .data, code: 0x1002, tid: 1, payload: Data([1])))])
        let transport = PTPUSBTransport(pipe: pipe, readChunkSize: 512)
        await #expect(throws: PTPError.operationMismatch(expected: 0x1001, actual: 0x1002)) {
            try await transport.execute(PTPCommand(.getDeviceInfo), transactionID: 1, dataOut: nil, timeout: .seconds(1))
        }
    }

    @Test func silentDeviceTimesOutWithinDeadline() async {
        let pipe = ScriptedPipe()
        let transport = PTPUSBTransport(pipe: pipe, readChunkSize: 512)
        let start = ContinuousClock.now
        await #expect(throws: PTPError.self) {
            try await transport.execute(PTPCommand(.getDeviceInfo), transactionID: 1, dataOut: nil, timeout: .milliseconds(100))
        }
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func disconnectDuringReadSurfacesAsTransportError() async {
        let pipe = ScriptedPipe(reads: [.failure(.disconnected("unplugged"))])
        let transport = PTPUSBTransport(pipe: pipe, readChunkSize: 512)
        await #expect(throws: PTPError.transport(.disconnected("unplugged"))) {
            try await transport.execute(PTPCommand(.getDeviceInfo), transactionID: 1, dataOut: nil, timeout: .seconds(1))
        }
    }
}

@Suite struct PTPSessionTests {
    @Test func opensWithTransactionZeroThenNumbersFromOne() async throws {
        let pipe = ScriptedPipe(reads: [
            .success(Bytes.response(tid: 0)),
            .success(Bytes.response(tid: 1)),
            .success(Bytes.response(tid: 2)),
        ])
        let session = PTPSession(transport: PTPUSBTransport(pipe: pipe, readChunkSize: 512))
        try await session.open()
        try await session.execute(PTPCommand(PTPOperationCode(0x9114), [1]))
        try await session.execute(PTPCommand(PTPOperationCode(0x9115), [1]))
        let tids = await pipe.writes.map { $0[8] }
        #expect(tids == [0, 1, 2])
        #expect(await pipe.writes[0][6...7] == Data([0x02, 0x10]))
    }

    @Test func sessionAlreadyOpenIsAccepted() async throws {
        let pipe = ScriptedPipe(reads: [.success(Bytes.response(0x201E, tid: 0))])
        let session = PTPSession(transport: PTPUSBTransport(pipe: pipe, readChunkSize: 512))
        try await session.open()
        #expect(await session.opened)
    }

    @Test func failedOpenSessionReportsResponseCode() async {
        let pipe = ScriptedPipe(reads: [.success(Bytes.response(0x2002, tid: 0))])
        let session = PTPSession(transport: PTPUSBTransport(pipe: pipe, readChunkSize: 512))
        await #expect(throws: PTPError.response(.generalError, operation: .openSession)) { try await session.open() }
        #expect(await !session.opened)
    }

    @Test func nonOKResponseBecomesTypedErrorButTransactCarriesIt() async throws {
        let pipe = ScriptedPipe(reads: [
            .success(Bytes.response(tid: 0)),
            .success(Bytes.response(0xA102, tid: 1)),
            .success(Bytes.response(0xA102, tid: 2)),
        ])
        let session = PTPSession(transport: PTPUSBTransport(pipe: pipe, readChunkSize: 512))
        try await session.open()
        await #expect(throws: PTPError.response(PTPResponseCode(0xA102), operation: PTPOperationCode(0x9153))) {
            try await session.execute(PTPCommand(PTPOperationCode(0x9153)))
        }
        let raw = try await session.transact(PTPCommand(PTPOperationCode(0x9153)))
        #expect(raw.response.code.rawValue == 0xA102)
    }

    @Test func operationsBeforeOpenAreRejectedExceptDeviceInfo() async {
        let session = PTPSession(transport: PTPUSBTransport(pipe: ScriptedPipe(), readChunkSize: 512))
        await #expect(throws: PTPError.sessionNotOpen) { try await session.execute(PTPCommand(.getStorageIDs)) }
    }

    @Test func concurrentCallersNeverOverlapOnTheWire() async throws {
        let transport = OverlapDetectingTransport()
        let session = PTPSession(transport: transport)
        try await session.open()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask { try await session.execute(PTPCommand(PTPOperationCode(0x9116), [UInt32(i)])) }
            }
            try await group.waitForAll()
        }
        #expect(transport.maxConcurrent == 1)
        #expect(transport.transactionIDs == Array(1...50))
    }

    @Test func cancelledWaiterDoesNotRunOrBlockOthers() async throws {
        let transport = OverlapDetectingTransport(delay: .milliseconds(50))
        let session = PTPSession(transport: transport)
        try await session.open()
        let first = Task { try await session.execute(PTPCommand(PTPOperationCode(0x9116))) }
        try await Task.sleep(for: .milliseconds(10))
        let cancelled = Task { try await session.execute(PTPCommand(PTPOperationCode(0x9153))) }
        try await Task.sleep(for: .milliseconds(10))
        cancelled.cancel()
        await #expect(throws: PTPError.transport(.cancelled)) { try await cancelled.value }
        _ = try await first.value
        try await session.execute(PTPCommand(PTPOperationCode(0x9114)))
        #expect(transport.codes == [0x9116, 0x9114])
    }
}

/// Transport fake that records concurrency and transaction IDs.
final class OverlapDetectingTransport: PTPTransport, @unchecked Sendable {
    let sessionOwnership = PTPSessionOwnership.system
    private let lock = NSLock()
    private var inFlight = 0
    private(set) var maxConcurrent = 0
    private(set) var transactionIDs: [UInt32] = []
    private(set) var codes: [UInt16] = []
    private let delay: Duration

    init(delay: Duration = .milliseconds(1)) { self.delay = delay }

    func open() async throws(PTPTransportError) {}
    func close() async {}

    func execute(_ command: PTPCommand, transactionID: UInt32, dataOut: Data?, timeout: Duration) async throws(PTPError) -> PTPTransactionResult {
        lock.withLock {
            inFlight += 1
            maxConcurrent = max(maxConcurrent, inFlight)
            transactionIDs.append(transactionID)
            codes.append(command.code.rawValue)
        }
        try? await Task.sleep(for: delay)
        lock.withLock { inFlight -= 1 }
        return PTPTransactionResult(response: PTPResponse(code: .ok, transactionID: transactionID), data: Data())
    }
}
