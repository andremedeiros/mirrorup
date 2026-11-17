import ImageCaptureCore
public import MirrorupCapture
import MirrorupDiagnostics
import MirrorupImageCapture
import MirrorupPTP
import MirrorupUSB

/// Finds an attached Canon camera and builds a `CanonCamera` on the chosen transport.
public enum CanonBackendFactory {
    public enum Transport: String, Sendable, CaseIterable {
        /// ImageCaptureCore pass-through via macOS's ptpcamerad (default; works alongside the system).
        case imageCapture
        /// Direct IOUSBHost bulk transfers; requires the PTP interface to be unclaimed.
        case usb
    }

    public static func makeBackend(
        transport: Transport = .imageCapture,
        discoveryTimeout: Duration = .seconds(3),
        options: CanonCamera.Options = .init()
    ) async throws(CameraError) -> any CameraBackend {
        try await makeCamera(transport: transport, discoveryTimeout: discoveryTimeout, options: options)
    }

    public static func makeCamera(
        transport: Transport = .imageCapture,
        discoveryTimeout: Duration = .seconds(3),
        options: CanonCamera.Options = .init()
    ) async throws(CameraError) -> CanonCamera {
        switch transport {
        case .imageCapture:
            guard let (ptpTransport, name) = await findImageCaptureCamera(timeout: discoveryTimeout) else {
                throw CameraError(.notFound, "No Canon camera is connected. Connect it with USB and turn it on.")
            }
            let session = PTPSession(transport: ptpTransport, defaultTimeout: options.commandTimeout)
            return CanonCamera(session: session, identity: CameraIdentity(name: name, transport: "ImageCaptureCore"), options: options)

        case .usb:
            guard let device = USBDiscovery.devices(vendorID: USBDiscovery.canonVendorID, readDescriptors: false)
                .first(where: { $0.stillImageRegistryInterface != nil })
            else {
                throw CameraError(.notFound, "No Canon camera is connected. Connect it with USB and turn it on.")
            }
            do {
                let ptpTransport = try USBPTPConnection.open(device)
                let session = PTPSession(transport: ptpTransport, defaultTimeout: options.commandTimeout)
                return CanonCamera(session: session, identity: CameraIdentity(name: device.product ?? "Canon camera", transport: "USB"), options: options)
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
        }
    }

    @MainActor
    private static func findImageCaptureCamera(timeout: Duration) async -> (ImageCapturePTPTransport, String)? {
        let camera = await ImageCaptureBrowser.shared.camera(matching: { camera in
            camera.usbVendorID == Int32(USBDiscovery.canonVendorID)
                && camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanAcceptPTPCommands.rawValue)
        }, timeout: timeout)
        guard let camera else { return nil }
        return (ImageCapturePTPTransport(camera: camera), camera.name ?? "Canon camera")
    }
}
