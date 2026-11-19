import Foundation
import Testing
import MirrorupCapture
import MirrorupPTP
@testable import MirrorupCanon

private func fixture(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
        throw CocoaError(.fileNoSuchFile)
    }
    return try Data(contentsOf: url)
}

private func initialEventCache() throws -> CanonPropertyCache {
    var cache = CanonPropertyCache()
    cache.apply(try CanonEventParser.parse(fixture("getevent-initial-sl2.bin")))
    return cache
}

private func value(_ code: UInt32, _ v: UInt32) -> String {
    CanonCatalog.describe(property: code, value: .integer(v)).value
}

@Suite struct CanonPropertyDecodingTests {
    @Test func everySL2PropertyDecodes() throws {
        let cache = try initialEventCache()
        #expect(cache.values.count == 124)
        var documented = 0
        var undocumented: [UInt32] = []
        for (code, v) in cache.values {
            let item = CanonCatalog.describe(property: code, value: v)
            #expect(!item.value.isEmpty, "empty value for 0x\(String(code, radix: 16))")
            #expect(!item.label.isEmpty)
            if item.isDocumented { documented += 1 } else { undocumented.append(code) }
        }
        // 0x0000 is not a property code and 0xD19A is named only "UnknownPropD19A" by libgphoto2.
        #expect(documented == 122)
        #expect(undocumented.sorted() == [0x0000, 0xD19A])
    }

