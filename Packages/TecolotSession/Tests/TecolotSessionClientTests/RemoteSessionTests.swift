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

func makeHost(rows: Int = 10, columns: Int = 40, scrollback: Int = 5000) -> SessionHost {
    let launch = SessionLaunch(
        executable: "/bin/sh",
        environment: ["PATH=/usr/bin:/bin"],
        columns: columns,
        rows: rows,
        scrollback: scrollback
    )
    return SessionHost(id: "client\(UInt32.random(in: 0 ... .max))", launch: launch, build: "test")
}

extension SessionHost {
    func inject(_ text: String) {
        let bytes = Array(text.utf8)
        ptyQueue.sync {
            dataReceived(slice: bytes[...])
        }
    }
}

func connect(
    _ host: SessionHost,
    rows: Int = 10,
    columns: Int = 40,
    clientInstance: String = ""
) throws -> RemoteSession {
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
        throw POSIXError(.EIO)
    }
    host.accept(socket: fds[1])
    let session = RemoteSession(socket: fds[0], clientName: "test", build: "test", clientInstance: clientInstance)
    session.start(size: WireGridSize(columns: columns, rows: rows), focused: true)
    return session
}

func eventually(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return
        }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
    Issue.record("timed out: \(what)")
}

func screen(_ session: RemoteSession) -> [String] {
    session.withState { state, cache in
        (0 ..< Int64(state.rows)).map { offset in
            let line = state.displayTop + offset
            guard let row = cache[line] else {
                return "<missing>"
            }
            return cache.text(from: (line, 0), to: (line, row.cells.count - 1))?
                .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) ?? ""
        }
    }
}

final class EventLog: @unchecked Sendable {
    let events = Mutex<[RemoteSessionEvent]>([])
    func add(_ event: RemoteSessionEvent) {
        events.withLock {
            $0.append(event)
        }
    }
    var titles: [String] {
        events.withLock {
            $0.compactMap {
                if case .title(let title) = $0 {
                    return title
                } else {
                    return nil
                }
            }
        }
    }
}

final class Inbox: Sendable {
    let items = Mutex<[Envelope]>([])
    var all: [Envelope] {
        items.withLock {
            $0
        }
    }
}

/// A helper that answers Hello, keeps what the client sends and passes
/// each message to `handle`.
func fakeHelper(_ handle: @escaping @Sendable (Envelope, MessageChannel) -> Void) throws
-> (MessageChannel, Inbox, RemoteSession) {
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
        throw POSIXError(.EIO)
    }
    let helper = MessageChannel(readFD: fds[1], writeFD: fds[1])
    let received = Inbox()
    helper.onMessage = { [unowned helper] envelope in
        received.items.withLock {
            $0.append(envelope)
        }
        if envelope.kind == .hello {
            helper.send(HelloReplyMessage(
                version: SessionProtocol.version,
                build: "fake",
                capabilities: [],
                sessionID: "fake"
            ), requestID: envelope.requestID)
        }
        handle(envelope, helper)
    }
    helper.start()
    let session = RemoteSession(socket: fds[0], clientName: "test", build: "test")
    session.start(size: WireGridSize(columns: 40, rows: 10), focused: true)
    return (helper, received, session)
}

