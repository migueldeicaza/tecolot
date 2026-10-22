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
    let launch = SessionLaunch(executable: "/bin/sh", environment: ["PATH=/usr/bin:/bin"],
                               columns: columns, rows: rows, scrollback: scrollback)
    return SessionHost(id: "client\(UInt32.random(in: 0 ... .max))", launch: launch, build: "test")
}

extension SessionHost {
    func inject(_ text: String) {
        let bytes = Array(text.utf8)
        ptyQueue.sync { dataReceived(slice: bytes[...]) }
    }
}

func connect(_ host: SessionHost, rows: Int = 10, columns: Int = 40,
             clientInstance: String = "") throws -> RemoteSession {
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
    host.accept(socket: fds[1])
    let session = RemoteSession(socket: fds[0], clientName: "test", build: "test", clientInstance: clientInstance)
    session.start(size: WireGridSize(columns: columns, rows: rows), focused: true)
    return session
}

func eventually(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
    Issue.record("timed out: \(what)")
}

func screen(_ session: RemoteSession) -> [String] {
    session.withState { state, cache in
        (0 ..< Int64(state.rows)).map { offset in
            let line = state.displayTop + offset
            guard let row = cache[line] else { return "<missing>" }
            return cache.text(from: (line, 0), to: (line, row.cells.count - 1))?
                .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) ?? ""
        }
    }
}

final class EventLog: @unchecked Sendable {
    let events = Mutex<[RemoteSessionEvent]>([])
    func add(_ event: RemoteSessionEvent) { events.withLock { $0.append(event) } }
    var titles: [String] {
        events.withLock { $0.compactMap { if case .title(let title) = $0 { return title } else { return nil } } }
    }
}

struct RemoteSessionTests {
    /// A restored pane preloads its saved rows into the session that it
    /// opens. The rows can have the versions of the helper's rows, so the
    /// first frame must replace all of them, also the rows above the screen.
    @Test func firstFrameReplacesPreloadedRows() async throws {
        let host = makeHost()
        host.inject((0 ..< 30).map { "line \($0)\r\n" }.joined())
        // The versions of the helper's rows, as a new session restored from an ended one can have.
        let probe = try connect(host)
        try await eventually("probe frame") { probe.state.lastFrameSequence > 0 }
        probe.scroll(toTop: 0)
        try await eventually("probe scrollback") { screen(probe).first == "line 0" }
        let versions = probe.withState { _, cache in (0 ..< 31).map { cache[Int64($0)]?.version ?? 0 } }
        probe.close()

        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
        let session = RemoteSession(socket: fds[0], clientName: "test", build: "test")
        defer { session.close() }
        let saved = (0 ..< 31).map { line -> RemoteRowSnapshot.Row in
            var encoder = RowEncoder()
            encoder.begin(WireRowHeader(columns: 40))
            for byte in "stale".utf8 { encoder.append(.ascii(byte), style: .plain) }
            return RemoteRowSnapshot.Row(line: Int64(line), version: versions[line], payload: encoder.finish())
        }
        session.preload(RemoteRowSnapshot(sessionID: "old", savedAt: Date(), columns: 40, rows: 10, firstLine: 0,
                                          endLine: 31, savedRows: saved))
        try await eventually("preloaded") { screen(session).first == "stale" }
        host.accept(socket: fds[1])
        session.start(size: WireGridSize(columns: 40, rows: 10), focused: true)
        try await eventually("first frame") { session.state.lastFrameSequence > 0 }
        session.scroll(toTop: 0)
        try await eventually("scrollback from the helper") { screen(session).first == "line 0" }
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
        try await eventually("first attach") { screen(first).prefix(2) == ["one", "two"] }
        let pending = try #require(RemoteRowSnapshot.capture(first, sessionID: "s", limit: 100))
        let saved = try RemoteRowSnapshot.decode(pending.encode(savedAt: Date()))
        first.close()
        host.inject("detached\r\n")

        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
        let session = RemoteSession(socket: fds[0], clientName: "test", build: "test")
        defer { session.close() }
        session.preload(saved)
        try await eventually("preloaded") { screen(session).prefix(2) == ["one", "two"] }
        let preloaded = session.withState { state, cache in
            Set((state.firstLine ..< state.endLine).compactMap { cache[$0]?.stamp })
        }
        host.accept(socket: fds[1])
        session.start(size: WireGridSize(columns: 40, rows: 10), focused: true)
        try await eventually("detached output") { screen(session).prefix(3) == ["one", "two", "detached"] }
        let attached = session.withState { state, cache in
            Set((state.firstLine ..< state.endLine).compactMap { cache[$0]?.stamp })
        }
        #expect(preloaded.isDisjoint(with: attached))
    }

