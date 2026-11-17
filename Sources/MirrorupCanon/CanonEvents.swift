public import Foundation
public import MirrorupPTP

/// One GetEvent record. Unrecognised records are preserved by code so logs can show them.
public enum CanonEvent: Sendable, Equatable {
    case propertyChanged(property: UInt32, value: CanonPropertyValue)
    case allowedValuesChanged(property: UInt32, values: [UInt32])
    case cameraStatusChanged(UInt32)
    case willSoonShutdown
    case shutdownTimerUpdated
    case objectAdded(handle: UInt32)
    case other(code: UInt32, size: Int)

    public static let propValueChanged: UInt32 = 0xC189
    public static let availListChanged: UInt32 = 0xC18A
    public static let objectAddedEx: UInt32 = 0xC181
    public static let cameraStatusChangedCode: UInt32 = 0xC18B
    public static let willSoonShutdownCode: UInt32 = 0xC18D
    public static let shutdownTimerUpdatedCode: UInt32 = 0xC18E
    public static let objectAddedEx64: UInt32 = 0xC1A7
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
        case CanonEvent.objectAddedEx, CanonEvent.objectAddedEx64:
            return .objectAdded(handle: try r.u32())
        default:
            return .other(code: code, size: body.count + 8)
        }
    }

    /// Integer properties use a 1, 2 or 4 byte little-endian value.
    static func integerValue(_ bytes: Data) -> UInt32? {
        guard [1, 2, 4].contains(bytes.count) else { return nil }
        var value: UInt32 = 0
        for (i, b) in bytes.enumerated() { value |= UInt32(b) << (8 * UInt32(i)) }
        return value
    }
}