struct RemoteSessionTests {
    @Test func settersQueuedAfterStartUpdateLegacyReattach() async throws {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw POSIXError(.EIO)
        }
        let helper = MessageChannel(readFD: fds[1], writeFD: fds[1])
        let attaches = Mutex<[AttachMessage]>([])
        helper.onMessage = { envelope in
            if envelope.kind == .attach, let attach = try? envelope.decode(AttachMessage.self) {
                attaches.withLock {
                    $0.append(attach)
                }
            }
        }
        helper.start()
        let session = RemoteSession(socket: fds[0], clientName: "test", build: "test")
        defer { session.close()
            helper.close()
        }
        // Hold start on its queue so the setters deterministically arrive first.
        session.queue.suspend()
        session.start(size: WireGridSize(columns: 80, rows: 24), focused: true, scale: 100)
        let currentSize = WireGridSize(columns: 132, rows: 43)
        session.resize(currentSize, scale: 200)
        session.setFocus(false)
        session.setFramesEnabled(false)
        session.queue.resume()
        try await eventually("initial attach") {
            attaches.withLock {
                $0.count == 1
            }
        }
        helper.send(HelloReplyMessage(version: 1, build: "old helper", capabilities: [], sessionID: "test"))
        try await eventually("legacy reattach") {
            attaches.withLock {
                $0.count == 2
            }
        }
        let attach = try #require(attaches.withLock {
            $0.last
        })
        #expect(attach.size == currentSize)
        #expect(attach.scale == 200)
        #expect(!attach.focused)
        #expect(attach.maximumFramesPerSecond == 1)
    }

    @Test(arguments: [SessionCapabilities(), [.statusOnly, .metadata]])
    func frameVisibilityWaitsForHelloAndAppliesLatestRequest(capabilities: SessionCapabilities) async throws {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw POSIXError(.EIO)
        }
        let helper = MessageChannel(readFD: fds[1], writeFD: fds[1])
        let attaches = Mutex<[Int]>([])
        let rates = Mutex<[Int]>([])
        helper.onMessage = { envelope in
            if envelope.kind == .attach, let attach = try? envelope.decode(AttachMessage.self) {
                attaches.withLock {
                    $0.append(attach.maximumFramesPerSecond)
                }
            } else if envelope.kind == .setFrameRate, let rate = try? envelope.decode(SetFrameRateMessage.self) {
                rates.withLock {
                    $0.append(rate.maximumFramesPerSecond)
                }
            }
        }
        helper.start()
        let session = RemoteSession(socket: fds[0], clientName: "test", build: "test")
        defer { session.close()
            helper.close()
        }
        session.start(size: WireGridSize(columns: 80, rows: 24), focused: true)
        try await eventually("initial attach") {
            attaches.withLock {
                $0.count == 1
            }
        }
        session.setFramesEnabled(false)
        session.setFramesEnabled(true)
        session.setFramesEnabled(false)
        await withCheckedContinuation { c in
            session.queue.async {
                c.resume()
            }
        }
        // No premature legacy reattach while hello is delayed.
        #expect(attaches.withLock {
            $0
        } == [120])
        helper.send(HelloReplyMessage(version: 1, build: "helper", capabilities: capabilities, sessionID: "test"))
        if capabilities.contains([.statusOnly, .metadata]) {
            try await eventually("suspend after hello") {
                rates.withLock {
                    $0.last == 0
                }
            }
            #expect(attaches.withLock {
                $0
            } == [120])
            #expect(rates.withLock {
                $0
            } == [0])
        } else {
            try await eventually("legacy fallback after hello") {
                attaches.withLock {
                    $0.last == 1
                }
            }
            #expect(attaches.withLock {
                $0
            } == [120, 1])
            #expect(rates.withLock {
                $0.isEmpty
            })
        }
    }

    @Test(arguments: [SessionCapabilities(), [.statusOnly]])
    func oldHelperReattachAndHistoryFetchDoNotReportNewOutput(capabilities: SessionCapabilities) async throws {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw POSIXError(.EIO)
        }
        let old = MessageChannel(readFD: fds[1], writeFD: fds[1])
        let rates = Mutex<[Int]>([])
        let changes = Mutex<[RemoteSessionChange]>([])
        func row(_ text: String, line: UInt64 = 0, version: UInt64) -> WireRowRecord {
            var encoder = RowEncoder()
            encoder.begin(WireRowHeader(columns: 40))
            for byte in text.utf8 {
                encoder.append(.ascii(byte), style: .plain)
            }
            return WireRowRecord(line: line, version: version, payload: encoder.finish())
        }
        let initialRow = row("existing", version: 1)
        old.onMessage = { envelope in
            switch envelope.kind {
            case .hello:
                old.send(HelloReplyMessage(version: SessionProtocol.version, build: "old", capabilities: capabilities, sessionID: "old"), requestID: envelope.requestID)
            case .attach:
                guard let attach = try? envelope.decode(AttachMessage.self) else {
                    return
                }
                let sequence = rates.withLock { values in
                    values.append(attach.maximumFramesPerSecond)
                    return UInt64(values.count)
                }
                old.send(FrameMessage(
                    sequence: sequence,
                    snapshotSequence: 1,
                    buffer: .normal,
                    epoch: 1,
                    firstLine: 0,
                    endLine: 10,
                    viewTop: 0,
                    columns: 40,
                    rows: 10,
                    cursor: WireCursor(line: 0, column: 0, visible: true, blink: false, style: 0),
                    changedRows: [initialRow]
                ))
            default:
                break
            }
        }
        old.start()
        let session = RemoteSession(socket: fds[0], clientName: "test", build: "test")
        session.onChange = { change in
            changes.withLock {
                $0.append(change)
            }
        }
        defer { session.close()
            old.close()
        }
        session.start(size: WireGridSize(columns: 40, rows: 10), focused: true)
        try await eventually("initial frame") {
            session.state.lastFrameSequence == 1
        }
        #expect(!changes.withLock {
            $0.contains {
                $0.contains(.output)
            }
        })
        changes.withLock {
            $0.removeAll()
        }
        session.setFramesEnabled(false)
        try await eventually("one fps reattach") {
            session.state.lastFrameSequence == 2
        }
        #expect(rates.withLock {
            $0.last
        } == 1)
        #expect(!changes.withLock {
            $0.contains {
                $0.contains(.rows) || $0.contains(.output)
            }
        })
        old.send(RowsMessage(snapshotSequence: 1, buffer: .normal, epoch: 1, final: true, records: [row("history", line: 9, version: 1)]))
        try await eventually("history fetch") {
            session.withState { _, cache in
                cache[9] != nil
            }
        }
        #expect(!changes.withLock {
            $0.contains {
                $0.contains(.output)
            }
        })
        old.send(FrameMessage(
            sequence: 3,
            snapshotSequence: 2,
            buffer: .normal,
            epoch: 1,
            firstLine: 0,
            endLine: 10,
            viewTop: 0,
            columns: 40,
            rows: 10,
            cursor: WireCursor(line: 0, column: 0, visible: true, blink: false, style: 0),
            changedRows: [row("new output", version: 2)]
        ))
        try await eventually("actual output") {
            changes.withLock {
                $0.contains {
                    $0.contains(.output)
                }
            }
        }
    }

    /// A restored pane preloads its saved rows into the session that it
    /// opens. The rows can have the versions of the helper's rows, so the
    /// first frame must replace all of them, also the rows above the screen.
    @Test func firstFrameReplacesPreloadedRows() async throws {
        let host = makeHost()
        host.inject((0 ..< 30).map {
            "line \($0)\r\n"
        }.joined())
        // The versions of the helper's rows, as a new session restored from an ended one can have.
        let probe = try connect(host)
        try await eventually("probe frame") {
            probe.state.lastFrameSequence > 0
        }
        probe.scroll(toTop: 0)
        try await eventually("probe scrollback") {
            screen(probe).first == "line 0"
        }
        let versions = probe.withState { _, cache in
            (0 ..< 31).map {
                cache[Int64($0)]?.version ?? 0
            }
        }
        probe.close()

        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw POSIXError(.EIO)
        }
        let session = RemoteSession(socket: fds[0], clientName: "test", build: "test")
        defer { session.close() }
        let saved = (0 ..< 31).map { line -> RemoteRowSnapshot.Row in
            var encoder = RowEncoder()
            encoder.begin(WireRowHeader(columns: 40))
            for byte in "stale".utf8 {
                encoder.append(.ascii(byte), style: .plain)
            }
            return RemoteRowSnapshot.Row(line: Int64(line), version: versions[line], payload: encoder.finish())
        }
        session.preload(RemoteRowSnapshot(
            sessionID: "old",
            savedAt: Date(),
            columns: 40,
            rows: 10,
            firstLine: 0,
            endLine: 31,
            savedRows: saved
        ))
        try await eventually("preloaded") {
            screen(session).first == "stale"
        }
        host.accept(socket: fds[1])
        session.start(size: WireGridSize(columns: 40, rows: 10), focused: true)
        try await eventually("first frame") {
            session.state.lastFrameSequence > 0
        }
        session.scroll(toTop: 0)
        try await eventually("scrollback from the helper") {
            screen(session).first == "line 0"
        }
        #expect(!screen(session).contains("stale"))
    }

    /// The app saves the rows at quit, the helper writes while no client is
    /// attached, and the next launch preloads the saved rows. The view keeps
    /// converted rows by line and stamp: the first frame stores the rows in
    /// a new cache, and a stamp of that cache must not be a stamp of a
    /// preloaded row, or the view shows the saved row.
    @Test func outputWhileDetachedReplacesPreloadedRows() async throws {
        let host = makeHost()
        host.inject("one\r\ntwo\r\n")
        let first = try connect(host)
        try await eventually("first attach") {
            screen(first).prefix(2) == ["one", "two"]
        }
        let pending = try #require(RemoteRowSnapshot.capture(first, sessionID: "s", limit: 100))
        let saved = try RemoteRowSnapshot.decode(pending.encode(savedAt: Date()))
        first.close()
        host.inject("detached\r\n")

        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw POSIXError(.EIO)
        }
        let session = RemoteSession(socket: fds[0], clientName: "test", build: "test")
        defer { session.close() }
        session.preload(saved)
        try await eventually("preloaded") {
            screen(session).prefix(2) == ["one", "two"]
        }
        let preloaded = session.withState { state, cache in
            Set((state.firstLine ..< state.endLine).compactMap {
                cache[$0]?.stamp
            })
        }
        host.accept(socket: fds[1])
        session.start(size: WireGridSize(columns: 40, rows: 10), focused: true)
        try await eventually("detached output") {
            screen(session).prefix(3) == ["one", "two", "detached"]
        }
        let attached = session.withState { state, cache in
            Set((state.firstLine ..< state.endLine).compactMap {
                cache[$0]?.stamp
            })
        }
        #expect(preloaded.isDisjoint(with: attached))
    }

    @Test func newerClientInstanceClosesTheOlderConnection() async throws {
        let host = makeHost()
        let first = try connect(host, clientInstance: "same-pane")
        defer { first.close() }
        try await eventually("first attached") {
            first.state.connected
        }
        let log = EventLog()
        first.onEvent = {
            log.add($0)
        }
        let second = try connect(host, clientInstance: "same-pane")
        defer { second.close() }
        try await eventually("second attached") {
            second.state.connected
        }
        try await eventually("first closed") {
            log.events.withLock { $0.contains {
                if case .closed = $0 {
                    return true
                }
                return false
            } }
        }
        #expect(!first.state.connected)
        #expect(second.state.connected)
    }

    @Test func emptyInstanceAllowsTwoConnections() async throws {
        let host = makeHost()
        let first = try connect(host)
        defer { first.close() }
        try await eventually("first attached") {
            first.state.connected
        }
        let second = try connect(host)
        defer { second.close() }
        try await eventually("second attached") {
            second.state.connected
        }
        #expect(first.state.connected)
    }

    @Test func attachShowsTheLiveScreen() async throws {
        let host = makeHost()
        host.inject("alpha\r\nbeta\r\n\u{1b}]0;hello title\u{07}")
        let session = try connect(host)
        let log = EventLog()
        session.onEvent = {
            log.add($0)
        }
        try await eventually("screen") {
            screen(session).first == "alpha"
        }
        #expect(screen(session)[1] == "beta")
        let state = session.state
        #expect(state.connected)
        #expect(state.follow)
        #expect(state.cursor?.line == UInt64(state.displayTop + 2))
        try await eventually("title") {
            log.titles.contains("hello title")
        }
        session.close()
    }

    @Test func scrollingFetchesAndShowsScrollback() async throws {
        let host = makeHost(rows: 10)
        var output = ""
        for index in 1 ... 1000 {
            output += "line \(index)\r\n"
        }
        host.inject(output)
        let session = try connect(host)
        try await eventually("live") {
            screen(session).contains("line 1000")
        }
        let before = session.state
        #expect(before.endLine - before.firstLine == 1001)

        let top = session.scroll(by: -500)
        #expect(!session.state.follow)
        try await eventually("rows above") {
            screen(session).first == "line \(top - before.firstLine + 1)"
        }
        // Prefetch fills more than the viewport.
        try await eventually("prefetch") {
            session.withState { _, cache in
                cache.count
            } > 30
        }

        // New output does not move the anchored view.
        host.inject("line 1001\r\n")
        try await eventually("extent") {
            session.state.endLine == before.endLine + 1
        }
        #expect(session.state.displayTop == top)

        session.followLive()
        try await eventually("follow") {
            screen(session).contains("line 1001")
        }
        session.close()
    }

    @Test func scrollingToTheBottomFollowsAgain() async throws {
        let host = makeHost(rows: 10)
        var output = ""
        for index in 1 ... 100 {
            output += "row \(index)\r\n"
        }
        host.inject(output)
        let session = try connect(host)
        try await eventually("live") {
            screen(session).contains("row 100")
        }
        session.scroll(by: -20)
        #expect(!session.state.follow)
        session.scroll(by: 1000)
        #expect(session.state.follow)
        session.close()
    }

    @Test func textComesFromTheCacheOrTheHelper() async throws {
        let host = makeHost(rows: 5, columns: 20)
        host.inject("one two three four five six\r\nshort")
        let session = try connect(host, rows: 5, columns: 20)
        try await eventually("screen") {
            screen(session).contains("short")
        }
        let top = session.state.displayTop
        let cached = session.withState { _, cache in
            cache.text(from: (top, 0), to: (top + 2, 4))
        }
        #expect(cached == "one two three four five six\nshort")

        let box = Mutex<String?>(nil)
        session.text(from: (top, 0), to: (top + 2, 4)) { text in
            box.withLock {
                $0 = text
            }
        }
        try await eventually("helper text") {
            box.withLock {
                $0
            } != nil
        }
        #expect(box.withLock {
            $0
        }?.contains("short") == true)
        session.close()
    }

    /// A selection can reach past the cells of a cached row: a row from a
    /// narrower grid, or an empty row. The text stops at the row's end.
    @Test func textPastTheEndOfACachedRowIsEmpty() async throws {
        let host = makeHost(rows: 5, columns: 20)
        host.inject("short\r\nnext")
        let session = try connect(host, rows: 5, columns: 20)
        try await eventually("screen") {
            screen(session).contains("next")
        }
        let top = session.state.displayTop
        let width = session.withState { _, cache in
            cache[top]?.cells.count ?? 0
        }
        let past = session.withState { _, cache in
            cache.text(from: (top, width + 5), to: (top, width + 10))
        }
        #expect(past == "")
        let spanning = session.withState { _, cache in
            cache.text(from: (top, width + 5), to: (top + 1, 3))
        }
        #expect(spanning == "\nnext")
        session.close()
    }

    /// A selection to the last column (a triple-click) does not copy the
    /// empty cells after the text. A space that the program wrote stays.
    @Test func textDropsEmptyCellsAtTheEndOfTheSelection() async throws {
        let host = makeHost(rows: 5, columns: 20)
        host.inject("ls -la\r\nword  \r\nnext")
        let session = try connect(host, rows: 5, columns: 20)
        try await eventually("screen") {
            screen(session).contains("next")
        }
        let top = session.state.displayTop
        let texts = session.withState { _, cache in
            [
                cache.text(from: (top, 0), to: (top, 19)),
                cache.text(from: (top + 1, 0), to: (top + 1, 19)),
                cache.text(from: (top + 1, 0), to: (top + 1, 4)),
                cache.text(from: (top + 3, 0), to: (top + 3, 19))
            ]
        }
        #expect(texts == ["ls -la", "word  ", "word ", ""])
        session.close()
    }

    @Test func floodEndsWithTheLatestScreen() async throws {
        let host = makeHost(rows: 10)
        let session = try connect(host)
        try await eventually("attached") {
            session.state.connected
        }
        for chunk in 0 ..< 100 {
            var output = ""
            for index in 0 ..< 100 {
                output += "flood \(chunk * 100 + index)\r\n"
            }
            host.inject(output)
        }
        try await eventually("latest") {
            screen(session).contains("flood 9999")
        }
        session.close()
    }

    @Test func pasteReportsItsStatus() async throws {
        let host = makeHost()
        let session = try connect(host)
        try await eventually("attached") {
            session.state.connected
        }
        let result = Mutex<PasteResultMessage?>(nil)
        session.paste("echo hi") { value in
            result.withLock {
                $0 = value
            }
        }
        try await eventually("paste result") {
            result.withLock {
                $0
            } != nil
        }
        #expect(result.withLock {
            $0
        }?.status == .sent)
        session.close()
    }

    @Test func helperAdvertisesWhatItHandles() async throws {
        let host = makeHost()
        let session = try connect(host)
        try await eventually("attached") {
            session.state.connected
        }
        #expect(session.state.helperCapabilities.contains([.search, .reset]))
        session.close()
    }

    /// An older helper does not know Search. It answers a required message
    /// that it does not know with Error(unsupported), and the search must
    /// end with a reason instead of waiting forever.
    @Test func searchOnAnOlderHelperEndsWithAProblem() async throws {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw POSIXError(.EIO)
        }
        let old = MessageChannel(readFD: fds[1], writeFD: fds[1])
        old.onMessage = { envelope in
            switch envelope.kind {
            case .hello:
                old.send(HelloReplyMessage(
                    version: SessionProtocol.version,
                    build: "old",
                    capabilities: [],
                    sessionID: "old"
                ), requestID: envelope.requestID)
            default:
                if envelope.flags.contains(.required) {
                    old.send(
                        ErrorMessage(code: .unsupported, failedKind: envelope.kind, message: "unsupported"),
                        requestID: envelope.requestID
                    )
                }
            }
        }
        old.start()
        let session = RemoteSession(socket: fds[0], clientName: "test", build: "test")
        session.start(size: WireGridSize(columns: 40, rows: 10), focused: true)
        try await eventually("attached") {
            session.state.connected
        }
        #expect(session.state.helperCapabilities.isEmpty)
        let result = Mutex<SearchResultMessage?>(nil)
        session.search("x", options: [], from: (0, 0)) { value in
            result.withLock {
                $0 = value
            }
        }
        try await eventually("search answer") {
            result.withLock {
                $0
            } != nil
        }
        #expect(result.withLock {
            $0
        }?.found == false)
        #expect(result.withLock {
            $0
        }?.problem.isEmpty == false)
        session.close()
        old.close()
    }

    /// A frame whose row does not decode still returns its credit: the
    /// helper holds the next frame until the ack comes.
    @Test func frameWithABadRowIsAcknowledged() async throws {
        let (helper, received, session) = try fakeHelper { _, _ in }
        try await eventually("attached") {
            session.state.connected
        }
        helper.send(FrameMessage(
            sequence: 7,
            snapshotSequence: 7,
            buffer: .normal,
            epoch: 1,
            firstLine: 0,
            endLine: 10,
            viewTop: 0,
            columns: 40,
            rows: 10,
            cursor: WireCursor(line: 0, column: 0, visible: true, blink: false, style: 0),
            changedRows: [WireRowRecord(line: 0, payload: [0xFF, 0xFF, 0xFF])]
        ))
        try await eventually("frame ack") {
            received.all.contains { envelope in
                envelope.kind == .frameAck && (try? envelope.decode(FrameAckMessage.self))?.sequence == 7
            }
        }
        session.close()
        helper.close()
    }

    /// An error reply to a row fetch frees its slot, so that later fetches
    /// go out.
    @Test func failedFetchFreesItsSlot() async throws {
        let (helper, received, session) = try fakeHelper { envelope, helper in
            guard envelope.kind == .fetchRows else {
                return
            }
            helper.send(
                ErrorMessage(code: .badRequest, failedKind: envelope.kind, message: "no"),
                requestID: envelope.requestID
            )
        }
        try await eventually("attached") {
            session.state.connected
        }
        let fetches = {
            received.all.filter {
                $0.kind == .fetchRows
            }.count
        }
        helper.send(FrameMessage(
            sequence: 1,
            snapshotSequence: 1,
            buffer: .normal,
            epoch: 1,
            firstLine: 0,
            endLine: 5000,
            viewTop: 4990,
            columns: 40,
            rows: 10,
            cursor: WireCursor(line: 4990, column: 0, visible: true, blink: false, style: 0)
        ))
        try await eventually("first fetches") {
            fetches() > 0
        }
        // Each scroll to a new place fetches a new chunk. Without a free
        // slot for each failed fetch, the fifth place gets no fetch.
        for top in stride(from: Int64(0), through: 4000, by: 1000) {
            // Let the error replies arrive.
            try await Task.sleep(nanoseconds: 100_000_000)
            let before = fetches()
            _ = session.scroll(toTop: top)
            try await eventually("fetch at \(top)") {
                fetches() > before
            }
        }
        session.close()
        helper.close()
    }

    @Test func oversizedImagesAreRefused() {
        #expect(ImageDataMessage(imageID: 1, width: 8192, height: 8192).hasAcceptableSize)
        #expect(!ImageDataMessage(imageID: 1, width: 65_535, height: 65_535).hasAcceptableSize)
        #expect(!ImageDataMessage(imageID: 1, width: 0, height: 10).hasAcceptableSize)
    }

    @Test func imagesArriveWithoutAsking() async throws {
        let host = makeHost(rows: 10, columns: 40)
        let session = try connect(host, rows: 10, columns: 40)
        try await eventually("attached") {
            session.state.connected
        }
        #expect(session.state.maximumBidiParagraphRows == 500)
        // A red Sixel image and a green Kitty image.
        let green = Data([0, 255, 0, 0, 255, 0, 0, 255, 0, 0, 255, 0]).base64EncodedString()
        host.inject("A\u{1b}Pq#0;2;100;0;0#0!20~-!20~\u{1b}\\\r\nB\u{1b}_Gi=3,f=24,s=2,v=2,a=T,c=2,r=1;\(green)\u{1b}\\")
        var sliceID: UInt64?
        try await eventually("slice") {
            sliceID = session.withState { state, cache in
                (state.firstLine ..< state.endLine).lazy.compactMap {
                    cache[$0]?.header.images.first?.imageID
                }.first
            }
            return sliceID != nil
        }
        let id = try #require(sliceID)
        try await eventually("sixel pixels") {
            session.image(id) != nil
        }
        #expect(session.image(id)?.width == 20)
        #expect(Array(session.image(id)?.rgba.prefix(4) ?? []) == [255, 0, 0, 255])

        let kitty = try #require(session.state.kitty)
        let kittyImage = try #require(kitty.images.first)
        #expect(kittyImage.kittyID == 3)
        try await eventually("kitty pixels") {
            session.image(kittyImage.imageID) != nil
        }
        #expect(session.image(kittyImage.imageID)?.rgba.count == 16)
        session.close()
    }
}

