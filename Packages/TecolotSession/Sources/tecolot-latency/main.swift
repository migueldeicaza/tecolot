//
// tecolot-latency: measures the time from one keystroke to the updated
// screen state, through each path that a pane can use.
//
//   swift run -c release tecolot-latency [keys] [flood-rounds]
//
// The child is /bin/cat. The PTY line discipline echoes each typed byte,
// so the numbers show the cost of our own pipeline, not of a shell.
//
// Paths:
//   local    LocalProcess + Terminal.feed in this process (a local pane,
//            without the draw).
//   inproc   RemoteSession -> socketpair -> SessionHost in this process.
//   helper   RemoteSession -> Unix socket -> the tecolot-sessiond process.
//
// The draw is not measured: local and persistent panes both mark the same
// FrameDriver dirty, so that stage costs the same.
//

import Foundation
import Synchronization
import SwiftTerm
import TecolotSessionClient
import TecolotSessionDirectory
import TecolotSessionHost
import TecolotTransport
import TecolotWire
#if canImport(Darwin)
import Darwin
#endif

func uptime() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

let environment = ["PATH=/usr/bin:/bin", "TERM=xterm-256color", "LANG=en_US.UTF-8"]
let kill: UInt8 = 0x15 // ^U erases the typed line, so cat never sees a full line.
let lineLength = 40

/// Waits for the echo of each keystroke and keeps the time it took.
final class Probe: @unchecked Sendable {
    private struct State {
        var target = 0
        var waiting = false
    }
    private let state = Mutex(State())
    private let arrived = DispatchSemaphore(value: 0)

    /// Call from the delivery thread with the count that is now visible.
    func observe(_ count: Int) {
        let fire = state.withLock { state -> Bool in
            guard state.waiting, count >= state.target else { return false }
            state.waiting = false
            return true
        }
        if fire { arrived.signal() }
    }

    /// Sends one key and returns the nanoseconds until `observe` sees `target`.
    func measure(target: Int, send: () -> Void) -> UInt64? {
        state.withLock {
            $0.target = target
            $0.waiting = true
        }
        let start = uptime()
        send()
        guard arrived.wait(timeout: .now() + 2) == .success else {
            state.withLock { $0.waiting = false }
            return nil
        }
        return uptime() - start
    }
}

protocol Path: AnyObject {
    var name: String { get }
    var probe: Probe { get }
    /// Sends `bytes` as typed input.
    func type(_ bytes: [UInt8])
    /// Starts counting from zero after a line kill.
    func resetCount()
    func stop()
}

// MARK: Local pane

final class LocalPath: Path, LocalProcessDelegate, TerminalDelegate, @unchecked Sendable {
    let name = "local"
    let probe = Probe()
    private let queue = DispatchQueue(label: "local.pty", qos: .userInitiated)
    private var terminal: Terminal!
    private var process: LocalProcess!

    init() throws {
        terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 24))
        process = LocalProcess(delegate: self, dispatchQueue: queue)
        let result = process.startProcessChecked(executable: "/bin/cat", environment: environment)
        if case .failure(let error) = result { throw error }
    }

    func type(_ bytes: [UInt8]) { process.send(data: bytes[...]) }
    func resetCount() {}
    func stop() { process.terminate() }

    func dataReceived(slice: ArraySlice<UInt8>) {
        terminal.feed(buffer: slice)
        probe.observe(terminal.getCursorLocation().x)
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {}
    func getWindowSize() -> winsize { winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0) }
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

// MARK: Persistent pane

final class RemotePath: Path, @unchecked Sendable {
    let name: String
    let probe = Probe()
    let session: RemoteSession
    private let cleanup: () -> Void

    init(name: String, socket: Int32, cleanup: @escaping () -> Void) throws {
        self.name = name
        self.cleanup = cleanup
        session = RemoteSession(socket: socket, clientName: "latency", build: "latency")
        session.onChange = { [weak self] _ in
            guard let self else { return }
            let column = session.withState { state, _ in Int(state.cursor?.column ?? 0) }
            probe.observe(column)
        }
        session.start(size: WireGridSize(columns: 80, rows: 24), focused: true)
        let deadline = Date().addingTimeInterval(5)
        while !session.state.connected || session.state.cursor == nil {
            guard Date() < deadline else { throw TransportError("\(name): no first frame") }
            usleep(1000)
        }
    }

    func type(_ bytes: [UInt8]) {
        // The app sends printable keys as Text; the helper writes them with
        // sendHostText, under the terminal lock.
        if bytes == [kill] {
            session.send(bytes: bytes)
        } else {
            session.send(text: String(decoding: bytes, as: UTF8.self))
        }
    }

