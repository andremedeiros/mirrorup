import ImageCaptureCore
public import MirrorupCapture
import MirrorupDiagnostics
import MirrorupImageCapture
import MirrorupUSB

/// Finds attached cameras on either transport, with no vendor filter: choosing a driver is
/// `CameraRegistry`'s job.
public enum CameraDiscovery {
    /// Cameras attached right now. ImageCaptureCore enumerates asynchronously after it starts, so the
    /// first call waits `settle` for it to report; USB enumeration is synchronous.
    public static func cameras(on transport: CameraTransport, settle: Duration = .seconds(2)) async -> [DiscoveredCamera] {
        switch transport {
        case .imageCapture:
            let started = await MainActor.run { () -> Bool in
                let browser = ImageCaptureBrowser.shared
                defer { browser.start() }
                return browser.isStarted
            }
            if !started { try? await Task.sleep(for: settle) }
            return await MainActor.run { ImageCaptureBrowser.shared.devices.map(DiscoveredCamera.init(imageCapture:)) }
        case .usb:
            return usbCameras()
        }
    }

    /// When cameras appear on `transport`, for `CaptureEngine(arrivals:)`; nil for USB, which reports
    /// no arrivals (the engine then re-checks on an interval).
    public static func arrivals(on transport: CameraTransport) -> (any CameraArrivals)? {
        switch transport {
        case .imageCapture: ImageCaptureArrivals()
        case .usb: nil
        }
    }

    private struct ImageCaptureArrivals: CameraArrivals {
        var arrivalCount: UInt64 {
            get async { await ImageCaptureBrowser.shared.arrivalCount }
        }

        func waitForArrival(after count: UInt64) async {
            await ImageCaptureBrowser.shared.waitForArrival(after: count)
        }
    }

    /// The first attached camera on `transport` for which `accept` is true. On ImageCaptureCore this
    /// waits up to `timeout` for one to appear (it reports devices shortly after it starts, and again
    /// when one is plugged in or turned on); USB enumeration is immediate.
    public static func firstCamera(
        on transport: CameraTransport, timeout: Duration, where accept: @escaping @Sendable (DiscoveredCamera) -> Bool
    ) async -> DiscoveredCamera? {
        switch transport {
        case .imageCapture:
            return await firstImageCaptureCamera(timeout: timeout, where: accept)
        case .usb:
            return usbCameras().first(where: accept)
        }
    }

    @MainActor
    private static func firstImageCaptureCamera(
        timeout: Duration, where accept: @escaping @Sendable (DiscoveredCamera) -> Bool
    ) async -> DiscoveredCamera? {
        let device = await ImageCaptureBrowser.shared.camera(matching: { accept(DiscoveredCamera(imageCapture: $0)) }, timeout: timeout)
        return device.map(DiscoveredCamera.init(imageCapture:))
    }

    /// USB devices with a Still Image (PTP) interface, plus devices from known camera makers that have
    /// none (so `mirrorup devices` can say why they can't be used).
    static func usbCameras() -> [DiscoveredCamera] {
        USBDiscovery.devices(vendorID: nil, readDescriptors: false).compactMap { device in
            let ptp = device.stillImageRegistryInterface != nil
            guard ptp || CameraVendor(usbVendorID: device.vendorID) != nil else { return nil }
            return DiscoveredCamera(
                name: device.product ?? CameraVendor(usbVendorID: device.vendorID).map { "\($0.name) camera" } ?? "USB camera",
                usbVendorID: device.vendorID, usbProductID: device.productID,
                transport: .usb, acceptsPTP: ptp, handle: .usb(device))
        }
    }
}

extension DiscoveredCamera {
    @MainActor
    init(imageCapture device: ICCameraDevice) {
        self.init(
            name: device.name ?? "Camera",
            usbVendorID: UInt16(truncatingIfNeeded: device.usbVendorID),
            usbProductID: UInt16(truncatingIfNeeded: device.usbProductID),
            transport: .imageCapture,
            acceptsPTP: device.capabilities.contains(ICDeviceCapability.cameraDeviceCanAcceptPTPCommands.rawValue),
            handle: .imageCapture(device))
    }
}
