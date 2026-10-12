import Testing
@testable import TecolotWire

struct MessageTests {
    func roundTrip<M: WireMessage & Equatable>(_ message: M) throws {
        let bytes = EnvelopeCodec.encode(message, requestID: 3)
        var decoder = EnvelopeStreamDecoder()
        decoder.append(bytes)
        let envelope = try #require(try decoder.next())
        #expect(envelope.kind == M.kind)
        #expect(envelope.requestID == 3)
        #expect(try envelope.decode(M.self) == message)
    }

    static let sampleRow: WireRowRecord = {
        var encoder = RowEncoder()
        encoder.begin(WireRowHeader(columns: 10))
        for byte in "row".utf8 { encoder.append(.ascii(byte), style: .plain) }
        return WireRowRecord(line: 1234, payload: encoder.finish())
    }()

    static let samples: [any WireMessage] = [
        HelloMessage(build: "1.0 (42)", capabilities: [.search], clientName: "Tecolot"),
        HelloReplyMessage(version: 1, build: "1.0", capabilities: [.images], sessionID: "abc"),
        AttachMessage(size: WireGridSize(columns: 80, rows: 24, cellWidth: 8, cellHeight: 17),
                      maximumFramesPerSecond: 120, viewer: true, focused: false),
        DetachMessage(),
        ResizeMessage(size: WireGridSize(columns: 132, rows: 50)),
        SetViewportMessage(buffer: .normal, follow: false, top: 99,
                           known: [WireKnownVersion(line: 99, version: 0xFEED)]),
        FrameAckMessage(sequence: 77),
        FetchRowsMessage(buffer: .alternate, epoch: 3, start: 10, count: 128,
                         known: [WireKnownVersion(line: 10, version: 1)]),
        KeyMessage(key: "ArrowUp", code: "ArrowUp", modifiers: 5, eventType: 1, text: nil),
        KeyMessage(key: "a", code: "KeyA", text: "a", shiftedKey: 65, baseLayoutKey: 97),
        TextMessage(text: "こんにちは"),
        InputMessage(bytes: [0x1b, 0x5b, 0x41]),
        MouseMessage(action: 1, button: 0, modifiers: 4, column: 3, row: 4, pixelX: 30, pixelY: 70),
        PasteMessage(text: "echo hi\n", allowUnsafe: true),
        PasteApproveMessage(token: 5, approved: true),
        FocusMessage(focused: true),
        GetTextMessage(buffer: .normal, startLine: 1, startColumn: 2, endLine: 3, endColumn: 4),
        TextResultMessage(text: "copied"),
        ClipboardReplyMessage(request: 8, allowed: true, data: Array("clip".utf8)),
        SetThemeMessage(palette: (0 ..< 16).map { WireRGB(red: UInt16($0), green: 2, blue: 3) },
                        foreground: WireRGB(red: 1, green: 1, blue: 1),
                        background: WireRGB(red: 0, green: 0, blue: 0),
                        cursor: WireRGB(red: 9, green: 9, blue: 9)),
        PingMessage(nonce: 1),
        PongMessage(nonce: 1),
        TerminateMessage(signal: 15),
        ResetMessage(action: .clearToStart),
        SearchMessage(query: "needle", options: [.caseSensitive, .backward], buffer: .normal,
                      startLine: 40, startColumn: 3),
        SearchResultMessage(found: true, line: 10, column: 2, endLine: 11, endColumn: 4),
        SearchResultMessage(found: false, problem: "bad pattern"),
        FindPromptMessage(buffer: .normal, line: 1234, upward: true),
        PromptResultMessage(found: true, line: 99),
        PromptResultMessage(found: false),
        AttachMessage(size: WireGridSize(columns: 80, rows: 24, cellWidth: 16, cellHeight: 34), scale: 200),
        ResizeMessage(size: WireGridSize(columns: 100, rows: 30), scale: 150),
        FetchImageMessage(imageID: 1 << 40),
        ImageDataMessage(imageID: 7, width: 2, height: 1, offset: 4, bytes: [1, 2, 3, 4]),
        ImageDataMessage(imageID: 8, width: 0, height: 0),
        FrameMessage(sequence: 3, snapshotSequence: 4, buffer: .normal, epoch: 0, firstLine: 0,
                     endLine: 24, viewTop: 0, columns: 80, rows: 24,
                     cursor: WireCursor(line: 0, column: 0, visible: true, blink: false, style: 0),
                     changedRows: [sampleRow], maximumBidiParagraphRows: 500,
                     kitty: WireKittyState(
                        generation: 12,
                        images: [WireKittyImage(kittyID: 1, imageNumber: 0, imageID: 99, width: 640, height: 480),
                                 WireKittyImage(kittyID: 2, imageID: 100, width: 1, height: 1)],
                        placements: [WireKittyPlacement(token: 5, placementID: 0, kittyID: 1, sourceX: 0, sourceY: 10,
                                                        sourceWidth: 640, sourceHeight: 470, line: -3, column: 2,
                                                        columns: 40, rows: 12, pixelOffsetX: 3, pixelOffsetY: -1,
                                                        zIndex: -1_073_741_825, isVirtual: false, insertionOrder: 9),
                                     WireKittyPlacement(token: 6, placementID: 4, kittyID: 2, sourceX: 0, sourceY: 0,
                                                        sourceWidth: 1, sourceHeight: 1, line: 0, column: 0,
                                                        columns: 2, rows: 1, pixelOffsetX: 0, pixelOffsetY: 0,
                                                        zIndex: 0, isVirtual: true, insertionOrder: 10)])),
        FrameMessage(sequence: 4, snapshotSequence: 5, buffer: .normal, epoch: 0, firstLine: 0,
                     endLine: 24, viewTop: 0, columns: 80, rows: 24,
                     cursor: WireCursor(line: 0, column: 0, visible: true, blink: false, style: 0),
                     kitty: WireKittyState(generation: 13)),
        FrameMessage(sequence: 1, snapshotSequence: 2, buffer: .normal, epoch: 0, firstLine: 0,
                     endLine: 24, viewTop: 0, columns: 80, rows: 24,
                     cursor: WireCursor(line: 3, column: 2, visible: true, blink: false, style: 4),
                     modes: WireModes(input: 0x105, pointer: 0x12), title: "vim",
                     iconTitle: "icon", directory: "file:///tmp",
                     colors: WireColorState(foreground: WireRGB(red: 1, green: 2, blue: 3),
                                            background: WireRGB(red: 4, green: 5, blue: 6),
                                            cursor: nil,
                                            paletteOverrides: [1: WireRGB(red: 7, green: 8, blue: 9)]),
                     reverseVideo: true, changedRows: [sampleRow]),
        FrameMessage(sequence: 2, snapshotSequence: 3, buffer: .alternate, epoch: 1, firstLine: 5,
                     endLine: 29, viewTop: 5, columns: 80, rows: 24,
                     cursor: WireCursor(line: 5, column: 0, visible: false, blink: true, style: 0)),
        RowsMessage(snapshotSequence: 4, buffer: .normal, epoch: 2, final: true, records: [sampleRow],
                    confirmed: [WireLineRange(start: 0, count: 10)],
                    unavailable: [WireLineRange(start: 100, count: 5)]),
        DefineLinksMessage(links: [1: "id=x;https://example.com", 2: ";file:///etc/hosts"]),
        BellMessage(),
        ClipboardCopyMessage(data: [1, 2, 3]),
        ClipboardReadRequestMessage(request: 4, selection: "c"),
        ProcessExitedMessage(exitCode: 0),
        ProcessExitedMessage(exitCode: nil),
        PasteResultMessage(status: .needsApproval, token: 12),
        SessionInfoMessage(shellPID: 123, shellName: "zsh",
                           foreground: WireProcess(pid: 456, name: "vim", path: "/usr/bin/vim"),
                           hasChildren: true),
        ErrorMessage(code: .unsupported, failedKind: .getText, message: "no"),
    ]

