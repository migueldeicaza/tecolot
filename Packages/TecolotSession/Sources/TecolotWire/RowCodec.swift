//
// RowCodec.swift
// TecolotWire
//
// Encodes one terminal row as a compact, stateless byte stream. The helper
// hashes the encoded bytes to produce the row version, so identical rows have
// identical versions on every connection.
//
// Payload layout:
//
//     u8      flags            RowFlags
//     varint  columns
//     u8      bidi state       if flags contains .bidi
//     u8      render mode      if flags contains .renderMode
//     marks                    if flags contains .marks: varint count, (u8 kind, varint column)*
//     images                   if flags contains .images: varint count, then for each slice
//                              varint image ID, varint column, and f32 width, height,
//                              source y, source height (see WireRowImage)
//     ops...                   until the end of the payload
//
// The .rightToLeft flag has no payload. Decoders ignore flags they do not
// know, but not sections: a row with images needs a decoder that knows the
// images section (the helper and the app that starts it are one release).
//
// Each op either produces cells or changes the style that later cells use:
//
//     0x00          one null cell (never written; distinct from a space)
//     0x20...0x7E   one ASCII cell
//     0x01 attr     set the attribute
//     0x02 varint   set the hyperlink ID (0 = none)
//     0x03 u8       set the semantic role (bits 0-2) and protection (bit 3)
//     0x04 blob     one narrow grapheme cell (UTF-8)
//     0x05 blob     one wide grapheme cell (UTF-8); the next cell is sent as 0x06
//     0x06          one spacer cell (width 0)
//     0x07 varint   repeat the previous cell n more times
//     0x08 u8 blob  one grapheme cell with an explicit width
//
// Cells that the ops do not produce are null cells in the plain style. So the
// encoder drops trailing plain null cells.
//

/// A color as SwiftTerm stores it in a cell attribute.
public enum WireColor: Hashable, Sendable {
    case `default`
    case defaultInverted
    case ansi(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

/// A cell attribute. The fields mirror SwiftTerm's `Attribute`.
public struct WireAttribute: Hashable, Sendable {
    public var foreground: WireColor
    public var background: WireColor
    /// SwiftTerm `CharacterStyle` raw value.
    public var style: UInt8
    /// SwiftTerm `UnderlineStyle` raw value.
    public var underlineStyle: UInt8
    public var underlineColor: WireColor?

    public init(foreground: WireColor = .default, background: WireColor = .default,
                style: UInt8 = 0, underlineStyle: UInt8 = 0, underlineColor: WireColor? = nil) {
        self.foreground = foreground
        self.background = background
        self.style = style
        self.underlineStyle = underlineStyle
        self.underlineColor = underlineColor
    }

    /// The attribute that cells have before any style op.
    public static let plain = WireAttribute()
}

/// The per-cell values that change rarely along a row.
public struct WireCellStyle: Hashable, Sendable {
    public var attribute: WireAttribute
    /// Hyperlink identifier from a `DefineLinks` table; 0 means none.
    public var link: UInt32
    /// SwiftTerm `SemanticContent` code: 0 none, 1-4 prompt kinds, 5 input, 6 output.
    public var semantic: UInt8
    public var isProtected: Bool

    public init(attribute: WireAttribute = .plain, link: UInt32 = 0,
                semantic: UInt8 = 0, isProtected: Bool = false) {
        self.attribute = attribute
        self.link = link
        self.semantic = semantic
        self.isProtected = isProtected
    }

    public static let plain = WireCellStyle()
}

/// The content of one cell.
public enum WireCellContent: Hashable, Sendable {
    /// A cell that was never written (SwiftTerm code 0).
    case null
    /// A printable ASCII character, 0x20...0x7E.
    case ascii(UInt8)
    /// A grapheme cluster with its width in cells.
    case grapheme(String, width: UInt8)
    /// The width-0 cell that follows a wide character.
    case spacer

    public var width: Int {
        switch self {
        case .null, .ascii: return 1
        case .grapheme(_, let width): return Int(width)
        case .spacer: return 0
        }
    }
}

public struct WireCell: Hashable, Sendable {
    public var content: WireCellContent
    public var style: WireCellStyle

    public init(_ content: WireCellContent, style: WireCellStyle = .plain) {
        self.content = content
        self.style = style
    }
}

public struct RowFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// This row continues the previous row (SwiftTerm `isWrapped`).
    public static let wrapped = RowFlags(rawValue: 1)
    public static let bidi = RowFlags(rawValue: 2)
    public static let renderMode = RowFlags(rawValue: 4)
    public static let marks = RowFlags(rawValue: 8)
    /// The row has inline image slices (Sixel, iTerm2).
    public static let images = RowFlags(rawValue: 16)
    /// The row has characters that can start right-to-left text (Hebrew,
    /// Arabic, bidi controls), so its paragraph may need bidi layout.
    public static let rightToLeft = RowFlags(rawValue: 32)
}

/// One slice of an inline image on a row, as `Terminal.insertRasterImage`
/// attaches them: drawn at `column` from the top of the row, `width` ×
/// `height` device pixels, showing image rows `sourceY ..< sourceY +
/// sourceHeight`. Fetch the pixels with `FetchImage(imageID)`.
public struct WireRowImage: Hashable, Sendable {
    public var imageID: UInt64
    public var column: Int
    public var width: Float
    public var height: Float
    public var sourceY: Float
    public var sourceHeight: Float