    @Test func knownSL2Values() throws {
        let cache = try initialEventCache()
        func item(_ code: UInt32) throws -> CameraMetadata.Item {
            CanonCatalog.describe(property: code, value: try #require(cache[code]))
        }
        #expect(try item(0xD114) == CameraMetadata.Item(.autoPowerOff, value: "2 min", raw: "0x78"))
        #expect(try item(0xD1B0).kind == .liveViewOutput)
        #expect(try item(0xD1B0).value == "Rear LCD")
        #expect(try item(0xD103) == CameraMetadata.Item(.iso, value: "Auto", raw: "0x0"))
        #expect(try item(0xD101).value == "Auto")
        #expect(try item(0xD102).value == "Auto")
        #expect(try item(0xD138) == CameraMetadata.Item(.exposureMode, value: "Scene Intelligent Auto", raw: "0x16",
                                                         symbol: CanonModeSymbols.symbol(forExposureMode: 0x16)))
        #expect(try item(0xD138).symbol != nil)
        #expect(try item(0xD105).symbol == nil)
        #expect(try item(0xD105).kind == .vendorProperty(0xD105))
        #expect(try item(0xD105).label == "Auto Exposure Mode")
        #expect(try item(0xD105).value == "Scene Intelligent Auto")
        #expect(try item(0xD106).value == "Single")
        #expect(try item(0xD107).value == "Center-weighted Average")
        #expect(try item(0xD108).value == "AI Focus AF")
        #expect(try item(0xD109).value == "Auto (Ambience Priority)")
        #expect(try item(0xD10A).value == "5200 K")
        #expect(try item(0xD10F).value == "sRGB")
        #expect(try item(0xD110).value == "Auto")
        #expect(try item(0xD111).value == "100%")
        #expect(try item(0xD11C).value == "Memory Card")
        #expect(try item(0xD120) == CameraMetadata.Item(
            .imageQuality, value: "Large Fine JPEG",
            raw: "01 00 00 00 10 00 00 00 01 00 00 00 00 00 00 00 03 00 00 00 00 00 00 00 03 00 00 00 01 00 00 00 00 00 00 00"))
        #expect(try item(0xD122).label == "Image Quality (SD)")
        #expect(try item(0xD1D8) == CameraMetadata.Item(.lensName, value: "EF-S18-55mm f/4-5.6 IS STM", raw: try item(0xD1D8).raw))
        #expect(try item(0xD1A8).kind == .lensAttached)
        #expect(try item(0xD1A8).value == "Attached")
        #expect(try item(0xD125).kind == .nickname)
        #expect(try item(0xD125).value == "EOSSL2")
        #expect(try item(0xD115) == CameraMetadata.Item(.ownerName, value: "Not set", raw: "0x0"))
        #expect(try item(0xD1BA).value == "Face + Tracking")
        #expect(try item(0xD1BC) == CameraMetadata.Item(.exposureSimulation, value: "Enabled", raw: "0x1"))
        #expect(try item(0xD1B1).kind == .liveViewMode)
        #expect(try item(0xD1B1).value == "Undocumented (2)")  // EDSDK documents only 0 and 1
        #expect(try item(0xD1B4).value == "Auto (Ambience Priority)")
        #expect(try item(0xD1B6).value == "5200 K")
        #expect(try item(0xD1B8).value == "Camera Memory (SDRAM)")
        #expect(try item(0xD113) == CameraMetadata.Item(.dateTime, value: "2026-11-16 21:21:01", raw: "0x6AFB73BD"))
        #expect(try item(0xD17C).value == "2026-11-17 01:21:01 UTC")
        #expect(try item(0xD17D).value == "New York (UTC-5:00)")
        #expect(try item(0xD17E).value == "On")
        #expect(try item(0xD194) == CameraMetadata.Item(.aspectRatio, value: "3:2", raw: "0x0"))
        #expect(try item(0xD1AB).value == "Normal")
        #expect(try item(0xD1D9) == CameraMetadata.Item(.autoExposureBracketing, value: "Off", raw: "0x0"))
        #expect(try item(0xD116).value == "0x80000417")
        #expect(try item(0xD1DD).value == "4158")
        #expect(try item(0xD1C1).value == "Standard (Off in Manual Exposure)")
    }

    @Test func exposureTablesMatchReferences() {
        // EDSDK kEdsPropID_Av / Tv / ISOSpeed / ExposureCompensation.
        #expect(value(0xD101, 0x30) == "f/5.6")
        #expect(value(0xD101, 0x2D) == "f/5")
        #expect(value(0xD101, 0x85) == "f/3.4")
        #expect(value(0xD101, 0x08) == "f/1")
        #expect(value(0xD102, 0x70) == "1/125 s")
        #expect(value(0xD102, 0xA0) == "1/8000 s")
        #expect(value(0xD102, 0x10) == "30\"")
        #expect(value(0xD102, 0x2D) == "2.5\"")
        #expect(value(0xD102, 0x0C) == "Bulb")
        #expect(value(0xD103, 0x48) == "ISO 100")
        #expect(value(0xD103, 0x58) == "ISO 400")
        #expect(value(0xD103, 0x80) == "ISO 12800")
        #expect(value(0xD104, 0x03) == "+1/3 EV")
        #expect(value(0xD104, 0x00) == "0 EV")
        #expect(value(0xD104, 0xF5) == "-1 1/3 EV")
        #expect(value(0xD104, 0xFFFF_FFF8) == "-1 EV")  // u8 value sign-extended in its 4-byte slot
        #expect(value(0xD1D9, 0x08) == "±1 EV")
    }

    @Test func enumerationTablesMatchReferences() {
        #expect(value(0xD138, 0x02) == "Av (Aperture Priority AE)")
        #expect(value(0xD138, 0x03) == "M (Manual Exposure)")
        #expect(value(0xD106, 0x11) == "Self-timer: 2 s")
        #expect(value(0xD107, 0x03) == "Evaluative")
        #expect(value(0xD108, 0x00) == "One-Shot AF")
        #expect(value(0xD109, 0x01) == "Daylight")
        #expect(value(0xD110, 0x81) == "Standard")
        #expect(value(0xD111, 0x00) == "Low")
        #expect(value(0xD11C, 0x04) == "Computer")
        #expect(value(0xD1B0, 0x00) == "Off")
        #expect(value(0xD1B0, 0x02) == "Computer")
        #expect(value(0xD1B0, 0x03) == "Rear LCD + Computer")
        #expect(value(0xD1B0, 0x18) == "Computer (Small) + Undocumented 0x10")
        #expect(value(0xD114, 0) == "Disabled")
        #expect(value(0xD114, 30) == "30 s")
        #expect(value(0xD114, 90) == "1 min 30 s")
        #expect(value(0xD114, 3600) == "1 h")
        #expect(value(0xD11D, 0xFFFF) == "Off")
        #expect(value(0xD11D, 0x5) == "AE + White Balance")
        #expect(value(0xD1AB, 0x0002_0001) == "Warning, Movie Recording Restricted")
        #expect(value(0xD1BF, 2) == "Mirror Up (Shooting)")
        #expect(value(0xD1A9, 0xFF) == "Hold")
    }

    @Test func imageQualityStruct() {
        func quality(_ words: [UInt32]) -> String {
            var w = PTPDataWriter()
            for word in words { w.u32(word) }
            return CanonCatalog.describe(property: 0xD120, value: .raw(w.data)).value
        }
        #expect(quality([2, 0x10, 6, 0, 4, 0x10, 1, 0, 3]) == "RAW + Large Fine JPEG")
        #expect(quality([1, 0x10, 1, 0x0E, 2]) == "Small 1 Normal JPEG")
        #expect(quality([1, 0x10, 6, 1, 4]) == "M-RAW")
        #expect(quality([1, 0x10, 6, 0, 3]) == "C-RAW")
        #expect(quality([3, 0x10, 1, 0, 3]) == "0x3 0x10 0x1 0x0 0x3")  // malformed count: shown, not guessed
    }

    @Test func shortStringsRecoveredFromIntegerSlot() {
        #expect(value(0xD115, 0x0043_4241) == "ABC")
        #expect(value(0xD1D0, 0) == "Not set")
        let item = CanonCatalog.describe(property: 0xD1D1, value: .raw(Data("(c) Me\0\0".utf8)))
        #expect(item == CameraMetadata.Item(.copyright, value: "(c) Me", raw: "28 63 29 20 4D 65 00 00"))
    }

    @Test func undocumentedCodesKeepTheirRawValue() {
        let unknown = CanonCatalog.describe(property: 0xD147, value: .integer(0x2A))
        #expect(unknown == CameraMetadata.Item(.vendorProperty(0xD147), value: "0x2A", raw: "0x2A", isDocumented: false))
        #expect(unknown.label == "Property 0xD147")
        // libgphoto2 names it only "UnknownPropD14D".
        #expect(CanonCatalog.describe(property: 0xD14D, value: .raw(Data([1, 2]))).isDocumented == false)
        #expect(CanonCatalog.describe(property: 0xD14D, value: .raw(Data([1, 2]))).value == "01 02")
        #expect(CanonCatalog.section(forProperty: 0xD147) == .other)
        // Named property without a value table: documented, plain number.
        let sharpness = CanonCatalog.describe(property: 0xD1B3, value: .integer(3))
        #expect(sharpness == CameraMetadata.Item(.vendorProperty(0xD1B3), label: "EVF Sharpness", value: "3", raw: "0x3"))
    }

    @Test func sections() {
        #expect(CanonCatalog.section(forProperty: 0xD101) == .exposure)
        #expect(CanonCatalog.section(forProperty: 0xD108) == .focus)
        #expect(CanonCatalog.section(forProperty: 0xD109) == .whiteBalance)
        #expect(CanonCatalog.section(forProperty: 0xD111) == .power)
        #expect(CanonCatalog.section(forProperty: 0xD11B) == .storage)
        #expect(CanonCatalog.section(forProperty: 0xD120) == .image)
        #expect(CanonCatalog.section(forProperty: 0xD1B0) == .liveView)
        #expect(CanonCatalog.section(forProperty: 0xD1D8) == .lens)
        #expect(CanonCatalog.section(forProperty: 0xD1C2) == .movie)
        #expect(CanonCatalog.section(forProperty: 0xD1AF) == .device)
    }

    @Test func allowedValuesUseTheSameDecoder() throws {
        let cache = try initialEventCache()
        func allowed(_ code: UInt32) throws -> [String] {
            CanonCatalog.describeAllowedValues(property: code, values: try #require(cache.allowedValues[code]))
        }
        #expect(try allowed(0xD10A).first == "2500 K")
        #expect(try allowed(0xD1B0)[3] == "Rear LCD + Computer")
        #expect(try allowed(0xD1BA) == ["Face + Tracking", "Zone AF", "1-point AF (Live Mode)"])
        #expect(try allowed(0xD11C) == ["Computer"])
        #expect(try allowed(0xD1A9) == ["Off", "2 s", "4 s", "8 s", "Hold"])
        let zones = try allowed(0xD17D)
        #expect(zones.count == 11)
        #expect(zones.prefix(2) == ["Samoa (UTC+13:00)", "Chatham Islands (UTC+12:45)"])
        #expect(CanonCatalog.describeAllowedValues(property: 0xD147, values: [1, 0x20]) == ["0x1", "0x20"])
    }
}

