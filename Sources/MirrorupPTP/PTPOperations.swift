/// PTP operation code (ISO 15740 §10.4). Vendor extensions define further codes in 0x9000–0x9FFF;
/// those live in their vendor modules, not here.
public struct PTPOperationCode: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public init(_ rawValue: UInt16) { self.rawValue = rawValue }

    public static let getDeviceInfo = Self(0x1001)
    public static let openSession = Self(0x1002)
    public static let closeSession = Self(0x1003)
    public static let getStorageIDs = Self(0x1004)
    public static let getStorageInfo = Self(0x1005)
    public static let getNumObjects = Self(0x1006)
    public static let getObjectHandles = Self(0x1007)
    public static let getObjectInfo = Self(0x1008)
    public static let getObject = Self(0x1009)
    public static let getThumb = Self(0x100A)
    public static let deleteObject = Self(0x100B)
    public static let sendObjectInfo = Self(0x100C)
    public static let sendObject = Self(0x100D)
    public static let initiateCapture = Self(0x100E)
    public static let formatStore = Self(0x100F)
    public static let resetDevice = Self(0x1010)
    public static let selfTest = Self(0x1011)
    public static let setObjectProtection = Self(0x1012)
    public static let powerDown = Self(0x1013)
    public static let getDevicePropDesc = Self(0x1014)
    public static let getDevicePropValue = Self(0x1015)
    public static let setDevicePropValue = Self(0x1016)
    public static let resetDevicePropValue = Self(0x1017)
    public static let terminateOpenCapture = Self(0x1018)
    public static let moveObject = Self(0x1019)
    public static let copyObject = Self(0x101A)
    public static let getPartialObject = Self(0x101B)
    public static let initiateOpenCapture = Self(0x101C)

    /// Standard (PTP/MTP) name; vendor modules name their own codes (e.g. `CanonCatalog`).
    public var name: String? { PTPCatalog.operationName(rawValue) }

    public var description: String {
        let hex = "0x" + String(rawValue, radix: 16, uppercase: true)
        return name.map { "\($0) (\(hex))" } ?? hex
    }
}

/// Parsed GetDeviceInfo dataset (ISO 15740 §5.5.1).
public struct PTPDeviceInfo: Sendable, Equatable {
    public var standardVersion: UInt16
    public var vendorExtensionID: UInt32
    public var vendorExtensionVersion: UInt16
    public var vendorExtensionDescription: String
    public var functionalMode: UInt16
    public var operationsSupported: [UInt16]
    public var eventsSupported: [UInt16]
    public var devicePropertiesSupported: [UInt16]
    public var captureFormats: [UInt16]
    public var imageFormats: [UInt16]
    public var manufacturer: String
    public var model: String
    public var deviceVersion: String
    public var serialNumber: String

    public init(
        standardVersion: UInt16, vendorExtensionID: UInt32, vendorExtensionVersion: UInt16,
        vendorExtensionDescription: String, functionalMode: UInt16, operationsSupported: [UInt16],
        eventsSupported: [UInt16], devicePropertiesSupported: [UInt16], captureFormats: [UInt16],
        imageFormats: [UInt16], manufacturer: String, model: String, deviceVersion: String, serialNumber: String
    ) {
        self.standardVersion = standardVersion
        self.vendorExtensionID = vendorExtensionID
        self.vendorExtensionVersion = vendorExtensionVersion
        self.vendorExtensionDescription = vendorExtensionDescription
        self.functionalMode = functionalMode
        self.operationsSupported = operationsSupported
        self.eventsSupported = eventsSupported
        self.devicePropertiesSupported = devicePropertiesSupported
        self.captureFormats = captureFormats
        self.imageFormats = imageFormats
        self.manufacturer = manufacturer
        self.model = model
        self.deviceVersion = deviceVersion
        self.serialNumber = serialNumber
    }

    /// Vendor extension IDs assigned by the PTP standard / PIMA registry.
    public static let vendorExtensionCanon: UInt32 = 0x0000_000B
    /// Many Canon bodies report the Microsoft (MTP) extension ID instead of Canon's own.
    public static let vendorExtensionMicrosoft: UInt32 = 0x0000_0006

    public init(decoding data: some Collection<UInt8>) throws(PTPError) {
        var r = PTPDataReader(data)
        standardVersion = try r.u16()
        vendorExtensionID = try r.u32()
        vendorExtensionVersion = try r.u16()
        vendorExtensionDescription = try r.string()
        functionalMode = try r.u16()
        operationsSupported = try r.u16Array()
        eventsSupported = try r.u16Array()
        devicePropertiesSupported = try r.u16Array()
        captureFormats = try r.u16Array()
        imageFormats = try r.u16Array()
        manufacturer = try r.string()
        model = try r.string()
        deviceVersion = try r.string()
        serialNumber = try r.string()
    }

    public func supports(_ op: PTPOperationCode) -> Bool { operationsSupported.contains(op.rawValue) }
}
