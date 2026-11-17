import Foundation
import Testing
import MirrorupPTP
import MirrorupCapture
@testable import MirrorupCanon

private func fixture(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
        throw CocoaError(.fileNoSuchFile)
    }
    return try Data(contentsOf: url)
}

private func block(_ type: UInt32, words: [UInt32]) -> Data {
    var w = PTPDataWriter()
    w.u32(UInt32(8 + 4 * words.count))
    w.u32(type)
    for word in words { w.u32(word) }
    return w.data
}

private func block(_ type: UInt32, bytes: Data) -> Data {
    var w = PTPDataWriter()
    w.u32(UInt32(8 + bytes.count))
    w.u32(type)
    w.bytes(bytes)
    return w.data
}

private let terminator = block(0, words: [])

private func minimalPayload(with extra: Data) throws -> Data {
    let jpeg = try CanonViewfinderParser.parse(fixture("evf-sl2.bin")).jpeg
    return block(1, bytes: Data(jpeg)) + extra + terminator
}

@Suite struct CanonViewfinderMetadataTests {
    static let undocumentedSL2Blocks: [UInt32] = [0xF, 0x10, 0x14, 0xC, 0x13, 0x15]

    @Test(arguments: ["evf-sl2.bin", "evf-sl2-fw110.bin"])
    func everyBlockIsAccountedFor(_ name: String) throws {
        let frame = try CanonViewfinderParser.parse(fixture(name))
        let metadata = frame.metadata
        #expect(metadata.blocks.map(\.type) == frame.blockTypes)
        // Typed blocks are exactly the documented ones; the rest are kept as unknown.
        #expect(metadata.unknownBlocks.map(\.type) == Self.undocumentedSL2Blocks)
        for block in metadata.blocks where block.isDecoded {
            #expect(CanonViewfinderBlockType(rawValue: block.type) != nil)
        }
        #expect(metadata.imageBlockType == .image)
        #expect(metadata.header?.count == 0x3C - 8)
        #expect(metadata.magnification == 1)
        #expect(metadata.magnifierOrigin == .init(x: 0, y: 0))
        #expect(metadata.magnifierRect == .init(x: 0, y: 0, width: 0, height: 0))
        #expect(metadata.autofocus == .idle)
        #expect(metadata.timestamp != nil && metadata.histogram != nil)
        // Blocks are slices of the payload, not copies.
        let image = try #require(metadata.blocks.first { $0.type == 1 })
        #expect(image.payload.startIndex == frame.jpeg.startIndex)
    }

    @Test func sensorSizeAndZoomRectAreReportedAsGiven() throws {
        let old = try CanonViewfinderParser.parse(fixture("evf-sl2.bin")).metadata
        #expect(old.sensorSize == .init(width: 6000, height: 3988))
        #expect(old.zoomRect == .init(x: 0, y: 0, width: 6000, height: 3988))
        #expect(old.focusFrames == nil)
        let new = try CanonViewfinderParser.parse(fixture("evf-sl2-fw110.bin")).metadata
        #expect(new.sensorSize == .init(width: 5976, height: 3952))
        #expect(new.zoomRect == .init(x: 0, y: 298, width: 5976, height: 3356))
    }

    @Test func timestampIsAPlausibleDateIn2026() throws {
        let stamp = try #require(try CanonViewfinderParser.parse(fixture("evf-sl2.bin")).metadata.timestamp)
        #expect(stamp.seconds == 0x6AFB_7146)
        #expect(stamp.counter == 770)
        let utc = try #require(TimeZone(identifier: "UTC"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        #expect(calendar.component(.year, from: stamp.date) == 2026)
        #expect(calendar.component(.month, from: stamp.date) == 11)
        let later = try #require(try CanonViewfinderParser.parse(fixture("evf-sl2-fw110.bin")).metadata.timestamp)
        #expect(later.seconds > stamp.seconds)
        #expect(later.counter == 87)
    }

    @Test func firmware110FocusFramesAreA7By7GridInsideTheSensor() throws {
        let metadata = try CanonViewfinderParser.parse(fixture("evf-sl2-fw110.bin")).metadata
        let frames = try #require(metadata.focusFrames)
        let sensor = try #require(metadata.sensorSize)
        #expect(frames.count == 49)
        #expect(frames.first?.rect == .init(x: 612, y: 517, width: 649, height: 399))
        #expect(frames.last?.rect == .init(x: 4716, y: 3037, width: 649, height: 399))
        #expect(Set(frames.map(\.rect.x)).count == 7 && Set(frames.map(\.rect.y)).count == 7)
        for frame in frames {
            #expect(frame.state == .undocumented(0))
            #expect(frame.unidentified == 1)
            #expect(frame.rect.width > 0 && frame.rect.height > 0)
            #expect(frame.rect.x + frame.rect.width <= sensor.width)
            #expect(frame.rect.y + frame.rect.height <= sensor.height)
        }
    }