@Suite struct CanonCatalogNameTests {
    @Test func sl2DeviceInfoCodesAreNamed() throws {
        let info = try PTPDeviceInfo(decoding: fixture("deviceinfo-sl2.bin"))
        #expect(info.operationsSupported.count == 170)
        let unnamedOperations = info.operationsSupported.filter { CanonCatalog.operationName($0) == nil }
        // No public reference names these SL2 opcodes (libgphoto2 ptp.h, camlib).
        #expect(Set(unnamedOperations) == [
            0x9051, 0x9058, 0x9059, 0x905A, 0x905B, 0x905C, 0x905D, 0x905F,
            0x912D, 0x912E, 0x912F, 0x914E, 0x917F, 0x9180, 0x9181,
            0x91D3, 0x91D4, 0x91D5, 0x91D7, 0x91D8, 0x91D9, 0x91DA, 0x91DB, 0x91DC, 0x91DD, 0x91DE, 0x91DF,
            0x91E1, 0x91E2, 0x91E3, 0x91E6, 0x91E7, 0x91EA, 0x91EB, 0x91EC, 0x91ED, 0x91EE, 0x91EF,
            0x91F2, 0x91F3, 0x91F4, 0x91F5, 0x91F6, 0x91F8, 0x91FB, 0x91FC,
        ])
        #expect(info.eventsSupported.filter { CanonCatalog.eventName(UInt32($0)) == nil } == [0xC1A0, 0xC1A1])
        #expect(info.devicePropertiesSupported.allSatisfy { CanonCatalog.propertyName(UInt32($0)) != nil })
        #expect(info.captureFormats.allSatisfy { CanonCatalog.objectFormatName($0) != nil })
        #expect(info.imageFormats.filter { CanonCatalog.objectFormatName($0) == nil } == [0xBF02])
    }

    @Test func vendorNamesLayerOverStandardOnes() {
        #expect(CanonCatalog.operationName(0x1001) == "GetDeviceInfo")
        #expect(CanonCatalog.operationName(0x9116) == "EOS_GetEvent")
        #expect(CanonCatalog.operationName(0x9050) == "EOS_EnableEventProc")
        #expect(CanonCatalog.operationName(0x9033) == "Canon_GetMACAddress")
        #expect(CanonCatalog.eventName(0x4002) == "ObjectAdded")
        #expect(CanonCatalog.eventName(0xC189) == "EOS_PropValueChanged")
        #expect(CanonCatalog.eventName(0xC19D) == "EOS_PowerZoomInfoChanged")
        #expect(CanonCatalog.eventName(0x1_0000) == nil)
        #expect(CanonCatalog.responseName(0x2019) == "DeviceBusy")
        #expect(CanonCatalog.responseName(0xA102) == "Canon_ObjectNotReady")
        #expect(CanonCatalog.responseName(0xA009) == nil)
        #expect(CanonCatalog.objectFormatName(0x3801) == "EXIF/JPEG")
        #expect(CanonCatalog.objectFormatName(0xB103) == "Canon RAW (CR2)")
        #expect(CanonCatalog.objectFormatName(0xB108) == "Canon RAW (CR3)")
        #expect(CanonCatalog.propertyName(0xD1B3) == "EVF Sharpness")
        #expect(CanonCatalog.propertyName(0x5001) == "Battery Level")
        #expect(CanonCatalog.propertyName(0xD402) == "Device Friendly Name")
        #expect(CanonCatalog.propertyName(0xD19A) == nil)
    }

    @Test func describeHelpersDelegateToTheCatalog() {
        #expect(CanonOperation.describe(0x9116) == "EOS_GetEvent (0x9116)")
        #expect(CanonOperation.describe(0x1002) == "OpenSession (0x1002)")
        #expect(CanonOperation.describe(0x91E1) == "0x91E1")
        #expect(CanonResponse.describe(.ok) == "OK (0x2001)")
        #expect(CanonResponse.describe(CanonResponse.objectNotReady) == "Canon_ObjectNotReady (0xA102)")
        #expect(CanonResponse.describe(PTPResponseCode(0xA1E8)) == "0xA1E8")
    }
}

