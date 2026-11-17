public import Foundation
public import MirrorupCapture

/// Parsed GetViewfinderData payload.
public struct CanonViewfinderFrame: Sendable {
    /// JPEG bytes as a slice of the original payload (no copy).
    public var jpeg: Data
    /// Block types present, in order, for diagnostics.
    public var blockTypes: [UInt32]
    /// Everything else the camera sent with the image, decoded where a source documents the block.
    public var metadata: CanonViewfinderMetadata
}

public enum CanonViewfinderError: Error, Sendable, Equatable, CustomStringConvertible {
    case blockLengthInvalid(offset: Int, length: UInt32)
    case noImageBlock(types: [UInt32])
    case imageNotJPEG
    case jpegTruncated

    public var description: String {
        switch self {
        case .blockLengthInvalid(let offset, let length): "EVF block at \(offset) has invalid length \(length)"
        case .noImageBlock(let types): "EVF payload has no image block (types: \(types.map { String($0, radix: 16) }))"
        case .imageNotJPEG: "EVF image block does not start with a JPEG SOI marker"
        case .jpegTruncated: "EVF JPEG has no EOI marker"
        }
    }
}

/// GetViewfinderData block types with a documented meaning (docs/canon-eos-ptp.md §4.2). Types not
/// listed here (0xC, 0xF, 0x10, 0x13, 0x14, 0x15 on the SL2) have no public decoding.
public enum CanonViewfinderBlockType: UInt32, Sendable, CaseIterable {
    /// `(8, 0)` ends the payload.
    case terminator = 0x0
    /// Live-view JPEG.
    case image = 0x1
    /// Magnification factor: 1, 5 or 10.
    case magnification = 0x4
    /// Magnifier origin `x, y` in sensor pixels (the first half of `magnifierRect`).
    case magnifierOrigin = 0x5
    /// 1 at rest, 2 while the body drives autofocus.
    case autofocusActivity = 0x7
    /// `count` then `count × [state, u32, x, y, w, h]` AF frames in sensor pixels.
    case focusFrames = 0x8
    /// Image in movie mode (libgphoto2 tags it as raw data, not JPEG).
    case movieImage = 0x9
    /// Unix timestamp then a counter.
    case timestamp = 0xA
    /// JPEG (variant numbering on some bodies).
    case imageVariant = 0xB
    /// Magnifier rect `x, y, w, h` in sensor pixels.
    case magnifierRect = 0xD
    /// Full sensor size `w, h`.
    case sensorSize = 0xE
    /// Planar Y, R, G, B histogram: 4 × 256 bins × u32.
    case histogram = 0x11
    /// Zoom rect: origin of the image sent, then size of the area shown, in sensor pixels.
    case zoomRect = 0x12
    /// Frame header; its fields have no public decoding.
    case header = 0xFFFF_FFFF
}

/// Per-frame metadata from a GetViewfinderData payload. Every block except the image and the
/// terminator is kept: documented blocks as typed fields, everything else (undocumented types,
/// malformed or repeated documented blocks) in `unknownBlocks`. All payloads are slices of the
/// original buffer; parsing formats nothing — `items` does that on demand.
public struct CanonViewfinderMetadata: Sendable, Equatable {
    public struct Point: Sendable, Equatable {
        public var x: UInt32
        public var y: UInt32
        public init(x: UInt32, y: UInt32) { self.x = x; self.y = y }
    }

    public struct Size: Sendable, Equatable {
        public var width: UInt32
        public var height: UInt32
        public init(width: UInt32, height: UInt32) { self.width = width; self.height = height }
    }

    /// Rectangle in sensor pixels.
    public struct Rect: Sendable, Equatable {
        public var x: UInt32
        public var y: UInt32
        public var width: UInt32
        public var height: UInt32
        public init(x: UInt32, y: UInt32, width: UInt32, height: UInt32) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
    }

    /// Block 0x7. FC.SDK: 1 at rest, 2 while the body drives AF.
    public enum AutofocusActivity: Sendable, Equatable {
        case idle
        case focusing
        case undocumented(UInt32)

