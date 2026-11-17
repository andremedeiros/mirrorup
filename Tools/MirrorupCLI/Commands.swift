import Foundation
import ImageIO
import MirrorupCameras
import MirrorupCapture
import MirrorupDevices
import MirrorupImageCapture
import MirrorupPTP
import MirrorupUSB

enum Commands {
    static func hex16(_ v: UInt16) -> String { String(format: "0x%04X", v) }

    static func devices() async {
        let registry = CameraRegistry.builtIn
        func show(_ cameras: [DiscoveredCamera]) {
            if cameras.isEmpty { print("  none") }
            for camera in cameras {
                let driver = registry.driver(for: camera).map { "driver \($0.id)" }
                    ?? (camera.acceptsPTP ? "not supported yet" : "no PTP interface")
                print("  \(camera.name)  usb \(String(format: "%04X:%04X", camera.usbVendorID, camera.usbProductID))  \(camera.vendorName ?? "unknown vendor")  \(driver)")
            }
        }
        print("USB cameras (PTP devices and known camera makers):")
        let usb = USBDiscovery.devices(vendorID: nil, readDescriptors: false)
            .filter { $0.stillImageRegistryInterface != nil || CameraVendor(usbVendorID: $0.vendorID) != nil }
        if usb.isEmpty { print("  none") }
        for d in usb {
            print("  \(d.product ?? "?") — \(d.manufacturer ?? "?")")
            print("    vendor \(hex16(d.vendorID))  product \(hex16(d.productID))  location \(d.locationID.map { String(format: "0x%08X", $0) } ?? "?")  \(d.speedDescription)")
            if let ptp = d.stillImageRegistryInterface {
                print("    PTP interface \(ptp.number): \(ptp.exclusiveOwner.map { "claimed by \($0)" } ?? "unclaimed")")
            } else {
                print("    no PTP (Still Image) interface")
            }
        }
        print("Image Capture cameras:")
        show(await CameraDiscovery.cameras(on: .imageCapture))
        print("Drivers: \(registry.drivers.map { "\($0.name) (\($0.id))" }.joined(separator: ", "))")
    }

    static func inspect() {
        let devices = USBDiscovery.devices(vendorID: nil, readDescriptors: true)
            .filter { $0.stillImageRegistryInterface != nil || CameraVendor(usbVendorID: $0.vendorID) != nil }
        if devices.isEmpty {
            print("No USB cameras attached.")
            return
        }
        for d in devices {
            print("\(d.product ?? "Unknown") (\(d.manufacturer ?? "unknown manufacturer"))")
            print("  vendor ID      \(hex16(d.vendorID))")
            print("  product ID     \(hex16(d.productID))")
            print("  serial         \(d.serialNumber ?? "not provided")")
            print("  speed          \(d.speedDescription)")
            print("  registry ID    0x\(String(d.registryID, radix: 16))")
            if let config = d.configuration {
                print("  configuration  \(config.value)  attributes 0x\(String(config.attributes, radix: 16)) (\(config.selfPowered ? "self" : "bus") powered)  max power \(config.maxPowerMilliamps) mA")
                for iface in config.interfaces {
                    print("  interface \(iface.number) alt \(iface.alternateSetting): \(iface.className) class 0x\(String(iface.interfaceClass, radix: 16)) subclass 0x\(String(iface.interfaceSubClass, radix: 16)) protocol 0x\(String(iface.interfaceProtocol, radix: 16))\(iface.isStillImage ? "  [PTP]" : "")")
                    for ep in iface.endpoints { print("    \(ep)") }
                    if iface.isStillImage {
                        print("    bulk IN  \(iface.bulkIn.map { "0x" + String($0.address, radix: 16) } ?? "missing")")
                        print("    bulk OUT \(iface.bulkOut.map { "0x" + String($0.address, radix: 16) } ?? "missing")")
                        print("    interrupt \(iface.interruptIn.map { "0x" + String($0.address, radix: 16) } ?? "none")")
                    }
                }
            } else {
                print("  configuration  unavailable: \(d.configurationError ?? "unknown error")")
            }
            for r in d.interfaces {
                print("  registry interface \(r.number): owner \(r.exclusiveOwner ?? "none")")
            }
            guard d.stillImageRegistryInterface != nil else { continue }
            print("  claim test:")
            do {
                // Dropping the transport destroys the interface client and releases the claim.
                _ = try USBPTPConnection.open(d)
                print("    claimed the PTP interface directly and released it")
            } catch {
                print("    \(error)")
                if case .exclusiveAccess = error.transportError {
                    print("    -> macOS's camera service holds the interface. Mirrorup uses the Image Capture")
                    print("       pass-through instead (the default transport). See docs/usb-feasibility.md.")
                }
            }
        }
    }

    /// The first attached camera a built-in driver supports.
    static func findCamera(_ transport: CameraTransport) async throws -> (camera: DiscoveredCamera, driver: any CameraDriver) {
        if let found = await CameraRegistry.builtIn.firstSupportedCamera(on: transport) { return found }
        throw await CameraRegistry.builtIn.notFoundError(on: transport)
    }

    static func openCamera(_ transport: CameraTransport) async throws -> any CameraBackend {
        let (camera, driver) = try await findCamera(transport)
        return try await driver.makeBackend(for: camera)
    }

