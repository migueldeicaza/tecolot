import Foundation
import Synchronization
import Testing
import TecolotTransport
import TecolotWire
@testable import TecolotSessionHost
import TecolotSessionDirectory
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A minimal client: it keeps the rows that frames and fetches deliver and
/// acknowledges frames when `autoAck` is true.
final class TestClient: @unchecked Sendable {
    struct State {
        var frames: [FrameMessage] = []
        var rows: [UInt64: (version: UInt64, cells: [WireCell], header: WireRowHeader)] = [:]
        var rowsMessages: [RowsMessage] = []
        var texts: [String] = []
        var events: [Envelope] = []
        var errors: [ErrorMessage] = []
        var links: [UInt32: String] = [:]
        var helloReply: HelloReplyMessage?
        var epoch: UInt64?
        var buffer: WireBuffer?
    }

    let channel: MessageChannel
    let state = Mutex(State())
    let autoAck: Bool

    init(host: SessionHost, size: WireGridSize = WireGridSize(columns: 40, rows: 10),
         autoAck: Bool = true, attach: Bool = true) throws {
        var fds: [Int32] = [0, 0]
        #if canImport(Darwin)
        let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        #else
        let result = socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds)
        #endif
        guard result == 0 else { throw TransportError("socketpair") }
        self.autoAck = autoAck
        channel = MessageChannel(socket: fds[0])
        host.accept(socket: fds[1])
        channel.onMessage = { [weak self] envelope in self?.receive(envelope) }
        channel.start()
        channel.send(HelloMessage(build: "test", clientName: "TestClient"))
        if attach {
            channel.send(AttachMessage(size: size, maximumFramesPerSecond: 1000))
        }
    }

    private func receive(_ envelope: Envelope) {
        do {
            switch envelope.kind {
            case .helloReply:
                let reply = try envelope.decode(HelloReplyMessage.self)
                state.withLock { $0.helloReply = reply }
            case .frame:
                let frame = try envelope.decode(FrameMessage.self)
                try apply(rows: frame.changedRows, epoch: frame.epoch, buffer: frame.buffer)
                state.withLock { $0.frames.append(frame) }
                if autoAck { channel.send(FrameAckMessage(sequence: frame.sequence)) }
            case .rows:
                let rows = try envelope.decode(RowsMessage.self)
                try apply(rows: rows.records, epoch: rows.epoch, buffer: rows.buffer)
                state.withLock { $0.rowsMessages.append(rows) }
            case .textResult:
                let text = try envelope.decode(TextResultMessage.self).text
                state.withLock { $0.texts.append(text) }
            case .defineLinks:
                let links = try envelope.decode(DefineLinksMessage.self).links
                state.withLock { $0.links.merge(links) { $1 } }
            case .error:
                let error = try envelope.decode(ErrorMessage.self)
                state.withLock { $0.errors.append(error) }
            default:
                state.withLock { $0.events.append(envelope) }
            }
        } catch {
            Issue.record("client decode failed: \(error)")
        }
    }

    private func apply(rows: [WireRowRecord], epoch: UInt64, buffer: WireBuffer) throws {
        var decoded: [(UInt64, UInt64, [WireCell], WireRowHeader)] = []
        for row in rows {
            #expect(row.version == WireHash.hash64(row.payload))
            let (header, cells) = try RowDecoder.decodeCells(row.payload)
            decoded.append((row.line, row.version, cells, header))
        }
        state.withLock { state in
            if state.epoch != epoch || state.buffer != buffer {
                // Line numbers are never reused, but keep the test model simple.
                if state.buffer != buffer { state.rows.removeAll() }
                state.epoch = epoch
                state.buffer = buffer
            }
            for (line, version, cells, header) in decoded {
                state.rows[line] = (version, cells, header)
            }
        }
    }

    var lastFrame: FrameMessage? { state.withLock { $0.frames.last } }
    var frameCount: Int { state.withLock { $0.frames.count } }

    func text(ofLine line: UInt64) -> String? {
        state.withLock { state in
            state.rows[line].map { Self.text($0.cells) }
        }
    }

    static func text(_ cells: [WireCell]) -> String {
        var result = ""
        for cell in cells {
            switch cell.content {
            case .null: result.append(" ")
            case .ascii(let byte): result.append(Character(UnicodeScalar(byte)))
            case .grapheme(let text, _): result.append(text)
            case .spacer: break
            }
        }
        while result.last == " " { result.removeLast() }
        return result
    }

    /// The visible screen according to the latest frame.
    func screen() -> [String] {
        guard let frame = lastFrame else { return [] }
        return (0 ..< UInt64(frame.rows)).map { text(ofLine: frame.viewTop + $0) ?? "<missing>" }
    }

    func cell(line: UInt64, column: Int) -> WireCell? {
        state.withLock { $0.rows[line]?.cells[column] }
    }

    /// Polls `condition` until it holds or the deadline passes.
    @discardableResult
    func wait(_ description: String, timeout: TimeInterval = 5,
              _ condition: (TestClient) -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition(self) { return true }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        Issue.record("timed out: \(description); screen=\(screen())")
        return false
    }

    func waitForScreen(containing text: String, timeout: TimeInterval = 5) async throws {
        try await wait("screen contains \(text)", timeout: timeout) { client in
            client.screen().contains { $0.contains(text) }
        }
    }

    func close() {
        channel.close()
    }
}

func makeHost(columns: Int = 40, rows: Int = 10, scrollback: Int = 1000,
              executable: String = "/bin/sh", arguments: [String] = []) -> SessionHost {
    let launch = SessionLaunch(executable: executable, arguments: arguments,
                               environment: ["PATH=/usr/bin:/bin", "TERM=xterm-256color", "LANG=en_US.UTF-8"],
                               workingDirectory: "/", columns: columns, rows: rows, scrollback: scrollback)
    return SessionHost(id: "test\(UInt32.random(in: 0 ... .max))", launch: launch, build: "test")
}

extension SessionHost {
    /// Feeds bytes as if the PTY produced them.
    func inject(_ text: String) {
        let bytes = Array(text.utf8)
        ptyQueue.sync { dataReceived(slice: bytes[...]) }
    }
}