        public init(code: UInt32) {
            switch code {
            case 1: self = .idle
            case 2: self = .focusing
            default: self = .undocumented(code)
            }
        }

        public var code: UInt32 {
            switch self {
            case .idle: 1
            case .focusing: 2
            case .undocumented(let code): code
            }
        }
    }

    /// One AF frame of block 0x8.
    public struct FocusFrame: Sendable, Equatable {
        /// First word of the entry. FC.SDK (6D/R6): 0x10 at rest, 0x11 focus achieved. Schroden
        /// (70D): 0x30 tracking, 0x20 face tracking. The SL2 sends 0 in FlexiZone-Multi (undocumented).
        public enum State: Sendable, Equatable {
            case resting
            case focused
            case faceTracking
            case tracking
            case undocumented(UInt32)

            public init(code: UInt32) {
                switch code {
                case 0x10: self = .resting
                case 0x11: self = .focused
                case 0x20: self = .faceTracking
                case 0x30: self = .tracking
                default: self = .undocumented(code)
                }
            }

            public var code: UInt32 {
                switch self {
                case .resting: 0x10
                case .focused: 0x11
                case .faceTracking: 0x20
                case .tracking: 0x30
                case .undocumented(let code): code
                }
            }
        }

        public var state: State
        /// Second word of the entry; 1 in every published capture and on the SL2, meaning unknown.
        public var unidentified: UInt32
        public var rect: Rect

        public init(state: State, unidentified: UInt32, rect: Rect) {
            self.state = state; self.unidentified = unidentified; self.rect = rect
        }
    }

    /// Block 0xA: camera clock and a counter.
    public struct Timestamp: Sendable, Equatable {
        /// Seconds since 1970-01-01 UTC.
        public var seconds: UInt32
        public var counter: UInt32
        public init(seconds: UInt32, counter: UInt32) { self.seconds = seconds; self.counter = counter }
        public var date: Date { Date(timeIntervalSince1970: TimeInterval(seconds)) }
    }

    /// Block 0x11: planar Y, R, G, B histogram of 256 u32 bins each, linear in light (FC.SDK).
    /// Kept as a slice of the payload; accessors read it on demand.
    public struct Histogram: Sendable, Equatable {
        public enum Channel: Int, Sendable, CaseIterable {
            case luminance, red, green, blue
        }

        public static let binCount = 256
        public static let byteCount = 4 * binCount * 4

        /// Exactly `byteCount` bytes.
        public let payload: Data

        public init?(payload: Data) {
            guard payload.count == Self.byteCount else { return nil }
            self.payload = payload
        }

        public func count(_ channel: Channel, bin: Int) -> UInt32 {
            precondition((0..<Self.binCount).contains(bin), "histogram bin out of range")
            return payload.withUnsafeBytes { Self.word($0, channel, bin) }
        }

        public func bins(_ channel: Channel) -> [UInt32] {
            payload.withUnsafeBytes { raw in (0..<Self.binCount).map { Self.word(raw, channel, $0) } }
        }

        /// Number of samples counted in `channel`.
        public func total(_ channel: Channel) -> UInt64 {
            payload.withUnsafeBytes { raw in
                (0..<Self.binCount).reduce(UInt64(0)) { $0 + UInt64(Self.word(raw, channel, $1)) }
            }
        }

        /// Mean level as a fraction of full scale (bin 255), or nil when the channel is empty.
        public func meanLevel(_ channel: Channel) -> Double? {
            payload.withUnsafeBytes { raw in
                var total: UInt64 = 0
                var weighted: UInt64 = 0
                for bin in 0..<Self.binCount {
                    let count = UInt64(Self.word(raw, channel, bin))
                    total += count
                    weighted += count * UInt64(bin)
                }
                guard total > 0 else { return nil }
                return Double(weighted) / Double(total) / Double(Self.binCount - 1)
            }
        }

        /// Share of `channel`'s samples in `bin`, or nil when the channel is empty.
        public func fraction(_ channel: Channel, bin: Int) -> Double? {
            let total = total(channel)
            guard total > 0 else { return nil }
            return Double(count(channel, bin: bin)) / Double(total)
        }