    func resetCount() {}
    func stop() {
        session.close()
        cleanup()
    }
}

func launch() -> SessionLaunch {
    SessionLaunch(executable: "/bin/cat", environment: environment, columns: 80, rows: 24)
}

func inProcessPath() throws -> RemotePath {
    let host = SessionHost(id: "latency", launch: launch(), build: "latency")
    try host.start()
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw TransportError("socketpair") }
    host.accept(socket: fds[1])
    return try RemotePath(name: "inproc", socket: fds[0]) { host.terminate(signal: SIGKILL) }
}

func helperPath() throws -> RemotePath {
    let tool = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let helper = tool.deletingLastPathComponent().appendingPathComponent("tecolot-sessiond").path
    let url = URL(fileURLWithPath: "/tmp/tlat-\(getpid())", isDirectory: true)
    try RuntimeDirectory.prepare(url)
    let directory = SessionDirectory(url: url)
    let record = try directory.create(launch(), helperPath: helper)
    let socket = try directory.connect(record.id)
    return try RemotePath(name: "helper", socket: socket) {
        try? directory.terminate(record.id, signal: SIGKILL)
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: Measuring

struct Summary {
    var samples: [UInt64]
    var timeouts: Int

    func percentile(_ fraction: Double) -> Double {
        guard !samples.isEmpty else { return .nan }
        let sorted = samples.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))
        return Double(sorted[index]) / 1000
    }

    var line: String {
        let columns = [0.0, 0.5, 0.9, 0.99, 1.0].map { String(format: "%8.0f", percentile($0)) }
        return columns.joined(separator: " ") + (timeouts > 0 ? "   timeouts: \(timeouts)" : "")
    }
}

/// Types `count` letters, `gap` apart, and times the echo of each one.
func run(_ path: Path, count: Int, gap: useconds_t) -> Summary {
    var samples: [UInt64] = []
    var timeouts = 0
    var column = 0
    for index in 0 ..< count {
        if column == lineLength {
            path.type([kill])
            usleep(20_000)
            column = 0
        }
        column += 1
        let letter = UInt8(ascii: "a") + UInt8(index % 26)
        if let time = path.probe.measure(target: column, send: { path.type([letter]) }) {
            samples.append(time)
        } else {
            timeouts += 1
            // Find out where the echo stands before going on.
            path.type([kill])
            usleep(100_000)
            column = 0
        }
        if gap > 0 { usleep(gap) }
    }
    return Summary(samples: samples, timeouts: timeouts)
}

let count = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 500
print("Keystroke to updated screen state, in microseconds (\(count) keys each).")
print("path    gap        min      p50      p90      p99      max")

var paths: [Path] = []
do {
    paths.append(try LocalPath())
    paths.append(try inProcessPath())
    paths.append(try helperPath())
} catch {
    print("setup failed: \(error)")
    exit(1)
}
usleep(300_000)

for gap: useconds_t in [0, 16_000, 120_000] {
    for path in paths {
        _ = run(path, count: 30, gap: 0) // warm up
        path.type([kill])
        usleep(50_000)
        let summary = run(path, count: gap >= 100_000 ? count / 5 : count, gap: gap)
        path.type([kill])
        usleep(50_000)
        let label = path.name.padding(toLength: 7, withPad: " ", startingAt: 0)
        print("\(label) \(String(format: "%4d ms", gap / 1000)) \(summary.line)")
    }
}
for path in paths { path.stop() }

// MARK: Interrupting a flood

// The shell floods the screen with `yes` until it gets SIGINT, then prints
// a numbered marker and waits for the next line. Typing Ctrl-C during the
// flood is the case where frame credits could delay the answer: the
// helper is busy and the client is behind.
let floodScript = """
    trap 'true' INT
    n=0
    while read line; do yes flood-line-with-some-text; n=$((n+1)); echo "STOPPED-$n"; done
    """

/// The screen shows `STOPPED-n` for the round being measured.
final class MarkerProbe: @unchecked Sendable {
    private let state = Mutex((target: "", waiting: false))
    private let arrived = DispatchSemaphore(value: 0)

    func observe(_ text: () -> String) {
        let target = state.withLock { $0.waiting ? $0.target : nil }
        guard let target, text().contains(target) else { return }
        let fire = state.withLock { state -> Bool in
            guard state.waiting else { return false }
            state.waiting = false
            return true
        }
        if fire { arrived.signal() }
    }

    func measure(marker: String, send: () -> Void) -> UInt64? {
        state.withLock { $0 = (marker, true) }
        let start = uptime()
        send()
        guard arrived.wait(timeout: .now() + 10) == .success else {
            state.withLock { $0.waiting = false }
            return nil
        }
        return uptime() - start
    }
}

