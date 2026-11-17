public import Foundation

/// Bounds-checked little-endian reader for PTP datasets. Every read validates the remaining length,
/// and array counts are checked against the bytes actually available before any allocation.
public struct PTPDataReader: Sendable {
    public let data: Data
    public private(set) var offset: Int  // relative to data.startIndex

    public init(_ data: Data) {
        self.data = data
        offset = 0
    }

    public init(_ bytes: some Collection<UInt8>) {
        self.init(Data(bytes))
    }

    public var remaining: Int { data.count - offset }
    public var isAtEnd: Bool { remaining == 0 }

    private mutating func need(_ n: Int) throws(PTPError) {
        guard n >= 0, remaining >= n else { throw .truncated(needed: n, available: remaining) }
    }

    public mutating func skip(_ n: Int) throws(PTPError) {
        try need(n)
        offset += n
    }

    public mutating func u8() throws(PTPError) -> UInt8 {
        try need(1)
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    public mutating func u16() throws(PTPError) -> UInt16 {
        try need(2)
        let i = data.startIndex + offset
        offset += 2
        return UInt16(data[i]) | UInt16(data[i + 1]) << 8
    }

    public mutating func u32() throws(PTPError) -> UInt32 {
        try need(4)
        let i = data.startIndex + offset
        offset += 4
        return UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
    }

    public mutating func u64() throws(PTPError) -> UInt64 {
        let lo = try u32()
        let hi = try u32()
        return UInt64(hi) << 32 | UInt64(lo)
    }

    public mutating func bytes(_ n: Int) throws(PTPError) -> Data {
        try need(n)
        let start = data.startIndex + offset
        offset += n
        return data[start..<(start + n)]
    }

    /// PTP string: u8 character count (including the NUL terminator) followed by UTF-16LE code units.
    public mutating func string() throws(PTPError) -> String {
        let count = Int(try u8())
        if count == 0 { return "" }
        try need(count * 2)
        var units: [UInt16] = []
        units.reserveCapacity(count)
        for _ in 0..<count { units.append(try u16()) }
        if units.last == 0 { units.removeLast() }
        guard let s = String(validating: units, as: UTF16.self) else { throw .invalidString("invalid UTF-16") }
        return s
    }

    /// u32 element count followed by u16 elements.
    public mutating func u16Array() throws(PTPError) -> [UInt16] {
        let count = Int(try u32())
        guard count <= remaining / 2 else { throw .truncated(needed: count * 2, available: remaining) }
        var out: [UInt16] = []
        out.reserveCapacity(count)
        for _ in 0..<count { out.append(try u16()) }
        return out
    }

    /// u32 element count followed by u32 elements.
    public mutating func u32Array() throws(PTPError) -> [UInt32] {
        let count = Int(try u32())
        guard count <= remaining / 4 else { throw .truncated(needed: count * 4, available: remaining) }
        var out: [UInt32] = []
        out.reserveCapacity(count)
        for _ in 0..<count { out.append(try u32()) }
        return out
    }
}

/// Little-endian writer for PTP containers and datasets.
public struct PTPDataWriter: Sendable {
    public private(set) var data: Data

    public init(capacity: Int = 64) {
        data = Data(capacity: capacity)
    }

    public mutating func u8(_ v: UInt8) { data.append(v) }
    public mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    public mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    public mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    public mutating func bytes(_ d: Data) { data.append(d) }

    public mutating func string(_ s: String) throws(PTPError) {
        if s.isEmpty { u8(0); return }
        let units = Array(s.utf16) + [0]
        guard units.count <= 255 else { throw .invalidString("longer than 254 UTF-16 code units") }
        u8(UInt8(units.count))
        for u in units { u16(u) }
    }
}
