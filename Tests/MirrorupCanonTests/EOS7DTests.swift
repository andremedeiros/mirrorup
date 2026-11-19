import Foundation
import Testing
import MirrorupCapture
import MirrorupPTP
@testable import MirrorupCanon

/// Captures from a real EOS 7D, firmware 2.0.3, Live View/Movie switch on stills, mode dial on P
/// (`mirrorup ptp dump --body 7d`, serial zeroed). docs/canon-eos-ptp.md §12.
private func fixture(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
        throw CocoaError(.fileNoSuchFile)
    }
    return try Data(contentsOf: url)
}

@Suite struct EOS7DTests {
    @Test func deviceInfoPassesValidationWithoutInitiateViewfinder() throws {
        let info = try PTPDeviceInfo(decoding: fixture("deviceinfo-7d.bin"))
        #expect(info.model == "Canon EOS 7D")
        #expect(info.deviceVersion == "3-2.0.3")
        #expect(CanonCamera.firmwareVersion(info.deviceVersion) == "2.0.3")
        #expect(info.vendorExtensionID == 0x6)  // Microsoft's, like the SL2
        #expect(info.serialNumber.allSatisfy { $0 == "0" })  // redacted by ptp dump
        #expect(throws: Never.self) { try CanonCamera.validate(info) }
        #expect(!info.supports(CanonOperation.initiateViewfinder))
        #expect(info.devicePropertiesSupported.count == 4)  // EOS properties arrive only through GetEvent
    }

    @Test func initialEventDumpInStillsMode() throws {
        var cache = CanonPropertyCache()
        cache.apply(try CanonEventParser.parse(fixture("getevent-initial-7d.bin")))
        #expect(cache[CanonProperty.evfOutputDevice] == .integer(0))  // optical viewfinder at idle
        #expect(cache[CanonProperty.evfMode] == .integer(1))  // 2 with the switch on movie
        #expect(cache[CanonProperty.movieMode] == .integer(0))
    }

    /// No 0xFFFFFFFF header, and a 4096-byte type 0x3 block where the SL2 sends its 0x11
    /// histogram. Its four 256 × u32 planes do not share a total, so it is not that layout: kept
    /// undecoded. Type 0x6 (8 bytes) is not sent by the SL2.
    @Test func viewfinderPayloadLayout() throws {
        let frame = try CanonViewfinderParser.parse(fixture("evf-7d.bin"))
        #expect(frame.blockTypes == [0x1, 0x4, 0x5, 0x6, 0x7, 0x3, 0x8])
        let size = try #require(CanonViewfinderParser.jpegDimensions(frame.jpeg))
        #expect(size.width == 1056 && size.height == 704)
        let metadata = frame.metadata
        #expect(metadata.header == nil)
        #expect(metadata.histogram == nil)
        #expect(metadata.magnification == 1)
        #expect(metadata.focusFrames?.count == 1)
        #expect(metadata.unknownBlocks.map(\.type) == [0x6, 0x3])
        #expect(metadata.unknownBlocks.first { $0.type == 0x3 }?.payload.count == 4096)
    }

    @Test func streamsThroughTheSimulatedSession() async throws {
        let sim = SimulatedSL2(
            initialEvents: try fixture("getevent-initial-7d.bin"),
            deviceInfo: try fixture("deviceinfo-7d.bin"),
            evf: try fixture("evf-7d.bin"))
        let camera = CanonCamera(session: PTPSession(transport: sim), identity: CameraIdentity(name: "7D", transport: "Simulated"))
        try await camera.connect()
        try await camera.startLiveView()
        let frame = try await camera.nextFrame()
        #expect(frame.jpeg.prefix(2) == Data([0xFF, 0xD8]))
        #expect(await camera.rawPayloads["evf"] == (try fixture("evf-7d.bin")))
        #expect(await camera.rawPayloads["getevent-initial"] == (try fixture("getevent-initial-7d.bin")))
        try await camera.stopLiveView()
        await camera.disconnect()
        // EVFOutputDevice was 0 (optical viewfinder): stop hands output to the rear LCD, like the SL2.
        #expect(sim.state.withLock { $0.propertyWrites.filter { $0.0 == CanonProperty.evfOutputDevice }.map(\.1) } == [2, 1])
    }
}