protocol FloodPath: AnyObject {
    var name: String { get }
    var probe: MarkerProbe { get }
    func type(_ bytes: [UInt8])
    func stop()
}

final class LocalFlood: FloodPath, LocalProcessDelegate, TerminalDelegate, @unchecked Sendable {
    let name = "local"
    let probe = MarkerProbe()
    private let queue = DispatchQueue(label: "local.flood", qos: .userInitiated)
    private var terminal: Terminal!
    private var process: LocalProcess!

    init() throws {
        terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 24))
        process = LocalProcess(delegate: self, dispatchQueue: queue)
        let result = process.startProcessChecked(executable: "/bin/sh", args: ["-c", floodScript],
                                                 environment: environment)
        if case .failure(let error) = result { throw error }
    }

    func type(_ bytes: [UInt8]) { process.send(data: bytes[...]) }
    func stop() { process.terminate() }

    func dataReceived(slice: ArraySlice<UInt8>) {
        terminal.feed(buffer: slice)
        probe.observe {
            (0 ..< terminal.rows).map { row in
                terminal.getLine(row: row)?.translateToString(trimRight: true) ?? ""
            }.joined(separator: "\n")
        }
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {}
    func getWindowSize() -> winsize { winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0) }
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

final class RemoteFlood: FloodPath, @unchecked Sendable {
    let name: String
    let probe = MarkerProbe()
    let session: RemoteSession
    private let cleanup: () -> Void

    init(name: String, socket: Int32, cleanup: @escaping () -> Void) throws {
        self.name = name
        self.cleanup = cleanup
        session = RemoteSession(socket: socket, clientName: "latency", build: "latency")
        session.onChange = { [weak self] _ in
            guard let self else { return }
            probe.observe {
                session.withState { state, cache in
                    (0 ..< Int64(state.rows)).compactMap { offset -> String? in
                        let line = state.displayTop + offset
                        guard let row = cache[line] else { return nil }
                        return cache.text(from: (line, 0), to: (line, row.cells.count - 1))
                    }.joined(separator: "\n")
                }
            }
        }
        session.start(size: WireGridSize(columns: 80, rows: 24), focused: true)
        let deadline = Date().addingTimeInterval(5)
        while !session.state.connected || session.state.cursor == nil {
            guard Date() < deadline else { throw TransportError("\(name): no first frame") }
            usleep(1000)
        }
    }

    func type(_ bytes: [UInt8]) { session.send(bytes: bytes) }
    func stop() {
        session.close()
        cleanup()
    }
}

func floodLaunch() -> SessionLaunch {
    SessionLaunch(executable: "/bin/sh", arguments: ["-c", floodScript], environment: environment,
                  columns: 80, rows: 24)
}

/// Times the helper stages of one round: the key reaching the terminal, the
/// marker being parsed, and the first frame that shows it.
final class Tracer: @unchecked Sendable {
    struct Round {
        var start: UInt64 = 0
        var input: UInt64?
        var parsed: UInt64?
        var markerFeed: UInt64?
        var frame: UInt64?
        var bytesAfterInput = 0
        var framesAfterInput = 0
        var creditWaitsAfterMarker = 0
        var slotWaitsAfterMarker = 0
    }
    private struct State {
        var armed = false
        var feed: UInt64 = 0
        var round = Round()
    }
    private let state = Mutex(State())
    private static let marker = Array("STOPPED".utf8)

    func arm() {
        state.withLock {
            $0.round = Round(start: uptime())
            $0.armed = true
        }
    }

    func finish() -> Round {
        state.withLock {
            $0.armed = false
            return $0.round
        }
    }

    func event(_ event: SessionTraceEvent) {
        let now = uptime()
        state.withLock { state in
            switch event {
            case .fed(let slice):
                state.feed += 1
                guard state.armed, state.round.input != nil else { return }
                state.round.bytesAfterInput += slice.count
                if state.round.parsed == nil, Self.contains(slice, Self.marker) {
                    state.round.parsed = now
                    state.round.markerFeed = state.feed
                }
            case .input:
                if state.armed, state.round.input == nil { state.round.input = now }
            case .waitingForCredit:
                if state.armed, state.round.parsed != nil, state.round.frame == nil {
                    state.round.creditWaitsAfterMarker += 1
                }
            case .waitingForSlot:
                if state.armed, state.round.parsed != nil, state.round.frame == nil {
                    state.round.slotWaitsAfterMarker += 1
                }
            case .childInput:
                break
            case .frameSent(_, let feed):
                guard state.armed, state.round.input != nil else { return }
                state.round.framesAfterInput += 1
                if state.round.frame == nil, let markerFeed = state.round.markerFeed, feed >= markerFeed {
                    state.round.frame = now
                }
            }
        }
    }