    /// Fields added at the end decode as their defaults from older peers.
    @Test func olderMessagesDecodeWithDefaults() throws {
        var attach = WireWriter()
        WireGridSize(columns: 80, rows: 24).encode(to: &attach)
        attach.varint(60)
        attach.bool(false)
        attach.bool(true)
        var reader = WireReader(attach.bytes)
        #expect(try AttachMessage(from: &reader).scale == 0)

        let old = FrameMessage(sequence: 1, snapshotSequence: 1, buffer: .normal, epoch: 0, firstLine: 0,
                               endLine: 1, viewTop: 0, columns: 10, rows: 1,
                               cursor: WireCursor(line: 0, column: 0, visible: true, blink: false, style: 0))
        var frame = WireWriter()
        old.encode(to: &frame)
        var frameReader = WireReader(frame.bytes)
        let decoded = try FrameMessage(from: &frameReader)
        #expect(decoded.kitty == nil)
        #expect(decoded.maximumBidiParagraphRows == nil)
    }

    @Test func everyMessageRoundTrips() throws {
        for sample in Self.samples {
            try roundTripAny(sample)
        }
    }

    func roundTripAny(_ message: some WireMessage) throws {
        func open<M: WireMessage>(_ message: M) throws {
            let bytes = EnvelopeCodec.encode(message)
            var decoder = EnvelopeStreamDecoder()
            decoder.append(bytes)
            let envelope = try #require(try decoder.next())
            #expect(envelope.kind == M.kind)
            let decoded = try envelope.decode(M.self)
            var original = WireWriter()
            message.encode(to: &original)
            var again = WireWriter()
            decoded.encode(to: &again)
            #expect(original.bytes == again.bytes, "\(M.self) did not round trip")
        }
        try open(message)
    }

