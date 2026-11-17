public import Foundation
public import MirrorupPTP

/// A file the camera announced through GetEvent (docs/canon-eos-ptp.md §5.1).
public struct CanonObjectInfo: Sendable, Equatable {
    public var handle: UInt32
    /// 0 for RequestObjectTransfer records (the file is in camera RAM, not on a card).
    public var storageID: UInt32
    /// PTP object format code (e.g. 0x3801 EXIF/JPEG, 0x3001 Association = folder).
    public var format: UInt16
    public var size: UInt32
    /// File name as the camera reports it ("IMG_0042.JPG"); empty when the record carries none.
    public var filename: String

    public init(handle: UInt32, storageID: UInt32, format: UInt16, size: UInt32, filename: String) {
        self.handle = handle
        self.storageID = storageID
        self.format = format
        self.size = size
        self.filename = filename
    }

    /// PTP Association: a folder, not a picture.
    public static let associationFormat: UInt16 = 0x3001
    public var isFolder: Bool { format == Self.associationFormat }
}

/// One GetEvent record. Unrecognised records are preserved by code so logs can show them.
public enum CanonEvent: Sendable, Equatable {
    case propertyChanged(property: UInt32, value: CanonPropertyValue)
    case allowedValuesChanged(property: UInt32, values: [UInt32])
    case cameraStatusChanged(UInt32)
    case willSoonShutdown
    case shutdownTimerUpdated
    /// ObjectAddedEx / ObjectAddedEx64: a new file on a card.
    case objectAdded(CanonObjectInfo)
    /// RequestObjectTransfer(64): a capture held in camera RAM for the host to fetch.
    case objectTransferRequested(CanonObjectInfo)
    case other(code: UInt32, size: Int)

    public static let propValueChanged: UInt32 = 0xC189
    public static let availListChanged: UInt32 = 0xC18A
    public static let objectAddedEx: UInt32 = 0xC181
    public static let requestObjectTransfer: UInt32 = 0xC186
    public static let cameraStatusChangedCode: UInt32 = 0xC18B
    public static let willSoonShutdownCode: UInt32 = 0xC18D
    public static let shutdownTimerUpdatedCode: UInt32 = 0xC18E
    public static let objectAddedEx64: UInt32 = 0xC1A7
    public static let requestObjectTransfer64: UInt32 = 0xC1A9
}

public enum CanonEventParser {
    /// Parses a GetEvent data phase: records `[u32 size][u32 code][size-8 bytes]`, terminated by a
    /// record of size 8 and code 0. Malformed tails are rejected rather than guessed at.
    public static func parse(_ data: Data) throws(PTPError) -> [CanonEvent] {
        var events: [CanonEvent] = []
        var r = PTPDataReader(data)
        while r.remaining >= 8 {
            let size = Int(try r.u32())
            let code = try r.u32()
            if size == 8 && code == 0 { return events }  // terminator
            guard size >= 8 else { throw .invalidContainerLength(UInt32(size)) }
            let body = try r.bytes(size - 8)
            events.append(try decode(code: code, body: body))
        }
        // No terminator: accept a cleanly consumed buffer, reject trailing garbage.
        guard r.isAtEnd else { throw .truncated(needed: 8, available: r.remaining) }
        return events
    }

    /// Body offsets (record offset − 8) of the object records, from libgphoto2 ptp-pack.c
    /// (PTP_cee_OA_*, PTP_cee_OA64_*, PTP_cee_OI_*).
    private struct ObjectLayout {
        let storage: Int?
        let format: Int
        let size: Int
        let name: Int

        static let added = ObjectLayout(storage: 0x04, format: 0x08, size: 0x14, name: 0x20)
        static let added64 = ObjectLayout(storage: 0x04, format: 0x08, size: 0x14, name: 0x24)
        static let transfer = ObjectLayout(storage: nil, format: 0x04, size: 0x0C, name: 0x14)
    }

    static func decode(code: UInt32, body: Data) throws(PTPError) -> CanonEvent {
        var r = PTPDataReader(body)
        switch code {
        case CanonEvent.propValueChanged:
            let property = try r.u32()
            let valueBytes = try r.bytes(r.remaining)
            return .propertyChanged(property: property, value: integerValue(valueBytes).map(CanonPropertyValue.integer) ?? .raw(valueBytes))
        case CanonEvent.availListChanged:
            let property = try r.u32()
            try r.skip(4)  // form type
            let count = Int(try r.u32())
            guard count <= r.remaining / 4 else { throw .truncated(needed: count * 4, available: r.remaining) }
            var values: [UInt32] = []
            values.reserveCapacity(count)
            for _ in 0..<count { values.append(try r.u32()) }
            return .allowedValuesChanged(property: property, values: values)
        case CanonEvent.cameraStatusChangedCode:
            return .cameraStatusChanged(try r.u32())
        case CanonEvent.willSoonShutdownCode:
            return .willSoonShutdown
        case CanonEvent.shutdownTimerUpdatedCode:
            return .shutdownTimerUpdated
        case CanonEvent.objectAddedEx:
            return .objectAdded(try object(body, .added))
        case CanonEvent.objectAddedEx64:
            return .objectAdded(try object(body, .added64))
        case CanonEvent.requestObjectTransfer, CanonEvent.requestObjectTransfer64:
            return .objectTransferRequested(try object(body, .transfer))
        default:
            return .other(code: code, size: body.count + 8)
        }
    }

    private static func object(_ body: Data, _ layout: ObjectLayout) throws(PTPError) -> CanonObjectInfo {
        guard body.count >= layout.name else { throw .truncated(needed: layout.name, available: body.count) }
        func u32(_ at: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(body[body.startIndex + at + $1]) << (8 * UInt32($1)) }
        }
        let nameBytes = body[(body.startIndex + layout.name)...].prefix { $0 != 0 }
        return CanonObjectInfo(
            handle: u32(0),
            storageID: layout.storage.map(u32) ?? 0,
            format: UInt16(truncatingIfNeeded: u32(layout.format)),
            size: u32(layout.size),
            filename: String(decoding: nameBytes, as: UTF8.self))
    }

    /// Integer properties use a 1, 2 or 4 byte little-endian value.
    static func integerValue(_ bytes: Data) -> UInt32? {
        guard [1, 2, 4].contains(bytes.count) else { return nil }
        var value: UInt32 = 0
        for (i, b) in bytes.enumerated() { value |= UInt32(b) << (8 * UInt32(i)) }
        return value
    }
}
