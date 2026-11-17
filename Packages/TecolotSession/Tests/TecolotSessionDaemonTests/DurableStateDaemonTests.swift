import Foundation
import Testing
import TecolotSessionDirectory
#if canImport(Darwin)
import Darwin
#endif

struct DurableStateDaemonTests {
    /// Log out, restart and shut down send SIGTERM: the helper saves the
    /// session's state and text, then ends.
    @Test func terminationSignalSavesTheSession() async throws {
        let directory = try makeDirectory()
        let states = DurableStateDirectory(url: directory.url.appendingPathComponent("states", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: directory.url) }
        let launch = SessionLaunch(executable: "/bin/sh",
                                   arguments: ["-c", "cd /usr; printf '\\033]7;file://localhost/usr\\007'; echo saved-line; exec sleep 60"],
                                   environment: ["PATH=/usr/bin:/bin"], workingDirectory: "/tmp", columns: 40, rows: 8,
                                   stateDirectory: states.url.path, restoreRows: 100)
        let record = try directory.create(launch, helperPath: try helperPath())
        try await waitFor("the shell's report") { directory.readRecord(record.id)?.directory.contains("/usr") == true }
        kill(record.pid, SIGTERM)
        try await waitFor("helper exit") { kill(record.pid, 0) != 0 }
        let state = try #require(states.read(record.id))
        #expect(state.directory?.path == "/usr")
        #expect(state.bootID == BootIdentifier.current())
        #expect(state.launch.replay == nil)
        #expect(states.scrollback(record.id)?.text.contains("saved-line") == true)
    }

    /// Terminate Session ends the session for good: nothing is saved.
    @Test func terminateSessionSavesNothing() async throws {
        let directory = try makeDirectory()
        let states = DurableStateDirectory(url: directory.url.appendingPathComponent("states", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: directory.url) }
        let launch = SessionLaunch(executable: "/bin/sh", arguments: ["-c", "exec sleep 60"],
                                   environment: ["PATH=/usr/bin:/bin"], columns: 40, rows: 8,
                                   stateDirectory: states.url.path)
        let record = try directory.create(launch, helperPath: try helperPath())
        try directory.terminate(record.id)
        try await waitFor("helper exit", timeout: 30) { kill(record.pid, 0) != 0 }
        #expect(states.read(record.id) == nil)
    }

    /// After a restart another process can have the PID of a record.
    @Test func reusedPIDIsNotARunningHelper() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.url) }
        // The record is older than the process that has its PID now.
        let record = SessionRecord(id: "aaaa00000001", pid: getpid(), shellPID: 0, protocolVersion: 1, build: "test",
                                   createdAt: Date(timeIntervalSince1970: 1_000_000), executable: "/bin/sh",
                                   workingDirectory: nil, labels: [:], columns: 80, rows: 24)
        try directory.writeRecord(record)
        #expect(directory.list().isEmpty)
        #expect(directory.readRecord(record.id) == nil)
    }
}
