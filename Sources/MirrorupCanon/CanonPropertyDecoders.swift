import Foundation
public import MirrorupCapture
import MirrorupPTP

// Canon EOS device-property decoding: every PropValueChanged code becomes a CameraMetadata.Item with a
// human value. Runs only when items are produced (property changes, metadata snapshots), never per
// live-view frame, so formatting strings here is fine.
//
// Provenance (protocol facts restated as data, no code copied):
// - Property codes and names: libgphoto2 camlibs/ptp2/ptp.h (PTP_DPC_CANON_EOS_*), ptp.c property names.
//   Codes libgphoto2 names only "UnknownPropXXXX" are treated as undocumented.
// - Value widths: libgphoto2 ptp-pack.c ptp_unpack_EOS_events (u8/u16/u32/i32/string per property).
// - Value tables: Canon EDSDK API Programming Reference 13.20.11 (AEMode, DriveMode, ISOSpeed,
//   MeteringMode, AFMode, Av, Tv, ExposureCompensation, WhiteBalance, ColorSpace, PictureStyle,
//   ImageQuality, LensStatus, Evf_OutputDevice, Evf_Mode, Evf_AFMode, Evf_ViewType, MirrorLockUpState,
//   CardExtension, TempStatus, AutoPowerOffSetting, TimeZone, SummerTimeSetting, MovieSoundRecord),
//   with libgphoto2 config.c tables for PTP-only codes (Av/Tv/ISO "auto", metering 0/2/6/7, picture
//   style user sets, battery level, capture destination, aspect ratio, high-ISO NR, auto lighting
//   optimizer, quick review, EVF recording destination, AEB) and ptp-pack.c ptp_unpack_EOS_ImageFormat
//   for the ImageFormat struct.

extension CanonCatalog {
    /// One metadata item for a Canon EOS property value. Codes without a public reference come back
    /// with `isDocumented: false`, a hex label and the raw value, so nothing the camera says is lost.
    public static func describe(property code: UInt32, value: CanonPropertyValue) -> CameraMetadata.Item {
        let raw = rawString(value)
        guard let spec = propertySpecs[code] else {
            if let code16 = UInt16(exactly: code), let name = PTPCatalog.propertyName(code16) {
                return CameraMetadata.Item(.vendorProperty(code), label: name, value: number(value), raw: raw)
            }
            return CameraMetadata.Item(.vendorProperty(code), value: raw.isEmpty ? "Empty" : raw, raw: raw, isDocumented: false)
        }
        let text = format(value, as: spec.format, width: spec.width)
        if let kind = spec.kind { return CameraMetadata.Item(kind, value: text, raw: raw) }
        return CameraMetadata.Item(.vendorProperty(code), label: spec.label, value: text, raw: raw)
    }

    /// Human values for an AvailListChanged list, using the property's own decoder. Struct-valued
    /// properties whose list is a run of size-prefixed records (Time Zone) are decoded per record;
    /// other struct lists are shown as hex words.
    public static func describeAllowedValues(property code: UInt32, values: [UInt32]) -> [String] {
        guard let spec = propertySpecs[code] else { return values.map { hex($0) } }
        switch spec.format {
        case .timeZone:
            return records(values).map { timeZone($0) ?? words($0) }
        case .imageQuality, .text:
            return values.map { hex($0) }
        default:
            return values.map { format(.integer($0), as: spec.format, width: spec.width) }
        }
    }

    /// Human title for one value a user may choose (a camera control option), or nil when no reference
    /// documents the value: undocumented codes are never offered as choices.
    public static func optionTitle(property code: UInt32, value: UInt32) -> String? {
        guard let spec = propertySpecs[code] else { return nil }
        let v = value & spec.width.mask
        switch spec.format {
        case .aperture: return CanonValueTables.aperture[v]
        case .shutterSpeed: return CanonValueTables.shutterSpeed[v]
        case .iso: return CanonValueTables.iso[v]
        case .exposureCompensation: return CanonValueTables.exposureCompensation[v]
        case .exposureBracketStep: return CanonValueTables.exposureBracketStep[v]
        case .table(let table): return table.entries[v]
        case .kelvin, .number, .signedNumber, .duration:
            return format(.integer(value), as: spec.format, width: spec.width)
        case .identifier, .text, .liveViewOutput, .imageQuality, .localTime, .utcTime, .timeZone, .bracketMode,
             .temperatureStatus:
            return nil
        }
    }

    /// The metadata section a property belongs to; `.other` for undocumented codes.
    public static func section(forProperty code: UInt32) -> CameraMetadata.SectionKind {
        if let spec = propertySpecs[code] { return spec.section }
        if let code16 = UInt16(exactly: code), PTPCatalog.propertyName(code16) != nil { return .device }
        return .other
    }
}

// MARK: - Property table

/// How many low bytes of the 4-byte event slot carry the value (ptp-pack.c data types).
enum PropertyWidth: Sendable {
    case u8, u16, u32

    var mask: UInt32 {
        switch self {
        case .u8: 0xFF
        case .u16: 0xFFFF
        case .u32: 0xFFFF_FFFF
        }
    }
}

enum PropertyFormat: Sendable {
    /// Unsigned decimal; struct payloads are shown as hex words.
    case number
    case signedNumber
    /// An identifier (storage ID, model ID), shown as hex.
    case identifier
    case text
    case aperture, shutterSpeed, iso, exposureCompensation, exposureBracketStep
    case kelvin
    /// Seconds, 0 = disabled.
    case duration
    case liveViewOutput
    case imageQuality
    case localTime, utcTime
    case timeZone
    case bracketMode
    case temperatureStatus
    case table(ValueTable)
}

/// Enumerated property values. Each case is one reference table.
enum ValueTable: Sendable {
    case exposureMode, driveMode, meteringMode, focusMode, whiteBalance, pictureStyle, colorSpace
    case batteryLevel, captureDestination, aspectRatio, highISONoiseReduction, autoLightingOptimizer
    case quickReviewTime, liveViewRecordingDestination, liveViewAFMethod, exposureSimulation
    case onOff, enabled, lensStatus, mirrorLockupState, cardExtension, movieSoundRecording

    var entries: [UInt32: String] {
        switch self {
        case .exposureMode: CanonValueTables.exposureMode
        case .driveMode: CanonValueTables.driveMode
        case .meteringMode: CanonValueTables.meteringMode
        case .focusMode: CanonValueTables.focusMode
        case .whiteBalance: CanonValueTables.whiteBalance
        case .pictureStyle: CanonValueTables.pictureStyle
        case .colorSpace: CanonValueTables.colorSpace
        case .batteryLevel: CanonValueTables.batteryLevel
        case .captureDestination: CanonValueTables.captureDestination
        case .aspectRatio: CanonValueTables.aspectRatio
        case .highISONoiseReduction: CanonValueTables.highISONoiseReduction
        case .autoLightingOptimizer: CanonValueTables.autoLightingOptimizer
        case .quickReviewTime: CanonValueTables.quickReviewTime
        case .liveViewRecordingDestination: CanonValueTables.liveViewRecordingDestination
        case .liveViewAFMethod: CanonValueTables.liveViewAFMethod
        case .exposureSimulation: CanonValueTables.exposureSimulation
        case .onOff: CanonValueTables.onOff
        case .enabled: CanonValueTables.enabled
        case .lensStatus: CanonValueTables.lensStatus
        case .mirrorLockupState: CanonValueTables.mirrorLockupState
        case .cardExtension: CanonValueTables.cardExtension
        case .movieSoundRecording: CanonValueTables.movieSoundRecording
        }
    }
}