struct ProgramStatusClientTests {
    @Test func programStatusEventsArriveWithoutFramesAndResume() async throws {
        let host = makeHost()
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw POSIXError(.EIO)
        }
        let session = RemoteSession(socket: fds[0], clientName: "status test", build: "test")
        let log = EventLog()
        session.onEvent = {
            log.add($0)
        }
        defer { session.close() }
        host.accept(socket: fds[1])
        session.start(size: WireGridSize(columns: 40, rows: 10), focused: false, framesEnabled: false)
        host.inject("background\u{1b}]7501;state=done\u{7}\u{1b}]0;hidden metadata\u{7}\u{1b}]1;hidden icon\u{7}\u{1b}]7;file://localhost/tmp/m15\u{7}")
        try await eventually("program status event") {
            log.events.withLock { events in events.contains { event in
                if case .programStatus(let snapshot) = event {
                    return snapshot.records.first?.state == .done
                }
                return false
            } }
        }
        try await eventually("metadata received while paused") {
            session.state.title == "hidden metadata" && session.state.iconTitle == "hidden icon" && session.state.directory == "file://localhost/tmp/m15"
        }
        #expect(session.state.title == "hidden metadata")
        #expect(session.state.iconTitle == "hidden icon")
        #expect(session.state.directory == "file://localhost/tmp/m15")
        #expect(session.state.lastFrameSequence == 0)
        session.setFramesEnabled(true)
        try await eventually("frames resumed") {
            session.state.lastFrameSequence > 0
        }
        #expect(screen(session).contains {
            $0.contains("background")
        })
    }
}

