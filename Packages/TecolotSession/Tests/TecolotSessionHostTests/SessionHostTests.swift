import Foundation
import Synchronization
import Testing
import TecolotWire
@testable import TecolotSessionHost

struct SessionHostScenarioTests {
    @Test func firstFrameShowsTheScreenWithAttributes() async throws {
        let host = makeHost()
        host.inject("\u{1b}[1;31mhello\u{1b}[0m\r\nworld")
        let client = try TestClient(host: host)
        try await client.waitForScreen(containing: "world")
        let screen = client.screen()
        #expect(screen[0] == "hello")
        #expect(screen[1] == "world")
        let frame = try #require(client.lastFrame)
        #expect(frame.columns == 40)
        #expect(frame.rows == 10)
        #expect(frame.cursor.line == frame.viewTop + 1)
        #expect(frame.cursor.column == 5)
        #expect(frame.modes != nil)
        let first = try #require(client.cell(line: frame.viewTop, column: 0))
        #expect(first.content == .ascii(UInt8(ascii: "h")))
        #expect(first.style.attribute.foreground == .ansi(1))
        #expect(first.style.attribute.style & 1 == 1)
        let reply = client.state.withLock { $0.helloReply }
        #expect(reply?.sessionID == host.id)
        client.close()
    }

    @Test func laterFramesCarryOnlyChangedRows() async throws {
        let host = makeHost()
        host.inject("one\r\ntwo\r\nthree")
        let client = try TestClient(host: host)
        try await client.waitForScreen(containing: "three")
        let before = client.frameCount
        host.inject("\r\nfour")
        try await client.waitForScreen(containing: "four")
        let frames = client.state.withLock { Array($0.frames[before...]) }
        let rows = frames.flatMap(\.changedRows)
        // Only the new row and the row the cursor left can change.
        #expect(rows.count <= 2)
        #expect(rows.contains { TestClient.text((try? RowDecoder.decodeCells($0.payload).1) ?? []) == "four" })
        client.close()
    }

    @Test func cursorOnlyChangesProduceFrames() async throws {
        let host = makeHost()
        host.inject("abc")
        let client = try TestClient(host: host)
        try await client.waitForScreen(containing: "abc")
        host.inject("\u{1b}[1D")
        try await client.wait("cursor moved") { $0.lastFrame?.cursor.column == 2 }
        #expect(client.lastFrame?.changedRows.isEmpty == true)
        client.close()
    }

    @Test func scrollbackRowsAreFetchedOnDemand() async throws {
        let host = makeHost(rows: 10)
        var output = ""
        for index in 1 ... 100 { output += "line \(index)\r\n" }
        host.inject(output)
        let client = try TestClient(host: host)
        try await client.waitForScreen(containing: "line 100")
        let frame = try #require(client.lastFrame)
        #expect(frame.endLine - frame.firstLine == 101)
        // Only the visible rows came with the frame.
        #expect(client.state.withLock { $0.rows.count } <= 10)

        client.channel.send(FetchRowsMessage(buffer: .normal, epoch: frame.epoch,
                                             start: frame.firstLine, count: 20), requestID: 1)
        try await client.wait("rows arrive") { $0.state.withLock { $0.rowsMessages.contains(where: \.final) } }
        #expect(client.text(ofLine: frame.firstLine) == "line 1")
        #expect(client.text(ofLine: frame.firstLine + 19) == "line 20")

        // A second fetch with known versions confirms instead of resending.
        let known = (0 ..< 5).compactMap { offset -> WireKnownVersion? in
            let line = frame.firstLine + UInt64(offset)
            return client.state.withLock { $0.rows[line] }.map { WireKnownVersion(line: line, version: $0.version) }
        }
        client.channel.send(FetchRowsMessage(buffer: .normal, epoch: frame.epoch, start: frame.firstLine,
                                             count: 5, known: known), requestID: 2)
        try await client.wait("confirmation") { $0.state.withLock { $0.rowsMessages.count >= 2 } }
        let second = try #require(client.state.withLock { $0.rowsMessages.last })
        #expect(second.records.isEmpty)
        #expect(second.confirmed == [WireLineRange(start: frame.firstLine, count: 5)])

        // Lines before the first one are unavailable.
        client.channel.send(FetchRowsMessage(buffer: .normal, epoch: frame.epoch, start: frame.endLine,
                                             count: 3), requestID: 3)
        try await client.wait("unavailable") { $0.state.withLock { $0.rowsMessages.count >= 3 } }
        #expect(client.state.withLock { $0.rowsMessages.last?.unavailable.first?.count } == 3)
        client.close()
    }

