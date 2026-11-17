import Foundation
import Testing
@testable import MirrorupPTP

@Suite struct PTPCodecTests {
    @Test func commandContainerIsLittleEndianWithParameters() throws {
        let data = try PTPCommand(.openSession, [0x0102_0304]).encodedContainer(transactionID: 0xAABB_CCDD)
        #expect(Array(data) == [
            0x10, 0, 0, 0,  // length 16
            0x01, 0x00,  // command
            0x02, 0x10,  // OpenSession
            0xDD, 0xCC, 0xBB, 0xAA,  // transaction ID
            0x04, 0x03, 0x02, 0x01,
        ])
    }

    @Test func commandRejectsMoreThanFiveParameters() {
        #expect(throws: PTPError.tooManyParameters(6)) {
            try PTPCommand(.getObject, [1, 2, 3, 4, 5, 6]).encodedContainer(transactionID: 1)
        }
    }

    @Test func headerRejectsLengthsBelowHeaderSize() {
        let bytes = Bytes.container(type: .response, code: 0x2001, tid: 1)
        var corrupt = bytes
        corrupt[0] = 11
        #expect(throws: PTPError.invalidContainerLength(11)) {
            try PTPContainerHeader.decode(corrupt, maxLength: 1024)
        }
    }

    @Test func headerRejectsLengthsAboveLimitBeforeAllocating() {
        var w = PTPDataWriter()
        w.u32(0xFFFF_FFF0)
        w.u16(2); w.u16(0x1009); w.u32(1)
        #expect(throws: PTPError.containerTooLarge(declared: 0xFFFF_FFF0, limit: 1 << 20)) {
            try PTPContainerHeader.decode(w.data, maxLength: 1 << 20)
        }
    }

    @Test func headerNeedsTwelveBytes() {
        #expect(throws: PTPError.truncated(needed: 4, available: 3)) {
            try PTPContainerHeader.decode(Data([12, 0, 0, 0, 3, 0, 1, 0x20, 1, 0, 0]), maxLength: 64)
        }
    }

    @Test func responseDecodesParameters() throws {
        let r = try PTPResponse(container: Bytes.response(0x2019, tid: 7, params: [9, 10]))
        #expect(r.code == .deviceBusy)
        #expect(r.transactionID == 7)
        #expect(r.parameters == [9, 10])
    }

    @Test func responseRejectsWrongContainerType() {
        let data = Bytes.container(type: .data, code: 0x2001, tid: 1)
        #expect(throws: PTPError.unexpectedContainerType(expected: .response, actual: 2)) {
            try PTPResponse(container: data)
        }
    }

    @Test func responseRejectsPartialParameter() {
        let data = Bytes.container(type: .response, code: 0x2001, tid: 1, payload: Data([1, 2]))
        #expect(throws: PTPError.invalidContainerLength(14)) { try PTPResponse(container: data) }
    }

    @Test func stringRoundTripIncludingNonASCII() throws {
        var w = PTPDataWriter()
        try w.string("Canon EOS Rebel SL2 — 200D")
        try w.string("")
        var r = PTPDataReader(w.data)
        #expect(try r.string() == "Canon EOS Rebel SL2 — 200D")
        #expect(try r.string() == "")
        #expect(r.isAtEnd)
    }

    @Test func stringWithCountBeyondDataIsTruncated() {
        var r = PTPDataReader(Data([5, 0x41, 0]))  // claims 5 UTF-16 units, has 1
        #expect(throws: PTPError.truncated(needed: 10, available: 2)) { try r.string() }
    }

    @Test func arrayCountIsBoundedByAvailableBytes() {
        var w = PTPDataWriter()
        w.u32(0x4000_0000)  // a billion u16 elements
        w.u16(1)
        var r = PTPDataReader(w.data)
        #expect(throws: PTPError.self) { try r.u16Array() }
    }

    @Test func readerHonorsSliceStartIndex() throws {
        let backing = Data([0xFF, 0xFF, 0x34, 0x12, 0x78, 0x56, 0x34, 0x12])
        var r = PTPDataReader(backing.dropFirst(2))
        #expect(try r.u16() == 0x1234)
        #expect(try r.u32() == 0x1234_5678)
    }

    @Test func deviceInfoFromRealSL2() throws {
        let info = try PTPDeviceInfo(decoding: Bytes.fixture("deviceinfo-sl2.bin"))
        #expect(info.standardVersion == 100)
        #expect(info.vendorExtensionID == 0x06)
        #expect(info.vendorExtensionName == "Microsoft (MTP)")
        #expect(info.manufacturer == "Canon.Inc")
        #expect(info.model == "Canon EOS Rebel SL2")
        #expect(info.operationsSupported.count == 170)
        #expect(info.supports(PTPOperationCode(0x9153)))
        #expect(!info.supports(PTPOperationCode(0x9151)))
    }

    @Test func deviceInfoTruncatedAtEveryPrefixThrowsInsteadOfCrashing() throws {
        let full = try Bytes.fixture("deviceinfo-sl2.bin")
        for length in 0..<full.count {
            #expect(throws: PTPError.self) { try PTPDeviceInfo(decoding: full.prefix(length)) }
        }
    }

    /// Property-style check: arbitrary mutations of a real dataset must parse or throw, never trap.
    @Test func deviceInfoSurvivesRandomMutation() throws {
        let full = try Bytes.fixture("deviceinfo-sl2.bin")
        var rng = SplitMix64(seed: 0x5EED)
        for _ in 0..<2000 {
            var mutated = full
            for _ in 0..<Int(rng.next() % 8 + 1) {
                mutated[Int(rng.next() % UInt64(mutated.count))] = UInt8(truncatingIfNeeded: rng.next())
            }
            _ = try? PTPDeviceInfo(decoding: mutated)
        }
    }
}

/// Deterministic generator so fuzz-style tests are reproducible.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
