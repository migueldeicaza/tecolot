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
    ].map {
        packageRoot.appendingPathComponent($0).path
    }
    if
        let found = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) {
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
    func add(_ envelope: Envelope) {
        state.withLock {
            $0.append(envelope)
        }
    }
    var all: [Envelope] {
        state.withLock {
            $0
        }
    }

    func screenText() -> String {
        var text = ""
        for envelope in all where envelope.kind == .frame {
            guard let frame = try? envelope.decode(FrameMessage.self) else {
                continue
            }
            for row in frame.changedRows {
                if let cells = try? RowDecoder.decodeCells(row.payload).1 {
                    for cell in cells {
                        if case .ascii(let byte) = cell.content {
                            text.append(Character(UnicodeScalar(byte)))
                        }
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
        if condition() {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    Issue.record("timed out: \(description)")
}

func parentPID(of pid: Int32) -> Int32? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
        return nil
    }
    return info.kp_eproc.e_ppid
}

struct SessionDaemonTests {
    @Test func createAttachListAndTerminate() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.url) }
        let launch = SessionLaunch(
            executable: "/bin/sh",
            arguments: ["-c", "echo daemon-says-hello; exec sleep 60"],
            environment: ["PATH=/usr/bin:/bin", "TERM=xterm-256color"],
            workingDirectory: "/tmp",
            columns: 60,
            rows: 12,
            labels: ["profile": "Test"]
        )
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
        channel.onMessage = {
            inbox.add($0)
        }
        channel.start()
        channel.send(HelloMessage(build: "test", clientName: "daemon-test"))
        channel.send(AttachMessage(size: WireGridSize(columns: 60, rows: 12)))
        try await waitFor("hello output") {
            inbox.screenText().contains("daemon-says-hello")
        }

        try await waitFor("record shows the client") {
            directory.readRecord(record.id)?.attachedClients == 1
        }

        try directory.terminate(record.id, signal: SIGTERM)
        try await waitFor("exit event") {
            inbox.all.contains {
                $0.kind == .processExited
            }
        }
        // The exit was seen by an attached client, so the helper ends when it detaches.
        channel.send(DetachMessage())
        channel.close()
        try await waitFor("helper exit") {
            kill(record.pid, 0) != 0
        }
        try await waitFor("files removed") {
            directory.list().isEmpty
        }
        #expect(!FileManager.default.fileExists(atPath: directory.socketPath(for: record.id)))
    }

    /// No client is attached: the helper keeps the notification in the
    /// session record, where the app reads it.
    @Test func detachedNotificationsGoToTheRecord() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.url) }
        let launch = SessionLaunch(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 0.3; printf '\\033]9;Build done\\007'; exec sleep 60"],
            environment: ["PATH=/usr/bin:/bin"],
            columns: 40,
            rows: 8
        )
        let record = try directory.create(launch, helperPath: try helperPath())
        defer { kill(record.pid, SIGTERM) }
        try await waitFor("notification in the record") {
            directory.readRecord(record.id)?.notification != nil
        }
        #expect(directory.readRecord(record.id)?.notification == SessionNotification(serial: 1, title: "", body: "Build done"))
    }

    @Test func sessionSurvivesClientDisconnect() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.url) }
        let launch = SessionLaunch(
            executable: "/bin/sh",
            arguments: ["-c", "i=0; while true; do i=$((i+1)); echo tick $i; sleep 0.05; done"],
            environment: ["PATH=/usr/bin:/bin"],
            columns: 40,
            rows: 8
        )
        let record = try directory.create(launch, helperPath: try helperPath())
        defer { kill(record.pid, SIGTERM) }

        for _ in 0 ..< 2 {
            let fd = try directory.connect(record.id)
            let channel = MessageChannel(socket: fd)
            let inbox = Collector()
            channel.onMessage = {
                inbox.add($0)
            }
            channel.start()
            channel.send(HelloMessage(build: "test", clientName: "reconnect"))
            channel.send(AttachMessage(size: WireGridSize(columns: 40, rows: 8)))
            try await waitFor("ticks") {
                inbox.screenText().contains("tick")
            }
            channel.close()
            try await Task.sleep(nanoseconds: 100_000_000)
            #expect(kill(record.pid, 0) == 0)
        }
    }

    /// The shell exits before the helper finishes its start: the record
    /// still shows the exit.
    @Test func immediateExitMarksTheRecord() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.url) }
        let launch = SessionLaunch(
            executable: "/bin/sh",
            arguments: ["-c", "exit 3"],
            environment: ["PATH=/usr/bin:/bin"],
            columns: 40,
            rows: 8
        )
        let record = try directory.create(launch, helperPath: try helperPath())
        defer { kill(record.pid, SIGTERM) }
        try await waitFor("exit in the record") {
            directory.readRecord(record.id)?.exited == true
        }
        #expect(directory.readRecord(record.id)?.exitCode == 3)
    }

    /// The record keeps the start time of the helper process, so that a
    /// slow start does not make the helper look like another process.
    @Test func recordKeepsTheHelperStartTime() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.url) }
        let launch = SessionLaunch(
            executable: "/bin/sh",
            arguments: ["-c", "exec sleep 60"],
            environment: ["PATH=/usr/bin:/bin"],
            columns: 40,
            rows: 8
        )
        let record = try directory.create(launch, helperPath: try helperPath())
        defer { kill(record.pid, SIGTERM) }
        let started = try #require(SessionDirectory.processStartTime(record.pid))
        #expect(abs(record.createdAt.timeIntervalSince(started)) < 1)
        #expect(SessionDirectory.isHelperRunning(record))
    }

    /// The caller stops waiting: no session stays without a pane.
    @Test func timedOutCreateLeavesNoSession() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.url) }
        let launch = SessionLaunch(
            executable: "/bin/sh",
            arguments: ["-c", "exec sleep 60"],
            environment: ["PATH=/usr/bin:/bin"],
            columns: 40,
            rows: 8
        )
        // Timeout 0: the helper finds no launch file. A short timeout can end
        // after the helper read the file: it then finds the pipe closed. When
        // the helper is fast enough, the create works: end that session.
        #expect(throws: (any Error).self) {
            _ = try directory.create(launch, helperPath: try helperPath(), timeout: 0)
        }
        for timeout in [0.005, 0.01, 0.02, 0.03] {
            if let record = try? directory.create(launch, helperPath: try helperPath(), timeout: timeout) {
                try directory.terminate(record.id, signal: SIGTERM)
            }
        }
        // Give the helper time to start (or to fail to start), then check
        // that it ended and removed its files.
        try await Task.sleep(nanoseconds: 500_000_000)
        try await waitFor("no session") {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.url.path)) ?? []
            return names.allSatisfy {
                $0.hasSuffix(".log")
            }
        }
        #expect(directory.list().isEmpty)
    }

    /// The helper reads the launch file and starts the session, but the
    /// process that started it no longer reads the ready pipe: the helper
    /// ends the session.
    @Test func helperEndsTheSessionWhenNobodyWaits() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.url) }
        let launch = SessionLaunch(
            executable: "/bin/sh",
            arguments: ["-c", "exec sleep 60"],
            environment: ["PATH=/usr/bin:/bin"],
            columns: 40,
            rows: 8
        )
        let id = SessionDirectory.makeIdentifier()
        try JSONEncoder().encode(launch).write(to: directory.launchURL(for: id))
        var ready: [Int32] = [0, 0]
        #expect(pipe(&ready) == 0)
        // Nobody reads the pipe.
        close(ready[0])
        let pid = try SessionDirectory.spawn(
            try helperPath(),
            arguments: [
                "tecolot-sessiond",
                "serve",
                "--id",
                id,
                "--runtime-dir",
                directory.url.path,
                "--ready-fd",
                "3"
            ],
            readyFD: ready[1],
            log: directory.logURL(for: id).path,
            newSession: true
        )
        close(ready[1])
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
        try await waitFor("launch file read") {
            !FileManager.default.fileExists(atPath: directory.launchURL(for: id).path)
        }
        try await waitFor("session ended") {
            !FileManager.default.fileExists(atPath: directory.recordURL(for: id).path)
                && !FileManager.default.fileExists(atPath: directory.socketPath(for: id))
                && !FileManager.default.fileExists(atPath: directory.logURL(for: id).path)
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