        private static func word(_ raw: UnsafeRawBufferPointer, _ channel: Channel, _ bin: Int) -> UInt32 {
            UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: (channel.rawValue * binCount + bin) * 4, as: UInt32.self))
        }
    }

    /// One payload block, as a slice of the original buffer.
    public struct Block: Sendable, Equatable {
        public var type: UInt32
        public var payload: Data
        /// true when a typed field (or the frame's image) holds this block's content.
        public var isDecoded: Bool
        public init(type: UInt32, payload: Data, isDecoded: Bool) {
            self.type = type; self.payload = payload; self.isDecoded = isDecoded
        }
    }

    /// Block that carried the image (0x1, 0x9 or 0xB).
    public var imageBlockType: CanonViewfinderBlockType?
    /// 0xFFFFFFFF, kept raw: no source decodes its fields.
    public var header: Data?
    public var magnification: UInt32?
    public var magnifierOrigin: Point?
    public var autofocus: AutofocusActivity?
    public var focusFrames: [FocusFrame]?
    public var timestamp: Timestamp?
    public var magnifierRect: Rect?
    public var sensorSize: Size?
    public var histogram: Histogram?
    public var zoomRect: Rect?
    /// Every block except the terminator, in payload order.
    public var blocks: [Block]

    public init() {
        blocks = []
    }

    /// Blocks no typed field holds: undocumented types, and documented ones that were malformed or
    /// repeated. Nothing the camera sends is dropped.
    public var unknownBlocks: [Block] { blocks.filter { !$0.isDecoded } }

    /// Decodes a documented block into its field. Returns false (block stays unknown) for
    /// undocumented types, images, wrong sizes, and repeats of a block already decoded.
    mutating func absorb(type: UInt32, payload: Data) -> Bool {
        guard let known = CanonViewfinderBlockType(rawValue: type) else { return false }
        let n = payload.count
        switch known {
        case .header:
            guard header == nil else { return false }
            header = payload
        case .magnification:
            guard magnification == nil, n == 4 else { return false }
            magnification = Self.u32(payload, 0)
        case .magnifierOrigin:
            guard magnifierOrigin == nil, n == 8 else { return false }
            magnifierOrigin = Point(x: Self.u32(payload, 0), y: Self.u32(payload, 4))
        case .autofocusActivity:
            guard autofocus == nil, n == 4 else { return false }
            autofocus = AutofocusActivity(code: Self.u32(payload, 0))
        case .focusFrames:
            guard focusFrames == nil, let frames = Self.decodeFocusFrames(payload) else { return false }
            focusFrames = frames
        case .timestamp:
            guard timestamp == nil, n == 8 else { return false }
            timestamp = Timestamp(seconds: Self.u32(payload, 0), counter: Self.u32(payload, 4))
        case .magnifierRect:
            guard magnifierRect == nil, n == 16 else { return false }
            magnifierRect = Self.rect(payload, 0)
        case .sensorSize:
            guard sensorSize == nil, n == 8 else { return false }
            sensorSize = Size(width: Self.u32(payload, 0), height: Self.u32(payload, 4))
        case .histogram:
            guard histogram == nil, let decoded = Histogram(payload: payload) else { return false }
            histogram = decoded
        case .zoomRect:
            guard zoomRect == nil, n == 16 else { return false }
            zoomRect = Self.rect(payload, 0)
        case .image, .imageVariant, .movieImage, .terminator:
            return false
        }
        return true
    }

    static let focusFrameEntrySize = 24

    /// `[u32 count][count × (state, u32, x, y, w, h)]`; the payload must be exactly that long.
    static func decodeFocusFrames(_ payload: Data) -> [FocusFrame]? {
        guard payload.count >= 4 else { return nil }
        let count = Int(u32(payload, 0))
        guard count <= (payload.count - 4) / focusFrameEntrySize,
              payload.count == 4 + count * focusFrameEntrySize
        else { return nil }
        var frames: [FocusFrame] = []
        frames.reserveCapacity(count)
        for index in 0..<count {
            let at = 4 + index * focusFrameEntrySize
            frames.append(FocusFrame(state: FocusFrame.State(code: u32(payload, at)),
                                     unidentified: u32(payload, at + 4),
                                     rect: rect(payload, at + 8)))
        }
        return frames
    }

    static func u32(_ data: Data, _ at: Int) -> UInt32 {
        let i = data.startIndex + at
        return UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
    }

    static func rect(_ data: Data, _ at: Int) -> Rect {
        Rect(x: u32(data, at), y: u32(data, at + 4), width: u32(data, at + 8), height: u32(data, at + 12))
    }
}