    /// GetDeviceInfo over a bare PTP session: works for any PTP camera a driver claims.
    static func deviceInfo(_ camera: DiscoveredCamera) async throws -> PTPDeviceInfo {
        let session = try await camera.openPTPSession()
        try await session.open()
        let info: PTPDeviceInfo
        do {
            info = try await session.deviceInfo()
        } catch {
            await session.close()
            throw error
        }
        await session.close()
        return info
    }

    static func ptpInfo(transport: CameraTransport) async throws {
        let (camera, driver) = try await findCamera(transport)
        let info = try await deviceInfo(camera)
        print("Manufacturer        \(info.manufacturer)")
        print("Model               \(info.model)")
        print("Device version      \(info.deviceVersion)")
        print("Serial number       \(info.serialNumber.isEmpty ? "(empty)" : info.serialNumber)")
        print("PTP version         \(Double(info.standardVersion) / 100)")
        let vendor = info.vendorExtensionName ?? "unknown"
        print("Vendor extension    \(vendor) (0x\(String(info.vendorExtensionID, radix: 16))) v\(info.vendorExtensionVersion) \"\(info.vendorExtensionDescription)\"")
        print("Functional mode     \(info.functionalMode)")
        print("Operations          \(info.operationsSupported.count)")
        print("Events              \(info.eventsSupported.count)")
        print("Device properties   \(info.devicePropertiesSupported.count)")
        func formats(_ codes: [UInt16]) -> String {
            codes.map { driver.ptpNames.objectFormat($0) ?? hex16($0) }.joined(separator: ", ")
        }
        print("Capture formats     \(formats(info.captureFormats))")
        print("Image formats       \(formats(info.imageFormats))")
        print("Live view support   \(driver.liveViewSupport(info) ?? "unknown")")
        print("Driver              \(driver.name) (\(driver.id))")
        print("Transport           \(camera.transport)")
    }

    static func ptpOperations(transport: CameraTransport) async throws {
        let (camera, driver) = try await findCamera(transport)
        let info = try await deviceInfo(camera)
        let names = driver.ptpNames
        func show(_ title: String, _ codes: [UInt16], name: (UInt16) -> String?) {
            print("\(title) (\(codes.count)):")
            for code in codes.sorted() { print("  \(hex16(code))  \(name(code) ?? "undocumented")") }
        }
        print(info.model)
        show("Operations", info.operationsSupported, name: names.operation)
        show("Events", info.eventsSupported, name: names.event)
        show("Device properties", info.devicePropertiesSupported, name: names.property)
        show("Capture formats", info.captureFormats, name: names.objectFormat)
        show("Image formats", info.imageFormats, name: names.objectFormat)
    }

    /// Connects (remote mode + event drain, which reports every property), prints the decoded
    /// metadata grouped by section, and leaves the camera in local mode again.
    static func cameraInfo(jsonPath: String?, transport: CameraTransport) async throws {
        let camera = try await openCamera(transport)
        let metadata: CameraMetadata
        do {
            try await camera.connect()
            metadata = await camera.metadata()
            await camera.disconnect()
        } catch {
            await camera.disconnect()
            throw error
        }
        printMetadata(metadata.documentedOnly)
        let all = metadata.sections.reduce(0) { $0 + $1.items.count }
        let documented = metadata.documentedOnly.sections.reduce(0) { $0 + $1.items.count }
        print("\n\(documented) documented items shown; \(all - documented) undocumented vendor codes omitted (included in --json).")
        if let jsonPath {
            try writeJSON(metadata, to: jsonPath)
            print("wrote \(jsonPath)")
        }
    }

    static func printMetadata(_ metadata: CameraMetadata) {
        for section in metadata.sections.sorted(by: { $0.kind < $1.kind }) {
            print("\n\(section.title)")
            let width = min(28, section.items.map(\.label.count).max() ?? 0)
            for item in section.items {
                let label = item.label.padding(toLength: max(width, item.label.count), withPad: " ", startingAt: 0)
                print("  \(label)  \(item.value)")
                if item.allowedValues.count > 1 {
                    let pad = String(repeating: " ", count: max(width, item.label.count) + 4)
                    print("\(pad)options: \(item.allowedValues.joined(separator: ", "))")
                }
            }
        }
    }

    static func writeJSON(_ value: some Encodable, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: URL(fileURLWithPath: path))
    }

    static func snapshot(output: String, transport: CameraTransport) async throws {
        let camera = try await openCamera(transport)
        do {
            try await camera.connect()
            try await camera.startLiveView()
            let frame = try await camera.nextFrame()
            // Ask before stopping live view: the frame section describes the latest frame.
            let frameMetadata = await camera.metadata().section(.frame).map { CameraMetadata(sections: [$0]) }
            try await camera.stopLiveView()
            await camera.disconnect()
            try frame.jpeg.write(to: URL(fileURLWithPath: output))
            let dims = jpegDimensions(frame.jpeg).map { "\($0.width)x\($0.height)" } ?? "undecodable"
            print("saved \(frame.jpeg.count) bytes (\(dims)) to \(output)")
            if let metadata = frameMetadata {
                printMetadata(metadata.documentedOnly)
                try writeJSON(metadata, to: output + ".json")
                print("\nwrote frame metadata to \(output).json")
            }
        } catch {
            await camera.disconnect()
            throw error
        }
    }
}

/// Decodes the JPEG header with ImageIO to report the camera's real frame size.
func jpegDimensions(_ jpeg: Data) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return (w, h)
}