    @Test func newerClientInstanceClosesTheOlderConnection() async throws {
        let host = makeHost()
        let first = try connect(host, clientInstance: "same-pane")
        defer { first.close() }
        try await eventually("first attached") { first.state.connected }
        let log = EventLog()
        first.onEvent = { log.add($0) }
        let second = try connect(host, clientInstance: "same-pane")
        defer { second.close() }
        try await eventually("second attached") { second.state.connected }
        try await eventually("first closed") {
            log.events.withLock { $0.contains { if case .closed = $0 { return true }; return false } }
        }
        #expect(!first.state.connected)
        #expect(second.state.connected)
    }

    @Test func emptyInstanceAllowsTwoConnections() async throws {
        let host = makeHost()
        let first = try connect(host)
        defer { first.close() }
        try await eventually("first attached") { first.state.connected }
        let second = try connect(host)
        defer { second.close() }
        try await eventually("second attached") { second.state.connected }
        #expect(first.state.connected)
    }

    @Test func attachShowsTheLiveScreen() async throws {
        let host = makeHost()
        host.inject("alpha\r\nbeta\r\n\u{1b}]0;hello title\u{07}")
        let session = try connect(host)
        let log = EventLog()
        session.onEvent = { log.add($0) }
        try await eventually("screen") { screen(session).first == "alpha" }
        #expect(screen(session)[1] == "beta")
        let state = session.state
        #expect(state.connected)
        #expect(state.follow)
        #expect(state.cursor?.line == UInt64(state.displayTop + 2))
        try await eventually("title") { log.titles.contains("hello title") }
        session.close()
    }

    @Test func scrollingFetchesAndShowsScrollback() async throws {
        let host = makeHost(rows: 10)
        var output = ""
        for index in 1 ... 1000 { output += "line \(index)\r\n" }
        host.inject(output)
        let session = try connect(host)
        try await eventually("live") { screen(session).contains("line 1000") }
        let before = session.state
        #expect(before.endLine - before.firstLine == 1001)

        let top = session.scroll(by: -500)
        #expect(!session.state.follow)
        try await eventually("rows above") { screen(session).first == "line \(top - before.firstLine + 1)" }
        // Prefetch fills more than the viewport.
        try await eventually("prefetch") { session.withState { _, cache in cache.count } > 30 }

        // New output does not move the anchored view.
        host.inject("line 1001\r\n")
        try await eventually("extent") { session.state.endLine == before.endLine + 1 }
        #expect(session.state.displayTop == top)

        session.followLive()
        try await eventually("follow") { screen(session).contains("line 1001") }
        session.close()
    }

    @Test func scrollingToTheBottomFollowsAgain() async throws {
        let host = makeHost(rows: 10)
        var output = ""
        for index in 1 ... 100 { output += "row \(index)\r\n" }
        host.inject(output)
        let session = try connect(host)
        try await eventually("live") { screen(session).contains("row 100") }
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
        try await eventually("screen") { screen(session).contains("short") }
        let top = session.state.displayTop
        let cached = session.withState { _, cache in cache.text(from: (top, 0), to: (top + 2, 4)) }
        #expect(cached == "one two three four five six\nshort")

        let box = Mutex<String?>(nil)
        session.text(from: (top, 0), to: (top + 2, 4)) { text in box.withLock { $0 = text } }
        try await eventually("helper text") { box.withLock { $0 } != nil }
        #expect(box.withLock { $0 }?.contains("short") == true)
        session.close()
    }