    @Test(arguments: ["evf-sl2.bin", "evf-sl2-fw110.bin"])
    func histogramHasFourEqualPlanes(_ name: String) throws {
        let histogram = try #require(try CanonViewfinderParser.parse(fixture(name)).metadata.histogram)
        let totals = CanonViewfinderMetadata.Histogram.Channel.allCases.map { histogram.total($0) }
        #expect(totals.allSatisfy { $0 == totals[0] && $0 > 0 })
        for channel in CanonViewfinderMetadata.Histogram.Channel.allCases {
            #expect(histogram.bins(channel).count == 256)
        }
        // Luma is the fixed blend of R, G and B (FC.SDK channel-order check).
        let y = try #require(histogram.meanLevel(.luminance))
        let r = try #require(histogram.meanLevel(.red))
        let g = try #require(histogram.meanLevel(.green))
        let b = try #require(histogram.meanLevel(.blue))
        #expect(abs(y - (0.299 * r + 0.587 * g + 0.114 * b)) < 0.02)
    }

    @Test func firmware101HistogramValues() throws {
        let histogram = try #require(try CanonViewfinderParser.parse(fixture("evf-sl2.bin")).metadata.histogram)
        #expect(histogram.total(.luminance) == 1_749_600)
        #expect(histogram.count(.red, bin: 255) == 276_246)
        #expect(histogram.count(.green, bin: 0) == 1_436)
    }

    @Test func itemsUseNeutralKindsAndMarkUndocumentedBlocks() throws {
        let frame = try CanonViewfinderParser.parse(fixture("evf-sl2-fw110.bin"))
        let size = try #require(CanonViewfinderParser.jpegDimensions(frame.jpeg))
        let utc = try #require(TimeZone(identifier: "UTC"))
        let items = frame.metadata.items(frameWidth: size.width, frameHeight: size.height, timeZone: utc)
        func item(_ kind: CameraMetadata.ItemKind) -> CameraMetadata.Item? { items.first { $0.kind == kind } }

        #expect(item(.frameSize)?.value == "1024 × 576")
        #expect(item(.sensorSize)?.value == "5976 × 3952")
        #expect(item(.zoom)?.value == "1×")
        #expect(item(.zoomRect)?.value == "5976 × 3356 at (0, 298)")
        #expect(item(.magnifierRect)?.value == "0 × 0 at (0, 0)")
        #expect(item(.autofocusActive)?.value == "Idle")
        #expect(item(.cameraTimestamp)?.value == "2026-11-16T22:35:59Z")
        #expect(item(.frameCounter)?.value == "87")
        let focus = try #require(item(.focusPoints))
        #expect(focus.value.hasPrefix("49 points in a 7 × 7 grid, each 649 × 399"))
        #expect(focus.value.contains("49 undocumented state 0x0"))
        #expect(focus.raw.hasSuffix("(1180 bytes)"))
        let histogram = try #require(item(.histogram))
        #expect(histogram.value.hasPrefix("Mean Y "))
        #expect(histogram.value.contains("2073600 samples"))

        let origin = try #require(item(.magnifierOrigin))
        #expect(origin.value == "(0, 0)" && origin.isDocumented)
        let header = try #require(item(.vendorFrameBlock(0xFFFF_FFFF)))
        #expect(!header.isDocumented && header.value.hasSuffix("(52 bytes)"))
        for type in Self.undocumentedSL2Blocks {
            let unknown = try #require(item(.vendorFrameBlock(type)))
            #expect(!unknown.isDocumented)
            #expect(!unknown.value.isEmpty && unknown.value == unknown.raw)
        }
        #expect(item(.vendorFrameBlock(0xE))?.value == nil)
        #expect(item(.vendorFrameBlock(0x14))?.value == "37 00 00 00 12 00 00 00 12 00 00 00")
        #expect(items.filter(\.isDocumented).count == 11)
    }

    @Test func jpegDimensionsOfBothFixtures() throws {
        let old = try CanonViewfinderParser.parse(fixture("evf-sl2.bin")).jpeg
        let oldSize = try #require(CanonViewfinderParser.jpegDimensions(old))
        #expect(oldSize.width == 960 && oldSize.height == 640)
        let new = try CanonViewfinderParser.parse(fixture("evf-sl2-fw110.bin")).jpeg
        let newSize = try #require(CanonViewfinderParser.jpegDimensions(new))
        #expect(newSize.width == 1024 && newSize.height == 576)
    }

    @Test func jpegDimensionsRejectsMalformedHeaders() throws {
        #expect(CanonViewfinderParser.jpegDimensions(Data()) == nil)
        #expect(CanonViewfinderParser.jpegDimensions(Data([0xFF, 0xD8, 0xFF, 0xC0])) == nil)
        #expect(CanonViewfinderParser.jpegDimensions(Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x00])) == nil)
        // Segment length runs past the end.
        #expect(CanonViewfinderParser.jpegDimensions(Data([0xFF, 0xD8, 0xFF, 0xE0, 0xFF, 0xFF, 0, 0])) == nil)
        let real = try CanonViewfinderParser.parse(fixture("evf-sl2.bin")).jpeg
        for length in 0..<min(real.count, 700) {
            _ = CanonViewfinderParser.jpegDimensions(real.prefix(length))
        }
    }

