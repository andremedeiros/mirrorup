/// PTP response code (ISO 15740 §10.5). Vendor codes (0xA000–0xAFFF) are named by vendor modules.
public struct PTPResponseCode: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public init(_ rawValue: UInt16) { self.rawValue = rawValue }

    public static let undefined = Self(0x2000)
    public static let ok = Self(0x2001)
    public static let generalError = Self(0x2002)
    public static let sessionNotOpen = Self(0x2003)
    public static let invalidTransactionID = Self(0x2004)
    public static let operationNotSupported = Self(0x2005)
    public static let parameterNotSupported = Self(0x2006)
    public static let incompleteTransfer = Self(0x2007)
    public static let invalidStorageID = Self(0x2008)
    public static let invalidObjectHandle = Self(0x2009)
    public static let devicePropNotSupported = Self(0x200A)
    public static let invalidObjectFormatCode = Self(0x200B)
    public static let storeFull = Self(0x200C)
    public static let objectWriteProtected = Self(0x200D)
    public static let storeReadOnly = Self(0x200E)
    public static let accessDenied = Self(0x200F)
    public static let noThumbnailPresent = Self(0x2010)
    public static let selfTestFailed = Self(0x2011)
    public static let partialDeletion = Self(0x2012)
    public static let storeNotAvailable = Self(0x2013)
    public static let specificationByFormatUnsupported = Self(0x2014)
    public static let noValidObjectInfo = Self(0x2015)
    public static let invalidCodeFormat = Self(0x2016)
    public static let unknownVendorCode = Self(0x2017)
    public static let captureAlreadyTerminated = Self(0x2018)
    public static let deviceBusy = Self(0x2019)
    public static let invalidParentObject = Self(0x201A)
    public static let invalidDevicePropFormat = Self(0x201B)
    public static let invalidDevicePropValue = Self(0x201C)
    public static let invalidParameter = Self(0x201D)
    public static let sessionAlreadyOpen = Self(0x201E)
    public static let transactionCancelled = Self(0x201F)
    public static let specificationOfDestinationUnsupported = Self(0x2020)

    /// Standard (PTP/MTP) name; vendor modules name their own codes (e.g. `CanonCatalog`).
    public var name: String? { PTPCatalog.responseName(rawValue) }

    public var description: String {
        let hex = "0x" + String(rawValue, radix: 16, uppercase: true)
        return name.map { "\($0) (\(hex))" } ?? hex
    }
}

/// Errors raised by a transport. Every transport (IOUSBHost, ImageCaptureCore, test fakes) maps its
/// native failures into this closed set so higher layers can classify them without knowing the transport.
public enum PTPTransportError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The device went away (unplugged, powered off, or the system terminated our access).
    case disconnected(String)
    /// The operation did not complete within its deadline. The transport is unusable afterwards
    /// because the device may still be mid-transaction.
    case timedOut(operation: String, after: Duration)
    /// Another process owns the device or interface.
    case exclusiveAccess(String)
    /// Permission or entitlement missing.
    case accessDenied(String)
    /// The transport was closed or never opened.
    case notOpen
    /// The calling task was cancelled. If cancellation interrupted a transaction, the transport is
    /// unusable afterwards for the same reason as a timeout.
    case cancelled
    /// Any other I/O failure, with the native code preserved for diagnostics.
    case io(String, code: Int)

    public var description: String {
        switch self {
        case .disconnected(let why): "device disconnected: \(why)"
        case .timedOut(let op, let after): "\(op) timed out after \(after)"
        case .exclusiveAccess(let owner): "device is in use by \(owner)"
        case .accessDenied(let why): "access denied: \(why)"
        case .notOpen: "transport is not open"
        case .cancelled: "operation cancelled"
        case .io(let what, let code): "I/O error: \(what) (code \(code))"
        }
    }
}

/// Protocol-level failures: malformed data from the device, or a well-formed failure response.
public enum PTPError: Error, Sendable, Equatable, CustomStringConvertible {
    case truncated(needed: Int, available: Int)
    case invalidContainerLength(UInt32)
    case containerTooLarge(declared: UInt32, limit: Int)
    case unexpectedContainerType(expected: PTPContainerType, actual: UInt16)
    case operationMismatch(expected: UInt16, actual: UInt16)
    case transactionIDMismatch(expected: UInt32, actual: UInt32)
    case tooManyParameters(Int)
    case invalidString(String)
    case unexpectedDataPhase(operation: PTPOperationCode)
    case missingDataPhase(operation: PTPOperationCode)
    /// The device completed the transaction with a non-OK response code.
    case response(PTPResponseCode, operation: PTPOperationCode)
    case transport(PTPTransportError)
    case sessionNotOpen

    public var description: String {
        switch self {
        case .truncated(let needed, let available): "truncated PTP data: needed \(needed) bytes, had \(available)"
        case .invalidContainerLength(let len): "invalid PTP container length \(len)"
        case .containerTooLarge(let declared, let limit): "PTP container of \(declared) bytes exceeds limit \(limit)"
        case .unexpectedContainerType(let expected, let actual): "expected \(expected) container, got type \(actual)"
        case .operationMismatch(let e, let a): "container code 0x\(String(a, radix: 16)) does not match 0x\(String(e, radix: 16))"
        case .transactionIDMismatch(let e, let a): "transaction ID \(a) does not match expected \(e)"
        case .tooManyParameters(let n): "\(n) parameters exceeds PTP maximum of 5"
        case .invalidString(let why): "invalid PTP string: \(why)"
        case .unexpectedDataPhase(let op): "\(op) returned an unexpected data phase"
        case .missingDataPhase(let op): "\(op) returned no data phase"
        case .response(let code, let op): "\(op) failed with \(code)"
        case .transport(let t): t.description
        case .sessionNotOpen: "PTP session is not open"
        }
    }

    /// Transport failure carried by this error, if any.
    public var transportError: PTPTransportError? {
        if case .transport(let t) = self { return t }
        return nil
    }
}
