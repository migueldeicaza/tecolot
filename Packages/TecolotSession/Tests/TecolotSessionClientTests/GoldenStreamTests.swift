//
// GoldenStreamTests.swift
// TecolotSessionClientTests
//
// Sessions outlive app updates, so a new app must read what an older helper
// writes. The files in Golden/<release>/ are bytes that a released helper
// wrote; every later release must still decode them.
//
// Rules: never change the files or the samples of a release. When a release
// changes the wire format, record a new directory with
//
//     TECOLOT_RECORD_GOLDEN=<release> swift test --filter GoldenStreamTests/record
//
// and add its samples and tests next to the old ones.
//

import Foundation
import Synchronization
import Testing
import TecolotSessionDirectory
import TecolotTransport
import TecolotWire
@testable import TecolotSessionClient
@testable import TecolotSessionHost
#if canImport(Darwin)
import Darwin
#endif

/// The messages in Golden/release-1/messages.bin, in order. Frozen: a value
/// here describes bytes that are already on disk.
enum GoldenRelease1 {
    static let row: WireRowRecord = {
        var encoder = RowEncoder()
        encoder.begin(WireRowHeader(columns: 12, isWrapped: true, bidi: 6, renderMode: 1,
                                    marks: [WireSemanticMark(kind: 1, column: 0)],
                                    images: [WireRowImage(imageID: 7, column: 2, width: 40, height: 18,
                                                          sourceY: 0, sourceHeight: 18)],
                                    rightToLeft: true))
        let bold = WireCellStyle(attribute: WireAttribute(foreground: .ansi(1), background: .rgb(1, 2, 3),
                                                          style: 1, underlineStyle: 3,
                                                          underlineColor: .ansi(4)),
                                 link: 2, semantic: 1, isProtected: true)
        encoder.append(.ascii(0x41), style: .plain)
        encoder.append(.grapheme("漢", width: 2), style: bold)
        encoder.append(.spacer, style: bold)
        encoder.append(.grapheme("ש", width: 1), style: .plain)
        encoder.append(.ascii(0x2d), style: .plain)
        encoder.append(.ascii(0x2d), style: .plain)
        encoder.append(.ascii(0x2d), style: .plain)
        return WireRowRecord(line: 4321, payload: encoder.finish())
    }()

