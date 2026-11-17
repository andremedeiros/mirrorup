public import IOKit
public import MirrorupPTP

/// USB-layer failure with the native IOReturn preserved.
public struct USBError: Error, Sendable, Equatable, CustomStringConvertible {
    public var operation: String
    public var code: IOReturn
    /// Registry-reported exclusive owner of the device/interface, when known (e.g. "pid 812, ptpcamerad").
    public var owner: String?

    public init(_ operation: String, code: IOReturn, owner: String? = nil) {
        self.operation = operation
        self.code = code
        self.owner = owner
    }

    public var description: String {
        var s = "\(operation) failed: \(USBError.name(of: code)) (0x\(String(UInt32(bitPattern: code), radix: 16)))"
        if let owner { s += "; interface owned by \(owner)" }
        return s
    }

    public static func name(of code: IOReturn) -> String {
        switch code {
        case kIOReturnSuccess: "kIOReturnSuccess"
        case kIOReturnError: "kIOReturnError"
        case kIOReturnNoResources: "kIOReturnNoResources"
        case kIOReturnNoDevice: "kIOReturnNoDevice"
        case kIOReturnNotPrivileged: "kIOReturnNotPrivileged"
        case kIOReturnBadArgument: "kIOReturnBadArgument"
        case kIOReturnExclusiveAccess: "kIOReturnExclusiveAccess"
        case kIOReturnUnsupported: "kIOReturnUnsupported"
        case kIOReturnInternalError: "kIOReturnInternalError"
        case kIOReturnIOError: "kIOReturnIOError"
        case kIOReturnNotOpen: "kIOReturnNotOpen"
        case kIOReturnBusy: "kIOReturnBusy"
        case kIOReturnTimeout: "kIOReturnTimeout"
        case kIOReturnOffline: "kIOReturnOffline"
        case kIOReturnNotReady: "kIOReturnNotReady"
        case kIOReturnNotPermitted: "kIOReturnNotPermitted"
        case kIOReturnUnderrun: "kIOReturnUnderrun"
        case kIOReturnOverrun: "kIOReturnOverrun"
        case kIOReturnDeviceError: "kIOReturnDeviceError"
        case kIOReturnAborted: "kIOReturnAborted"
        case kIOReturnNotResponding: "kIOReturnNotResponding"
        case IOReturn(bitPattern: 0xE000_5000): "kUSBHostReturnPipeStalled"
        default: "IOReturn"
        }
    }

    /// Maps into the transport-neutral error set used by the PTP layer.
    public var transportError: PTPTransportError {
        switch code {
        case kIOReturnNoDevice, kIOReturnOffline, kIOReturnNotResponding:
            return .disconnected(description)
        case kIOReturnAborted:
            return .cancelled
        case kIOReturnTimeout:
            return .timedOut(operation: operation, after: .zero)
        case kIOReturnExclusiveAccess:
            return .exclusiveAccess(owner ?? "another process")
        case kIOReturnNotPrivileged, kIOReturnNotPermitted:
            return .accessDenied(description)
        default:
            // IOUSBHost reports "interface already owned" as kIOReturnInternalError; the owner
            // recorded in the registry is the reliable signal.
            if let owner { return .exclusiveAccess(owner) }
            return .io(description, code: Int(code))
        }
    }
}

extension IOReturn {
    init(bitPattern: UInt32) { self.init(truncatingIfNeeded: Int64(bitPattern)) }
}
