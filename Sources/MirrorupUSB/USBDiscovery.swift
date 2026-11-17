import Foundation
import IOKit
import IOKit.usb
import IOUSBHost
import MirrorupDiagnostics

/// Snapshot of one attached USB device, read from the IORegistry plus (when the device user client
/// can be opened) its active configuration descriptor.
public struct USBDeviceSnapshot: Sendable {
    public var registryID: UInt64
    public var vendorID: UInt16
    public var productID: UInt16
    public var manufacturer: String?
    public var product: String?
    public var serialNumber: String?
    public var locationID: UInt32?
    /// USB speed as reported by the registry ("Device Speed": 0 low, 1 full, 2 high, 3 super, 4 super+).
    public var speed: Int?
    public var configuration: USBConfigurationInfo?
    /// Why the configuration descriptor could not be read, if it could not.
    public var configurationError: String?
    /// IORegistry interface nodes, which also report the current exclusive owner of each interface.
    public var interfaces: [RegistryInterface]

    public struct RegistryInterface: Sendable, Equatable {
        public var registryID: UInt64
        public var number: UInt8
        public var interfaceClass: UInt8
        public var interfaceSubClass: UInt8
        public var interfaceProtocol: UInt8
        /// e.g. "pid 812, ptpcamerad". nil when unclaimed.
        public var exclusiveOwner: String?
    }

    public var speedDescription: String {
        switch speed {
        case 0: "Low Speed (1.5 Mb/s)"
        case 1: "Full Speed (12 Mb/s)"
        case 2: "High Speed (480 Mb/s)"
        case 3: "SuperSpeed (5 Gb/s)"
        case 4: "SuperSpeed+ (10 Gb/s)"
        default: "unknown"
        }
    }

    public var stillImageRegistryInterface: RegistryInterface? {
        interfaces.first { $0.interfaceClass == 6 && $0.interfaceSubClass == 1 && $0.interfaceProtocol == 1 }
    }
}

public enum USBDiscovery {
    /// Enumerates attached devices, optionally filtered by USB vendor ID. Reading descriptors opens each
    /// device's user client briefly; failures are recorded per device, never swallowed.
    public static func devices(vendorID: UInt16? = nil, readDescriptors: Bool = true) -> [USBDeviceSnapshot] {
        var match: [String: Any] = [kIOProviderClassKey: "IOUSBHostDevice"]
        if let vendorID { match[kIOPropertyMatchKey] = ["idVendor": Int(vendorID)] }
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, match as CFDictionary, &iterator)
        guard kr == KERN_SUCCESS else {
            Diagnostics.usb.error("IOServiceGetMatchingServices failed: \(USBError.name(of: kr), privacy: .public)")
            return []
        }
        defer { IOObjectRelease(iterator) }
        var result: [USBDeviceSnapshot] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            result.append(snapshot(of: service, readDescriptors: readDescriptors))
        }
        return result
    }

    static func snapshot(of service: io_service_t, readDescriptors: Bool) -> USBDeviceSnapshot {
        var snap = USBDeviceSnapshot(
            registryID: registryID(service),
            vendorID: UInt16(truncatingIfNeeded: intProperty(service, "idVendor") ?? 0),
            productID: UInt16(truncatingIfNeeded: intProperty(service, "idProduct") ?? 0),
            manufacturer: stringProperty(service, "kUSBVendorString") ?? stringProperty(service, "USB Vendor Name"),
            product: stringProperty(service, "kUSBProductString") ?? stringProperty(service, "USB Product Name"),
            serialNumber: stringProperty(service, "kUSBSerialNumberString") ?? stringProperty(service, "USB Serial Number"),
            locationID: intProperty(service, "locationID").map { UInt32(truncatingIfNeeded: $0) },
            speed: intProperty(service, "Device Speed") ?? intProperty(service, "USBSpeed"),
            configuration: nil,
            configurationError: nil,
            interfaces: interfaces(of: service)
        )
        if readDescriptors {
            do {
                snap.configuration = try readConfiguration(service)
            } catch {
                snap.configurationError = String(describing: error)
            }
        }
        return snap
    }

    /// Opens the device user client (not the interface; ptpcamerad only owns the interface) and
    /// copies the active configuration descriptor.
    static func readConfiguration(_ service: io_service_t) throws -> USBConfigurationInfo {
        IOObjectRetain(service)  // the IOUSBHostObject takes over this reference
        let device: IOUSBHostDevice
        do {
            device = try IOUSBHostDevice(__ioService: service, options: [], queue: nil, interestHandler: nil)
        } catch {
            throw USBError("open IOUSBHostDevice", code: ioReturn(from: error))
        }
        defer { device.destroy() }
        guard let config = device.configurationDescriptor else {
            throw USBError("read configuration descriptor", code: kIOReturnNotReady)
        }
        let total = Int(config.pointee.wTotalLength)
        let bytes = [UInt8](UnsafeRawBufferPointer(start: UnsafeRawPointer(config), count: total))
        return try USBDescriptorParser.parseConfiguration(bytes)
    }

    /// The device's own interfaces. Interfaces may sit below intermediate nubs, so the walk descends,
    /// but it never enters a nested device: a hub's subtree holds the devices plugged into it, whose
    /// interfaces are theirs, not the hub's.
    static func interfaces(of device: io_service_t) -> [USBDeviceSnapshot.RegistryInterface] {
        var result: [USBDeviceSnapshot.RegistryInterface] = []
        collectInterfaces(below: device, into: &result)
        return result
    }

    private static func collectInterfaces(below parent: io_registry_entry_t, into result: inout [USBDeviceSnapshot.RegistryInterface]) {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(parent, kIOServicePlane, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            if IOObjectConformsTo(entry, "IOUSBHostDevice") != 0 { continue }
            guard IOObjectConformsTo(entry, "IOUSBHostInterface") != 0 else {
                collectInterfaces(below: entry, into: &result)
                continue
            }
            result.append(.init(
                registryID: registryID(entry),
                number: UInt8(truncatingIfNeeded: intProperty(entry, "bInterfaceNumber") ?? 0),
                interfaceClass: UInt8(truncatingIfNeeded: intProperty(entry, "bInterfaceClass") ?? 0),
                interfaceSubClass: UInt8(truncatingIfNeeded: intProperty(entry, "bInterfaceSubClass") ?? 0),
                interfaceProtocol: UInt8(truncatingIfNeeded: intProperty(entry, "bInterfaceProtocol") ?? 0),
                exclusiveOwner: stringProperty(entry, "UsbExclusiveOwner")
            ))
        }
    }

    /// Looks up a registry entry by ID; caller releases.
    static func service(registryID: UInt64) -> io_service_t? {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID))
        return s == 0 ? nil : s
    }

    static func registryID(_ entry: io_registry_entry_t) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &id)
        return id
    }

    static func intProperty(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        (property(entry, key) as? NSNumber)?.intValue
    }

    static func stringProperty(_ entry: io_registry_entry_t, _ key: String) -> String? {
        property(entry, key) as? String
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> CFTypeRef? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func ioReturn(from error: any Error) -> IOReturn {
        IOReturn(truncatingIfNeeded: (error as NSError).code)
    }
}