    static let messages: [any WireMessage] = [
        HelloMessage(build: "1.0 (42)", capabilities: [.search, .images], clientName: "Tecolot"),
        HelloReplyMessage(version: 1, build: "1.0 (42)", capabilities: [.search, .reset, .prompts, .images, .bidi],
                          sessionID: "abc123"),
        AttachMessage(size: WireGridSize(columns: 80, rows: 24, cellWidth: 16, cellHeight: 34),
                      maximumFramesPerSecond: 120, viewer: false, focused: true, scale: 200),
        DetachMessage(),
        ResizeMessage(size: WireGridSize(columns: 132, rows: 50, cellWidth: 16, cellHeight: 34), scale: 200),
        SetViewportMessage(buffer: .normal, follow: false, top: 99,
                           known: [WireKnownVersion(line: 99, version: 0xFEED)]),
        FrameAckMessage(sequence: 77),
        FetchRowsMessage(buffer: .alternate, epoch: 3, start: 10, count: 128,
                         known: [WireKnownVersion(line: 10, version: 1)]),
        KeyMessage(key: "a", code: "KeyA", modifiers: 1, eventType: 1, text: "A", shiftedKey: 65, baseLayoutKey: 97),
        TextMessage(text: "こんにちは"),
        InputMessage(bytes: [0x1b, 0x5b, 0x41]),
        MouseMessage(action: 1, button: 0, modifiers: 4, column: 3, row: 4, pixelX: 30, pixelY: 70),
        PasteMessage(text: "echo hi\n", allowUnsafe: true),
        PasteApproveMessage(token: 5, approved: true),
        FocusMessage(focused: true),
        GetTextMessage(buffer: .normal, startLine: 1, startColumn: 2, endLine: 3, endColumn: 4),
        ClipboardReplyMessage(request: 8, allowed: true, data: Array("clip".utf8)),
        SetThemeMessage(palette: (0 ..< 16).map { WireRGB(red: UInt16($0) * 4096, green: 2, blue: 3) },
                        foreground: WireRGB(red: 1, green: 1, blue: 1),
                        background: WireRGB(red: 0, green: 0, blue: 0),
                        cursor: WireRGB(red: 9, green: 9, blue: 9)),
        PingMessage(nonce: 1),
        TerminateMessage(signal: 15),
        ResetMessage(action: .clearToStart),
        SearchMessage(query: "needle", options: [.caseSensitive, .backward, .wholeWord], buffer: .normal,
                      startLine: 40, startColumn: 3),
        FindPromptMessage(buffer: .normal, line: 1234, upward: true),
        FetchImageMessage(imageID: 1 << 32),
        FrameMessage(sequence: 1, snapshotSequence: 2, buffer: .normal, epoch: 5, firstLine: 100,
                     endLine: 124, viewTop: 100, columns: 80, rows: 24,
                     cursor: WireCursor(line: 103, column: 2, visible: true, blink: false, style: 4),
                     modes: WireModes(input: 0x10105, pointer: 0x12), title: "vim",
                     iconTitle: "icon", directory: "file:///tmp",
                     colors: WireColorState(foreground: WireRGB(red: 1, green: 2, blue: 3),
                                            background: WireRGB(red: 4, green: 5, blue: 6),
                                            cursor: nil,
                                            paletteOverrides: [1: WireRGB(red: 7, green: 8, blue: 9)]),
                     reverseVideo: true, changedRows: [row], maximumBidiParagraphRows: 500,
                     kitty: WireKittyState(
                        generation: 12,
                        images: [WireKittyImage(kittyID: 1, imageNumber: 3, imageID: 1 << 32, width: 64, height: 32)],
                        placements: [WireKittyPlacement(token: 5, placementID: 2, kittyID: 1, sourceX: 0, sourceY: 4,
                                                        sourceWidth: 64, sourceHeight: 28, line: 101, column: 2,
                                                        columns: 8, rows: 2, pixelOffsetX: 3, pixelOffsetY: -1,
                                                        zIndex: -1, isVirtual: false, insertionOrder: 9)])),
        RowsMessage(snapshotSequence: 4, buffer: .normal, epoch: 5, final: true, records: [row],
                    confirmed: [WireLineRange(start: 0, count: 10)],
                    unavailable: [WireLineRange(start: 100, count: 5)]),
        DefineLinksMessage(links: [2: "id=x;https://example.com"]),
        BellMessage(),
        ClipboardCopyMessage(data: [1, 2, 3]),
        ClipboardReadRequestMessage(request: 4, selection: "c"),
        ProcessExitedMessage(exitCode: 3),
        PasteResultMessage(status: .needsApproval, token: 12),
        TextResultMessage(text: "copied"),
        SessionInfoMessage(shellPID: 123, shellName: "zsh",
                           foreground: WireProcess(pid: 456, name: "vim", path: "/usr/bin/vim"),
                           hasChildren: true),
        ErrorMessage(code: .unsupported, failedKind: .fetchImage, message: "no"),
        PongMessage(nonce: 1),
        SearchResultMessage(found: true, line: 10, column: 2, endLine: 11, endColumn: 4),
        PromptResultMessage(found: true, line: 99),
        ImageDataMessage(imageID: 7, width: 2, height: 1, offset: 0, bytes: [1, 2, 3, 4, 5, 6, 7, 8]),
    ]
}

