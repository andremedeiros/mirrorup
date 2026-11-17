import Foundation
import Testing
import MirrorupPTP
@testable import MirrorupCanon

private func fixture(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
        throw CocoaError(.fileNoSuchFile)
    }
    return try Data(contentsOf: url)
}

private func record(_ code: UInt32, _ body: [UInt8]) -> Data {
    var w = PTPDataWriter()
    w.u32(UInt32(8 + body.count))
    w.u32(code)
    w.bytes(Data(body))
    return w.data
}

private let terminator = record(0, [])

@Suite struct CanonEventParserTests {
    @Test func realInitialEventDumpFromSL2() throws {
        let events = try CanonEventParser.parse(fixture("getevent-initial-sl2.bin"))
        var cache = CanonPropertyCache()
        cache.apply(events)
        #expect(cache[CanonProperty.evfOutputDevice] == .integer(1))  // rear LCD at idle
        #expect(cache[CanonProperty.evfMode] == .integer(2))
        #expect(cache[CanonProperty.autoPowerOff] == .integer(120))
        #expect(events.contains { if case .allowedValuesChanged(0xD103, _) = $0 { true } else { false } })
    }

    /// The popover re-reads settings when the revision moves, so a camera re-reporting values it
    /// already sent (every GetEvent drain can) must not count as a change.
    @Test func revisionCountsOnlyRealChanges() throws {
        var cache = CanonPropertyCache()
        let initial = try CanonEventParser.parse(fixture("getevent-initial-sl2.bin"))
        cache.apply(initial)
        let afterDump = cache.revision
        #expect(afterDump > 0)
        cache.apply(initial)
        #expect(cache.revision == afterDump)
        // Mode dial P → Av: AE mode changes, the aperture list appears.
        let dial: [CanonEvent] = [
            .propertyChanged(property: 0xD105, value: .integer(2)),
            .allowedValuesChanged(property: 0xD101, values: [0x28, 0x2B]),
        ]
        cache.apply(dial)
        #expect(cache.revision == afterDump + 2)
        cache.apply(dial)
        #expect(cache.revision == afterDump + 2)
    }

    @Test func propertyValueWidths() throws {
        let data = record(0xC189, [0xB0, 0xD1, 0, 0, 2, 0, 0, 0])
            + record(0xC189, [0x04, 0xD1, 0, 0, 0xF8])  // u8 value
            + record(0xC189, [0x15, 0xD1, 0, 0, 0x41, 0x42, 0x43, 0x00, 0x00])  // 5-byte string
            + terminator
        let events = try CanonEventParser.parse(data)
        #expect(events == [
            .propertyChanged(property: 0xD1B0, value: .integer(2)),
            .propertyChanged(property: 0xD104, value: .integer(0xF8)),
            .propertyChanged(property: 0xD115, value: .raw(Data([0x41, 0x42, 0x43, 0, 0]))),
        ])
    }

    @Test func emptyAndTerminatorOnlyMeanNoEvents() throws {
        #expect(try CanonEventParser.parse(Data()).isEmpty)
        #expect(try CanonEventParser.parse(terminator).isEmpty)
    }

    @Test func shutdownWarningsAreRecognised() throws {
        let events = try CanonEventParser.parse(record(0xC18D, []) + record(0xC18E, [1, 0, 0, 0]) + terminator)
        #expect(events == [.willSoonShutdown, .shutdownTimerUpdated])
    }

    @Test func recordLongerThanBufferIsRejected() {
        var data = record(0xC189, [0xB0, 0xD1, 0, 0, 2, 0, 0, 0])
        data[0] = 0x40
        #expect(throws: PTPError.self) { try CanonEventParser.parse(data) }
    }

    @Test func recordShorterThanHeaderIsRejected() {
        var w = PTPDataWriter()
        w.u32(4); w.u32(0xC189)
        #expect(throws: PTPError.invalidContainerLength(4)) { try CanonEventParser.parse(w.data) }
    }

    @Test func availableValuesCountIsBounded() {
        let data = record(0xC18A, [0x03, 0xD1, 0, 0, 3, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0x0F]) + terminator
        #expect(throws: PTPError.self) { try CanonEventParser.parse(data) }
    }

    @Test func survivesRandomMutationOfRealDump() throws {
        let full = try fixture("getevent-initial-sl2.bin")
        var state: UInt64 = 42
        func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 11 }
        for _ in 0..<500 {
            var mutated = full
            for _ in 0..<4 { mutated[Int(next() % UInt64(mutated.count))] = UInt8(truncatingIfNeeded: next()) }
            _ = try? CanonEventParser.parse(mutated)
            _ = try? CanonEventParser.parse(mutated.prefix(Int(next() % UInt64(mutated.count))))
        }
    }
}

