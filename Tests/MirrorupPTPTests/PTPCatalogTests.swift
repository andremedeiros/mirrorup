import Foundation
import Testing
@testable import MirrorupPTP

@Suite struct PTPCatalogTests {
    @Test func standardOperationsAreAllNamed() {
        for code in UInt16(0x1001)...0x1025 { #expect(PTPCatalog.operationName(code) != nil, "0x\(String(code, radix: 16))") }
        #expect(PTPCatalog.operationName(0x1001) == "GetDeviceInfo")
        #expect(PTPCatalog.operationName(0x101C) == "InitiateOpenCapture")
        #expect(PTPCatalog.operationName(0x9801) == "GetObjectPropsSupported")
        // MTP DRM sets reuse the vendor range; on a camera those codes belong to the vendor.
        #expect(PTPCatalog.operationName(0x9101) == nil)
        #expect(PTPOperationCode.getDeviceInfo.description == "GetDeviceInfo (0x1001)")
        #expect(PTPOperationCode(0x9116).name == nil)
    }

    @Test func standardResponsesAreAllNamed() {
        for code in UInt16(0x2000)...0x2023 { #expect(PTPCatalog.responseName(code) != nil, "0x\(String(code, radix: 16))") }
        #expect(PTPCatalog.responseName(0x2001) == "OK")
        #expect(PTPCatalog.responseName(0x2019) == "DeviceBusy")
        #expect(PTPCatalog.responseName(0xA809) == "ObjectTooLarge")
        #expect(PTPResponseCode.deviceBusy.description == "DeviceBusy (0x2019)")
        #expect(PTPResponseCode(0xA102).name == nil)
    }

    @Test func eventsPropertiesAndFormats() {
        for code in UInt16(0x4000)...0x400E { #expect(PTPCatalog.eventName(code) != nil) }
        for code in UInt16(0x5000)...0x502C { #expect(PTPCatalog.propertyName(code) != nil) }
        #expect(PTPCatalog.eventName(0x4009) == "RequestObjectTransfer")
        #expect(PTPCatalog.eventName(0xC801) == "ObjectPropChanged")
        #expect(PTPCatalog.propertyName(0x5001) == "Battery Level")
        #expect(PTPCatalog.propertyName(0x501F) == "Copyright Info")
        #expect(PTPCatalog.propertyName(0xD101) == nil)  // MTP DRM code; Canon uses it for aperture
        #expect(PTPCatalog.objectFormatName(0x3001) == "Association (Folder)")
        #expect(PTPCatalog.objectFormatName(0x3801) == "EXIF/JPEG")
        #expect(PTPCatalog.objectFormatName(0x3811) == "DNG")
        #expect(PTPCatalog.objectFormatName(0xB802) == "Firmware")
        #expect(PTPCatalog.objectFormatName(0x3806) == nil)  // reserved
    }

    @Test func sl2StandardCodesAreNamed() throws {
        let info = try PTPDeviceInfo(decoding: Bytes.fixture("deviceinfo-sl2.bin"))
        #expect(info.devicePropertiesSupported.map { PTPCatalog.propertyName($0) } == [
            "Device Friendly Name", "Perceived Device Type", "Session Initiator Version Info",
            "Use Device Stage Flag", "Battery Level",
        ])
        let standardOps = info.operationsSupported.filter { $0 < 0x9000 }
        #expect(!standardOps.isEmpty)
        #expect(standardOps.allSatisfy { PTPCatalog.operationName($0) != nil })
        #expect(info.eventsSupported.filter { $0 < 0x8000 }.allSatisfy { PTPCatalog.eventName($0) != nil })
        #expect(info.imageFormats.filter { $0 < 0x8000 }.allSatisfy { PTPCatalog.objectFormatName($0) != nil })
    }
}
