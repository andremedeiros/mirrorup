import Foundation
@testable import MirrorupPTP

/// Bulk pipe fake: reads come from a script of chunks; writes are recorded. A read with an empty
/// script waits for its full timeout and then fails, which is what a silent device looks like.
actor ScriptedPipe: PTPBulkPipe {
    nonisolated let maxPacketSize: Int
    private var reads: [Result<Data, PTPTransportError>]
    private(set) var writes: [Data] = []
    private(set) var readRequests: [Int] = []

    init(maxPacketSize: Int = 512, reads: [Result<Data, PTPTransportError>] = []) {
        self.maxPacketSize = maxPacketSize
        self.reads = reads
    }

    func enqueue(_ chunks: [Data]) { reads.append(contentsOf: chunks.map { .success($0) }) }

    func write(_ data: Data, timeout: Duration) async throws(PTPTransportError) {
        writes.append(data)
    }

    func read(maxLength: Int, timeout: Duration) async throws(PTPTransportError) -> Data {
        readRequests.append(maxLength)
        guard !reads.isEmpty else {
            do { try await Task.sleep(for: timeout) } catch { throw .cancelled }
            throw .timedOut(operation: "bulk read", after: timeout)
        }
        let next = reads.removeFirst()
        switch next {
        case .success(let d):
            precondition(d.count <= maxLength, "script chunk larger than requested transfer")
            return d
        case .failure(let e):
            throw e
        }
    }
}

enum Bytes {
    static func container(type: PTPContainerType, code: UInt16, tid: UInt32, payload: Data = Data()) -> Data {
        var w = PTPDataWriter()
        w.u32(UInt32(12 + payload.count))
        w.u16(type.rawValue)
        w.u16(code)
        w.u32(tid)
        w.bytes(payload)
        return w.data
    }

    static func response(_ code: UInt16 = 0x2001, tid: UInt32, params: [UInt32] = []) -> Data {
        var w = PTPDataWriter()
        for p in params { w.u32(p) }
        return container(type: .response, code: code, tid: tid, payload: w.data)
    }

    static func fixture(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }
}
