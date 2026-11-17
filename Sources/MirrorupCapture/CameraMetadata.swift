/// Vendor-neutral, human-readable camera metadata: what the camera is, how it is configured, and
/// what each live-view frame reports. Backends translate their protocol codes into this model so the
/// app and CLI never interpret vendor codes themselves.
public struct CameraMetadata: Sendable, Equatable, Codable {
    public var sections: [Section]

    public init(sections: [Section] = []) {
        self.sections = sections
    }

    public struct Section: Sendable, Equatable, Codable, Identifiable {
        public var kind: SectionKind
        public var items: [Item]

        public init(_ kind: SectionKind, items: [Item]) {
            self.kind = kind
            self.items = items
        }

        public var id: SectionKind { kind }
        public var title: String { kind.title }
    }

    public struct Item: Sendable, Equatable, Codable, Identifiable {
        public var kind: ItemKind
        /// Display name. For neutral kinds this is `kind.title`; for vendor codes it is the vendor's
        /// documented name (or a hex placeholder when undocumented).
        public var label: String
        /// Human-readable value ("f/5.6", "1/125 s", "EF-S18-55mm f/4-5.6 IS STM").
        public var value: String
        /// The underlying protocol value ("0x30", hex bytes), for diagnostics.
        public var raw: String
        /// false for codes no public source documents. UIs hide these; JSON exports and
        /// diagnostics keep them so nothing the camera reports is lost.
        public var isDocumented: Bool
        /// Values the camera currently accepts for this setting, in human form (empty if the camera
        /// did not report a list or the setting is read-only).
        public var allowedValues: [String]

        public init(_ kind: ItemKind, label: String? = nil, value: String, raw: String, isDocumented: Bool = true, allowedValues: [String] = []) {
            self.kind = kind
            self.label = label ?? kind.title
            self.value = value
            self.raw = raw
            self.isDocumented = isDocumented
            self.allowedValues = allowedValues
        }

        public var id: ItemKind { kind }
    }

    public enum SectionKind: String, Sendable, Codable, CaseIterable, Comparable {
        case device, lens, exposure, focus, image, whiteBalance, liveView, movie, power, storage
        case frame, capabilities, other

        public var title: String {
            switch self {
            case .device: "Device"
            case .lens: "Lens"
            case .exposure: "Exposure"
            case .focus: "Focus"
            case .image: "Image"
            case .whiteBalance: "White Balance"
            case .liveView: "Live View"
            case .movie: "Movie"
            case .power: "Power"
            case .storage: "Storage"
            case .frame: "Current Frame"
            case .capabilities: "Capabilities"
            case .other: "Other"
            }
        }

        /// Display order follows declaration order.
        public static func < (lhs: Self, rhs: Self) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    /// What an item describes. Neutral kinds have the same meaning for every camera brand;
    /// `vendorProperty`/`vendorFrameBlock` carry codes without a neutral meaning.
    public enum ItemKind: Sendable, Hashable, Codable {
        // Device
        case manufacturer, model, firmwareVersion, serialNumber, nickname, ownerName, artist, copyright
        case transport, protocolVersion, vendorExtension, dateTime, timeZone
        // Lens
        case lensName, lensAttached
        // Exposure
        case exposureMode, aperture, shutterSpeed, iso, exposureCompensation, meteringMode, driveMode
        case flashCompensation, autoExposureBracketing
        // Focus
        case focusMode, liveViewAFMethod
        // Image
        case imageQuality, imageStyle, colorSpace, aspectRatio
        // White balance
        case whiteBalance, colorTemperature, whiteBalanceShift
        // Live view
        case liveViewOutput, liveViewMode, liveViewFrameSize, exposureSimulation
        // Movie
        case movieRecordingSize, movieRecordingState
        // Power
        case batteryLevel, autoPowerOff
        // Storage
        case captureDestination, availableShots
        // Capabilities
        case supportedOperations, supportedEvents, supportedProperties, supportedCaptureFormats
        case supportedImageFormats
        // Per-frame (live view)
        case frameSize, sensorSize, zoom, zoomRect, magnifierOrigin, magnifierRect, autofocusActive, focusPoints
        case cameraTimestamp, frameCounter, histogram
        // Vendor codes without a neutral meaning
        case vendorProperty(UInt32)
        case vendorFrameBlock(UInt32)