    @Test func floodIsCoalescedByCredits() async throws {
        let host = makeHost(rows: 10)
        let client = try TestClient(host: host, autoAck: false)
        try await client.wait("first frame") { $0.frameCount >= 1 }
        for chunk in 0 ..< 200 {
            var output = ""
            for index in 0 ..< 50 { output += "flood \(chunk * 50 + index)\r\n" }
            host.inject(output)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        // Without acks the helper stops after the credit window.
        #expect(client.frameCount <= 2)
        // Acknowledge: the next frame shows the latest state, not every step.
        let last = try #require(client.lastFrame)
        client.channel.send(FrameAckMessage(sequence: last.sequence))
        try await client.wait("latest state") { client in
            client.screen().contains { $0.contains("flood 9999") }
        }
        #expect(client.frameCount <= 4)
        client.close()
    }

    @Test func eraseScrollbackStartsANewEpochWithFreshNumbers() async throws {
        let host = makeHost(rows: 10)
        var output = ""
        for index in 1 ... 50 { output += "old \(index)\r\n" }
        host.inject(output)
        let client = try TestClient(host: host)
        try await client.waitForScreen(containing: "old 50")
        let before = try #require(client.lastFrame)

        // clear; then more output, in one chunk.
        var after = "\u{1b}[H\u{1b}[2J\u{1b}[3J"
        for index in 1 ... 30 { after += "new \(index)\r\n" }
        host.inject(after)
        try await client.waitForScreen(containing: "new 30")
        let frame = try #require(client.lastFrame)
        #expect(frame.epoch > before.epoch)
        #expect(frame.firstLine >= before.endLine)

        client.channel.send(FetchRowsMessage(buffer: .normal, epoch: frame.epoch, start: frame.firstLine,
                                             count: Int(frame.endLine - frame.firstLine)), requestID: 9)
        try await client.wait("fetch") { $0.state.withLock { $0.rowsMessages.contains(where: \.final) } }
        let texts = (frame.firstLine ..< frame.endLine).compactMap { client.text(ofLine: $0) }
        #expect(!texts.contains { $0.hasPrefix("old") })
        client.close()
    }

    @Test func alternateScreenUsesItsOwnBufferAndRestoresTheNormalOne() async throws {
        let host = makeHost()
        host.inject("normal text")
        let client = try TestClient(host: host)
        try await client.waitForScreen(containing: "normal text")
        host.inject("\u{1b}[?1049h\u{1b}[HALT SCREEN")
        try await client.wait("alternate") { $0.lastFrame?.buffer == .alternate }
        try await client.waitForScreen(containing: "ALT SCREEN")
        host.inject("\u{1b}[?1049l")
        try await client.wait("normal") { $0.lastFrame?.buffer == .normal }
        try await client.waitForScreen(containing: "normal text")
        client.close()
    }

    @Test func columnResizeStartsANewEpochButRowsOnlyDoesNot() async throws {
        let host = makeHost(columns: 40, rows: 10)
        var output = ""
        for index in 1 ... 30 { output += "row \(index)\r\n" }
        host.inject(output)
        let client = try TestClient(host: host)
        try await client.waitForScreen(containing: "row 30")
        let start = try #require(client.lastFrame)

        client.channel.send(ResizeMessage(size: WireGridSize(columns: 40, rows: 12)))
        try await client.wait("rows resize") { $0.lastFrame?.rows == 12 }
        #expect(client.lastFrame?.epoch == start.epoch)

        client.channel.send(ResizeMessage(size: WireGridSize(columns: 60, rows: 12)))
        try await client.wait("columns resize") { $0.lastFrame?.columns == 60 }
        #expect(try #require(client.lastFrame).epoch > start.epoch)
        try await client.waitForScreen(containing: "row 30")
        client.close()
    }

    @Test func titleDirectoryAndBellArrive() async throws {
        let host = makeHost()
        let client = try TestClient(host: host)
        try await client.wait("first frame") { $0.frameCount >= 1 }
        host.inject("\u{1b}]0;my title\u{07}\u{1b}]7;file:///tmp\u{07}\u{07}")
        try await client.wait("title") { client in
            client.state.withLock { $0.frames.contains { $0.title == "my title" } }
        }
        try await client.wait("directory") { client in
            client.state.withLock { $0.frames.contains { $0.directory == "file:///tmp" } }
        }
        try await client.wait("bell") { client in
            client.state.withLock { $0.events.contains { $0.kind == .bell } }
        }
        client.close()
    }

    @Test func progressAndNotificationsArrive() async throws {
        let host = makeHost()
        let client = try TestClient(host: host)
        try await client.wait("first frame") { $0.frameCount >= 1 }
        host.inject("\u{1b}]9;4;1;40\u{07}\u{1b}]777;notify;Build;Done\u{07}\u{1b}]9;Tests passed\u{1b}\\")
        try await client.wait("progress") { client in
            client.state.withLock { $0.frames.contains { $0.progress?.state == 1 && $0.progress?.progress == 40 } }
        }
        func notifications(_ client: TestClient) -> [NotificationMessage] {
            client.state.withLock { state in
                state.events.filter { $0.kind == .notification }.compactMap { try? $0.decode(NotificationMessage.self) }
            }
        }
        try await client.wait("notifications") { notifications($0).count == 2 }
        #expect(notifications(client) == [NotificationMessage(title: "Build", body: "Done"),
                                          NotificationMessage(title: "", body: "Tests passed")])

