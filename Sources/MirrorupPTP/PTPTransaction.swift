public import Foundation
import MirrorupDiagnostics

/// Who owns the PTP session on the device.
public enum PTPSessionOwnership: Sendable {
    /// Mirrorup sends OpenSession/CloseSession and assigns transaction IDs (direct USB).
    case host
    /// The operating system owns the session and rewrites transaction IDs (ImageCaptureCore's
    /// `ptpcamerad`). The host must never send OpenSession/CloseSession itself.
    case system
}

/// Executes complete PTP transactions. Implementations must:
/// - run at most one transaction at a time (callers serialize; implementations may assume it),
/// - enforce `timeout` without blocking a thread indefinitely,
/// - verify that the returned response belongs to the transaction when they control transaction IDs,
/// - become unusable (`notOpen`) after a timeout, cancellation or framing error, because the device's
///   transaction state is unknown at that point.
public protocol PTPTransport: Sendable {
    var sessionOwnership: PTPSessionOwnership { get }
    func open() async throws(PTPTransportError)
    func execute(
        _ command: PTPCommand, transactionID: UInt32, dataOut: Data?, timeout: Duration
    ) async throws(PTPError) -> PTPTransactionResult
    func close() async
}

/// A pair of bulk endpoints (or a fake of them). One `read` is one USB transfer: it returns whatever
/// arrived up to `maxLength`, which can be less than a container, exactly one container, or (on
/// non-conforming devices) more than one.
public protocol PTPBulkPipe: Sendable {
    var maxPacketSize: Int { get }
    func write(_ data: Data, timeout: Duration) async throws(PTPTransportError)
    func read(maxLength: Int, timeout: Duration) async throws(PTPTransportError) -> Data
}

/// Incrementally reassembles generic containers from a byte stream of arbitrary chunking.
public struct PTPContainerAssembler: Sendable {
    public struct Container: Sendable {
        public var header: PTPContainerHeader
        public var payload: Data
    }

    public let maxContainerLength: Int
    private var buffer = Data()

    public init(maxContainerLength: Int) {
        self.maxContainerLength = maxContainerLength
    }

    public var bufferedByteCount: Int { buffer.count }

    /// Appends a chunk and returns every container it completed, in order.
    public mutating func append(_ chunk: Data) throws(PTPError) -> [Container] {
        var out: [Container] = []
        var rest = chunk[...]
        while !rest.isEmpty {
            if buffer.isEmpty, rest.count >= PTPContainerHeader.size {
                // Fast path: a whole container inside this transfer is sliced without copying.
                let header = try PTPContainerHeader.decode(rest.prefix(PTPContainerHeader.size), maxLength: maxContainerLength)
                if rest.count >= Int(header.length) {
                    let start = rest.startIndex
                    out.append(Container(header: header, payload: rest[(start + PTPContainerHeader.size)..<(start + Int(header.length))]))
                    rest = rest[(start + Int(header.length))...]
                    continue
                }
                // Length validated against the limit; reserve once instead of growing geometrically.
                buffer.reserveCapacity(Int(header.length))
            }
            if buffer.count < PTPContainerHeader.size {
                let take = min(PTPContainerHeader.size - buffer.count, rest.count)
                buffer.append(rest.prefix(take))
                rest = rest.dropFirst(take)
                guard buffer.count == PTPContainerHeader.size else { break }
            }
            let header = try PTPContainerHeader.decode(buffer.prefix(PTPContainerHeader.size), maxLength: maxContainerLength)
            let take = min(Int(header.length) - buffer.count, rest.count)
            buffer.append(rest.prefix(take))
            rest = rest.dropFirst(take)
            if buffer.count == Int(header.length) {
                out.append(Container(header: header, payload: buffer.dropFirst(PTPContainerHeader.size)))
                buffer = Data()
            }
        }
        return out
    }
}