        public var title: String {
            switch self {
            case .manufacturer: "Manufacturer"
            case .model: "Model"
            case .firmwareVersion: "Firmware"
            case .serialNumber: "Serial Number"
            case .nickname: "Nickname"
            case .ownerName: "Owner"
            case .artist: "Artist"
            case .copyright: "Copyright"
            case .transport: "Connection"
            case .protocolVersion: "PTP Version"
            case .vendorExtension: "Vendor Extension"
            case .dateTime: "Camera Clock"
            case .timeZone: "Time Zone"
            case .lensName: "Lens"
            case .lensAttached: "Lens Attached"
            case .exposureMode: "Shooting Mode"
            case .aperture: "Aperture"
            case .shutterSpeed: "Shutter Speed"
            case .iso: "ISO"
            case .exposureCompensation: "Exposure Compensation"
            case .meteringMode: "Metering"
            case .driveMode: "Drive Mode"
            case .flashCompensation: "Flash Compensation"
            case .autoExposureBracketing: "Exposure Bracketing"
            case .focusMode: "Focus Mode"
            case .liveViewAFMethod: "Live View AF Method"
            case .imageQuality: "Image Quality"
            case .imageStyle: "Image Style"
            case .colorSpace: "Color Space"
            case .aspectRatio: "Aspect Ratio"
            case .whiteBalance: "White Balance"
            case .colorTemperature: "Color Temperature"
            case .whiteBalanceShift: "White Balance Shift"
            case .liveViewOutput: "Live View Output"
            case .liveViewMode: "Live View"
            case .liveViewFrameSize: "Live View Size"
            case .exposureSimulation: "Exposure Simulation"
            case .movieRecordingSize: "Movie Size"
            case .movieRecordingState: "Movie Recording"
            case .batteryLevel: "Battery"
            case .autoPowerOff: "Auto Power Off"
            case .captureDestination: "Save To"
            case .availableShots: "Shots Remaining"
            case .supportedOperations: "Operations"
            case .supportedEvents: "Events"
            case .supportedProperties: "Device Properties"
            case .supportedCaptureFormats: "Capture Formats"
            case .supportedImageFormats: "Image Formats"
            case .frameSize: "Frame Size"
            case .sensorSize: "Sensor Size"
            case .zoom: "Zoom"
            case .zoomRect: "Visible Area"
            case .magnifierOrigin: "Magnifier Position"
            case .magnifierRect: "Magnifier Area"
            case .autofocusActive: "Autofocus"
            case .focusPoints: "Focus Points"
            case .cameraTimestamp: "Camera Time"
            case .frameCounter: "Frame Counter"
            case .histogram: "Histogram"
            case .vendorProperty(let code): "Property 0x" + String(code, radix: 16, uppercase: true)
            case .vendorFrameBlock(let type): "Frame Block 0x" + String(type, radix: 16, uppercase: true)
            }
        }
    }

    public var isEmpty: Bool { sections.allSatisfy { $0.items.isEmpty } }

    public func section(_ kind: SectionKind) -> Section? { sections.first { $0.kind == kind } }

    public func item(_ kind: ItemKind) -> Item? {
        for section in sections { if let item = section.items.first(where: { $0.kind == kind }) { return item } }
        return nil
    }

    /// The same metadata without undocumented items (and without sections left empty).
    public var documentedOnly: CameraMetadata {
        CameraMetadata(sections: sections.compactMap { section in
            let items = section.items.filter(\.isDocumented)
            return items.isEmpty ? nil : Section(section.kind, items: items)
        })
    }
}