struct PropertySpec: Sendable {
    let label: String
    let section: CameraMetadata.SectionKind
    let format: PropertyFormat
    let width: PropertyWidth
    /// Set when the property has a vendor-neutral meaning; the item then uses that kind's title.
    let kind: CameraMetadata.ItemKind?

    init(_ label: String, _ section: CameraMetadata.SectionKind, _ format: PropertyFormat,
         width: PropertyWidth = .u32, kind: CameraMetadata.ItemKind? = nil) {
        self.label = label
        self.section = section
        self.format = format
        self.width = width
        self.kind = kind
    }
}

extension CanonCatalog {
    /// Every Canon EOS property a reference names. Neutral kinds: 0xD138 AEModeDial is the shooting
    /// mode dial (0xD105 AutoExposureMode stays vendor-specific); 0xD1BC LvViewTypeSelect is EDSDK's
    /// Evf_ViewType, the exposure-simulation setting (0xD1B7 ExposureSimMode has no documented values).
    static let propertySpecs: [UInt32: PropertySpec] = [
        0xD055: PropertySpec("Power Zoom Position", .lens, .number),
        0xD056: PropertySpec("Flash Setting (Simple)", .exposure, .number),
        0xD058: PropertySpec("Connect Trigger", .device, .number),
        0xD059: PropertySpec("Change Camera Mode", .device, .number),
        0xD101: PropertySpec("Aperture", .exposure, .aperture, width: .u16, kind: .aperture),
        0xD102: PropertySpec("Shutter Speed", .exposure, .shutterSpeed, width: .u16, kind: .shutterSpeed),
        0xD103: PropertySpec("ISO Speed", .exposure, .iso, width: .u16, kind: .iso),
        0xD104: PropertySpec("Exposure Compensation", .exposure, .exposureCompensation, width: .u8, kind: .exposureCompensation),
        0xD105: PropertySpec("Auto Exposure Mode", .exposure, .table(.exposureMode), width: .u16),
        0xD106: PropertySpec("Drive Mode", .exposure, .table(.driveMode), width: .u16, kind: .driveMode),
        0xD107: PropertySpec("Metering Mode", .exposure, .table(.meteringMode), width: .u8, kind: .meteringMode),
        0xD108: PropertySpec("Focus Mode", .focus, .table(.focusMode), kind: .focusMode),
        0xD109: PropertySpec("White Balance", .whiteBalance, .table(.whiteBalance), width: .u8, kind: .whiteBalance),
        0xD10A: PropertySpec("Color Temperature", .whiteBalance, .kelvin, kind: .colorTemperature),
        0xD10B: PropertySpec("White Balance Adjust A", .whiteBalance, .signedNumber),
        0xD10C: PropertySpec("White Balance Adjust B", .whiteBalance, .signedNumber),
        0xD10D: PropertySpec("White Balance XA", .whiteBalance, .number),
        0xD10E: PropertySpec("White Balance XB", .whiteBalance, .number),
        0xD10F: PropertySpec("Color Space", .image, .table(.colorSpace), width: .u16, kind: .colorSpace),
        0xD110: PropertySpec("Picture Style", .image, .table(.pictureStyle), width: .u8, kind: .imageStyle),
        0xD111: PropertySpec("Battery Level", .power, .table(.batteryLevel), width: .u16, kind: .batteryLevel),
        0xD112: PropertySpec("Battery Select", .power, .number),
        0xD113: PropertySpec("Camera Time", .device, .localTime, kind: .dateTime),
        0xD114: PropertySpec("Auto Power Off", .power, .duration, kind: .autoPowerOff),
        0xD115: PropertySpec("Owner", .device, .text, kind: .ownerName),
        0xD116: PropertySpec("Model ID", .device, .identifier),
        0xD119: PropertySpec("PTP Extension Version", .device, .identifier, width: .u16),
        0xD11A: PropertySpec("DPOF Version", .device, .number),
        0xD11B: PropertySpec("Available Shots", .storage, .number, kind: .availableShots),
        0xD11C: PropertySpec("Capture Destination", .storage, .table(.captureDestination), kind: .captureDestination),
        0xD11D: PropertySpec("Bracket Mode", .exposure, .bracketMode, width: .u16),
        0xD11E: PropertySpec("Current Storage", .storage, .identifier),
        0xD11F: PropertySpec("Current Folder", .storage, .identifier),
        0xD120: PropertySpec("Image Quality", .image, .imageQuality, kind: .imageQuality),
        0xD121: PropertySpec("Image Quality (CF)", .image, .imageQuality),
        0xD122: PropertySpec("Image Quality (SD)", .image, .imageQuality),
        0xD123: PropertySpec("Image Quality (External HD)", .image, .imageQuality),
        0xD124: PropertySpec("Refocus State", .focus, .number),
        0xD125: PropertySpec("Camera Nickname", .device, .text, kind: .nickname),
        0xD126: PropertySpec("Flash Exposure Composition Control", .exposure, .number),
        0xD127: PropertySpec("Connect Status", .device, .number),
        0xD128: PropertySpec("Lens Barrel Status", .lens, .number),
        0xD129: PropertySpec("Silent Shutter", .exposure, .number),
        0xD12C: PropertySpec("Live View AF Eye Detection", .focus, .number),
        0xD12D: PropertySpec("Auto Transfer to Mobile", .device, .number),
        0xD12E: PropertySpec("URL Support Format", .device, .number),
        0xD12F: PropertySpec("Special Acc", .device, .number),
        0xD130: PropertySpec("Compression (S)", .image, .number),
        0xD131: PropertySpec("Compression (M1)", .image, .number),
        0xD132: PropertySpec("Compression (M2)", .image, .number),
        0xD133: PropertySpec("Compression (L)", .image, .number),
        0xD134: PropertySpec("Interval Shooting Setting", .exposure, .number),
        0xD135: PropertySpec("Interval Shooting State", .exposure, .number),
        0xD136: PropertySpec("Push Mode", .storage, .number),
        0xD137: PropertySpec("Live View Creative Filter", .liveView, .number),
        0xD138: PropertySpec("AE Mode Dial", .exposure, .table(.exposureMode), width: .u16, kind: .exposureMode),
        0xD139: PropertySpec("AE Mode Custom", .exposure, .number),
        0xD13A: PropertySpec("Mirror Lockup", .exposure, .table(.onOff)),
        0xD13B: PropertySpec("Highlight Tone Priority", .image, .number),
        0xD13C: PropertySpec("AF Focus Area Selection", .focus, .number),
        0xD13D: PropertySpec("HDR Setting", .image, .number),
        0xD13E: PropertySpec("Time Shooting Setting", .exposure, .number),
        0xD13F: PropertySpec("NFC Application Info", .device, .number),
        0xD140: PropertySpec("PC White Balance 1", .whiteBalance, .number),
        0xD141: PropertySpec("PC White Balance 2", .whiteBalance, .number),
        0xD142: PropertySpec("PC White Balance 3", .whiteBalance, .number),
        0xD143: PropertySpec("PC White Balance 4", .whiteBalance, .number),
        0xD144: PropertySpec("PC White Balance 5", .whiteBalance, .number),
        0xD145: PropertySpec("Manual White Balance", .whiteBalance, .number),
        0xD146: PropertySpec("Manual White Balance Ex", .whiteBalance, .number),
        0xD149: PropertySpec("Power Zoom Speed", .lens, .number),
        0xD14A: PropertySpec("Network Server Region", .device, .number),
        0xD14B: PropertySpec("GPS Log Control", .device, .number),
        0xD14C: PropertySpec("GPS Log List Count", .device, .number),
        0xD150: PropertySpec("Picture Style Standard", .image, .number),
        0xD151: PropertySpec("Picture Style Portrait", .image, .number),
        0xD152: PropertySpec("Picture Style Landscape", .image, .number),
        0xD153: PropertySpec("Picture Style Neutral", .image, .number),
        0xD154: PropertySpec("Picture Style Faithful", .image, .number),
        0xD155: PropertySpec("Picture Style Monochrome", .image, .number),
        0xD156: PropertySpec("Picture Style Auto", .image, .number),
        0xD157: PropertySpec("Picture Style Ex Standard", .image, .number),
        0xD158: PropertySpec("Picture Style Ex Portrait", .image, .number),
        0xD159: PropertySpec("Picture Style Ex Landscape", .image, .number),
        0xD15A: PropertySpec("Picture Style Ex Neutral", .image, .number),
        0xD15B: PropertySpec("Picture Style Ex Faithful", .image, .number),
        0xD15C: PropertySpec("Picture Style Ex Monochrome", .image, .number),
        0xD15D: PropertySpec("Picture Style Ex Auto", .image, .number),
        0xD15E: PropertySpec("Picture Style Ex Fine Detail", .image, .number),
        0xD160: PropertySpec("Picture Style User Set 1", .image, .number),
        0xD161: PropertySpec("Picture Style User Set 2", .image, .number),
        0xD162: PropertySpec("Picture Style User Set 3", .image, .number),
        0xD163: PropertySpec("Picture Style Ex User Set 1", .image, .number),
        0xD164: PropertySpec("Picture Style Ex User Set 2", .image, .number),
        0xD165: PropertySpec("Picture Style Ex User Set 3", .image, .number),
        0xD166: PropertySpec("Movie AV Mode Fine", .movie, .number),
        0xD167: PropertySpec("Shutter Release Counter", .device, .number),
        0xD168: PropertySpec("Available Image Size", .image, .number),
        0xD169: PropertySpec("Error History", .device, .number),
        0xD16A: PropertySpec("Lens Exchange History", .lens, .number),
        0xD16B: PropertySpec("Flash Exchange History", .exposure, .number),
        0xD170: PropertySpec("Picture Style Parameters 1", .image, .number),
        0xD171: PropertySpec("Picture Style Parameters 2", .image, .number),
        0xD172: PropertySpec("Picture Style Parameters 3", .image, .number),
        0xD174: PropertySpec("Movie Record Volume Line", .movie, .number),
        0xD175: PropertySpec("Network Communication Mode", .device, .number),
        0xD176: PropertySpec("Canon Log Gamma", .movie, .number),
        0xD177: PropertySpec("Smartphone Image Display", .device, .number),
        0xD178: PropertySpec("High ISO Noise Reduction", .image, .table(.highISONoiseReduction), width: .u16),
        0xD179: PropertySpec("Movie Servo AF", .focus, .table(.onOff)),
        0xD17A: PropertySpec("Continuous AF Valid", .focus, .number),
        0xD17B: PropertySpec("Attenuator", .movie, .number),
        0xD17C: PropertySpec("UTC Time", .device, .utcTime),
        0xD17D: PropertySpec("Time Zone", .device, .timeZone, kind: .timeZone),
        0xD17E: PropertySpec("Daylight Saving Time", .device, .table(.onOff)),
        0xD17F: PropertySpec("Flavor LUT Parameters", .image, .number),
        0xD180: PropertySpec("Custom Function 1", .device, .number),
        0xD181: PropertySpec("Custom Function 2", .device, .number),
        0xD182: PropertySpec("Custom Function 3", .device, .number),
        0xD183: PropertySpec("Custom Function 4", .device, .number),
        0xD184: PropertySpec("Custom Function 5", .device, .number),
        0xD185: PropertySpec("Custom Function 6", .device, .number),
        0xD186: PropertySpec("Custom Function 7", .device, .number),
        0xD187: PropertySpec("Custom Function 8", .device, .number),
        0xD188: PropertySpec("Custom Function 9", .device, .number),
        0xD189: PropertySpec("Custom Function 10", .device, .number),
        0xD18A: PropertySpec("Custom Function 11", .device, .number),
        0xD18B: PropertySpec("Custom Function 12", .device, .number),
        0xD18C: PropertySpec("Custom Function 13", .device, .number),
        0xD18D: PropertySpec("Custom Function 14", .device, .number),
        0xD18E: PropertySpec("Custom Function 15", .device, .number),
        0xD18F: PropertySpec("Custom Function 16", .device, .number),
        0xD190: PropertySpec("Custom Function 17", .device, .number),
        0xD191: PropertySpec("Custom Function 18", .device, .number),
        0xD192: PropertySpec("Custom Function 19", .device, .number),
        0xD193: PropertySpec("Inner Develop", .device, .number),
        0xD194: PropertySpec("Aspect Ratio", .image, .table(.aspectRatio), kind: .aspectRatio),
        0xD195: PropertySpec("Movie Sound Record", .movie, .table(.movieSoundRecording)),
        0xD196: PropertySpec("Movie Record Volume", .movie, .number),
        0xD197: PropertySpec("Wind Cut", .movie, .number),
        0xD198: PropertySpec("Extender Type", .lens, .number),
        0xD199: PropertySpec("OLC Info Version", .device, .number),
        0xD19F: PropertySpec("GPS Device Active", .device, .number),
        0xD1A0: PropertySpec("Custom Functions", .device, .number),
        0xD1A1: PropertySpec("My Menu", .device, .number),
        0xD1A2: PropertySpec("My Menu List", .device, .number),
        0xD1A3: PropertySpec("WFT Status", .device, .number),
        0xD1A4: PropertySpec("WFT Input Transmission", .device, .number),
        0xD1A5: PropertySpec("HD Directory Structure", .storage, .number),
        0xD1A6: PropertySpec("Battery Info", .power, .number),
        0xD1A7: PropertySpec("Adapter Info", .power, .number),
        0xD1A8: PropertySpec("Lens Status", .lens, .table(.lensStatus), kind: .lensAttached),
        0xD1A9: PropertySpec("Quick Review Time", .device, .table(.quickReviewTime), width: .u16),
        0xD1AA: PropertySpec("Card Extension", .storage, .table(.cardExtension)),
        0xD1AB: PropertySpec("Temperature Status", .power, .temperatureStatus),
        0xD1AC: PropertySpec("Shutter Counter", .device, .number),
        0xD1AD: PropertySpec("Special Option", .device, .number),
        0xD1AE: PropertySpec("Photo Studio Mode", .device, .number),
        0xD1AF: PropertySpec("Serial Number", .device, .text, kind: .serialNumber),
        0xD1B0: PropertySpec("EVF Output Device", .liveView, .liveViewOutput, kind: .liveViewOutput),
        0xD1B1: PropertySpec("EVF Mode", .liveView, .table(.enabled), width: .u16, kind: .liveViewMode),
        0xD1B2: PropertySpec("Depth-of-Field Preview", .liveView, .table(.onOff)),
        0xD1B3: PropertySpec("EVF Sharpness", .liveView, .number),
        0xD1B4: PropertySpec("EVF White Balance", .liveView, .table(.whiteBalance)),
        0xD1B5: PropertySpec("EVF Click WB Coefficients", .liveView, .number),
        0xD1B6: PropertySpec("EVF Color Temperature", .liveView, .kelvin),
        0xD1B7: PropertySpec("Exposure Simulation Mode", .liveView, .number),
        0xD1B8: PropertySpec("EVF Recording Destination", .liveView, .table(.liveViewRecordingDestination), width: .u16),
        0xD1BA: PropertySpec("Live View AF Method", .focus, .table(.liveViewAFMethod), kind: .liveViewAFMethod),
        0xD1BB: PropertySpec("Movie Size", .movie, .number),
        0xD1BC: PropertySpec("Live View Type", .liveView, .table(.exposureSimulation), kind: .exposureSimulation),
        0xD1BD: PropertySpec("Mirror Down Status", .exposure, .number),
        0xD1BE: PropertySpec("Movie Parameters", .movie, .number),
        0xD1BF: PropertySpec("Mirror Lockup State", .exposure, .table(.mirrorLockupState)),
        0xD1C0: PropertySpec("Flash Charging State", .exposure, .number),
        0xD1C1: PropertySpec("Auto Lighting Optimizer", .image, .table(.autoLightingOptimizer)),
        0xD1C2: PropertySpec("Movie Mode", .movie, .table(.onOff)),
        0xD1C3: PropertySpec("One-Shot RAW", .image, .number),
        0xD1C4: PropertySpec("Displayed Error", .device, .number),
        0xD1C5: PropertySpec("Movie Exposure Mode", .movie, .number),
        0xD1C6: PropertySpec("Built-in Flash Mode", .exposure, .number),
        0xD1C7: PropertySpec("Flash Display State", .exposure, .number),
        0xD1C8: PropertySpec("Flash E-TTL II Metering", .exposure, .number),
        0xD1C9: PropertySpec("Continuous AF", .focus, .table(.onOff)),
        0xD1CA: PropertySpec("Movie Parameters 2", .movie, .number),
        0xD1CB: PropertySpec("Flash Exposure Composition", .exposure, .number),
        0xD1CC: PropertySpec("Movie Parameters 3", .movie, .number),
        0xD1CD: PropertySpec("Movie Parameters 4", .movie, .number),
        0xD1CF: PropertySpec("Live View Medical Rotate", .liveView, .number),
        0xD1D0: PropertySpec("Artist", .device, .text, kind: .artist),
        0xD1D1: PropertySpec("Copyright", .device, .text, kind: .copyright),
        0xD1D2: PropertySpec("Bracket Value", .exposure, .number),
        0xD1D3: PropertySpec("Focus Info", .focus, .number),
        0xD1D4: PropertySpec("Depth of Field", .exposure, .number),
        0xD1D5: PropertySpec("Brightness", .exposure, .number),
        0xD1D6: PropertySpec("Lens Adjustment Parameters", .lens, .number),
        0xD1D7: PropertySpec("Flash Exposure Compensation", .exposure, .number),
        0xD1D8: PropertySpec("Lens Name", .lens, .text, kind: .lensName),
        0xD1D9: PropertySpec("Auto Exposure Bracketing", .exposure, .exposureBracketStep, width: .u16, kind: .autoExposureBracketing),
        0xD1DA: PropertySpec("Flash Setting", .exposure, .number),
        0xD1DB: PropertySpec("Flash Wireless Setting", .exposure, .number),
        0xD1DC: PropertySpec("Flash Firing", .exposure, .number),
        0xD1DD: PropertySpec("Lens ID", .lens, .number),
        0xD1DE: PropertySpec("LCD Brightness", .device, .number),
        0xD1DF: PropertySpec("Creative Assist Dark/Bright", .image, .number),
        0xD201: PropertySpec("Creative Assist Preset", .image, .number),
        0xD202: PropertySpec("Creative Assist Brightness", .image, .number),
        0xD203: PropertySpec("Creative Assist Contrast", .image, .number),
        0xD204: PropertySpec("Creative Assist Saturation", .image, .number),
        0xD205: PropertySpec("Creative Assist Color Blue/Amber", .image, .number),
        0xD206: PropertySpec("Creative Assist Color Magenta/Green", .image, .number),
        0xD207: PropertySpec("Creative Assist Monochrome", .image, .number),
        0xD208: PropertySpec("Focus Shift Setting", .focus, .number),
        0xD209: PropertySpec("Movie Self Timer", .movie, .number),
        0xD20B: PropertySpec("Clarity", .image, .number),
        0xD20C: PropertySpec("2G HDR Setting", .image, .number),
        0xD20D: PropertySpec("Movie Parameters 5", .movie, .number),
        0xD20E: PropertySpec("HDR View Assist (Recording)", .movie, .number),
        0xD214: PropertySpec("Finder AF Frame", .focus, .number),
        0xD215: PropertySpec("Variable Movie Recording Setting", .movie, .number),
        0xD216: PropertySpec("Auto Rotate", .device, .number),
        0xD217: PropertySpec("MF Peaking", .focus, .number),
        0xD218: PropertySpec("Movie Spatial Oversampling", .movie, .number),
        0xD219: PropertySpec("Movie Crop Mode", .movie, .number),
        0xD21A: PropertySpec("Shutter Type", .exposure, .number),
        0xD21B: PropertySpec("WFT Battery Power", .power, .number),
        0xD21C: PropertySpec("Battery Info Ex", .power, .number),
    ]
}

