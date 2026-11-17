public import MirrorupCapture
public import MirrorupDevices
public import MirrorupPTP

/// Canon EOS cameras over PTP (validated: EOS Rebel SL2 / 200D). Claims every Canon USB device that
/// offers PTP; bodies without EOS live view fail at `startLiveView` with a clear error rather than
/// being hidden.
public struct CanonDriver: CameraDriver {
    public static let usbVendorID: UInt16 = 0x04A9

    public let options: CanonCamera.Options

    public init(options: CanonCamera.Options = .init()) {
        self.options = options
    }

    public var id: String { "canon-eos" }
    public var name: String { "Canon EOS" }

    public func supports(_ camera: DiscoveredCamera) -> Bool {
        camera.usbVendorID == Self.usbVendorID && camera.acceptsPTP
    }

    public func makeBackend(for camera: DiscoveredCamera) async throws(CameraError) -> any CameraBackend {
        try await makeCamera(for: camera)
    }

    /// The concrete backend, for tools that need Canon-only diagnostics (`pollStatistics`).
    public func makeCamera(for camera: DiscoveredCamera) async throws(CameraError) -> CanonCamera {
        let session = try await camera.openPTPSession(commandTimeout: options.commandTimeout)
        return CanonCamera(session: session, identity: camera.identity, options: options)
    }

    public var ptpNames: PTPCodeNames {
        PTPCodeNames(
            operation: CanonCatalog.operationName,
            event: { CanonCatalog.eventName(UInt32($0)) },
            property: { CanonCatalog.propertyName(UInt32($0)) },
            objectFormat: CanonCatalog.objectFormatName)
    }

    public func liveViewSupport(_ info: PTPDeviceInfo) -> String? {
        info.supports(CanonOperation.getViewfinderData) ? "yes (EOS GetViewFinderData)" : "no (GetViewFinderData not listed)"
    }
}