struct GoldenStreamTests {
    static var goldenDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Golden")
    }

    static func read(_ name: String) throws -> [UInt8] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Golden"))
        return Array(try Data(contentsOf: url))
    }

    static func envelopes(_ bytes: [UInt8]) throws -> [Envelope] {
        var decoder = EnvelopeStreamDecoder()
        decoder.append(bytes[...])
        var result: [Envelope] = []
        while let envelope = try decoder.next() { result.append(envelope) }
        return result
    }

    /// True when `envelope` decodes to exactly `sample`.
    static func matches(_ envelope: Envelope, _ sample: any WireMessage) -> Bool {
        func open<M: WireMessage>(_ sample: M) -> Bool {
            guard envelope.kind == M.kind, let decoded = try? envelope.decode(M.self) else { return false }
            var a = WireWriter()
            var b = WireWriter()
            decoded.encode(to: &a)
            sample.encode(to: &b)
            return a.bytes == b.bytes
        }
        return open(sample)
    }

    @Test func release1MessagesStillDecode() throws {
        let envelopes = try Self.envelopes(Self.read("release-1/messages.bin"))
        #expect(envelopes.count == GoldenRelease1.messages.count)
        for (index, (envelope, sample)) in zip(envelopes, GoldenRelease1.messages).enumerated() {
            #expect(Self.matches(envelope, sample), "message \(index) (\(type(of: sample)))")
        }
    }

    /// A recorded helper stream (title, colors, wide and combined characters,
    /// links, prompt marks, bidi, a wrapped line, scrollback, a Sixel slice
    /// and a Kitty placement) replays into a client and shows the recorded
    /// screen.
    @Test func release1SessionReplays() async throws {
        let stream = try Self.read("release-1/session.bin")
        let expected = String(decoding: try Self.read("release-1/session-screen.txt"), as: UTF8.self)
        let (screen, state) = try await Self.replay(stream)
        #expect(screen == expected)
        #expect(state.title == "golden")
        #expect(state.kitty?.placements.isEmpty == false)
        #expect(state.bracketedPaste)
    }

    /// Feeds `stream` to a new client as if a helper wrote it, and returns the
    /// screen text and the state after the last frame.
    static func replay(_ stream: [UInt8]) async throws -> (String, RemoteSessionState) {
        let lastSequence = try envelopes(stream).compactMap { try? $0.decode(FrameMessage.self).sequence }.max() ?? 0
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
        let session = RemoteSession(socket: fds[0], clientName: "golden", build: "golden")
        session.start(size: WireGridSize(columns: 40, rows: 10), focused: true)
        let peer = MessageChannel(socket: fds[1])
        peer.onMessage = { _ in }
        peer.start()
        peer.sendEncoded(stream)
        try await eventually("replayed") { session.state.lastFrameSequence == lastSequence }
        let result = (screen(session).joined(separator: "\n"), session.state)
        session.close()
        peer.close()
        return result
    }

    // MARK: Recording

    /// Writes Golden/<release>/ when TECOLOT_RECORD_GOLDEN names a release that
    /// has no files yet. Otherwise it does nothing.
    @Test func record() async throws {
        guard let release = ProcessInfo.processInfo.environment["TECOLOT_RECORD_GOLDEN"] else { return }
        let directory = Self.goldenDirectory.appendingPathComponent(release)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            Issue.record("\(directory.path) exists: the files of a release never change")
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var messages = WireWriter()
        for message in GoldenRelease1.messages {
            func append<M: WireMessage>(_ message: M) {
                EnvelopeCodec.append(message, requestID: M.self == ImageDataMessage.self ? 41 : nil, to: &messages)
            }
            append(message)
        }
        try Data(messages.bytes).write(to: directory.appendingPathComponent("messages.bin"))

        let stream = try await Self.recordSession()
        try Data(stream).write(to: directory.appendingPathComponent("session.bin"))
        let (screen, _) = try await Self.replay(stream)
        try Data(screen.utf8).write(to: directory.appendingPathComponent("session-screen.txt"))
    }

    /// Runs a scripted session in a helper and returns every byte that the
    /// helper wrote to its client.
    static func recordSession() async throws -> [UInt8] {
        let host = makeHost(rows: 10, columns: 40)
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
        host.accept(socket: fds[1])
        let recorded = Mutex<[UInt8]>([])
        let channel = MessageChannel(socket: fds[0])
        channel.onMessage = { envelope in
            var writer = WireWriter()
            writer.u32(0)
            writer.varint(UInt64(envelope.kind.rawValue))
            writer.u8(envelope.flags.rawValue)
            if let requestID = envelope.requestID { writer.varint(requestID) }
            writer.raw(envelope.payload.bytes[envelope.payload.offset ..< envelope.payload.end])
            writer.patchU32(UInt32(writer.count - 4), at: 0)
            recorded.withLock { $0 += writer.bytes }
            if envelope.kind == .frame, let frame = try? envelope.decode(FrameMessage.self) {
                channel.send(FrameAckMessage(sequence: frame.sequence))
            }
        }
        channel.start()
        channel.send(HelloMessage(build: "golden", clientName: "golden"))
        channel.send(AttachMessage(size: WireGridSize(columns: 40, rows: 10, cellWidth: 10, cellHeight: 20),
                                   maximumFramesPerSecond: 1000, scale: 200))
        try await eventually("attached") { !recorded.withLock { $0.isEmpty } }

        let green = Data([0, 255, 0, 0, 255, 0, 0, 255, 0, 0, 255, 0]).base64EncodedString()
        let script = [
            "\u{1b}]0;golden\u{07}\u{1b}]7;file:///tmp\u{07}\u{1b}[?2004h",
            (1 ... 30).map { "scroll \($0)" }.joined(separator: "\r\n") + "\r\n",
            "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}ls\r\n\u{1b}]133;C\u{07}",
            "\u{1b}[1;31mred\u{1b}[0m \u{1b}[38;2;10;200;30mtrue\u{1b}[0m \u{1b}[4:3mcurly\u{1b}[0m 漢字 e\u{301}\r\n",
            "\u{1b}]8;;https://example.com\u{1b}\\link\u{1b}]8;;\u{1b}\\ 👩‍👩‍👧\r\n",
            "שלום abc 123 مرحبا\r\n",
            String(repeating: "wrap", count: 15) + "\r\n",
            "A\u{1b}Pq#0;2;100;0;0#0!20~-!20~\u{1b}\\\r\n",
            "B\u{1b}_Gi=3,f=24,s=2,v=2,a=T,q=2,c=2,r=1;\(green)\u{1b}\\\r\n",
            "END",
        ]
        for part in script { host.inject(part) }
        // Wait until the helper stops sending.
        var size = -1
        while size != recorded.withLock({ $0.count }) {
            size = recorded.withLock { $0.count }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        channel.close()
        return recorded.withLock { $0 }
    }
}
