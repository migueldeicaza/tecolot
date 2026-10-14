import Foundation
import Testing
import TecolotSessionDirectory
import TecolotTransport
import TecolotWire
@testable import TecolotSessionDaemon
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct SessionUpkeepTests {
    @Test func touchUpdatesSocketRecordAndLog() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.url) }
        let id = "upkeep"
        let launch = SessionLaunch(executable: "/bin/sh", environment: [])
        try JSONEncoder().encode(launch).write(to: directory.launchURL(for: id))
        let server = try SessionServer(directory: directory, id: id, build: "test")
        let paths = [directory.socketPath(for: id), directory.recordURL(for: id).path,
                     directory.logURL(for: id).path]
        let old = Date(timeIntervalSince1970: 1_000_000)
        for path in paths {
            try Data().write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path)
        }
        server.host.queue.sync { server.touchFiles() }
        for path in paths {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let modified = try #require(attributes[.modificationDate] as? Date)
            #expect(modified.timeIntervalSinceNow > -5)
        }
    }

    @Test func signalRestoresMissingSocket() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.url) }
        let launch = SessionLaunch(executable: "/bin/sh", arguments: ["-c", "exec sleep 60"],
                                   environment: ["PATH=/usr/bin:/bin"])
        let record = try directory.create(launch, helperPath: try helperPath())
        defer { kill(record.pid, SIGTERM) }
        let path = directory.socketPath(for: record.id)
        #expect(unlink(path) == 0)
        #expect(kill(record.pid, SIGUSR1) == 0)
        try await waitFor("socket restored") { FileManager.default.fileExists(atPath: path) }
        let fd = try directory.connect(record.id)
        let channel = MessageChannel(socket: fd)
        defer { channel.close() }
        let inbox = Collector()
        channel.onMessage = { inbox.add($0) }
        channel.start()
        channel.send(HelloMessage(build: "test", clientName: "socket-upkeep"))
        try await waitFor("restored socket accepts hello") { inbox.all.contains { $0.kind == .helloReply } }
    }

    @Test func signalsGoOnlyToTheHelperThatWroteTheRecord() throws {
        func record(pid: Int32, createdAt: Date) -> SessionRecord {
            SessionRecord(id: "abc123", pid: pid, shellPID: 0, protocolVersion: 1, build: "test",
                          createdAt: createdAt, executable: "/bin/sh", workingDirectory: nil, labels: [:],
                          columns: 80, rows: 24)
        }
        // This test process plays the helper: it started before the record.
        #expect(SessionDirectory.isHelperRunning(record(pid: getpid(), createdAt: Date())))
        // A record from before this process started: the PID belongs to a new process.
        #expect(!SessionDirectory.isHelperRunning(record(pid: getpid(), createdAt: Date().addingTimeInterval(-24 * 3600))))
        // A helper that ended.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        #expect(!SessionDirectory.isHelperRunning(record(pid: child.processIdentifier, createdAt: Date())))
    }
}