// MARK: - Value tables

enum CanonValueTables {
    /// EDSDK Enum EdsAEMode; 0x31 HDR and 0x33 Hybrid Auto from libgphoto2.
    static let exposureMode: [UInt32: String] = [
            0x00: "P (Program AE)",
            0x01: "Tv (Shutter Priority AE)",
            0x02: "Av (Aperture Priority AE)",
            0x03: "M (Manual Exposure)",
            0x04: "Bulb",
            0x05: "A-DEP (Auto Depth-of-Field AE)",
            0x06: "DEP (Depth-of-Field AE)",
            0x07: "C1 (Custom 1)",
            0x08: "Lock",
            0x09: "Auto",
            0x0A: "Night Portrait",
            0x0B: "Sports",
            0x0C: "Portrait",
            0x0D: "Landscape",
            0x0E: "Close-Up",
            0x0F: "Flash Off",
            0x10: "C2 (Custom 2)",
            0x11: "C3 (Custom 3)",
            0x13: "Creative Auto",
            0x14: "Movie",
            0x15: "Photo in Movie",
            0x16: "Scene Intelligent Auto",
            0x17: "Handheld Night Scene",
            0x18: "HDR Backlight Control",
            0x19: "SCN (Special Scene)",
            0x1A: "Kids",
            0x1B: "Food",
            0x1C: "Candlelight",
            0x1E: "Grainy B/W",
            0x1F: "Soft Focus",
            0x20: "Toy Camera Effect",
            0x21: "Fish-eye Effect",
            0x22: "Water Painting Effect",
            0x23: "Miniature Effect",
            0x24: "HDR Art Standard",
            0x25: "HDR Art Vivid",
            0x26: "HDR Art Bold",
            0x27: "HDR Art Embossed",
            0x28: "Dream",
            0x29: "Old Movies",
            0x2A: "Memory",
            0x2B: "Dramatic B&W",
            0x2C: "Miniature Effect Movie",
            0x2D: "Panning",
            0x2E: "Group Photo",
            0x31: "HDR",
            0x32: "Self Portrait",
            0x33: "Hybrid Auto",
            0x34: "Smooth Skin",
            0x36: "Silent Mode",
            0x37: "Fv (Flexible-priority AE)",
            0x38: "Oil Painting",
            0x39: "Fireworks",
            0x3A: "Star Portrait",
            0x3B: "Star Nightscape",
            0x3C: "Star Trails",
            0x3D: "Star Time-lapse Movie",
            0x3E: "Background Blur",
            0x3F: "Video Blog",
            0x41: "Movie IS Mode",
            0x43: "Smooth Skin Movie",
    ]

