public import Foundation

/// USB Still Image container types (PIMA 15740 USB transport, "Generic Container").
public enum PTPContainerType: UInt16, Sendable, CustomStringConvertible {
    case command = 1
    case data = 2
    case response = 3
    case event = 4

    public var description: String {
        switch self {
        case .command: "command"
        case .data: "data"
        case .response: "response"
        case .event: "event"
        }
    }
}

/// 12-byte generic container header: length(u32) type(u16) code(u16) transactionID(u32), little endian.
public struct PTPContainerHeader: Sendable, Equatable {
    public static let size = 12

    public var length: UInt32
    public var type: UInt16
    public var code: UInt16
    public var transactionID: UInt32

    public init(length: UInt32, type: UInt16, code: UInt16, transactionID: UInt32) {
        self.length = length
        self.type = type
        self.code = code
        self.transactionID = transactionID
    }

    /// Decodes and validates a header. `maxLength` bounds the declared length *before* anyone
    /// allocates storage for the payload, so a corrupt or hostile length cannot trigger a huge allocation.
    public static func decode(_ bytes: some Collection<UInt8>, maxLength: Int) throws(PTPError) -> PTPContainerHeader {
        var r = PTPDataReader(bytes)
        let header = PTPContainerHeader(length: try r.u32(), type: try r.u16(), code: try r.u16(), transactionID: try r.u32())
        guard header.length >= UInt32(size) else { throw .invalidContainerLength(header.length) }
        guard Int(header.length) <= maxLength else { throw .containerTooLarge(declared: header.length, limit: maxLength) }
        return header
    }

    public var containerType: PTPContainerType? { PTPContainerType(rawValue: type) }
    public var payloadLength: Int { Int(length) - Self.size }
}

/// A command to send to the device. Parameters are limited to five by the standard.
public struct PTPCommand: Sendable, Equatable, CustomStringConvertible {
    public var code: PTPOperationCode
    public var parameters: [UInt32]

    public init(_ code: PTPOperationCode, _ parameters: [UInt32] = []) {
        self.code = code
        self.parameters = parameters
    }

    public func encodedContainer(transactionID: UInt32) throws(PTPError) -> Data {
        guard parameters.count <= 5 else { throw .tooManyParameters(parameters.count) }
        var w = PTPDataWriter(capacity: PTPContainerHeader.size + 4 * parameters.count)
        w.u32(UInt32(PTPContainerHeader.size + 4 * parameters.count))
        w.u16(PTPContainerType.command.rawValue)
        w.u16(code.rawValue)
        w.u32(transactionID)
        for p in parameters { w.u32(p) }
        return w.data
    }

    public var description: String {
        parameters.isEmpty ? code.description
            : "\(code) [" + parameters.map { "0x" + String($0, radix: 16) }.joined(separator: ", ") + "]"
    }
}

/// Data-phase container framing for a payload sent host → device.
public enum PTPDataContainer {
    public static func header(code: PTPOperationCode, transactionID: UInt32, payloadLength: Int) -> Data {
        var w = PTPDataWriter(capacity: PTPContainerHeader.size)
        w.u32(UInt32(PTPContainerHeader.size + payloadLength))
        w.u16(PTPContainerType.data.rawValue)
        w.u16(code.rawValue)
        w.u32(transactionID)
        return w.data
    }
}

/// Response container decoded from the device.
public struct PTPResponse: Sendable, Equatable, CustomStringConvertible {
    public var code: PTPResponseCode
    public var transactionID: UInt32
    public var parameters: [UInt32]

    public init(code: PTPResponseCode, transactionID: UInt32, parameters: [UInt32] = []) {
        self.code = code
        self.transactionID = transactionID
        self.parameters = parameters
    }

    /// Decodes a complete response container (header included).
    public init(container bytes: some Collection<UInt8>) throws(PTPError) {
        let header = try PTPContainerHeader.decode(bytes, maxLength: PTPContainerHeader.size + 4 * 5)
        guard header.type == PTPContainerType.response.rawValue else {
            throw .unexpectedContainerType(expected: .response, actual: header.type)
        }
        guard bytes.count >= Int(header.length) else { throw .truncated(needed: Int(header.length), available: bytes.count) }
        let payload = header.payloadLength
        guard payload % 4 == 0 else { throw .invalidContainerLength(header.length) }
        var r = PTPDataReader(bytes)
        try r.skip(PTPContainerHeader.size)
        var params: [UInt32] = []
        params.reserveCapacity(payload / 4)
        for _ in 0..<(payload / 4) { params.append(try r.u32()) }
        self.init(code: PTPResponseCode(header.code), transactionID: header.transactionID, parameters: params)
    }

    public var description: String {
        parameters.isEmpty ? code.description
            : "\(code) [" + parameters.map { "0x" + String($0, radix: 16) }.joined(separator: ", ") + "]"
    }
}

/// Event container (interrupt endpoint or ImageCaptureCore event callback).
public struct PTPEvent: Sendable, Equatable {
    public var code: UInt16
    public var transactionID: UInt32
    public var parameters: [UInt32]

    public init(container bytes: some Collection<UInt8>) throws(PTPError) {
        let header = try PTPContainerHeader.decode(bytes, maxLength: PTPContainerHeader.size + 4 * 5)
        guard header.type == PTPContainerType.event.rawValue else {
            throw .unexpectedContainerType(expected: .event, actual: header.type)
        }
        guard bytes.count >= Int(header.length) else { throw .truncated(needed: Int(header.length), available: bytes.count) }
        var r = PTPDataReader(bytes)
        try r.skip(PTPContainerHeader.size)
        var params: [UInt32] = []
        for _ in 0..<(header.payloadLength / 4) { params.append(try r.u32()) }
        code = header.code
        transactionID = header.transactionID
        parameters = params
    }
}

/// The result of one complete transaction.
public struct PTPTransactionResult: Sendable {
    public var response: PTPResponse
    /// Payload of the device → host data phase, without the container header. Empty if none.
    public var data: Data

    public init(response: PTPResponse, data: Data) {
        self.response = response
        self.data = data
    }
}
