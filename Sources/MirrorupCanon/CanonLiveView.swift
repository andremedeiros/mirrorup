public import Foundation

/// Parsed GetViewfinderData payload.
public struct CanonViewfinderFrame: Sendable {
    /// JPEG bytes as a slice of the original payload (no copy).
    public var jpeg: Data
    /// Block types present, in order, for diagnostics.
    public var blockTypes: [UInt32]
}

public enum CanonViewfinderError: Error, Sendable, Equatable, CustomStringConvertible {
    case blockLengthInvalid(offset: Int, length: UInt32)
    case noImageBlock(types: [UInt32])
    case imageNotJPEG
    case jpegTruncated

    public var description: String {
        switch self {
        case .blockLengthInvalid(let offset, let length): "EVF block at \(offset) has invalid length \(length)"
        case .noImageBlock(let types): "EVF payload has no image block (types: \(types.map { String($0, radix: 16) }))"
        case .imageNotJPEG: "EVF image block does not start with a JPEG SOI marker"
        case .jpegTruncated: "EVF JPEG has no EOI marker"
        }
    }
}

/// Parser for the EOS live-view payload: blocks of `[u32 length incl. header][u32 type][payload]`
/// (docs/canon-eos-ptp.md §4.2). Type 1 (and 11 on some bodies) carries the JPEG.
public enum CanonViewfinderParser {
    public static let jpegBlockTypes: Set<UInt32> = [0x1, 0xB]

    public static func parse(_ data: Data) throws(CanonViewfinderError) -> CanonViewfinderFrame {
        var offset = 0
        var types: [UInt32] = []
        var jpeg: Data?
        let base = data.startIndex
        func u32(_ at: Int) -> UInt32 {
            let i = base + at
            return UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
        }
        while offset + 8 <= data.count {
            let length = u32(offset)
            let type = u32(offset + 4)
            if length == 8 && type == 0 { break }  // terminator
            guard length >= 8, Int(length) <= data.count - offset else {
                throw .blockLengthInvalid(offset: offset, length: length)
            }
            types.append(type)
            if jpeg == nil, jpegBlockTypes.contains(type) {
                jpeg = data[(base + offset + 8)..<(base + offset + Int(length))]
            }
            offset += Int(length)
        }
        guard let jpeg else { throw .noImageBlock(types: types) }
        try validateJPEG(jpeg)
        return CanonViewfinderFrame(jpeg: jpeg, blockTypes: types)
    }

    /// Checks the SOI marker and an EOI marker near the end (encoders may pad after EOI).
    static func validateJPEG(_ jpeg: Data) throws(CanonViewfinderError) {
        guard jpeg.count >= 4, jpeg[jpeg.startIndex] == 0xFF, jpeg[jpeg.startIndex + 1] == 0xD8 else {
            throw .imageNotJPEG
        }
        let tailStart = max(jpeg.startIndex + 2, jpeg.endIndex - 64)
        var i = jpeg.endIndex - 2
        while i >= tailStart {
            if jpeg[i] == 0xFF && jpeg[i + 1] == 0xD9 { return }
            i -= 1
        }
        throw .jpegTruncated
    }
}