    /// EDSDK kEdsPropID_DriveMode.
    static let driveMode: [UInt32: String] = [
            0x00: "Single",
            0x01: "Continuous",
            0x02: "Video",
            0x04: "High-speed Continuous",
            0x05: "Low-speed Continuous",
            0x06: "Single Silent",
            0x07: "Self-timer: Continuous",
            0x10: "Self-timer: 10 s",
            0x11: "Self-timer: 2 s",
            0x12: "14 fps Super High-speed Continuous",
            0x13: "Silent Single",
            0x14: "Silent Continuous",
            0x15: "Silent High-speed Continuous",
            0x16: "Silent Low-speed Continuous",
    ]

    /// EDSDK kEdsPropID_MeteringMode (1, 3, 4, 5); libgphoto2 canon_meteringmode (0, 2, 6, 7).
    static let meteringMode: [UInt32: String] = [
            0x00: "Center-weighted",
            0x01: "Spot",
            0x02: "Average",
            0x03: "Evaluative",
            0x04: "Partial",
            0x05: "Center-weighted Average",
            0x06: "Spot (Linked to AF Point)",
            0x07: "Multi-spot",
    ]

    /// EDSDK kEdsPropID_AFMode.
    static let focusMode: [UInt32: String] = [
            0x00: "One-Shot AF",
            0x01: "AI Servo AF",
            0x02: "AI Focus AF",
            0x03: "Manual Focus",
    ]

