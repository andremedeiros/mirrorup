public import Foundation
import MirrorupPTP

/// Canon EOS device property codes used by Mirrorup (docs/canon-eos-ptp.md §3, §8).
public enum CanonProperty {
    public static let aperture: UInt32 = 0xD101
    public static let shutterSpeed: UInt32 = 0xD102
    public static let isoSpeed: UInt32 = 0xD103
    public static let exposureCompensation: UInt32 = 0xD104
    public static let autoExposureMode: UInt32 = 0xD105
    public static let whiteBalance: UInt32 = 0xD109
    public static let batteryPower: UInt32 = 0xD111
    public static let autoPowerOff: UInt32 = 0xD114
    public static let availableShots: UInt32 = 0xD11B
    public static let aeModeDial: UInt32 = 0xD138
    public static let lensStatus: UInt32 = 0xD1A8
    /// EVF output device bitmask: 0x1 TFT (rear LCD), 0x2 PC.
    public static let evfOutputDevice: UInt32 = 0xD1B0
    /// EVF mode: 0 off, 1 on.
    public static let evfMode: UInt32 = 0xD1B1

    public static let evfOutputTFT: UInt32 = 0x1
    public static let evfOutputPC: UInt32 = 0x2
}

/// A property value as reported by GetEvent PropValueChanged. Integer properties occupy a 4-byte
/// little-endian slot; anything else (strings, arrays) is kept raw.
public enum CanonPropertyValue: Sendable, Equatable {
    case integer(UInt32)
    case raw(Data)

    public var integer: UInt32? {
        if case .integer(let v) = self { return v }
        return nil
    }
}

/// Last-known property values and allowed-value lists, fed by GetEvent.
public struct CanonPropertyCache: Sendable {
    public private(set) var values: [UInt32: CanonPropertyValue] = [:]
    public private(set) var allowedValues: [UInt32: [UInt32]] = [:]

    public init() {}

    public subscript(_ property: UInt32) -> CanonPropertyValue? { values[property] }

    public mutating func apply(_ events: [CanonEvent]) {
        for event in events {
            switch event {
            case .propertyChanged(let prop, let value): values[prop] = value
            case .allowedValuesChanged(let prop, let allowed): allowedValues[prop] = allowed
            default: break
            }
        }
    }
}

/// SetDevicePropValueEx data phase for integer properties: [u32 size=12][u32 prop][u32 value].
public enum CanonPropertyEncoding {
    public static func integerPayload(property: UInt32, value: UInt32) -> Data {
        var w = PTPDataWriter(capacity: 12)
        w.u32(12)
        w.u32(property)
        w.u32(value)
        return w.data
    }
}
