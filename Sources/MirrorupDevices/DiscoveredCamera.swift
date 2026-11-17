import ImageCaptureCore
public import MirrorupCapture
import MirrorupDiagnostics
import MirrorupImageCapture
public import MirrorupPTP
import MirrorupUSB

/// How the Mac talks to a camera's PTP interface.
public enum CameraTransport: String, Sendable, CaseIterable, CustomStringConvertible {
    /// ImageCaptureCore pass-through via macOS's ptpcamerad. The default: it works alongside the
    /// system, which owns the PTP interface whenever a camera is attached.
    case imageCapture
    /// Direct IOUSBHost bulk transfers. Needs the PTP interface to be unclaimed
    /// (docs/usb-feasibility.md).
    case usb

    /// The name used in `CameraIdentity.transport` and diagnostics.
    public var description: String {
        switch self {
        case .imageCapture: "ImageCaptureCore"
        case .usb: "USB"
        }
    }
}

/// An attached camera, found by `CameraDiscovery`, before any driver has talked to it. Carries what
/// a driver needs to decide whether it supports the camera and a way to open its PTP interface.
public struct DiscoveredCamera: Sendable, CustomStringConvertible {
    /// The name the device reports ("Canon EOS Rebel SL2", "Canon Digital Camera").
    public var name: String
    public var usbVendorID: UInt16
    public var usbProductID: UInt16
    public var transport: CameraTransport
    /// Whether the device offers a PTP (Still Image class) interface on this transport.
    public var acceptsPTP: Bool
    /// The vendor's name when the USB vendor ID is a known camera maker.
    public var vendorName: String? { CameraVendor(usbVendorID: usbVendorID)?.name }

    let handle: Handle

    enum Handle: @unchecked Sendable {
        /// Only touched on the main actor, where ImageCaptureCore lives.
        case imageCapture(ICCameraDevice)
        case usb(USBDeviceSnapshot)
        /// Tests: a camera with no real device behind it.
        case none
    }

    init(name: String, usbVendorID: UInt16, usbProductID: UInt16, transport: CameraTransport, acceptsPTP: Bool, handle: Handle) {
        self.name = name
        self.usbVendorID = usbVendorID
        self.usbProductID = usbProductID
        self.transport = transport
        self.acceptsPTP = acceptsPTP
        self.handle = handle
    }

    /// A camera with no device behind it, for testing driver selection. Opening it fails.
    public static func placeholder(name: String, usbVendorID: UInt16, usbProductID: UInt16 = 0,
                                   transport: CameraTransport = .imageCapture, acceptsPTP: Bool = true) -> Self {
        Self(name: name, usbVendorID: usbVendorID, usbProductID: usbProductID, transport: transport,
             acceptsPTP: acceptsPTP, handle: .none)
    }

    public var description: String {
        "\(name) [\(String(format: "%04X:%04X", usbVendorID, usbProductID))] via \(transport)"
    }

    /// An identity for backends built on this camera; drivers refine it after GetDeviceInfo.
    public var identity: CameraIdentity { CameraIdentity(name: name, transport: transport.description) }

    /// Opens a PTP session on the camera's Still Image interface. The session is not opened on the
    /// camera yet (`PTPSession.open()` does that); the transport is claimed.
    public func openPTPSession(commandTimeout: Duration = .seconds(5)) async throws(CameraError) -> PTPSession {
        guard acceptsPTP else {
            throw CameraError(.protocolViolation, "This camera doesn't offer a PTP connection over USB.",
                              detail: "\(description) has no Still Image interface")
        }
        switch handle {
        case .imageCapture(let device):
            let transport = await MainActor.run { ImageCapturePTPTransport(camera: device) }
            return PTPSession(transport: transport, defaultTimeout: commandTimeout)
        case .usb(let device):
            do {
                return PTPSession(transport: try USBPTPConnection.open(device), defaultTimeout: commandTimeout)
            } catch {
                switch error.transportError {
                case .exclusiveAccess(let owner):
                    throw CameraError(
                        .inUseByAnotherApplication,
                        "The camera's USB interface is in use by another process. Use the default (Image Capture) transport.",
                        detail: "\(error.description) [owner: \(owner)]")
                case .accessDenied:
                    throw CameraError(.accessDenied, "macOS denied direct USB access to the camera.", detail: error.description)
                default:
                    throw CameraError(.disconnected, "Could not open the camera over USB.", detail: error.description)
                }
            }
        case .none:
            throw CameraError(.notFound, "This camera is not attached.", detail: "\(description) is a placeholder")
        }
    }
}

/// Camera makers by USB vendor ID, for naming devices before any driver has talked to them.
public struct CameraVendor: Sendable, Equatable {
    public let usbVendorID: UInt16
    public let name: String

    public init?(usbVendorID: UInt16) {
        guard let name = Self.known[usbVendorID] else { return nil }
        self.usbVendorID = usbVendorID
        self.name = name
    }

    /// USB-IF assigned vendor IDs of camera makers that speak PTP.
    static let known: [UInt16: String] = [
        0x04A9: "Canon",
        0x04B0: "Nikon",
        0x054C: "Sony",
        0x04CB: "Fujifilm",
        0x04DA: "Panasonic",
        0x07B4: "Olympus",
        0x0A17: "Pentax",
        0x25FB: "Ricoh",
    ]
}