    public init(imageID: UInt64, column: Int, width: Float, height: Float, sourceY: Float, sourceHeight: Float) {
        self.imageID = imageID
        self.column = column
        self.width = width
        self.height = height
        self.sourceY = sourceY
        self.sourceHeight = sourceHeight
    }
}

/// An OSC 133 prompt mark on a row.
public struct WireSemanticMark: Hashable, Sendable {
    /// 1 initial, 2 right, 3 continuation, 4 secondary.
    public var kind: UInt8
    public var column: Int

    public init(kind: UInt8, column: Int) {
        self.kind = kind
        self.column = column
    }
}

/// Row-level metadata.
public struct WireRowHeader: Hashable, Sendable {
    public var columns: Int
    public var isWrapped: Bool
    /// Packed `BidiPresentationState`: bit 0 explicit, bit 1 autodetect,
    /// bit 2 right-to-left, bit 3 box mirroring. Nil means the default state.
    public var bidi: UInt8?
    /// 0 single, 1 double width, 2 double height top, 3 double height bottom.
    public var renderMode: UInt8
    public var marks: [WireSemanticMark]
    public var images: [WireRowImage]
    /// The row may need bidi layout (see `RowFlags.rightToLeft`).
    public var rightToLeft: Bool

    public var hasImages: Bool { !images.isEmpty }

    public init(columns: Int, isWrapped: Bool = false, bidi: UInt8? = nil,
                renderMode: UInt8 = 0, marks: [WireSemanticMark] = [], images: [WireRowImage] = [],
                rightToLeft: Bool = false) {
        self.columns = columns
        self.isWrapped = isWrapped
        self.bidi = bidi
        self.renderMode = renderMode
        self.marks = marks
        self.images = images
        self.rightToLeft = rightToLeft
    }
}

enum RowOp {
    static let null: UInt8 = 0x00
    static let style: UInt8 = 0x01
    static let link: UInt8 = 0x02
    static let semantic: UInt8 = 0x03
    static let narrow: UInt8 = 0x04
    static let wide: UInt8 = 0x05
    static let spacer: UInt8 = 0x06
    static let repeatPrevious: UInt8 = 0x07
    static let sized: UInt8 = 0x08
}

/// Builds row payloads. Reuse one encoder to avoid allocations.
public struct RowEncoder: Sendable {
    private var writer = WireWriter(capacity: 512)
    private var columns = 0
    private var produced = 0
    private var style = WireCellStyle.plain
    // The last emitted cell, for repeat runs.
    private var last: WireCellContent?
    private var lastIsOneByte = false
    private var lastByte: UInt8 = 0
    private var lastSignificant = false
    private var pendingRepeats = 0
    // The payload length up to the last cell that is not a plain null cell.
    private var significantEnd = 0

