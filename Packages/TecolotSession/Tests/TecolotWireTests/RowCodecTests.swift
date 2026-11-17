import Testing
@testable import TecolotWire

struct RowCodecTests {
    static let red = WireCellStyle(attribute: WireAttribute(foreground: .ansi(1), style: 1))
    static let blueBackground = WireCellStyle(attribute: WireAttribute(background: .rgb(0, 0, 200)))

    func roundTrip(_ cells: [WireCell], header: WireRowHeader) throws -> (WireRowHeader, [WireCell], [UInt8]) {
        var encoder = RowEncoder()
        encoder.begin(header)
        for cell in cells { encoder.append(cell.content, style: cell.style) }
        let payload = encoder.finish()
        let (decodedHeader, decoded) = try RowDecoder.decodeCells(payload)
        return (decodedHeader, decoded, payload)
    }

    func ascii(_ text: String, style: WireCellStyle = .plain) -> [WireCell] {
        text.utf8.map { WireCell(.ascii($0), style: style) }
    }

    @Test func asciiRowUsesOneBytePerCellAndTrimsTrailingBlanks() throws {
        var cells = ascii("$ ls -la")
        cells += Array(repeating: WireCell(.null), count: 72)
        let (header, decoded, payload) = try roundTrip(cells, header: WireRowHeader(columns: 80))
        #expect(decoded == cells)
        #expect(header.columns == 80)
        // flags + columns varint + 8 ASCII bytes.
        #expect(payload.count == 1 + 1 + 8)
    }

    @Test func blankRowIsHeaderOnly() throws {
        let cells = Array(repeating: WireCell(.null), count: 120)
        let (_, decoded, payload) = try roundTrip(cells, header: WireRowHeader(columns: 120))
        #expect(decoded == cells)
        #expect(payload.count == 2)
    }

    @Test func stylesLinksSemanticsAndWideCells() throws {
        let link = WireCellStyle(attribute: .plain, link: 7, semantic: 6)
        let prompt = WireCellStyle(attribute: WireAttribute(foreground: .defaultInverted,
                                                            background: .ansi(4), style: 0x42,
                                                            underlineStyle: 3,
                                                            underlineColor: .rgb(1, 2, 3)),
                                   semantic: 1, isProtected: true)
        var cells: [WireCell] = []
        cells += ascii("ok", style: Self.red)
        cells.append(WireCell(.grapheme("漢", width: 2), style: prompt))
        cells.append(WireCell(.spacer, style: prompt))
        cells.append(WireCell(.grapheme("👩‍👩‍👧", width: 2), style: link))
        cells.append(WireCell(.spacer, style: link))
        cells.append(WireCell(.grapheme("é", width: 1)))
        cells.append(WireCell(.grapheme("\u{200B}", width: 0)))
        cells += ascii("tail")
        cells += Array(repeating: WireCell(.null), count: 20 - cells.count)
        let header = WireRowHeader(columns: 20, isWrapped: true, bidi: 0b0110, renderMode: 2,
                                   marks: [WireSemanticMark(kind: 1, column: 0)],
                                   images: [WireRowImage(imageID: 1 << 40, column: 3, width: 120.5, height: 34,
                                                         sourceY: 68, sourceHeight: 34),
                                            WireRowImage(imageID: 9, column: 0, width: 10, height: 2.25,
                                                         sourceY: 0, sourceHeight: 4.5)],
                                   rightToLeft: true)
        let (decodedHeader, decoded, _) = try roundTrip(cells, header: header)
        #expect(decoded == cells)
        #expect(decodedHeader == header)
    }

    @Test func repeatRunsAreCompact() throws {
        // A colored background erase to the end of the row (CSI 44 m, CSI K).
        var cells = ascii("x")
        cells += Array(repeating: WireCell(.null, style: Self.blueBackground), count: 199)
        let (_, decoded, payload) = try roundTrip(cells, header: WireRowHeader(columns: 200))
        #expect(decoded == cells)
        #expect(payload.count < 20)

        let dashes = ascii(String(repeating: "─", count: 0) + String(repeating: "=", count: 100))
        let (_, decodedDashes, dashPayload) = try roundTrip(dashes, header: WireRowHeader(columns: 100))
        #expect(decodedDashes == dashes)
        #expect(dashPayload.count < 10)

        let boxes = (0 ..< 50).map { _ in WireCell(.grapheme("─", width: 1)) }
        let (_, decodedBoxes, boxPayload) = try roundTrip(boxes, header: WireRowHeader(columns: 50))
        #expect(decodedBoxes == boxes)
        #expect(boxPayload.count < 12)
    }

    @Test func plainNullsInsideTheRowAreKept() throws {
        var cells = ascii("a")
        cells += Array(repeating: WireCell(.null), count: 5)
        cells += ascii("b")
        cells += Array(repeating: WireCell(.null), count: 3)
        let (_, decoded, _) = try roundTrip(cells, header: WireRowHeader(columns: 10))
        #expect(decoded == cells)
    }

    @Test func styleChangeBackToPlainAtTheEndIsTrimmed() throws {
        var cells = ascii("abc", style: Self.red)
        cells += Array(repeating: WireCell(.null), count: 7)
        let (_, decoded, payload) = try roundTrip(cells, header: WireRowHeader(columns: 10))
        #expect(decoded == cells)
        // No trailing style op that resets to plain.
        let (_, againDecoded) = try RowDecoder.decodeCells(payload)
        #expect(againDecoded == cells)
        #expect(payload.last == UInt8(ascii: "c"))
    }

    @Test func extraCellsAreIgnored() throws {
        let cells = ascii("abcdef")
        var encoder = RowEncoder()
        encoder.begin(WireRowHeader(columns: 3))
        for cell in cells { encoder.append(cell.content, style: cell.style) }
        let (_, decoded) = try RowDecoder.decodeCells(encoder.finish())
        #expect(decoded == Array(cells.prefix(3)))
    }

    @Test func identicalRowsHaveIdenticalVersions() {
        var encoder = RowEncoder()
        func encode(_ text: String) -> UInt64 {
            encoder.begin(WireRowHeader(columns: 40))
            for byte in text.utf8 { encoder.append(.ascii(byte), style: .plain) }
            return WireRowRecord(line: 0, payload: encoder.finish()).version
        }
        #expect(encode("hello") == encode("hello"))
        #expect(encode("hello") != encode("hellp"))
    }

    @Test func malformedRowsThrow() {
        // Overflow: three ASCII cells in a one-column row.
        #expect(throws: (any Error).self) { try RowDecoder.decodeCells([0, 1, 0x41, 0x42, 0x43]) }
        // Repeat without a previous cell.
        #expect(throws: (any Error).self) { try RowDecoder.decodeCells([0, 5, 0x07, 2]) }
        // Unknown op.
        #expect(throws: (any Error).self) { try RowDecoder.decodeCells([0, 5, 0xF0]) }
        // Bad color tag.
        #expect(throws: (any Error).self) { try RowDecoder.decodeCells([0, 5, 0x01, 0, 9]) }
    }
}