// MARK: - Human-readable items

extension CanonViewfinderMetadata {
    /// Human-readable items for this frame. `frameWidth`/`frameHeight` are the decoded image size
    /// (see `CanonViewfinderParser.jpegDimensions`). The camera clock is shown in `timeZone`.
    public func items(frameWidth: Int?, frameHeight: Int?, timeZone: TimeZone = .current) -> [CameraMetadata.Item] {
        var items: [CameraMetadata.Item] = []
        func raw(_ type: CanonViewfinderBlockType) -> String {
            blocks.first { $0.isDecoded && $0.type == type.rawValue }.map { Self.hex($0.payload) } ?? ""
        }

        if let frameWidth, let frameHeight {
            let image = imageBlockType.flatMap { type in blocks.first { $0.isDecoded && $0.type == type.rawValue } }
            let source = image.map { "block 0x\(Self.hexCode($0.type)), \($0.payload.count) bytes" } ?? ""
            items.append(.init(.frameSize, value: "\(frameWidth) × \(frameHeight)", raw: source))
        }
        if let sensorSize {
            items.append(.init(.sensorSize, value: "\(sensorSize.width) × \(sensorSize.height)", raw: raw(.sensorSize)))
        }
        if let magnification {
            items.append(.init(.zoom, value: "\(magnification)×", raw: raw(.magnification)))
        }
        if let zoomRect {
            items.append(.init(.zoomRect, value: Self.describe(zoomRect), raw: raw(.zoomRect)))
        }
        if let magnifierRect {
            items.append(.init(.magnifierRect, value: Self.describe(magnifierRect), raw: raw(.magnifierRect)))
        }
        if let magnifierOrigin {
            items.append(.init(.magnifierOrigin, value: "(\(magnifierOrigin.x), \(magnifierOrigin.y))",
                               raw: raw(.magnifierOrigin)))
        }
        if let autofocus {
            let value: String
            let documented: Bool
            switch autofocus {
            case .idle: value = "Idle"; documented = true
            case .focusing: value = "Focusing"; documented = true
            case .undocumented(let code): value = "Unknown (0x\(Self.hexCode(code)))"; documented = false
            }
            items.append(.init(.autofocusActive, value: value, raw: raw(.autofocusActivity), isDocumented: documented))
        }
        if let focusFrames {
            items.append(.init(.focusPoints, value: Self.describe(focusFrames), raw: raw(.focusFrames)))
        }
        if let timestamp {
            let time = Date.ISO8601FormatStyle(timeZone: timeZone).format(timestamp.date)
            items.append(.init(.cameraTimestamp, value: time, raw: raw(.timestamp)))
            items.append(.init(.frameCounter, value: "\(timestamp.counter)", raw: raw(.timestamp)))
        }
        if let histogram {
            items.append(.init(.histogram, value: Self.describe(histogram), raw: raw(.histogram)))
        }
        if let header {
            let hex = Self.hex(header)
            items.append(.init(.vendorFrameBlock(CanonViewfinderBlockType.header.rawValue), label: "Frame Header",
                               value: hex, raw: hex, isDocumented: false))
        }
        for block in blocks where !block.isDecoded {
            let hex = block.payload.isEmpty ? "empty" : Self.hex(block.payload)
            items.append(.init(.vendorFrameBlock(block.type), value: hex, raw: hex, isDocumented: false))
        }
        return items
    }

    static let hexByteLimit = 32

