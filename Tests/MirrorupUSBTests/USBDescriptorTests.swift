import IOKit
import Testing
import MirrorupPTP
@testable import MirrorupUSB

/// The SL2's real configuration descriptor (39 bytes), reconstructed from `mirrorup inspect`.
private let sl2Config: [UInt8] = [
    0x09, 0x02, 0x27, 0x00, 0x01, 0x01, 0x00, 0xC0, 0x01,  // configuration, total 39, self powered
    0x09, 0x04, 0x00, 0x00, 0x03, 0x06, 0x01, 0x01, 0x00,  // interface 0, 3 endpoints, Still Image
    0x07, 0x05, 0x81, 0x02, 0x00, 0x02, 0x00,  // EP 0x81 bulk IN 512
    0x07, 0x05, 0x02, 0x02, 0x00, 0x02, 0x00,  // EP 0x02 bulk OUT 512
    0x07, 0x05, 0x83, 0x03, 0x08, 0x00, 0x0A,  // EP 0x83 interrupt IN 8, interval 10
]

@Suite struct USBDescriptorTests {
    @Test func parsesStillImageInterfaceAndEndpoints() throws {
        let config = try USBDescriptorParser.parseConfiguration(sl2Config)
        #expect(config.value == 1)
        #expect(config.selfPowered)
        let ptp = try #require(config.stillImageInterface)
        #expect(ptp.bulkIn?.address == 0x81 && ptp.bulkIn?.maxPacketSize == 512)
        #expect(ptp.bulkOut?.address == 0x02)
        #expect(ptp.interruptIn?.address == 0x83 && ptp.interruptIn?.interval == 10)
    }

    @Test func classSpecificDescriptorsAreSkipped() throws {
        var bytes = sl2Config
        bytes.insert(contentsOf: [0x05, 0x24, 0x00, 0x10, 0x01], at: 18)  // CS_INTERFACE descriptor
        bytes[2] = UInt8(bytes.count)
        let config = try USBDescriptorParser.parseConfiguration(bytes)
        #expect(config.stillImageInterface?.endpoints.count == 3)
    }

    @Test func truncatedTotalLengthIsRejected() {
        #expect(throws: USBDescriptorError.truncated(at: 20)) {
            try USBDescriptorParser.parseConfiguration(Array(sl2Config.prefix(20)))
        }
    }

    @Test func zeroLengthDescriptorDoesNotLoop() {
        var bytes = sl2Config
        bytes[9] = 0
        #expect(throws: USBDescriptorError.invalidDescriptorLength(at: 9, length: 0)) {
            try USBDescriptorParser.parseConfiguration(bytes)
        }
    }

    @Test func nonConfigurationDescriptorIsRejected() {
        #expect(throws: USBDescriptorError.notAConfigurationDescriptor) {
            try USBDescriptorParser.parseConfiguration([0x12, 0x01, 0, 2, 0, 0, 0, 64, 0])
        }
    }

    @Test func ioReturnMapping() {
        #expect(USBError("x", code: kIOReturnNoDevice).transportError == .disconnected(USBError("x", code: kIOReturnNoDevice).description))
        #expect(USBError("x", code: kIOReturnAborted).transportError == .cancelled)
        // The registry owner turns IOUSBHost's generic InternalError into a precise diagnosis.
        #expect(USBError("open", code: kIOReturnInternalError, owner: "pid 1, ptpcamerad").transportError == .exclusiveAccess("pid 1, ptpcamerad"))
        if case .io = USBError("open", code: kIOReturnInternalError).transportError {} else { Issue.record("expected .io") }
    }

    /// The SL2 through a USB-C multiport adapter (which contains a hub) was at 0x00110000; directly
    /// in a Mac port a device sits at 0x00100000. Other buses carry their number in the top byte.
    @Test func hubCountFromLocationID() {
        #expect(USBDeviceSnapshot.hubCount(locationID: 0x0010_0000) == 0)
        #expect(USBDeviceSnapshot.hubCount(locationID: 0x0011_0000) == 1)
        #expect(USBDeviceSnapshot.hubCount(locationID: 0x0214_3000) == 2)
        #expect(USBDeviceSnapshot.hubCount(locationID: 0) == 0)
    }
}