    @Test func floodEndsWithTheLatestScreen() async throws {
        let host = makeHost(rows: 10)
        let session = try connect(host)
        try await eventually("attached") { session.state.connected }
        for chunk in 0 ..< 100 {
            var output = ""
            for index in 0 ..< 100 { output += "flood \(chunk * 100 + index)\r\n" }
            host.inject(output)
        }
        try await eventually("latest") { screen(session).contains("flood 9999") }
        session.close()
    }

    @Test func pasteReportsItsStatus() async throws {
        let host = makeHost()
        let session = try connect(host)
        try await eventually("attached") { session.state.connected }
        let result = Mutex<PasteResultMessage?>(nil)
        session.paste("echo hi") { value in result.withLock { $0 = value } }
        try await eventually("paste result") { result.withLock { $0 } != nil }
        #expect(result.withLock { $0 }?.status == .sent)
        session.close()
    }

    @Test func helperAdvertisesWhatItHandles() async throws {
        let host = makeHost()
        let session = try connect(host)
        try await eventually("attached") { session.state.connected }
        #expect(session.state.helperCapabilities.contains([.search, .reset]))
        session.close()
    }

    /// An older helper does not know Search. It answers a required message
    /// that it does not know with Error(unsupported), and the search must
    /// end with a reason instead of waiting forever.
    @Test func searchOnAnOlderHelperEndsWithAProblem() async throws {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
        let old = MessageChannel(readFD: fds[1], writeFD: fds[1])
        old.onMessage = { envelope in
            switch envelope.kind {
            case .hello:
                old.send(HelloReplyMessage(version: SessionProtocol.version, build: "old", capabilities: [],
                                           sessionID: "old"), requestID: envelope.requestID)
            default:
                if envelope.flags.contains(.required) {
                    old.send(ErrorMessage(code: .unsupported, failedKind: envelope.kind, message: "unsupported"),
                             requestID: envelope.requestID)
                }
            }
        }
        old.start()
        let session = RemoteSession(socket: fds[0], clientName: "test", build: "test")
        session.start(size: WireGridSize(columns: 40, rows: 10), focused: true)
        try await eventually("attached") { session.state.connected }
        #expect(session.state.helperCapabilities.isEmpty)
        let result = Mutex<SearchResultMessage?>(nil)
        session.search("x", options: [], from: (0, 0)) { value in result.withLock { $0 = value } }
        try await eventually("search answer") { result.withLock { $0 } != nil }
        #expect(result.withLock { $0 }?.found == false)
        #expect(result.withLock { $0 }?.problem.isEmpty == false)
        session.close()
        old.close()
    }

    @Test func imagesArriveWithoutAsking() async throws {
        let host = makeHost(rows: 10, columns: 40)
        let session = try connect(host, rows: 10, columns: 40)
        try await eventually("attached") { session.state.connected }
        #expect(session.state.maximumBidiParagraphRows == 500)
        // A red Sixel image and a green Kitty image.
        let green = Data([0, 255, 0, 0, 255, 0, 0, 255, 0, 0, 255, 0]).base64EncodedString()
        host.inject("A\u{1b}Pq#0;2;100;0;0#0!20~-!20~\u{1b}\\\r\nB\u{1b}_Gi=3,f=24,s=2,v=2,a=T,c=2,r=1;\(green)\u{1b}\\")
        var sliceID: UInt64?
        try await eventually("slice") {
            sliceID = session.withState { state, cache in
                (state.firstLine ..< state.endLine).lazy.compactMap { cache[$0]?.header.images.first?.imageID }.first
            }
            return sliceID != nil
        }
        let id = try #require(sliceID)
        try await eventually("sixel pixels") { session.image(id) != nil }
        #expect(session.image(id)?.width == 20)
        #expect(Array(session.image(id)?.rgba.prefix(4) ?? []) == [255, 0, 0, 255])

        let kitty = try #require(session.state.kitty)
        let kittyImage = try #require(kitty.images.first)
        #expect(kittyImage.kittyID == 3)
        try await eventually("kitty pixels") { session.image(kittyImage.imageID) != nil }
        #expect(session.image(kittyImage.imageID)?.rgba.count == 16)
        session.close()
    }
}
