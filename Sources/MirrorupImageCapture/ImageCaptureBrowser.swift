public import ImageCaptureCore
import MirrorupDiagnostics

/// Long-lived ImageCaptureCore device browser. ImageCaptureCore delivers browser and device delegate
/// callbacks on the main thread, so this type is main-actor isolated; transports hop here only to
/// start requests, never to wait for them.
@MainActor
public final class ImageCaptureBrowser: NSObject {
    public static let shared = ImageCaptureBrowser()

    public struct CameraSummary: Sendable, Equatable {
        public var name: String
        public var uuid: String?
        public var transport: String?
        public var usbVendorID: Int
        public var usbProductID: Int
        public var acceptsPTPCommands: Bool
    }

    private let browser = ICDeviceBrowser()
    private var started = false
    private(set) var cameras: [ICCameraDevice] = []
    private var waiters: [UInt64: CheckedContinuation<UncheckedBox<ICCameraDevice>?, Never>] = [:]
    private var waiterPredicates: [UInt64: (ICCameraDevice) -> Bool] = [:]
    private var nextWaiter: UInt64 = 0
    private var removalHandlers: [ObjectIdentifier: [UInt64: @MainActor () -> Void]] = [:]
    private var nextRemovalToken: UInt64 = 0

    override private init() {
        super.init()
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(
            rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        ) ?? .camera
    }

    public var isStarted: Bool { started }

    /// Cameras ImageCaptureCore currently reports, in arrival order.
    public var devices: [ICCameraDevice] { cameras }

    public func start() {
        guard !started else { return }
        started = true
        browser.start()
    }

    public var summaries: [CameraSummary] {
        cameras.map {
            CameraSummary(
                name: $0.name ?? "Camera", uuid: $0.uuidString, transport: $0.transportType,
                usbVendorID: Int($0.usbVendorID), usbProductID: Int($0.usbProductID),
                acceptsPTPCommands: $0.capabilities.contains(ICDeviceCapability.cameraDeviceCanAcceptPTPCommands.rawValue)
            )
        }
    }

    /// Returns the first camera matching `predicate`, waiting up to `timeout` for one to appear.
    /// Enumeration after `start()` is asynchronous, so a short wait is normal even when attached.
    public func camera(matching predicate: @escaping (ICCameraDevice) -> Bool, timeout: Duration) async -> ICCameraDevice? {
        start()
        if let found = cameras.first(where: predicate) { return found }
        nextWaiter += 1
        let id = nextWaiter
        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            self?.resolveWaiter(id, with: nil)
        }
        defer { timer.cancel() }
        let box = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<UncheckedBox<ICCameraDevice>?, Never>) in
                waiters[id] = cont
                waiterPredicates[id] = predicate
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolveWaiter(id, with: nil) }
        }
        return box?.value
    }

    /// Registers a callback for when `device` disappears. Returns a token for `removeRemovalHandler`.
    func onRemoval(of device: ICCameraDevice, _ handler: @escaping @MainActor () -> Void) -> UInt64 {
        nextRemovalToken += 1
        removalHandlers[ObjectIdentifier(device), default: [:]][nextRemovalToken] = handler
        return nextRemovalToken
    }

    func removeRemovalHandler(_ token: UInt64, for device: ICCameraDevice) {
        removalHandlers[ObjectIdentifier(device)]?[token] = nil
    }

    private func resolveWaiter(_ id: UInt64, with device: ICCameraDevice?) {
        waiterPredicates[id] = nil
        waiters.removeValue(forKey: id)?.resume(returning: device.map(UncheckedBox.init))
    }
}

extension ImageCaptureBrowser: @MainActor ICDeviceBrowserDelegate {
    public func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        Diagnostics.imageCapture.info("camera added: \(camera.name ?? "?", privacy: .public) usb=\(String(format: "%04x:%04x", camera.usbVendorID, camera.usbProductID), privacy: .public)")
        cameras.append(camera)
        for (id, predicate) in waiterPredicates where predicate(camera) {
            resolveWaiter(id, with: camera)
        }
    }

    public func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Diagnostics.imageCapture.notice("camera removed: \(device.name ?? "?", privacy: .public)")
        cameras.removeAll { $0 === device }
        if let handlers = removalHandlers.removeValue(forKey: ObjectIdentifier(device)) {
            for handler in handlers.values { handler() }
        }
    }
}