    public init() {}

    /// Starts a new row. Cells beyond `header.columns` are ignored.
    public mutating func begin(_ header: WireRowHeader) {
        writer.removeAll()
        columns = header.columns
        produced = 0
        style = .plain
        last = nil
        pendingRepeats = 0

        var flags: RowFlags = []
        if header.isWrapped { flags.insert(.wrapped) }
        if header.bidi != nil { flags.insert(.bidi) }
        if header.renderMode != 0 { flags.insert(.renderMode) }
        if !header.marks.isEmpty { flags.insert(.marks) }
        if header.hasImages { flags.insert(.images) }
        if header.rightToLeft { flags.insert(.rightToLeft) }
        writer.u8(flags.rawValue)
        writer.varint(header.columns)
        if let bidi = header.bidi { writer.u8(bidi) }
        if header.renderMode != 0 { writer.u8(header.renderMode) }
        if !header.marks.isEmpty {
            writer.varint(header.marks.count)
            for mark in header.marks {
                writer.u8(mark.kind)
                writer.varint(mark.column)
            }
        }
        if header.hasImages {
            writer.varint(header.images.count)
            for image in header.images {
                writer.varint(image.imageID)
                writer.varint(image.column)
                writer.u32(image.width.bitPattern)
                writer.u32(image.height.bitPattern)
                writer.u32(image.sourceY.bitPattern)
                writer.u32(image.sourceHeight.bitPattern)
            }
        }
        significantEnd = writer.count
    }

    /// Marks the row as possibly right-to-left (`RowFlags.rightToLeft`) after
    /// `begin`, for encoders that find out while they append cells.
    public mutating func markRightToLeft() {
        writer.setBits(RowFlags.rightToLeft.rawValue, at: 0)
    }

    /// Appends one cell.
    public mutating func append(_ content: WireCellContent, style newStyle: WireCellStyle) {
        guard produced < columns else { return }
        produced += 1
        if newStyle == style, let last, last == content {
            pendingRepeats += 1
            if lastSignificant { markSignificantAfterRepeats = true }
            return
        }
        flushRepeats()
        if newStyle != style {
            emitStyleChanges(from: style, to: newStyle)
            style = newStyle
        }
        let significant = !(content == .null && style == .plain)
        switch content {
        case .null:
            writer.u8(RowOp.null)
            lastIsOneByte = true
            lastByte = RowOp.null
        case .ascii(let byte):
            precondition(byte >= 0x20 && byte <= 0x7e, "ASCII cell outside 0x20...0x7E")
            writer.u8(byte)
            lastIsOneByte = true
            lastByte = byte
        case .spacer:
            writer.u8(RowOp.spacer)
            lastIsOneByte = true
            lastByte = RowOp.spacer
        case .grapheme(let text, let width):
            switch width {
            case 1: writer.u8(RowOp.narrow)
            case 2: writer.u8(RowOp.wide)
            default:
                writer.u8(RowOp.sized)
                writer.u8(width)
            }
            writer.string(text)
            lastIsOneByte = false
        }
        last = content
        lastSignificant = significant
        if significant { significantEnd = writer.count }
    }

    /// Returns the payload for the row started with `begin`.
    public mutating func finish() -> [UInt8] {
        flushRepeats()
        writer.truncate(to: significantEnd)
        return writer.bytes
    }

    private var markSignificantAfterRepeats = false

    private mutating func flushRepeats() {
        guard pendingRepeats > 0 else { return }
        if lastIsOneByte && pendingRepeats <= 2 {
            for _ in 0 ..< pendingRepeats { writer.u8(lastByte) }
        } else {
            writer.u8(RowOp.repeatPrevious)
            writer.varint(pendingRepeats)
        }
        pendingRepeats = 0
        if markSignificantAfterRepeats {
            significantEnd = writer.count
            markSignificantAfterRepeats = false
        }
    }

