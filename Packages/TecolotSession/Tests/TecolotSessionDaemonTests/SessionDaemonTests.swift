import Foundation
import Synchronization
import Testing
import TecolotSessionDirectory
import TecolotTransport
import TecolotWire
#if canImport(Darwin)
import Darwin
#endif

/// Finds the helper that `swift build` produced next to the test bundle.
func helperPath() throws -> String {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let candidates = [
        ".build/out/Products/Debug/tecolot-sessiond",
        ".build/debug/tecolot-sessiond",
        ".build/arm64-apple-macosx/debug/tecolot-sessiond",
    ].map { packageRoot.appendingPathComponent($0).path }
    if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
        return found
    }
    throw SessionDirectoryError.helperNotFound(candidates.joined(separator: ", "))
}

func makeDirectory() throws -> SessionDirectory {
    // Socket paths are limited to 104 bytes, so use a short directory.
    let url = URL(fileURLWithPath: "/tmp/tsd-\(getpid())-\(UInt16.random(in: 0 ... .max))", isDirectory: true)
    try RuntimeDirectory.prepare(url)
    return SessionDirectory(url: url)
}

final class Collector: @unchecked Sendable {
    let state = Mutex<[Envelope]>([])
    func add(_ envelope: Envelope) { state.withLock { $0.append(envelope) } }
    var all: [Envelope] { state.withLock { $0 } }

    func screenText() -> String {
        var text = ""
        for envelope in all where envelope.kind == .frame {
            guard let frame = try? envelope.decode(FrameMessage.self) else { continue }
            for row in frame.changedRows {
                if let cells = try? RowDecoder.decodeCells(row.payload).1 {
                    for cell in cells {
                        if case .ascii(let byte) = cell.content { text.append(Character(UnicodeScalar(byte))) }
                    }
                    text.append("\n")
                }
            }
        }
        return text
    }
}

func waitFor(_ description: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    Issue.record("timed out: \(description)")
}

func parentPID(of pid: Int32) -> Int32? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
}

struct SessionDaemonTests {
    @Test func createAttachListAndTerminate() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.url) }
        let launch = SessionLaunch(executable: "/bin/sh",
                                   arguments: ["-c", "echo daemon-says-hello; exec sleep 60"],
                                   environment: ["PATH=/usr/bin:/bin", "TERM=xterm-256color"],
                                   workingDirectory: "/tmp", columns: 60, rows: 12,
                                   labels: ["profile": "Test"])
        let record = try directory.create(launch, helperPath: try helperPath())
        #expect(record.labels["profile"] == "Test")
        #expect(record.shellPID > 0)
        #expect(kill(record.pid, 0) == 0)
        // The helper is detached: it is not our child.
        #expect(parentPID(of: record.pid) != getpid())
        // The launch file (which holds the environment) is gone.
        #expect(!FileManager.default.fileExists(atPath: directory.launchURL(for: record.id).path))

        #expect(directory.list().map(\.id) == [record.id])

        let fd = try directory.connect(record.id)
        let channel = MessageChannel(socket: fd)
        let inbox = Collector()
        channel.onMessage = { inbox.add($0) }
        channel.start()
        channel.send(HelloMessage(build: "test", clientName: "daemon-test"))
        channel.send(AttachMessage(size: WireGridSize(columns: 60, rows: 12)))
        try await waitFor("hello output") { inbox.screenText().contains("daemon-says-hello") }

        try await waitFor("record shows the client") {
            directory.readRecord(record.id)?.attachedClients == 1
        }

        try directory.terminate(record.id, signal: SIGTERM)
        try await waitFor("exit event") { inbox.all.contains { $0.kind == .processExited } }
        // The exit was seen by an attached client, so the helper ends when it detaches.
        channel.send(DetachMessage())
        channel.close()
        try await waitFor("helper exit") { kill(record.pid, 0) != 0 }
        try await waitFor("files removed") { directory.list().isEmpty }
        #expect(!FileManager.default.fileExists(atPath: directory.socketPath(for: record.id)))
    }

    @Test func sessionSurvivesClientDisconnect() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.url) }
        let launch = SessionLaunch(executable: "/bin/sh",
                                   arguments: ["-c", "i=0; while true; do i=$((i+1)); echo tick $i; sleep 0.05; done"],
                                   environment: ["PATH=/usr/bin:/bin"], columns: 40, rows: 8)
        let record = try directory.create(launch, helperPath: try helperPath())
        defer { kill(record.pid, SIGTERM) }

        for _ in 0 ..< 2 {
            let fd = try directory.connect(record.id)
            let channel = MessageChannel(socket: fd)
            let inbox = Collector()
            channel.onMessage = { inbox.add($0) }
            channel.start()
            channel.send(HelloMessage(build: "test", clientName: "reconnect"))
            channel.send(AttachMessage(size: WireGridSize(columns: 40, rows: 8)))
            try await waitFor("ticks") { inbox.screenText().contains("tick") }
            channel.close()
            try await Task.sleep(nanoseconds: 100_000_000)
            #expect(kill(record.pid, 0) == 0)
        }
    }

    @Test func badLaunchReportsAnError() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.url) }
        let launch = SessionLaunch(executable: "/nonexistent/shell", environment: [])
        #expect(throws: SessionDirectoryError.self) {
            _ = try directory.create(launch, helperPath: try helperPath())
        }
        #expect(directory.list().isEmpty)
    }
}