        // A client that attaches while the report is current gets it too,
        // with its age: the client shows the bar for the time that is left.
        try await Task.sleep(nanoseconds: 300_000_000)
        let late = try TestClient(host: host)
        try await late.wait("progress for a late client") { client in
            client.state.withLock { $0.frames.contains { $0.progress?.state == 1 && $0.progress?.progress == 40 } }
        }
        let lateProgress = late.state.withLock { $0.frames.compactMap(\.progress).first }
        #expect((lateProgress?.age ?? 0) >= 250)
        host.inject("\u{1b}]9;4;0\u{07}")
        try await client.wait("progress removed") { client in
            client.state.withLock { $0.frames.contains { $0.progress?.state == 0 } }
        }
        late.close()
        client.close()
    }

    /// A program that prints notifications in a loop sends at most five in
    /// 30 seconds. A notification that comes while no client is attached
    /// goes to the owner (the helper keeps it in the session record).
    @Test func notificationsHaveALimitAndReachTheOwnerWhenDetached() async throws {
        let host = makeHost()
        let detached = Mutex<[NotificationMessage]>([])
        host.onDetachedNotification = { message in detached.withLock { $0.append(message) } }
        host.inject("\u{1b}]9;While detached\u{07}")
        let deadline = Date().addingTimeInterval(5)
        while detached.withLock({ $0.isEmpty }) && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(detached.withLock { $0 } == [NotificationMessage(title: "", body: "While detached")])

        let client = try TestClient(host: host)
        try await client.wait("first frame") { $0.frameCount >= 1 }
        host.inject((0 ..< 8).map { "\u{1b}]9;Note \($0)\u{07}" }.joined())
        func count(_ client: TestClient) -> Int {
            client.state.withLock { state in state.events.filter { $0.kind == .notification }.count }
        }
        try await client.wait("notifications") { count($0) == SessionHost.notificationLimit - 1 }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(count(client) == SessionHost.notificationLimit - 1)
        #expect(detached.withLock { $0.count } == 1)
        client.close()
    }

    @Test func synchronizedOutputIsWithheldUntilItEnds() async throws {
        let host = makeHost()
        let client = try TestClient(host: host)
        try await client.wait("first frame") { $0.frameCount >= 1 }
        host.inject("\u{1b}[?2026hhidden")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!client.screen().contains { $0.contains("hidden") })
        host.inject(" shown\u{1b}[?2026l")
        try await client.waitForScreen(containing: "hidden shown")
        client.close()
    }

    @Test func anchoredViewportServesScrollback() async throws {
        let host = makeHost(rows: 10)
        var output = ""
        for index in 1 ... 60 { output += "entry \(index)\r\n" }
        host.inject(output)
        let client = try TestClient(host: host)
        try await client.waitForScreen(containing: "entry 60")
        let frame = try #require(client.lastFrame)
        client.channel.send(SetViewportMessage(buffer: .normal, follow: false, top: frame.firstLine + 5))
        try await client.wait("anchored") { $0.lastFrame?.viewTop == frame.firstLine + 5 }
        #expect(client.screen().first == "entry 6")
        // New output does not move an anchored viewport.
        host.inject("entry 61\r\n")
        try await client.wait("extent grows") { $0.lastFrame.map { $0.endLine > frame.endLine } ?? false }
        #expect(client.lastFrame?.viewTop == frame.firstLine + 5)
        client.channel.send(SetViewportMessage(buffer: .normal, follow: true))
        try await client.waitForScreen(containing: "entry 61")
        client.close()
    }

    @Test func hyperlinksAreDefinedBeforeUse() async throws {
        let host = makeHost()
        host.inject("\u{1b}]8;;https://example.com\u{07}link\u{1b}]8;;\u{07} plain")
        let client = try TestClient(host: host)
        try await client.waitForScreen(containing: "link plain")
        let frame = try #require(client.lastFrame)
        let cell = try #require(client.cell(line: frame.viewTop, column: 0))
        #expect(cell.style.link != 0)
        #expect(client.state.withLock { $0.links[cell.style.link] }?.hasSuffix("https://example.com") == true)
        #expect(client.cell(line: frame.viewTop, column: 5)?.style.link == 0)
        client.close()
    }

    @Test func getTextReturnsBufferText() async throws {
        let host = makeHost()
        host.inject("first line\r\nsecond line")
        let client = try TestClient(host: host)
        try await client.waitForScreen(containing: "second line")
        let frame = try #require(client.lastFrame)
        client.channel.send(GetTextMessage(buffer: .normal, startLine: frame.viewTop, startColumn: 0,
                                           endLine: frame.viewTop + 1, endColumn: 5), requestID: 4)
        try await client.wait("text") { !$0.state.withLock { $0.texts.isEmpty } }
        let text = try #require(client.state.withLock { $0.texts.first })
        #expect(text.hasPrefix("first line"))
        #expect(text.contains("second"))
        client.close()
    }

    @Test func clearToStartEmptiesScreenAndScrollback() async throws {
        let host = makeHost(rows: 10)
        var output = ""
        for index in 1 ... 40 { output += "keep \(index)\r\n" }
        host.inject(output)
        let client = try TestClient(host: host)
        try await client.waitForScreen(containing: "keep 40")
        let before = try #require(client.lastFrame)
        #expect(before.endLine - before.firstLine > 10)
        client.channel.send(ResetMessage(action: .clearToStart))
        try await client.wait("cleared") { client in
            guard let frame = client.lastFrame else { return false }
            return frame.epoch > before.epoch && frame.endLine - frame.firstLine == 10 &&
                !client.screen().contains { $0.contains("keep") }
        }
        #expect(client.lastFrame?.cursor.line == client.lastFrame?.viewTop)
        client.close()
    }

    @Test func findPromptWalksShellPrompts() async throws {
        let host = makeHost(columns: 30, rows: 5)
        // Three commands with OSC 133 marks, each followed by 20 output rows.
        var output = ""
        for command in ["one", "two", "three"] {
            output += "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}\(command)\r\n\u{1b}]133;C\u{07}"
            for index in 1 ... 20 { output += "\(command) \(index)\r\n" }
            output += "\u{1b}]133;D;0\u{07}"
        }
        host.inject(output)
        let client = try TestClient(host: host, size: WireGridSize(columns: 30, rows: 5))
        try await client.wait("screen") { $0.lastFrame != nil }
        let frame = try #require(client.lastFrame)

        func prompt(from line: UInt64, upward: Bool) async throws -> PromptResultMessage? {
            let before = client.state.withLock { $0.events.filter { $0.kind == MessageKind.promptResult }.count }
            client.channel.send(FindPromptMessage(buffer: .normal, line: line, upward: upward),
                                flags: .required, requestID: 9)
            try await client.wait("prompt result") { client in
                client.state.withLock { $0.events.filter { $0.kind == MessageKind.promptResult }.count } > before
            }
            return try client.state.withLock { $0.events.last { $0.kind == MessageKind.promptResult } }?
                .decode(PromptResultMessage.self)
        }

        // Rows: prompt "one" at 0, "two" at 21, "three" at 42.
        let last = try #require(try await prompt(from: frame.endLine, upward: true))
        #expect(last.found)
        #expect(last.line == frame.firstLine + 42)
        let middle = try #require(try await prompt(from: last.line, upward: true))
        #expect(middle.line == frame.firstLine + 21)
        let first = try #require(try await prompt(from: middle.line, upward: true))
        #expect(first.line == frame.firstLine)
        let none = try #require(try await prompt(from: first.line, upward: true))
        #expect(!none.found)
        let down = try #require(try await prompt(from: first.line, upward: false))
        #expect(down.line == middle.line)
        let end = try #require(try await prompt(from: last.line, upward: false))
        #expect(!end.found)
        client.close()
    }

    @Test func searchFindsMatchesInScrollbackAndWraps() async throws {
        let host = makeHost(columns: 20, rows: 5)
        var output = ""
        for index in 1 ... 60 { output += index == 7 ? "the Needle is here\r\n" : "hay \(index)\r\n" }
        // A match that wraps across two rows (20 columns).
        output += "012345678901234567needle\r\n"
        host.inject(output)
        let client = try TestClient(host: host, size: WireGridSize(columns: 20, rows: 5))
        try await client.wait("screen") { $0.lastFrame != nil }
        let frame = try #require(client.lastFrame)

        func search(_ query: String, _ options: SessionSearchOptions, from line: UInt64, _ column: Int = 0) async throws -> SearchResultMessage? {
            let before = client.state.withLock { $0.events.filter { $0.kind == MessageKind.searchResult }.count }
            client.channel.send(SearchMessage(query: query, options: options, buffer: .normal,
                                              startLine: line, startColumn: column), requestID: 77)
            try await client.wait("search result") { client in
                client.state.withLock { $0.events.filter { $0.kind == MessageKind.searchResult }.count } > before
            }
            return try client.state.withLock { $0.events.last { $0.kind == MessageKind.searchResult } }?
                .decode(SearchResultMessage.self)
        }

        // Case-insensitive by default; found deep in scrollback.
        let first = try #require(try await search("needle", [], from: frame.firstLine))
        #expect(first.found)
        #expect(first.line == frame.firstLine + 6)
        #expect(first.column == 4)
        #expect(first.endColumn == 9)

        // Next match: it wraps across rows.
        let second = try #require(try await search("needle", [], from: first.line, first.column))
        #expect(second.found)
        #expect(second.endLine == second.line + 1)

        // Forward from the last match wraps around to the first.
        let wrapped = try #require(try await search("needle", [], from: second.line, second.column))
        #expect(wrapped.line == first.line)

        // Backward from the first match wraps to the last one.
        let back = try #require(try await search("needle", [.backward], from: first.line, first.column))
        #expect(back.line == second.line)

        // Backward from past the last line finds the newest match.
        let fromEnd = try #require(try await search("needle", [.backward], from: frame.endLine + 5))
        #expect(fromEnd.found)
        #expect(fromEnd.line == second.line)

        // Case-sensitive search does not find "needle" on line 7.
        let exact = try #require(try await search("Needle", [.caseSensitive], from: frame.firstLine))
        #expect(exact.line == first.line)
        let none = try #require(try await search("NEEDLE", [.caseSensitive], from: frame.firstLine))
        #expect(!none.found)

        // Regular expressions, and a bad one.
        let regex = try #require(try await search("hay 5[0-9]", [.regularExpression], from: frame.firstLine))
        #expect(regex.found)
        let bad = try #require(try await search("(", [.regularExpression], from: frame.firstLine))
        #expect(!bad.found)
        #expect(!bad.problem.isEmpty)
        client.close()
    }

    @Test func helloIsRequiredBeforeOtherMessages() async throws {
        let host = makeHost()
        var fds: [Int32] = [0, 0]
        _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        host.accept(socket: fds[1])
        let bytes = EnvelopeCodec.encode(AttachMessage(size: WireGridSize(columns: 10, rows: 5)))
        _ = bytes.withUnsafeBytes { write(fds[0], $0.baseAddress, $0.count) }
        var decoder = EnvelopeStreamDecoder()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(fds[0], &buffer, buffer.count)
        decoder.append(buffer[0 ..< max(0, count)])
        let envelope = try #require(try decoder.next())
        #expect(envelope.kind == .error)
        #expect(try envelope.decode(ErrorMessage.self).code == .badRequest)
        close(fds[0])
    }
}