    private mutating func emitStyleChanges(from old: WireCellStyle, to new: WireCellStyle) {
        if old.attribute != new.attribute {
            writer.u8(RowOp.style)
            Self.encode(new.attribute, to: &writer)
        }
        if old.link != new.link {
            writer.u8(RowOp.link)
            writer.varint(new.link)
        }
        if old.semantic != new.semantic || old.isProtected != new.isProtected {
            writer.u8(RowOp.semantic)
            writer.u8((new.semantic & 0x7) | (new.isProtected ? 0x8 : 0))
        }
    }

    static func encode(_ attribute: WireAttribute, to writer: inout WireWriter) {
        var mask: UInt8 = 0
        if attribute.style != 0 { mask |= 1 }
        if attribute.underlineStyle != 0 { mask |= 2 }
        if attribute.underlineColor != nil { mask |= 4 }
        writer.u8(mask)
        encode(attribute.foreground, to: &writer)
        encode(attribute.background, to: &writer)
        if attribute.style != 0 { writer.u8(attribute.style) }
        if attribute.underlineStyle != 0 { writer.u8(attribute.underlineStyle) }
        if let color = attribute.underlineColor { encode(color, to: &writer) }
    }

    static func encode(_ color: WireColor, to writer: inout WireWriter) {
        switch color {
        case .default: writer.u8(0)
        case .defaultInverted: writer.u8(1)
        case .ansi(let code):
            writer.u8(2)
            writer.u8(code)
        case .rgb(let red, let green, let blue):
            writer.u8(3)
            writer.u8(red)
            writer.u8(green)
            writer.u8(blue)
        }
    }
}

/// Decodes row payloads.
public enum RowDecoder {
    /// Decodes the header and calls `body` once per cell, in column order,
    /// for every column of the row (missing trailing cells are plain nulls).
    public static func decode(_ payload: [UInt8], range: Range<Int>? = nil,
                              cell body: (Int, WireCellContent, WireCellStyle) throws -> Void)
        throws -> WireRowHeader {
        var reader = range.map { WireReader(payload, range: $0) } ?? WireReader(payload)
        let flags = RowFlags(rawValue: try reader.u8())
        let columns = try reader.count(limit: 65_535)
        var header = WireRowHeader(columns: columns, isWrapped: flags.contains(.wrapped),
                                   rightToLeft: flags.contains(.rightToLeft))
        if flags.contains(.bidi) { header.bidi = try reader.u8() }
        if flags.contains(.renderMode) { header.renderMode = try reader.u8() }
        if flags.contains(.marks) {
            let count = try reader.count(limit: columns + 1)
            header.marks.reserveCapacity(count)
            for _ in 0 ..< count {
                let kind = try reader.u8()
                let column = try reader.count(limit: columns)
                header.marks.append(WireSemanticMark(kind: kind, column: column))
            }
        }
        if flags.contains(.images) {
            let count = try reader.count(limit: 4096)
            header.images.reserveCapacity(count)
            for _ in 0 ..< count {
                let imageID = try reader.varint()
                let column = try reader.count(limit: 65_535)
                let width = Float(bitPattern: try reader.u32())
                let height = Float(bitPattern: try reader.u32())
                let sourceY = Float(bitPattern: try reader.u32())
                let sourceHeight = Float(bitPattern: try reader.u32())
                header.images.append(WireRowImage(imageID: imageID, column: column, width: width,
                                                  height: height, sourceY: sourceY, sourceHeight: sourceHeight))
            }
        }

        var style = WireCellStyle.plain
        var column = 0
        var last: WireCellContent?
        while !reader.isAtEnd {
            let op = try reader.u8()
            let content: WireCellContent
            switch op {
            case 0x20 ... 0x7e:
                content = .ascii(op)
            case RowOp.null:
                content = .null
            case RowOp.spacer:
                content = .spacer
            case RowOp.narrow:
                content = .grapheme(try reader.string(limit: 1024), width: 1)
            case RowOp.wide:
                content = .grapheme(try reader.string(limit: 1024), width: 2)
            case RowOp.sized:
                let width = try reader.u8()
                content = .grapheme(try reader.string(limit: 1024), width: width)
            case RowOp.style:
                style.attribute = try decodeAttribute(&reader)
                continue
            case RowOp.link:
                style.link = try reader.varint32()
                continue
            case RowOp.semantic:
                let value = try reader.u8()
                style.semantic = value & 0x7
                style.isProtected = value & 0x8 != 0
                continue
            case RowOp.repeatPrevious:
                guard let previous = last else { throw WireError.invalidValue("repeat without a cell") }
                let count = try reader.count(limit: columns)
                guard column + count <= columns else { throw WireError.invalidValue("row overflow") }
                for _ in 0 ..< count {
                    try body(column, previous, style)
                    column += 1
                }
                continue
            default:
                throw WireError.invalidValue("row op \(op)")
            }
            guard column < columns else { throw WireError.invalidValue("row overflow") }
            try body(column, content, style)
            column += 1
            last = content
        }
        while column < columns {
            try body(column, .null, .plain)
            column += 1
        }
        return header
    }