    /// EDSDK Enum EdsWhiteBalance (also used by EVF White Balance).
    static let whiteBalance: [UInt32: String] = [
            0x00: "Auto (Ambience Priority)",
            0x01: "Daylight",
            0x02: "Cloudy",
            0x03: "Tungsten",
            0x04: "Fluorescent",
            0x05: "Flash",
            0x06: "Manual",
            0x08: "Shade",
            0x09: "Color Temperature",
            0x0A: "Custom PC-1",
            0x0B: "Custom PC-2",
            0x0C: "Custom PC-3",
            0x0F: "Manual 2",
            0x10: "Manual 3",
            0x12: "Manual 4",
            0x13: "Manual 5",
            0x14: "Custom PC-4",
            0x15: "Custom PC-5",
            0x17: "Auto (White Priority)",
            0x18: "Color Temperature 2",
            0x19: "Color Temperature 3",
            0x1A: "Color Temperature 4",
    ]

    /// EDSDK Enum EdsPictureStyle; user sets 0x21–0x23 from libgphoto2.
    static let pictureStyle: [UInt32: String] = [
            0x21: "User Defined 1",
            0x22: "User Defined 2",
            0x23: "User Defined 3",
            0x41: "Computer Setting 1",
            0x42: "Computer Setting 2",
            0x43: "Computer Setting 3",
            0x81: "Standard",
            0x82: "Portrait",
            0x83: "Landscape",
            0x84: "Neutral",
            0x85: "Faithful",
            0x86: "Monochrome",
            0x87: "Auto",
            0x88: "Fine Detail",
    ]

    /// EDSDK Enum EdsColorSpace.
    static let colorSpace: [UInt32: String] = [
            0x01: "sRGB",
            0x02: "Adobe RGB",
    ]

    /// libgphoto2 _get_Canon_EOS_BatteryLevel.
    static let batteryLevel: [UInt32: String] = [
            0x00: "Low",
            0x01: "50%",
            0x02: "100%",
            0x04: "75%",
            0x05: "25%",
    ]
    /// The battery level code libgphoto2 names "Low" (the lowest level the property reports).
    static let batteryLevelLow: UInt32 = 0x00

    /// libgphoto2 camera_canon_eos_update_capture_target: 4 is PC RAM (PTP_CANON_EOS_CAPTUREDEST_HD),
    /// 2 is the card value bodies report (gphoto2 issue 383).
    static let captureDestination: [UInt32: String] = [
            0x02: "Memory Card",
            0x04: "Computer",
    ]

    /// libgphoto2 canon_eos_aspectratio (EDSDK kEdsPropID_Aspect uses the same codes).
    static let aspectRatio: [UInt32: String] = [
            0x00: "3:2",
            0x01: "1:1",
            0x02: "4:3",
            0x07: "16:9",
            0x0D: "1.6x (Crop)",
    ]

    /// libgphoto2 canon_eos_highisonr.
    static let highISONoiseReduction: [UInt32: String] = [
            0x00: "Off",
            0x01: "Low",
            0x02: "Standard",
            0x03: "High",
            0x04: "Multi Shot",
    ]

    /// libgphoto2 canon_eos_alomode.
    static let autoLightingOptimizer: [UInt32: String] = [
            0x00000: "Standard (Off in Manual Exposure)",
            0x00001: "x1",
            0x00002: "x2",
            0x00003: "x3",
            0x00101: "Low (Off in Manual Exposure)",
            0x00202: "High (Off in Manual Exposure)",
            0x00303: "Off",
            0x10000: "Standard",
            0x10101: "Low",
            0x10202: "High",
            0x10303: "Off",
    ]

    /// libgphoto2 eos_quickreviewtime.
    static let quickReviewTime: [UInt32: String] = [
            0x00: "Off",
            0x02: "2 s",
            0x04: "4 s",
            0x08: "8 s",
            0xFF: "Hold",
    ]

    /// libgphoto2 canon_eos_evfrecordtarget.
    static let liveViewRecordingDestination: [UInt32: String] = [
            0x00: "None",
            0x03: "Camera Memory (SDRAM)",
            0x04: "Memory Card",
    ]

    /// EDSDK kEdsPropID_Evf_AFMode.
    static let liveViewAFMethod: [UInt32: String] = [
            0x00: "Quick Mode",
            0x01: "1-point AF (Live Mode)",
            0x02: "Face + Tracking",
            0x03: "FlexiZone - Multi",
            0x04: "Zone AF",
            0x05: "Expand AF Area",
            0x06: "Expand AF Area: Around",
            0x07: "Large Zone AF: Horizontal",
            0x08: "Large Zone AF: Vertical",
            0x09: "Tracking AF",
            0x0A: "Spot AF",
            0x0B: "Flexible Zone AF 1",
            0x0C: "Flexible Zone AF 2",
            0x0D: "Flexible Zone AF 3",
            0x0E: "Whole Area AF",
            0x0F: "Spot AF (No Tracking)",
            0x10: "1-point AF (No Tracking)",
            0x11: "Expand AF Area (No Tracking)",
            0x12: "Expand AF Area: Around (No Tracking)",
    ]

    /// EDSDK kEdsPropID_Evf_ViewType ("Expo. simulation").
    static let exposureSimulation: [UInt32: String] = [
            0x00: "During Depth-of-Field Preview",
            0x01: "Enabled",
            0x03: "Disabled",
            0x04: "Exposure + Depth of Field",
    ]

    /// EDSDK Off/On properties (MirrorUpSetting, Evf_DepthOfFieldPreview, SummerTimeSetting,
    /// FixedMovie, MovieServoAf, ContinuousAfMode).
    static let onOff: [UInt32: String] = [
            0x00: "Off",
            0x01: "On",
    ]