extension ProgramStatusClientTests {
    @Test(arguments: [SessionCapabilities(), [.statusOnly]])
    func initiallyHiddenClientKeepsMetadataFallbackForOlderHelpers(capabilities: SessionCapabilities) async throws {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw POSIXError(.EIO)
        }
        let helper = MessageChannel(socket: fds[1])
        let rates = Mutex<[Int]>([])
        helper.onMessage = { envelope in
            if envelope.kind == .hello {
                helper.send(HelloReplyMessage(version: 1, build: "old", capabilities: capabilities, sessionID: "old"))
            } else if envelope.kind == .attach, let attach = try? envelope.decode(AttachMessage.self) {
                rates.withLock {
                    $0.append(attach.maximumFramesPerSecond)
                }
            } else if envelope.kind == .setFrameRate {
                Issue.record("metadata-incapable helper must use legacy attach fallback")
            }
        }
        helper.start()
        let session = RemoteSession(socket: fds[0], clientName: "test", build: "test")
        defer { session.close()
            helper.close()
        }
        session.start(size: .init(columns: 40, rows: 10), focused: false, framesEnabled: false)
        try await eventually("hidden initial attach falls back to one fps") {
            rates.withLock {
                $0.last == 1
            }
        }
        session.setFramesEnabled(true)
        try await eventually("visible original rate restored") {
            rates.withLock {
                $0.last == 120
            }
        }
    }
}
