public import MirrorupCapture
import MirrorupDiagnostics
public import MirrorupPTP

/// Support for one family of cameras (e.g. Canon EOS over PTP). A driver decides from what discovery
/// reports whether it can drive a camera, and builds the `CameraBackend` for it. Everything
/// vendor-specific (opcodes, property codes, live-view framing, control semantics, user-facing hints)
/// stays inside the driver's module; the capture engine, app and CLI only see `CameraBackend`,
/// `CameraControlling` and this protocol.
///
/// Adding a camera maker: see docs/adding-a-camera.md.
public protocol CameraDriver: Sendable {
    /// Stable identifier for logs and diagnostics ("canon-eos").
    var id: String { get }
    /// What the driver supports, for people ("Canon EOS").
    var name: String { get }

    /// Whether this driver can drive `camera`. Called for every attached camera on every discovery,
    /// so it must be cheap and must not talk to the device.
    func supports(_ camera: DiscoveredCamera) -> Bool

    /// Builds a backend for `camera`. Must not connect yet: `CameraBackend.connect()` does that,
    /// inside the capture engine's deadlines.
    func makeBackend(for camera: DiscoveredCamera) async throws(CameraError) -> any CameraBackend

    /// Names for the vendor's PTP codes, for `mirrorup ptp` and diagnostics. Defaults to the
    /// standard ISO 15740 names only.
    var ptpNames: PTPCodeNames { get }

    /// One line on how the camera provides live view, from its GetDeviceInfo; nil when unknown.
    func liveViewSupport(_ info: PTPDeviceInfo) -> String?
}

extension CameraDriver {
    public var ptpNames: PTPCodeNames { .standard }
    public func liveViewSupport(_ info: PTPDeviceInfo) -> String? { nil }
}

/// The drivers an app or tool ships with, and the one place that turns "whatever is plugged in" into
/// a backend.
public struct CameraRegistry: Sendable {
    public let drivers: [any CameraDriver]

    public init(drivers: [any CameraDriver]) {
        self.drivers = drivers
    }

    /// The first driver that supports `camera`, in registration order.
    public func driver(for camera: DiscoveredCamera) -> (any CameraDriver)? {
        drivers.first { $0.supports(camera) }
    }

    /// The first attached camera some driver supports, on `transport` (waiting up to `timeout` on
    /// ImageCaptureCore; see `CameraDiscovery.firstCamera`).
    public func firstSupportedCamera(on transport: CameraTransport = .imageCapture, timeout: Duration = .seconds(3))
        async -> (camera: DiscoveredCamera, driver: any CameraDriver)? {
        let drivers = drivers
        let camera = await CameraDiscovery.firstCamera(on: transport, timeout: timeout) { camera in
            drivers.contains { $0.supports(camera) }
        }
        guard let camera, let driver = driver(for: camera) else { return nil }
        return (camera, driver)
    }

    /// Finds the first supported camera and builds its backend. When cameras are attached but none is
    /// supported, the error names them, so the user knows Mirrorup saw the camera.
    public func makeBackend(on transport: CameraTransport = .imageCapture, timeout: Duration = .seconds(3))
        async throws(CameraError) -> any CameraBackend {
        if let (camera, driver) = await firstSupportedCamera(on: transport, timeout: timeout) {
            Diagnostics.devices.info("Using \(driver.id, privacy: .public) for \(camera.description, privacy: .public)")
            return try await driver.makeBackend(for: camera)
        }
        throw await notFoundError(on: transport)
    }

    /// Supported cameras attached over USB, whether or not Image Capture lists them. They carry the
    /// USB path (`usbHubCount`), which Image Capture doesn't report.
    public func supportedUSBCameras() -> [DiscoveredCamera] {
        CameraDiscovery.usbCameras().filter { camera in drivers.contains { $0.supports(camera) } }
    }

    /// The error for "no supported camera": names attached cameras no driver supports, if any, and
    /// says so when a supported camera is on USB but Image Capture doesn't list it.
    public func notFoundError(on transport: CameraTransport) async -> CameraError {
        Self.notFound(
            unsupported: await CameraDiscovery.cameras(on: transport, settle: .zero),
            unresponsive: transport == .imageCapture ? supportedUSBCameras() : [],
            drivers: drivers)
    }

    /// The not-found error for a discovery that matched no driver. `unresponsive`: supported cameras
    /// on USB that the transport didn't list: seen on the SL2 for minutes after a USB dropout. Some
    /// bodies may also stay on USB while off or asleep, so the message covers both.
    static func notFound(unsupported: [DiscoveredCamera], unresponsive: [DiscoveredCamera] = [],
                         drivers: [any CameraDriver]) -> CameraError {
        let supported = drivers.map(\.name).joined(separator: ", ")
        if let camera = unresponsive.first {
            return CameraError(
                .notFound, "\(camera.name) is connected but not responding. Turn it on, or if it is on, turn it off and on again.",
                detail: "on USB, not listed by Image Capture: \(unresponsive.map(\.description).joined(separator: "; ")); drivers: \(supported)")
        }
        // Image Capture also reports phones and scanners, and camera makers' USB IDs also cover their
        // printers and game controllers: only name something that looks like a camera.
        let camera = unsupported.first { $0.acceptsPTP && $0.vendorName != nil } ?? unsupported.first { $0.vendorName != nil && !$0.acceptsPTP }
        guard let camera else {
            let seen = unsupported.isEmpty ? "no attached devices" : "attached, not cameras: \(unsupported.map(\.description).joined(separator: "; "))"
            return CameraError(.notFound, "No camera found. Connect your camera with a USB cable and turn it on.",
                               detail: "\(seen); drivers: \(supported)")
        }
        let detail = "attached: \(unsupported.map(\.description).joined(separator: "; ")); drivers: \(supported)"
        if !camera.acceptsPTP {
            return CameraError(.notFound, "\(camera.name) doesn't offer a PTP connection. Set its USB mode to PTP or “PC Remote”, if it has one.",
                               detail: detail)
        }
        return CameraError(.notFound, "Mirrorup doesn't support \(camera.name) yet. It works with: \(supported).", detail: detail)
    }
}