    /// EDSDK kEdsPropID_Evf_Mode.
    static let enabled: [UInt32: String] = [
            0x00: "Disabled",
            0x01: "Enabled",
    ]

    /// EDSDK kEdsPropID_LensStatus.
    static let lensStatus: [UInt32: String] = [
            0x00: "Not Attached",
            0x01: "Attached",
    ]

    /// EDSDK kEdsPropID_MirrorLockUpState.
    static let mirrorLockupState: [UInt32: String] = [
            0x00: "Disabled",
            0x01: "Enabled",
            0x02: "Mirror Up (Shooting)",
    ]

    /// EDSDK kEdsPropID_CardExtension.
    static let cardExtension: [UInt32: String] = [
            0x00: "Standard",
            0x01: "Record to Multiple",
            0x02: "Record Separately",
            0x03: "Auto Switch Card",
    ]

    /// EDSDK kEdsPropID_MovieSoundRecord.
    static let movieSoundRecording: [UInt32: String] = [
            0x01: "Disabled",
            0x02: "Auto",
            0x03: "Manual",
    ]

    /// EDSDK kEdsPropID_Av; 0 / 0xB0 / 0xFFFF "auto" from libgphoto2 canon_aperture.
    static let aperture: [UInt32: String] = [
            0x0000: "Auto",
            0x0008: "f/1",
            0x000B: "f/1.1",
            0x000C: "f/1.2",
            0x000D: "f/1.2",
            0x0010: "f/1.4",
            0x0013: "f/1.6",
            0x0014: "f/1.8",
            0x0015: "f/1.8",
            0x0018: "f/2",
            0x001B: "f/2.2",
            0x001C: "f/2.5",
            0x001D: "f/2.5",
            0x0020: "f/2.8",
            0x0023: "f/3.2",
            0x0024: "f/3.5",
            0x0025: "f/3.5",
            0x0028: "f/4",
            0x002B: "f/4.5",
            0x002C: "f/4.5",
            0x002D: "f/5",
            0x0030: "f/5.6",
            0x0033: "f/6.3",
            0x0034: "f/6.7",
            0x0035: "f/7.1",
            0x0038: "f/8",
            0x003B: "f/9",
            0x003C: "f/9.5",
            0x003D: "f/10",
            0x0040: "f/11",
            0x0043: "f/13",
            0x0044: "f/13",
            0x0045: "f/14",
            0x0048: "f/16",
            0x004B: "f/18",
            0x004C: "f/19",
            0x004D: "f/20",
            0x0050: "f/22",
            0x0053: "f/25",
            0x0054: "f/27",
            0x0055: "f/29",
            0x0058: "f/32",
            0x005B: "f/36",
            0x005C: "f/38",
            0x005D: "f/40",
            0x0060: "f/45",
            0x0063: "f/51",
            0x0064: "f/54",
            0x0065: "f/57",
            0x0068: "f/64",
            0x006B: "f/72",
            0x006C: "f/76",
            0x006D: "f/80",
            0x0070: "f/91",
            0x0085: "f/3.4",
            0x00B0: "Auto",
            0xFFFF: "Auto",
    ]

    /// EDSDK kEdsPropID_Tv; 0 "auto" and 0x04 "bulb" from libgphoto2 canon_shutterspeed.
    static let shutterSpeed: [UInt32: String] = [
            0x00: "Auto",
            0x04: "Bulb",
            0x0C: "Bulb",
            0x10: "30\"",
            0x13: "25\"",
            0x14: "20\"",
            0x15: "20\"",
            0x18: "15\"",
            0x1B: "13\"",
            0x1C: "10\"",
            0x1D: "10\"",
            0x20: "8\"",
            0x23: "6\"",
            0x24: "6\"",
            0x25: "5\"",
            0x28: "4\"",
            0x2B: "3.2\"",
            0x2C: "3\"",
            0x2D: "2.5\"",
            0x30: "2\"",
            0x33: "1.6\"",
            0x34: "1.5\"",
            0x35: "1.3\"",
            0x38: "1\"",
            0x3B: "0.8\"",
            0x3C: "0.7\"",
            0x3D: "0.6\"",
            0x40: "0.5\"",
            0x43: "0.4\"",
            0x44: "0.3\"",
            0x45: "0.3\"",
            0x48: "1/4 s",
            0x4B: "1/5 s",
            0x4C: "1/6 s",
            0x4D: "1/6 s",
            0x50: "1/8 s",
            0x53: "1/10 s",
            0x54: "1/10 s",
            0x55: "1/13 s",
            0x58: "1/15 s",
            0x5B: "1/20 s",
            0x5C: "1/20 s",
            0x5D: "1/25 s",
            0x60: "1/30 s",
            0x63: "1/40 s",
            0x64: "1/45 s",
            0x65: "1/50 s",
            0x68: "1/60 s",
            0x6B: "1/80 s",
            0x6C: "1/90 s",
            0x6D: "1/100 s",
            0x70: "1/125 s",
            0x73: "1/160 s",
            0x74: "1/180 s",
            0x75: "1/200 s",
            0x78: "1/250 s",
            0x7B: "1/320 s",
            0x7C: "1/350 s",
            0x7D: "1/400 s",
            0x80: "1/500 s",
            0x83: "1/640 s",
            0x84: "1/750 s",
            0x85: "1/800 s",
            0x88: "1/1000 s",
            0x8B: "1/1250 s",
            0x8C: "1/1500 s",
            0x8D: "1/1600 s",
            0x90: "1/2000 s",
            0x93: "1/2500 s",
            0x94: "1/3000 s",
            0x95: "1/3200 s",
            0x98: "1/4000 s",
            0x9B: "1/5000 s",
            0x9C: "1/6000 s",
            0x9D: "1/6400 s",
            0xA0: "1/8000 s",
            0xA3: "1/10000 s",
            0xA5: "1/12800 s",
            0xA8: "1/16000 s",
            0xAB: "1/20000 s",
            0xAD: "1/25600 s",
            0xB0: "1/32000 s",
    ]

    /// EDSDK kEdsPropID_ISOSpeed; 0x01 "Auto ISO", 0x43 and 0x45 from libgphoto2 canon_isospeed.
    static let iso: [UInt32: String] = [
            0x00: "Auto",
            0x01: "Auto",
            0x28: "ISO 6",
            0x30: "ISO 12",
            0x38: "ISO 25",
            0x40: "ISO 50",
            0x43: "ISO 64",
            0x45: "ISO 80",
            0x48: "ISO 100",
            0x4B: "ISO 125",
            0x4D: "ISO 160",
            0x50: "ISO 200",
            0x53: "ISO 250",
            0x55: "ISO 320",
            0x58: "ISO 400",
            0x5B: "ISO 500",
            0x5D: "ISO 640",
            0x60: "ISO 800",
            0x63: "ISO 1000",
            0x65: "ISO 1250",
            0x68: "ISO 1600",
            0x6B: "ISO 2000",
            0x6D: "ISO 2500",
            0x70: "ISO 3200",
            0x73: "ISO 4000",
            0x75: "ISO 5000",
            0x78: "ISO 6400",
            0x7B: "ISO 8000",
            0x7D: "ISO 10000",
            0x80: "ISO 12800",
            0x83: "ISO 16000",
            0x85: "ISO 20000",
            0x88: "ISO 25600",
            0x8B: "ISO 32000",
            0x8D: "ISO 40000",
            0x90: "ISO 51200",
            0x93: "ISO 64000",
            0x95: "ISO 80000",
            0x98: "ISO 102400",
            0xA0: "ISO 204800",
            0xA8: "ISO 409600",
            0xB0: "ISO 819200",
    ]