struct SessionHostProcessTests {
    @Test func liveShellOutputKeysAndExit() async throws {
        let host = makeHost(rows: 10, executable: "/bin/sh",
                            arguments: ["-c", "printf '\\033[1;31mhello\\033[0m\\n'; seq 1 500; read line; echo \"got:$line\"; sleep 30"])
        let exited = ExitBox()
        host.onExit = { exited.set($0) }
        try host.start()
        let client = try TestClient(host: host)
        try await client.waitForScreen(containing: "500", timeout: 10)

        client.channel.send(TextMessage(text: "abc"))
        client.channel.send(KeyMessage(key: "Enter", code: "Enter"))
        try await client.waitForScreen(containing: "got:abc", timeout: 10)

        try await client.wait("session info", timeout: 5) { client in
            client.state.withLock { $0.events.contains { $0.kind == .sessionInfo } }
        }

        client.channel.send(TerminateMessage(signal: SIGTERM))
        try await client.wait("exit", timeout: 10) { client in
            client.state.withLock { $0.events.contains { $0.kind == .processExited } }
        }
        #expect(exited.isSet)
        client.close()
    }
}

struct SessionHostKeyTests {
    /// The helper sends the client's bytes for a key while the terminal has
    /// the modes that the client used. When the program changed the modes
    /// before the key arrived, the helper encodes the key again.
    @Test func keyBytesApplyOnlyWithTheClientsModes() async throws {
        let host = makeHost(rows: 10, executable: "/bin/sh",
                            arguments: ["-c", "stty -icanon -echo; echo ready; head -c 1 | xxd -p; head -c 8 | xxd -p; sleep 30"])
        try host.start()
        let client = try TestClient(host: host)
        try await client.waitForScreen(containing: "ready", timeout: 10)

        let controlW = KeyMessage(key: "w", code: "", modifiers: 4, bytes: [0x17], modes: 0)
        client.channel.send(controlW)
        try await client.waitForScreen(containing: "17", timeout: 10)
        // The program enables the kitty protocol; the client does not know yet.
        host.inject("\u{1b}[>1u")
        client.channel.send(controlW)
        try await client.waitForScreen(containing: "1b5b3131393b3575", timeout: 10)
        host.terminate(signal: SIGKILL)
        client.close()
    }
}

final class ExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32??
    func set(_ code: Int32?) { lock.withLock { value = .some(code) } }
    var isSet: Bool { lock.withLock { value != nil } }
}
