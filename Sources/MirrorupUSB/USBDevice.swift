/// Endpoint transfer type (bmAttributes bits 0–1).
public enum USBTransferType: UInt8, Sendable, CustomStringConvertible {
    case control = 0, isochronous = 1, bulk = 2, interrupt = 3

    public var description: String {
        switch self {
        case .control: "control"
        case .isochronous: "isochronous"
        case .bulk: "bulk"
        case .interrupt: "interrupt"
        }
    }
}

public struct USBEndpointInfo: Sendable, Equatable, CustomStringConvertible {
    public var address: UInt8
    public var transferType: USBTransferType
    /// wMaxPacketSize bits 0–10.
    public var maxPacketSize: Int
    public var interval: UInt8

    public var isInput: Bool { address & 0x80 != 0 }
    public var number: UInt8 { address & 0x0F }

    public var description: String {
        "EP 0x\(String(address, radix: 16)) \(isInput ? "IN" : "OUT") \(transferType) maxPacket=\(maxPacketSize)"
            + (transferType == .interrupt ? " interval=\(interval)" : "")
    }
}

public struct USBInterfaceInfo: Sendable, Equatable {
    public var number: UInt8
    public var alternateSetting: UInt8
    public var interfaceClass: UInt8
    public var interfaceSubClass: UInt8
    public var interfaceProtocol: UInt8
    public var endpoints: [USBEndpointInfo]

    /// USB Still Image Capture class (PTP): class 6, subclass 1, protocol 1.
    public var isStillImage: Bool { interfaceClass == 6 && interfaceSubClass == 1 && interfaceProtocol == 1 }

    public var bulkIn: USBEndpointInfo? { endpoints.first { $0.transferType == .bulk && $0.isInput } }
    public var bulkOut: USBEndpointInfo? { endpoints.first { $0.transferType == .bulk && !$0.isInput } }
    public var interruptIn: USBEndpointInfo? { endpoints.first { $0.transferType == .interrupt && $0.isInput } }

    public var className: String {
        switch interfaceClass {
        case 0x01: "Audio"
        case 0x02: "CDC Control"
        case 0x03: "HID"
        case 0x06: "Still Image"
        case 0x07: "Printer"
        case 0x08: "Mass Storage"
        case 0x09: "Hub"
        case 0x0A: "CDC Data"
        case 0x0E: "Video"
        case 0xFF: "Vendor Specific"
        default: "Class 0x\(String(interfaceClass, radix: 16))"
        }
    }
}

public struct USBConfigurationInfo: Sendable, Equatable {
    public var value: UInt8
    public var attributes: UInt8
    /// bMaxPower in milliamps, assuming 2 mA units (USB 2.0); SuperSpeed devices use 8 mA units.
    public var maxPowerMilliamps: Int
    public var interfaces: [USBInterfaceInfo]

    public var selfPowered: Bool { attributes & 0x40 != 0 }
    public var stillImageInterface: USBInterfaceInfo? { interfaces.first { $0.isStillImage } }
}

public enum USBDescriptorError: Error, Sendable, Equatable, CustomStringConvertible {
    case truncated(at: Int)
    case notAConfigurationDescriptor
    case invalidDescriptorLength(at: Int, length: UInt8)

    public var description: String {
        switch self {
        case .truncated(let at): "configuration descriptor truncated at byte \(at)"
        case .notAConfigurationDescriptor: "not a configuration descriptor"
        case .invalidDescriptorLength(let at, let len): "descriptor at byte \(at) has invalid length \(len)"
        }
    }
}

/// Parses a full configuration descriptor (configuration + interface + endpoint + class descriptors).
public enum USBDescriptorParser {
    public static func parseConfiguration(_ bytes: [UInt8]) throws(USBDescriptorError) -> USBConfigurationInfo {
        guard bytes.count >= 9 else { throw .truncated(at: bytes.count) }
        guard bytes[1] == 0x02, bytes[0] >= 9 else { throw .notAConfigurationDescriptor }
        let total = Int(bytes[2]) | Int(bytes[3]) << 8
        guard total <= bytes.count else { throw .truncated(at: bytes.count) }
        var config = USBConfigurationInfo(
            value: bytes[5], attributes: bytes[7], maxPowerMilliamps: Int(bytes[8]) * 2, interfaces: []
        )
        var offset = Int(bytes[0])
        while offset < total {
            guard offset + 2 <= total else { throw .truncated(at: offset) }
            let length = bytes[offset]
            guard length >= 2 else { throw .invalidDescriptorLength(at: offset, length: length) }
            guard offset + Int(length) <= total else { throw .truncated(at: offset) }
            switch bytes[offset + 1] {
            case 0x04 where length >= 9:
                config.interfaces.append(USBInterfaceInfo(
                    number: bytes[offset + 2], alternateSetting: bytes[offset + 3],
                    interfaceClass: bytes[offset + 5], interfaceSubClass: bytes[offset + 6],
                    interfaceProtocol: bytes[offset + 7], endpoints: []
                ))
            case 0x05 where length >= 7:
                // Endpoints belong to the most recent interface descriptor.
                guard !config.interfaces.isEmpty else { break }
                let attributes = bytes[offset + 3]
                let maxPacket = (Int(bytes[offset + 4]) | Int(bytes[offset + 5]) << 8) & 0x07FF
                config.interfaces[config.interfaces.count - 1].endpoints.append(USBEndpointInfo(
                    address: bytes[offset + 2],
                    transferType: USBTransferType(rawValue: attributes & 0x03) ?? .control,
                    maxPacketSize: maxPacket,
                    interval: bytes[offset + 6]
                ))
            default:
                break  // class-specific and other descriptors are skipped
            }
            offset += Int(length)
        }
        return config
    }
}