    @Test func focusFrameCountLargerThanPayloadIsKeptAsUnknown() throws {
        // count 2 but only one entry.
        let malformed = block(0x8, words: [2, 0x10, 1, 10, 20, 30, 40])
        let metadata = try CanonViewfinderParser.parse(minimalPayload(with: malformed)).metadata
        #expect(metadata.focusFrames == nil)
        #expect(metadata.unknownBlocks.map(\.type) == [0x8])
        // A huge count cannot overflow the size check.
        let huge = block(0x8, words: [0xFFFF_FFFF, 0, 0, 0, 0, 0, 0])
        #expect(try CanonViewfinderParser.parse(minimalPayload(with: huge)).metadata.unknownBlocks.map(\.type) == [0x8])
        // Trailing bytes after the declared entries are not silently ignored.
        let padded = block(0x8, words: [1, 0x11, 1, 10, 20, 30, 40, 0])
        #expect(try CanonViewfinderParser.parse(minimalPayload(with: padded)).metadata.focusFrames == nil)
    }

    @Test func publishedSingleFrameLayoutsDecode() throws {
        // FC.SDK 6D at 1×: `1,16,1,2460,1456,552,736`; Schroden 70D: `1,0x30,1,0x1150,0x206,0x1AE,0x1AE`.
        let sixD = try CanonViewfinderParser.parse(minimalPayload(with: block(0x8, words: [1, 16, 1, 2460, 1456, 552, 736])))
        #expect(sixD.metadata.focusFrames == [.init(state: .resting, unidentified: 1,
                                                    rect: .init(x: 2460, y: 1456, width: 552, height: 736))])
        let seventyD = try CanonViewfinderParser.parse(minimalPayload(with: block(0x8, words: [1, 0x30, 1, 0x1150, 0x206, 0x1AE, 0x1AE])))
        #expect(seventyD.metadata.focusFrames?.first?.state == .tracking)
        let items = seventyD.metadata.items(frameWidth: nil, frameHeight: nil)
        #expect(items.first { $0.kind == .focusPoints }?.value == "1 point, 430 × 430 at (4432, 518); tracking")
        #expect(!items.contains { $0.kind == .frameSize })
    }

    @Test func malformedAndRepeatedDocumentedBlocksStayUnknown() throws {
        let extra = block(0xE, words: [6000])  // too short
            + block(0x11, bytes: Data(count: 100))  // wrong histogram size
            + block(0x4, words: [5])
            + block(0x4, words: [10])  // repeat
            + block(0x7, words: [3])  // undocumented AF value
            + block(0x1, bytes: Data([0xFF, 0xD8, 0xFF, 0xD9]))  // second image
        let metadata = try CanonViewfinderParser.parse(minimalPayload(with: extra)).metadata
        #expect(metadata.sensorSize == nil && metadata.histogram == nil)
        #expect(metadata.magnification == 5)
        #expect(metadata.autofocus == .undocumented(3))
        #expect(metadata.unknownBlocks.map(\.type) == [0xE, 0x11, 0x4, 0x1])
        let items = metadata.items(frameWidth: nil, frameHeight: nil)
        let autofocus = try #require(items.first { $0.kind == .autofocusActive })
        #expect(autofocus.value == "Unknown (0x3)" && !autofocus.isDocumented)
        #expect(items.filter { !$0.isDocumented }.count == 5)
    }

    @Test func movieModeImageIsUsedOnlyWhenItIsAJPEG() throws {
        let jpeg = try CanonViewfinderParser.parse(fixture("evf-sl2.bin")).jpeg
        let movie = try CanonViewfinderParser.parse(block(0x9, bytes: Data(jpeg)) + terminator)
        #expect(movie.metadata.imageBlockType == .movieImage)
        #expect(movie.jpeg == jpeg)
        #expect(throws: CanonViewfinderError.imageNotJPEG) {
            try CanonViewfinderParser.parse(block(0x9, bytes: Data([1, 2, 3, 4, 5])) + terminator)
        }
        // With a JPEG block present, the movie block is kept but not used.
        let both = try CanonViewfinderParser.parse(block(0x9, bytes: Data([1, 2, 3, 4])) + block(0x1, bytes: Data(jpeg)) + terminator)
        #expect(both.metadata.imageBlockType == .image)
        #expect(both.metadata.unknownBlocks.map(\.type) == [0x9])
    }

    @Test func survivesRandomMutationOfFirmware110Payload() throws {
        let full = try fixture("evf-sl2-fw110.bin")
        var state: UInt64 = 11
        func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 11 }
        // Mutate the metadata blocks after the JPEG (histogram, 0x8 count and entries).
        let tailStart = full.count - 1188 - 8 - 4104 - 200
        for _ in 0..<300 {
            var mutated = full
            for _ in 0..<4 { mutated[tailStart + Int(next() % UInt64(full.count - tailStart))] = UInt8(truncatingIfNeeded: next()) }
            if let frame = try? CanonViewfinderParser.parse(mutated) {
                _ = frame.metadata.items(frameWidth: 1, frameHeight: 1)
            }
        }
    }
}