    static func contains(_ slice: ArraySlice<UInt8>, _ needle: [UInt8]) -> Bool {
        guard slice.count >= needle.count else { return false }
        var index = slice.startIndex
        while index <= slice.endIndex - needle.count {
            if slice[index] == needle[0], slice[index ..< index + needle.count].elementsEqual(needle) { return true }
            index += 1
        }
        return false
    }
}

let tracer = Tracer()

func inProcessFlood() throws -> RemoteFlood {
    let host = SessionHost(id: "flood", launch: floodLaunch(), build: "latency")
    host.trace = { tracer.event($0) }
    try host.start()
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw TransportError("socketpair") }
    host.accept(socket: fds[1])
    return try RemoteFlood(name: "inproc", socket: fds[0]) { host.terminate(signal: SIGKILL) }
}

func helperFlood() throws -> RemoteFlood {
    let tool = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let helper = tool.deletingLastPathComponent().appendingPathComponent("tecolot-sessiond").path
    let url = URL(fileURLWithPath: "/tmp/tflood-\(getpid())", isDirectory: true)
    try RuntimeDirectory.prepare(url)
    let directory = SessionDirectory(url: url)
    let record = try directory.create(floodLaunch(), helperPath: helper)
    let socket = try directory.connect(record.id)
    return try RemoteFlood(name: "helper", socket: socket) {
        try? directory.terminate(record.id, signal: SIGKILL)
        try? FileManager.default.removeItem(at: url)
    }
}

let rounds = CommandLine.arguments.dropFirst(2).first.flatMap(Int.init) ?? 20
print("")
print("Ctrl-C during a `yes` flood to the marker on screen, in microseconds (\(rounds) rounds).")
print("path               min      p50      p90      p99      max")
var floods: [FloodPath] = []
do {
    floods.append(try LocalFlood())
    floods.append(try inProcessFlood())
    floods.append(try helperFlood())
} catch {
    print("setup failed: \(error)")
    exit(1)
}
usleep(300_000)
var traced: [(round: Tracer.Round, end: UInt64)] = []
for path in floods {
    var samples: [UInt64] = []
    var timeouts = 0
    for round in 1 ... rounds {
        path.type(Array("\n".utf8))  // start the flood
        usleep(300_000)
        if path.name == "inproc" { tracer.arm() }
        let time = path.probe.measure(marker: "STOPPED-\(round)", send: { path.type([0x03]) })
        if path.name == "inproc" {
            let traceRound = tracer.finish()
            if let time { traced.append((traceRound, traceRound.start + time)) }
        }
        if let time {
            samples.append(time)
        } else {
            timeouts += 1
        }
        usleep(50_000)
    }
    let summary = Summary(samples: samples, timeouts: timeouts)
    let label = path.name.padding(toLength: 7, withPad: " ", startingAt: 0)
    print("\(label)        \(summary.line)")
    path.stop()
}

// Where the in-process time goes, per stage (p50 / p90 in microseconds).
func stage(_ name: String, _ values: [UInt64?]) {
    let samples = values.compactMap { $0 }
    let summary = Summary(samples: samples, timeouts: values.count - samples.count)
    print("  \(name.padding(toLength: 34, withPad: " ", startingAt: 0)) \(String(format: "%8.0f %8.0f", summary.percentile(0.5), summary.percentile(0.9)))")
}
print("")
print("inproc stages                         p50      p90")
func difference(_ later: UInt64?, _ earlier: UInt64?) -> UInt64? {
    guard let later, let earlier, later >= earlier else { return nil }
    return later - earlier
}
stage("key sent -> written to the PTY", traced.map { difference($0.round.input, $0.round.start) })
stage("written -> marker parsed", traced.map { difference($0.round.parsed, $0.round.input) })
stage("parsed -> frame sent", traced.map { difference($0.round.frame, $0.round.parsed) })
stage("frame sent -> client has it", traced.map { difference($0.end, $0.round.frame) })
let bytes = traced.map { UInt64($0.round.bytesAfterInput) }.sorted()
let frames = traced.map { UInt64($0.round.framesAfterInput) }.sorted()
let creditWaits = traced.filter { $0.round.creditWaitsAfterMarker > 0 }.count
let slotWaits = traced.filter { $0.round.slotWaitsAfterMarker > 0 }.count
print("  rounds where the marker frame waited for a credit: \(creditWaits) of \(traced.count); for a slot: \(slotWaits)")
if !bytes.isEmpty {
    print("  bytes parsed after the key (p50): \(bytes[bytes.count / 2]); frames sent until the marker (p50): \(frames[frames.count / 2])")
}