/// PTP over USB bulk endpoints (USB Still Image Capture Device class), generic over the pipe so the
/// framing and transaction logic is tested without hardware.
public actor PTPUSBTransport<Pipe: PTPBulkPipe>: PTPTransport {
    public nonisolated let sessionOwnership = PTPSessionOwnership.host

    private let pipe: Pipe
    private let maxContainerLength: Int
    private let readChunkSize: Int
    private var usable = true

    /// - Parameters:
    ///   - maxContainerLength: upper bound for any incoming container; larger declared lengths are
    ///     rejected before allocation.
    ///   - readChunkSize: bytes requested per bulk IN transfer. Must be a multiple of the max packet size.
    public init(pipe: Pipe, maxContainerLength: Int = 32 << 20, readChunkSize: Int = 1 << 20) {
        precondition(readChunkSize % max(pipe.maxPacketSize, 1) == 0, "read size must be a multiple of wMaxPacketSize")
        self.pipe = pipe
        self.maxContainerLength = maxContainerLength
        self.readChunkSize = readChunkSize
    }

    public func open() async throws(PTPTransportError) {}

    public func close() async { usable = false }

    public func execute(
        _ command: PTPCommand, transactionID: UInt32, dataOut: Data?, timeout: Duration
    ) async throws(PTPError) -> PTPTransactionResult {
        guard usable else { throw .transport(.notOpen) }
        do {
            return try await run(command, transactionID: transactionID, dataOut: dataOut, timeout: timeout)
        } catch {
            // The device may be mid-transaction; nothing further can be framed reliably on this pipe.
            usable = false
            throw error
        }
    }

    private func run(
        _ command: PTPCommand, transactionID: UInt32, dataOut: Data?, timeout: Duration
    ) async throws(PTPError) -> PTPTransactionResult {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        func remaining() throws(PTPError) -> Duration {
            let left = deadline - clock.now
            guard left > .zero else { throw .transport(.timedOut(operation: command.code.description, after: timeout)) }
            return left
        }

        do {
            try await pipe.write(try command.encodedContainer(transactionID: transactionID), timeout: try remaining())
            if let dataOut {
                var container = PTPDataContainer.header(code: command.code, transactionID: transactionID, payloadLength: dataOut.count)
                container.append(dataOut)
                try await pipe.write(container, timeout: try remaining())
                // A transfer that is an exact multiple of wMaxPacketSize needs a zero-length packet
                // so the device knows the data phase ended.
                if container.count % pipe.maxPacketSize == 0 {
                    try await pipe.write(Data(), timeout: try remaining())
                }
            }
        } catch let error as PTPTransportError {
            throw .transport(error)
        } catch let error as PTPError {
            throw error
        } catch {
            throw .transport(.io(String(describing: error), code: -1))
        }

        var assembler = PTPContainerAssembler(maxContainerLength: maxContainerLength)
        var dataIn: Data?
        while true {
            let chunk: Data
            do {
                chunk = try await pipe.read(maxLength: readChunkSize, timeout: try remaining())
            } catch let error as PTPTransportError {
                throw .transport(error)
            } catch let error as PTPError {
                throw error
            } catch {
                throw .transport(.io(String(describing: error), code: -1))
            }
            for container in try assembler.append(chunk) {
                let header = container.header
                switch header.containerType {
                case .data:
                    guard header.code == command.code.rawValue else {
                        throw .operationMismatch(expected: command.code.rawValue, actual: header.code)
                    }
                    guard header.transactionID == transactionID else {
                        throw .transactionIDMismatch(expected: transactionID, actual: header.transactionID)
                    }
                    guard dataIn == nil, dataOut == nil else { throw .unexpectedDataPhase(operation: command.code) }
                    dataIn = container.payload
                case .response:
                    guard header.transactionID == transactionID else {
                        throw .transactionIDMismatch(expected: transactionID, actual: header.transactionID)
                    }
                    let payload = container.payload
                    guard payload.count % 4 == 0, payload.count <= 20 else { throw .invalidContainerLength(header.length) }
                    var reader = PTPDataReader(payload)
                    var params: [UInt32] = []
                    while !reader.isAtEnd { params.append(try reader.u32()) }
                    let response = PTPResponse(code: PTPResponseCode(header.code), transactionID: header.transactionID, parameters: params)
                    return PTPTransactionResult(response: response, data: dataIn ?? Data())
                case .event:
                    // Events belong on the interrupt endpoint; tolerate and log a misrouted one.
                    Diagnostics.ptp.notice("ignoring event container 0x\(String(header.code, radix: 16)) on bulk pipe")
                case .command, .none:
                    throw .unexpectedContainerType(expected: .response, actual: header.type)
                }
            }
        }
    }
}