@Suite struct CanonModeSymbolTests {
    /// Every outline parses, belongs to a documented mode and stays inside its box: a mistyped
    /// coordinate would otherwise draw over the lens name or be cut off.
    @Test func everyOutlineIsAValidSymbolForADocumentedMode() throws {
        #expect(CanonModeSymbols.outlines.count == 47)
        for (mode, outline) in CanonModeSymbols.outlines {
            #expect(CanonValueTables.exposureMode[mode] != nil, "0x\(String(mode, radix: 16)) is not a mode")
            let symbol = try #require(CanonModeSymbols.symbol(forExposureMode: mode), "0x\(String(mode, radix: 16))")
            #expect(symbol.width == outline.width)
            #expect(!symbol.elements.isEmpty)
            for element in symbol.elements {
                let points: [CameraSymbol.Point] = switch element {
                case .move(let p), .line(let p): [p]
                case .quadCurve(let p, let c): [p, c]
                case .curve(let p, let c1, let c2): [p, c1, c2]
                case .close: []
                }
                for p in points {
                    #expect((-1...symbol.width + 1).contains(p.x) && (-1...symbol.height + 1).contains(p.y),
                            "0x\(String(mode, radix: 16)) point \(p) outside \(symbol.width)×\(symbol.height)")
                }
            }
        }
    }

    @Test func dialModesHaveTheirIconAndOthersKeepTheirName() {
        func symbol(_ mode: UInt32) -> CameraSymbol? {
            CanonCatalog.describe(property: 0xD138, value: .integer(mode)).symbol
        }
        // SL2 dial modes, and modes only other bodies' manuals draw (Bulb, A-DEP, Fv, C1, Full Auto,
        // Self Portrait, Hybrid Auto).
        for mode: UInt32 in [0x00, 0x01, 0x02, 0x03, 0x16, 0x0F, 0x13, 0x19, 0x14, 0x04, 0x05, 0x37, 0x07, 0x09, 0x32, 0x33] {
            #expect(symbol(mode) != nil, "0x\(String(mode, radix: 16))")
        }
        #expect(symbol(0x06) == nil)  // DEP: no manual draws it
        #expect(symbol(0x39) == nil)  // Fireworks
        #expect(symbol(0x16) != symbol(0x00))
        // The dials print only Scene Intelligent Auto and Full Auto in colour.
        #expect(symbol(0x16)?.tint == CanonModeSymbols.sceneIntelligentAutoGreen)
        #expect(symbol(0x09)?.tint == CanonModeSymbols.sceneIntelligentAutoGreen)
        #expect(CanonModeSymbols.outlines.keys.filter { ![0x09, 0x16].contains($0) }.allSatisfy {
            CanonModeSymbols.symbol(forExposureMode: $0)?.tint == nil
        })
    }
}