    /// Space-separated hex bytes; long payloads keep the first `hexByteLimit` bytes plus the length.
    static func hex(_ data: Data) -> String {
        var text = data.prefix(hexByteLimit).map { byte in
            let digits = String(byte, radix: 16, uppercase: true)
            return byte < 0x10 ? "0" + digits : digits
        }.joined(separator: " ")
        if data.count > hexByteLimit { text += " … (\(data.count) bytes)" }
        return text
    }

    static func hexCode(_ value: UInt32) -> String { String(value, radix: 16, uppercase: true) }

    static func describe(_ rect: Rect) -> String {
        "\(rect.width) × \(rect.height) at (\(rect.x), \(rect.y))"
    }

    static func describe(_ frames: [FocusFrame]) -> String {
        guard let first = frames.first else { return "None" }
        var parts: [String] = []
        if frames.count == 1 {
            parts.append("1 point, " + describe(first.rect))
        } else {
            var text = "\(frames.count) points"
            if frames.allSatisfy({ $0.rect.width == first.rect.width && $0.rect.height == first.rect.height }) {
                let columns = Set(frames.map(\.rect.x)).count
                let rows = Set(frames.map(\.rect.y)).count
                if columns * rows == frames.count, columns > 1, rows > 1 {
                    text += " in a \(columns) × \(rows) grid"
                }
                text += ", each \(first.rect.width) × \(first.rect.height)"
            }
            let minX = frames.map(\.rect.x).min() ?? 0
            let minY = frames.map(\.rect.y).min() ?? 0
            let maxX = frames.map { UInt64($0.rect.x) + UInt64($0.rect.width) }.max() ?? 0
            let maxY = frames.map { UInt64($0.rect.y) + UInt64($0.rect.height) }.max() ?? 0
            text += ", covering \(maxX - UInt64(minX)) × \(maxY - UInt64(minY)) at (\(minX), \(minY))"
            parts.append(text)
        }
        // State tally in first-seen order.
        var states: [(FocusFrame.State, Int)] = []
        for frame in frames {
            if let index = states.firstIndex(where: { $0.0 == frame.state }) {
                states[index].1 += 1
            } else {
                states.append((frame.state, 1))
            }
        }
        let tally = states.map { state, count in
            let name = switch state {
            case .resting: "at rest"
            case .focused: "in focus"
            case .faceTracking: "face tracking"
            case .tracking: "tracking"
            case .undocumented(let code): "undocumented state 0x\(hexCode(code))"
            }
            return frames.count == 1 ? name : "\(count) \(name)"
        }
        parts.append(tally.joined(separator: ", "))
        return parts.joined(separator: "; ")
    }

    static func describe(_ histogram: Histogram) -> String {
        let channels: [(Histogram.Channel, String)] = [(.luminance, "Y"), (.red, "R"), (.green, "G"), (.blue, "B")]
        let samples = histogram.total(.luminance)
        guard samples > 0 else { return "No samples" }
        func percent(_ value: Double?) -> String {
            guard let value else { return "–" }
            return String(format: "%.1f%%", value * 100)
        }
        func list(_ value: (Histogram.Channel) -> Double?) -> String {
            channels.map { "\($0.1) \(percent(value($0.0)))" }.joined(separator: " ")
        }
        let mean = list { histogram.meanLevel($0) }
        let highlights = list { histogram.fraction($0, bin: Histogram.binCount - 1) }
        let shadows = list { histogram.fraction($0, bin: 0) }
        return "Mean \(mean) · Highlights clipped \(highlights) · Shadows clipped \(shadows) · \(samples) samples"
    }
}

// MARK: - Parser

/// Parser for the EOS live-view payload: blocks of `[u32 length incl. header][u32 type][payload]`
/// (docs/canon-eos-ptp.md §4.2). Type 1 (and 11 on some bodies) carries the JPEG; type 9 (movie
/// mode) is used only when no JPEG block is present and it holds a JPEG.
public enum CanonViewfinderParser {
    public static let jpegBlockTypes: Set<UInt32> = [
        CanonViewfinderBlockType.image.rawValue, CanonViewfinderBlockType.imageVariant.rawValue,
    ]