    /// EDSDK kEdsPropID_ExposureCompensation (signed eighths-of-a-stop code in one byte).
    static let exposureCompensation: [UInt32: String] = [
            0x00: "0 EV",
            0x03: "+1/3 EV",
            0x04: "+1/2 EV",
            0x05: "+2/3 EV",
            0x08: "+1 EV",
            0x0B: "+1 1/3 EV",
            0x0C: "+1 1/2 EV",
            0x0D: "+1 2/3 EV",
            0x10: "+2 EV",
            0x13: "+2 1/3 EV",
            0x14: "+2 1/2 EV",
            0x15: "+2 2/3 EV",
            0x18: "+3 EV",
            0x1B: "+3 1/3 EV",
            0x1C: "+3 1/2 EV",
            0x1D: "+3 2/3 EV",
            0x20: "+4 EV",
            0x23: "+4 1/3 EV",
            0x24: "+4 1/2 EV",
            0x25: "+4 2/3 EV",
            0x28: "+5 EV",
            0xD8: "-5 EV",
            0xDB: "-4 2/3 EV",
            0xDC: "-4 1/2 EV",
            0xDD: "-4 1/3 EV",
            0xE0: "-4 EV",
            0xE3: "-3 2/3 EV",
            0xE4: "-3 1/2 EV",
            0xE5: "-3 1/3 EV",
            0xE8: "-3 EV",
            0xEB: "-2 2/3 EV",
            0xEC: "-2 1/2 EV",
            0xED: "-2 1/3 EV",
            0xF0: "-2 EV",
            0xF3: "-1 2/3 EV",
            0xF4: "-1 1/2 EV",
            0xF5: "-1 1/3 EV",
            0xF8: "-1 EV",
            0xFB: "-2/3 EV",
            0xFC: "-1/2 EV",
            0xFD: "-1/3 EV",
    ]

    /// libgphoto2 canon_eos_aeb.
    static let exposureBracketStep: [UInt32: String] = [
            0x00: "Off",
            0x03: "±1/3 EV",
            0x04: "±1/2 EV",
            0x05: "±2/3 EV",
            0x08: "±1 EV",
            0x0B: "±1 1/3 EV",
            0x0C: "±1 1/2 EV",
            0x0D: "±1 2/3 EV",
            0x10: "±2 EV",
            0x13: "±2 1/3 EV",
            0x14: "±2 1/2 EV",
            0x15: "±2 2/3 EV",
            0x18: "±3 EV",
    ]

    /// EDSDK Enum EdsTimeZone.
    static let timeZone: [UInt32: String] = [
            0x000: "None",
            0x001: "Chatham Islands",
            0x002: "Wellington",
            0x003: "Solomon Islands",
            0x004: "Sydney",
            0x005: "Adelaide",
            0x006: "Tokyo",
            0x007: "Hong Kong",
            0x008: "Bangkok",
            0x009: "Yangon",
            0x00A: "Dhaka",
            0x00B: "Kathmandu",
            0x00C: "Delhi",
            0x00D: "Karachi",
            0x00E: "Kabul",
            0x00F: "Dubai",
            0x010: "Tehran",
            0x011: "Moscow",
            0x012: "Cairo",
            0x013: "Paris",
            0x014: "London",
            0x015: "Azores",
            0x016: "Fernando de Noronha",
            0x017: "São Paulo",
            0x018: "Newfoundland",
            0x019: "Santiago",
            0x01A: "Caracas",
            0x01B: "New York",
            0x01C: "Chicago",
            0x01D: "Denver",
            0x01E: "Los Angeles",
            0x01F: "Anchorage",
            0x020: "Honolulu",
            0x021: "Samoa",
            0x022: "Riyadh",
            0x023: "Manaus",
            0x100: "UTC",
    ]

    /// EDSDK Enum EdsImageType / ptp_unpack_EOS_ImageFormat image type (RAW types collapse to "RAW").
    static let imageType: [UInt32: String] = [
        0x1: "JPEG",
        0x2: "RAW",
        0x4: "RAW",
        0x6: "RAW",
        0x8: "HEIF",
    ]

    /// EDSDK Enum EdsImageSize.
    static let imageSize: [UInt32: String] = [
        0x00: "Large",
        0x01: "Medium",
        0x02: "Small",
        0x05: "Medium 1",
        0x06: "Medium 2",
        0x0E: "Small 1",
        0x0F: "Small 2",
        0x10: "Small 3",
    ]

    /// EDSDK Enum EdsCompressQuality; 0 is libgphoto2's user-defined JPEG compression.
    static let imageCompression: [UInt32: String] = [
        0x0: "User-defined",
        0x2: "Normal",
        0x3: "Fine",
        0x4: "Lossless",
        0x5: "Superfine",
    ]
}

// MARK: - Formatting

extension CanonCatalog {
    static func format(_ value: CanonPropertyValue, as format: PropertyFormat, width: PropertyWidth) -> String {
        switch format {
        case .text: return text(value)
        case .imageQuality: return imageQuality(value)
        case .timeZone:
            guard case .raw(let data) = value else { return number(value) }
            let w = littleEndianWords(data)
            return timeZone(w[...]) ?? words(w[...])
        default: break
        }
        guard case .integer(let slot) = value else { return number(value) }
        let v = slot & width.mask
        switch format {
        case .number: return String(v)
        case .signedNumber: return String(Int32(bitPattern: v))
        case .identifier: return hex(v, digits: width == .u16 ? 4 : 8)
        case .aperture: return lookup(v, in: CanonValueTables.aperture)
        case .shutterSpeed: return lookup(v, in: CanonValueTables.shutterSpeed)
        case .iso: return lookup(v, in: CanonValueTables.iso)
        case .exposureCompensation: return lookup(v, in: CanonValueTables.exposureCompensation)
        case .exposureBracketStep: return lookup(v, in: CanonValueTables.exposureBracketStep)
        case .kelvin: return "\(v) K"
        case .duration: return duration(Int32(bitPattern: v))
        case .liveViewOutput: return liveViewOutput(v)
        case .localTime: return clock(v)
        case .utcTime: return clock(v) + " UTC"
        case .bracketMode: return bracketMode(v)
        case .temperatureStatus: return temperatureStatus(v)
        case .table(let table): return lookup(v, in: table.entries)
        case .text, .imageQuality, .timeZone: return number(value)  // handled above
        }
    }

    static func lookup(_ value: UInt32, in table: [UInt32: String]) -> String {
        table[value] ?? "Undocumented (\(value))"
    }

    /// Integer as decimal; struct payloads as little-endian u32 words (or bytes when not word-sized).
    static func number(_ value: CanonPropertyValue) -> String {
        switch value {
        case .integer(let v): return String(v)
        case .raw(let data):
            if data.isEmpty { return "Empty" }
            if data.count % 4 == 0 { return words(littleEndianWords(data)[...]) }
            return bytesHex(data)
        }
    }

    /// ASCII/UTF-8 text up to the first NUL. Short strings arrive as `.integer` because the event
    /// parser cannot tell a 1/2/4-byte string from an integer; their bytes are recovered here.
    static func text(_ value: CanonPropertyValue) -> String {
        let bytes: [UInt8]
        switch value {
        case .integer(let v): bytes = (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) }
        case .raw(let data): bytes = Array(data)
        }
        let content = bytes.prefix { $0 != 0 }
        let string = String(decoding: content, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return string.isEmpty ? "Not set" : string
    }