    /// Decodes a whole row into an array of cells.
    public static func decodeCells(_ payload: [UInt8]) throws -> (WireRowHeader, [WireCell]) {
        var cells: [WireCell] = []
        let header = try decode(payload) { _, content, style in
            cells.append(WireCell(content, style: style))
        }
        return (header, cells)
    }

    static func decodeAttribute(_ reader: inout WireReader) throws(WireError) -> WireAttribute {
        let mask = try reader.u8()
        var attribute = WireAttribute()
        attribute.foreground = try decodeColor(&reader)
        attribute.background = try decodeColor(&reader)
        if mask & 1 != 0 { attribute.style = try reader.u8() }
        if mask & 2 != 0 { attribute.underlineStyle = try reader.u8() }
        if mask & 4 != 0 { attribute.underlineColor = try decodeColor(&reader) }
        return attribute
    }

    static func decodeColor(_ reader: inout WireReader) throws(WireError) -> WireColor {
        switch try reader.u8() {
        case 0: return .default
        case 1: return .defaultInverted
        case 2: return .ansi(try reader.u8())
        case 3: return .rgb(try reader.u8(), try reader.u8(), try reader.u8())
        case let tag: throw .invalidValue("color tag \(tag)")
        }
    }
}

extension WireReader {
    public mutating func attribute() throws(WireError) -> WireAttribute {
        try RowDecoder.decodeAttribute(&self)
    }

    public mutating func color() throws(WireError) -> WireColor {
        try RowDecoder.decodeColor(&self)
    }
}

extension WireWriter {
    public mutating func attribute(_ value: WireAttribute) {
        RowEncoder.encode(value, to: &self)
    }

    public mutating func color(_ value: WireColor) {
        RowEncoder.encode(value, to: &self)
    }
}

/// One encoded row with its absolute line number and version.
public struct WireRowRecord: Hashable, Sendable {
    public var line: UInt64
    /// The content hash of `payload`.
    public var version: UInt64
    public var payload: [UInt8]

    public init(line: UInt64, version: UInt64, payload: [UInt8]) {
        self.line = line
        self.version = version
        self.payload = payload
    }

    /// Builds a record and computes its version from the payload.
    public init(line: UInt64, payload: [UInt8]) {
        self.init(line: line, version: WireHash.hash64(payload), payload: payload)
    }

    func encode(to writer: inout WireWriter) {
        writer.varint(line)
        writer.u64(version)
        writer.blob(payload)
    }

    init(from reader: inout WireReader) throws(WireError) {
        line = try reader.varint()
        version = try reader.u64()
        payload = try reader.blob(limit: 4 * 1024 * 1024)
    }
}