    public static func parse(_ data: Data) throws(CanonViewfinderError) -> CanonViewfinderFrame {
        var offset = 0
        var types: [UInt32] = []
        var metadata = CanonViewfinderMetadata()
        var jpegIndex: Int?
        var movieIndex: Int?
        let base = data.startIndex
        func u32(_ at: Int) -> UInt32 {
            let i = base + at
            return UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
        }
        while offset + 8 <= data.count {
            let length = u32(offset)
            let type = u32(offset + 4)
            if length == 8 && type == CanonViewfinderBlockType.terminator.rawValue { break }
            guard length >= 8, Int(length) <= data.count - offset else {
                throw .blockLengthInvalid(offset: offset, length: length)
            }
            types.append(type)
            let payload = data[(base + offset + 8)..<(base + offset + Int(length))]
            let decoded = metadata.absorb(type: type, payload: payload)
            if jpegIndex == nil, jpegBlockTypes.contains(type) {
                jpegIndex = metadata.blocks.count
            } else if movieIndex == nil, type == CanonViewfinderBlockType.movieImage.rawValue {
                movieIndex = metadata.blocks.count
            }
            metadata.blocks.append(.init(type: type, payload: payload, isDecoded: decoded))
            offset += Int(length)
        }
        guard let imageIndex = jpegIndex ?? movieIndex else { throw .noImageBlock(types: types) }
        let jpeg = metadata.blocks[imageIndex].payload
        try validateJPEG(jpeg)
        metadata.blocks[imageIndex].isDecoded = true
        metadata.imageBlockType = CanonViewfinderBlockType(rawValue: metadata.blocks[imageIndex].type)
        return CanonViewfinderFrame(jpeg: jpeg, blockTypes: types, metadata: metadata)
    }

    /// Checks the SOI marker and an EOI marker near the end (encoders may pad after EOI).
    static func validateJPEG(_ jpeg: Data) throws(CanonViewfinderError) {
        guard jpeg.count >= 4, jpeg[jpeg.startIndex] == 0xFF, jpeg[jpeg.startIndex + 1] == 0xD8 else {
            throw .imageNotJPEG
        }
        let tailStart = max(jpeg.startIndex + 2, jpeg.endIndex - 64)
        var i = jpeg.endIndex - 2
        while i >= tailStart {
            if jpeg[i] == 0xFF && jpeg[i + 1] == 0xD9 { return }
            i -= 1
        }
        throw .jpegTruncated
    }

    /// Pixel dimensions from the first start-of-frame segment (SOF0–SOF15 except DHT 0xC4, JPG 0xC8,
    /// DAC 0xCC), or nil when the header is malformed or ends first. Walks marker segments only;
    /// never allocates.
    public static func jpegDimensions(_ jpeg: Data) -> (width: Int, height: Int)? {
        let start = jpeg.startIndex
        let end = jpeg.endIndex
        guard jpeg.count >= 4, jpeg[start] == 0xFF, jpeg[start + 1] == 0xD8 else { return nil }
        var i = start + 2
        while i + 4 <= end {
            guard jpeg[i] == 0xFF else { return nil }
            let marker = jpeg[i + 1]
            if marker == 0xFF { i += 1; continue }  // fill byte
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }  // no length
            if marker == 0xD9 || marker == 0xDA { return nil }  // EOI / start of scan before any SOF
            let length = Int(jpeg[i + 2]) << 8 | Int(jpeg[i + 3])
            guard length >= 2 else { return nil }
            if (0xC0...0xCF).contains(marker), marker != 0xC4, marker != 0xC8, marker != 0xCC {
                // [length:2][precision:1][height:2][width:2]
                guard length >= 7, i + 9 <= end else { return nil }
                let height = Int(jpeg[i + 5]) << 8 | Int(jpeg[i + 6])
                let width = Int(jpeg[i + 7]) << 8 | Int(jpeg[i + 8])
                guard width > 0, height > 0 else { return nil }
                return (width, height)
            }
            i += 2 + length
        }
        return nil
    }
}