    /// "2 min", "30 s", "1 min 30 s", "Disabled" (0).
    static func duration(_ seconds: Int32) -> String {
        guard seconds > 0 else { return seconds == 0 ? "Disabled" : "Undocumented (\(seconds))" }
        if seconds < 60 { return "\(seconds) s" }
        if seconds % 3600 == 0 { return "\(seconds / 3600) h" }
        if seconds % 60 == 0 { return "\(seconds / 60) min" }
        return "\(seconds / 60) min \(seconds % 60) s"
    }

    /// EVF output bitmask: EDSDK 0x1 TFT, 0x2 PC, 0x8 PC_Small; libgphoto2 0x4 MOBILE.
    static func liveViewOutput(_ mask: UInt32) -> String {
        if mask == 0 { return "Off" }
        let known: [(UInt32, String)] = [(0x1, "Rear LCD"), (0x2, "Computer"), (0x4, "Mobile Device"), (0x8, "Computer (Small)")]
        var parts = known.filter { mask & $0.0 != 0 }.map(\.1)
        let rest = mask & ~0xF
        if rest != 0 { parts.append("Undocumented " + hex(rest)) }
        return parts.joined(separator: " + ")
    }

    /// EDSDK kEdsPropID_Bracket: logical sum of bracket types, 0xFFFF(FFFF) = off.
    static func bracketMode(_ mask: UInt32) -> String {
        if mask == 0xFFFF || mask == 0xFFFF_FFFF { return "Off" }
        if mask == 0 { return "None" }
        let known: [(UInt32, String)] = [(0x1, "AE"), (0x2, "ISO"), (0x4, "White Balance"), (0x8, "Flash Exposure")]
        var parts = known.filter { mask & $0.0 != 0 }.map(\.1)
        let rest = mask & ~0xF
        if rest != 0 { parts.append("Undocumented " + hex(rest)) }
        return parts.joined(separator: " + ")
    }

    /// EDSDK kEdsPropID_TempStatus: bits 16–31 movie restriction, bits 0–15 general status.
    static func temperatureStatus(_ value: UInt32) -> String {
        let movie = value >> 16
        let general = value & 0xFFFF
        if value == 0 { return "Normal" }
        let generalText: [UInt32: String] = [
            1: "Warning", 2: "Reduced Frame Rate", 3: "Live View Prohibited", 4: "Shooting Prohibited",
            5: "Still Image Quality Degraded",
        ]
        var parts: [String] = []
        if general != 0 { parts.append(generalText[general] ?? "Undocumented (\(general))") }
        if movie != 0 { parts.append(movie == 2 ? "Movie Recording Restricted" : "Undocumented movie status (\(movie))") }
        return parts.joined(separator: ", ")
    }

    /// EOS ImageFormat struct (ptp_unpack_EOS_ImageFormat): u32 entry count (1 or 2), then per entry
    /// [u32 size = 0x10][u32 type][u32 size code][u32 compression]. "Large Fine JPEG", "RAW + Large Fine JPEG".
    static func imageQuality(_ value: CanonPropertyValue) -> String {
        guard case .raw(let data) = value else { return number(value) }
        let w = littleEndianWords(data)
        guard let count = w.first, count == 1 || count == 2, w.count >= 1 + 4 * Int(count) else { return number(value) }
        var parts: [String] = []
        for i in 0..<Int(count) {
            let base = 1 + 4 * i
            guard w[base] == 0x10 else { return number(value) }
            parts.append(imageQualityEntry(type: w[base + 1], size: w[base + 2], compression: w[base + 3]))
        }
        return parts.joined(separator: " + ")
    }

    static func imageQualityEntry(type: UInt32, size: UInt32, compression: UInt32) -> String {
        guard let typeName = CanonValueTables.imageType[type] else { return "Undocumented image type (\(type))" }
        if typeName == "RAW" {
            // libgphoto2: RAW lossless = RAW, M/S sizes = mRAW/sRAW, fine compression = cRAW.
            if compression == 3 { return "C-RAW" }
            switch size {
            case 0: return "RAW"
            case 1, 5, 6: return "M-RAW"
            case 2, 0xE, 0xF, 0x10: return "S-RAW"
            default: return "RAW (size \(size))"
            }
        }
        let sizeName = CanonValueTables.imageSize[size] ?? "Undocumented size (\(size))"
        let quality = CanonValueTables.imageCompression[compression] ?? "Undocumented quality (\(compression))"
        return "\(sizeName) \(quality) \(typeName)"
    }

    /// EOS time-zone struct [u32 size = 12][u32 zone][i32 offset minutes]: "New York (UTC-5:00)".
    static func timeZone(_ w: ArraySlice<UInt32>) -> String? {
        guard w.count == 3, w[w.startIndex] == 12 else { return nil }
        let zone = w[w.startIndex + 1]
        let offset = Int32(bitPattern: w[w.startIndex + 2])
        let sign = offset < 0 ? "-" : "+"
        let minutes = offset.magnitude
        let utc = "UTC\(sign)\(minutes / 60):" + pad2(Int(minutes % 60))
        let name = CanonValueTables.timeZone[zone] ?? "Undocumented zone \(zone)"
        return "\(name) (\(utc))"
    }

    /// Splits a flattened AvailList of size-prefixed u32 records ([size, ...]) into records.
    static func records(_ values: [UInt32]) -> [ArraySlice<UInt32>] {
        var result: [ArraySlice<UInt32>] = []
        var i = 0
        while i < values.count {
            let wordCount = Int(values[i] / 4)
            guard wordCount > 0, i + wordCount <= values.count else {
                result.append(values[i...])
                break
            }
            result.append(values[i..<(i + wordCount)])
            i += wordCount
        }
        return result
    }

    /// Seconds since 1970 as a calendar date and time, without time-zone conversion
    /// ("2026-11-16 17:41:17"). CameraTime holds local wall-clock time, UTCTime holds UTC.
    static func clock(_ seconds: UInt32) -> String {
        let days = Int(seconds / 86_400)
        let secondOfDay = Int(seconds % 86_400)
        // Civil-from-days (proleptic Gregorian), days since 1970-01-01.
        let z = days + 719_468
        let era = z / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return "\(year)-\(pad2(month))-\(pad2(day)) \(pad2(secondOfDay / 3600)):\(pad2(secondOfDay / 60 % 60)):\(pad2(secondOfDay % 60))"
    }

    // MARK: Raw renderings

    /// The protocol value for diagnostics: "0x30" for integers, spaced byte hex for payloads.
    static func rawString(_ value: CanonPropertyValue) -> String {
        switch value {
        case .integer(let v): hex(v)
        case .raw(let data): bytesHex(data)
        }
    }

    static func hex(_ value: UInt32, digits: Int = 0) -> String {
        let s = String(value, radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, digits - s.count)) + s
    }

    static func bytesHex(_ data: Data) -> String {
        let digits: [Character] = Array("0123456789ABCDEF")
        var out = ""
        out.reserveCapacity(data.count * 3)
        for (i, byte) in data.enumerated() {
            if i > 0 { out.append(" ") }
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0xF)])
        }
        return out
    }

    static func words(_ w: ArraySlice<UInt32>) -> String {
        w.map { hex($0) }.joined(separator: " ")
    }

    static func littleEndianWords(_ data: Data) -> [UInt32] {
        let bytes = Array(data)
        return stride(from: 0, to: bytes.count - bytes.count % 4, by: 4).map { i in
            UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
        }
    }

    static func pad2(_ n: Int) -> String { n < 10 ? "0\(n)" : String(n) }
}