    /// Every prefix of every message must fail cleanly, never crash.
    @Test func truncatedMessagesThrow() throws {
        for sample in Self.samples {
            try truncate(sample)
        }
    }

    func truncate(_ message: some WireMessage) throws {
        func open<M: WireMessage>(_ message: M) {
            var writer = WireWriter()
            message.encode(to: &writer)
            let bytes = writer.bytes
            guard !bytes.isEmpty else { return }
            for length in 0 ..< bytes.count {
                var reader = WireReader(Array(bytes.prefix(length)))
                _ = try? M(from: &reader)
            }
        }
        open(message)
    }

    /// Random bytes must never crash a decoder.
    @Test func randomBytesNeverCrash() {
        var generator = SplitMix64(seed: 0x7EC0_107)
        let decoders: [(inout WireReader) throws -> Void] = [
            { _ = try FrameMessage(from: &$0) },
            { _ = try RowsMessage(from: &$0) },
            { _ = try HelloMessage(from: &$0) },
            { _ = try SetThemeMessage(from: &$0) },
            { _ = try KeyMessage(from: &$0) },
            { reader in _ = try RowDecoder.decodeCells(Array(reader.bytes)) },
        ]
        for _ in 0 ..< 2000 {
            let length = Int(generator.next() % 64)
            let bytes = (0 ..< length).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
            for decode in decoders {
                var reader = WireReader(bytes)
                _ = try? decode(&reader)
            }
        }
    }

    @Test func frameRowsRoundTripThroughTheRowDecoder() throws {
        let frame = FrameMessage(sequence: 1, snapshotSequence: 1, buffer: .normal, epoch: 0,
                                 firstLine: 0, endLine: 1, viewTop: 0, columns: 10, rows: 1,
                                 cursor: WireCursor(line: 0, column: 3, visible: true, blink: true, style: 0),
                                 changedRows: [Self.sampleRow])
        let bytes = EnvelopeCodec.encode(frame)
        var decoder = EnvelopeStreamDecoder()
        decoder.append(bytes)
        let decoded = try #require(try decoder.next()).decode(FrameMessage.self)
        let row = try #require(decoded.changedRows.first)
        #expect(row.version == WireHash.hash64(row.payload))
        let (_, cells) = try RowDecoder.decodeCells(row.payload)
        #expect(cells.prefix(3).map(\.content) == [.ascii(0x72), .ascii(0x6f), .ascii(0x77)])
    }
}

struct SplitMix64 {
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