@Suite struct CanonViewfinderParserTests {
    @Test func realSL2FrameYieldsDecodableJPEG() throws {
        let frame = try CanonViewfinderParser.parse(fixture("evf-sl2.bin"))
        #expect(frame.blockTypes.first == 0xFFFF_FFFF)
        #expect(frame.blockTypes.contains(1))
        #expect(frame.blockTypes.contains(0x11))
        #expect(frame.jpeg.count == 0x37313 - 8)
        #expect(frame.jpeg.prefix(2) == Data([0xFF, 0xD8]))
        // Slice of the original payload, not a copy.
        #expect(frame.jpeg.startIndex == 0x3C + 8)
    }

    /// Firmware 1.1.0 adds a type 0x8 block (AF frame on other EOS bodies) before the terminator.
    @Test func realSL2Firmware110FrameWithExtraBlock() throws {
        let frame = try CanonViewfinderParser.parse(fixture("evf-sl2-fw110.bin"))
        #expect(frame.blockTypes.last == 0x8)
        #expect(frame.blockTypes.contains(1))
        #expect(frame.jpeg.prefix(2) == Data([0xFF, 0xD8]))
    }

    @Test func jpegBlockMayBeType11() throws {
        let jpeg: [UInt8] = [0xFF, 0xD8, 0x00, 0x00, 0xFF, 0xD9]
        let data = record(0xFFFF_FFFF, [0, 0, 0, 0]) + record(0xB, jpeg) + terminator
        #expect(try CanonViewfinderParser.parse(data).jpeg == Data(jpeg))
    }

    @Test func missingImageBlock() {
        let data = record(0xFFFF_FFFF, [0, 0, 0, 0]) + record(0x11, [1, 2, 3, 4]) + terminator
        #expect(throws: CanonViewfinderError.noImageBlock(types: [0xFFFF_FFFF, 0x11])) {
            try CanonViewfinderParser.parse(data)
        }
    }

    @Test func blockOverrunningPayloadIsRejected() {
        var data = record(0x1, [0xFF, 0xD8, 0xFF, 0xD9])
        data[0] = 0xFF
        #expect(throws: CanonViewfinderError.blockLengthInvalid(offset: 0, length: 0xFF)) {
            try CanonViewfinderParser.parse(data)
        }
    }

    @Test func zeroLengthBlockIsRejectedInsteadOfLooping() {
        var w = PTPDataWriter()
        w.u32(0); w.u32(1)
        #expect(throws: CanonViewfinderError.blockLengthInvalid(offset: 0, length: 0)) {
            try CanonViewfinderParser.parse(w.data)
        }
    }

    @Test func nonJPEGImageBlock() {
        let data = record(0x1, [0x00, 0x00, 0xFF, 0xD9]) + terminator
        #expect(throws: CanonViewfinderError.imageNotJPEG) { try CanonViewfinderParser.parse(data) }
    }

    @Test func truncatedJPEGWithoutEOI() throws {
        let real = try CanonViewfinderParser.parse(fixture("evf-sl2.bin")).jpeg
        let cut = Data(real.prefix(real.count / 2))
        let data = record(0x1, Array(cut)) + terminator
        #expect(throws: CanonViewfinderError.jpegTruncated) { try CanonViewfinderParser.parse(data) }
    }

    @Test func survivesRandomMutationAndTruncation() throws {
        let full = try fixture("evf-sl2.bin")
        var state: UInt64 = 7
        func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 11 }
        for _ in 0..<300 {
            var mutated = full
            for _ in 0..<3 { mutated[Int(next() % 0x3C + next() % 64)] = UInt8(truncatingIfNeeded: next()) }
            _ = try? CanonViewfinderParser.parse(mutated)
            _ = try? CanonViewfinderParser.parse(full.prefix(Int(next() % UInt64(full.count))))
        }
    }
}

@Suite struct CanonEncodingTests {
    @Test func setPropertyPayloadMatchesVerifiedBytes() {
        // Verified on the SL2: [12][0xD1B0][2] -> OK.
        #expect(Array(CanonPropertyEncoding.integerPayload(property: 0xD1B0, value: 2)) == [
            12, 0, 0, 0, 0xB0, 0xD1, 0, 0, 2, 0, 0, 0,
        ])
    }
}
