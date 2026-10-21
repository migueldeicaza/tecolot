import Dispatch
import Foundation
import Synchronization
import Testing
import TecolotSessionClient
import TecolotSessionDirectory
import TecolotTransport
import TecolotWire
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private enum BridgeTestError: Error { case timedOut(String) }

private func bridgeWait(_ name: String, timeout: TimeInterval = 10, _ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw BridgeTestError.timedOut(name)
}

private func bridgeResult<Value: Sendable>(_ name: String,
    _ begin: (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
    let result = Mutex<Result<Value, Error>?>(nil)
    begin { value in result.withLock { $0 = value } }
    try await bridgeWait(name) { result.withLock { $0 != nil } }
    return try result.withLock { $0! }.get()
}

private final class RunningBridge: @unchecked Sendable {
    let process = Process()
    let client: LinkClient
    let info = Mutex<HelperInfoMessage?>(nil)
    let closeError = Mutex<String?>(nil)
    let errors = Pipe()

    init(directory: SessionDirectory, host: String? = nil, environment: [String: String] = [:]) throws {
        let input = Pipe()
        let output = Pipe()
        let nonce = host.map { _ in String(UInt64.random(in: 0 ... .max), radix: 16) }
        let helper = try helperPath()
        let command = ["bridge", "--stdio", "--runtime-dir", directory.url.path] + (nonce.map { ["--nonce", $0] } ?? [])
        process.executableURL = URL(fileURLWithPath: host == nil ? helper : "/usr/bin/ssh")
        process.arguments = host.map { ["-T", "-o", "BatchMode=yes", $0, helper] + command } ?? command
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let readFD = dup(output.fileHandleForReading.fileDescriptor)
        let writeFD = dup(input.fileHandleForWriting.fileDescriptor)
        guard readFD >= 0, writeFD >= 0 else { throw TransportError("dup") }
        client = LinkClient(readFD: readFD, writeFD: writeFD, expectedNonce: nonce,
                            build: "test", clientName: "bridge-test")
        client.onReady = { [weak self] value in self?.info.withLock { $0 = value } }
        client.onClose = { [weak self] error in self?.closeError.withLock { $0 = error.map { "\($0)" } ?? "closed" } }
        do { try process.run() } catch { client.close(); throw error }
        try input.fileHandleForWriting.close()
        try output.fileHandleForReading.close()
        client.start()
    }

    deinit {
        client.close()
        if process.isRunning { process.terminate() }
    }

    func waitReady() async throws -> HelperInfoMessage {
        do { try await bridgeWait("HelperInfo") { info.withLock { $0 != nil } } }
        catch {
            client.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            let diagnostic = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            Issue.record("bridge failed: \(diagnostic); \(closeError.withLock { $0 } ?? "no close")")
            throw error
        }
        return info.withLock { $0! }
    }

    func stop() async throws {
        client.close()
        try await bridgeWait("bridge process exit") { !process.isRunning }
        #expect(process.terminationStatus == 0)
    }
}

private func bridgeScreen(_ session: RemoteSession) -> [String] {
    session.withState { state, cache in
        (0 ..< Int64(state.rows)).map { offset in
            let line = state.displayTop + offset
            guard let row = cache[line] else { return "<missing>" }
            return cache.text(from: (line, 0), to: (line, row.cells.count - 1))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }
}

private func attach(_ bridge: RunningBridge, id: String) async throws -> RemoteSession {
    let opened = Mutex<Result<Void, Error>?>(nil)
    let fd = bridge.client.openChannel(sessionID: id) { value in opened.withLock { $0 = value } }
    #expect(fd >= 0)
    let session = RemoteSession(socket: fd, clientName: "bridge-test", build: "test")
    // Hello and Attach wait in the socketpair before ChannelOpened.
    session.start(size: WireGridSize(columns: 60, rows: 12), focused: true)
    try await bridgeWait("ChannelOpened") { opened.withLock { $0 != nil } }
    try opened.withLock { $0! }.get()
    try await bridgeWait("attached") { session.state.connected }
    return session
}

private func bridgeFlow(host: String? = nil) async throws {
    let directory = try makeDirectory()
    defer {
        for record in directory.list() { kill(record.pid, SIGTERM) }
        try? FileManager.default.removeItem(at: directory.url)
    }
    let first = try RunningBridge(directory: directory, host: host)
    let info = try await first.waitReady()
    #expect(info.version == LinkProtocol.version)
    #expect(info.runtimeDirectory == directory.url.path)
    #expect(!info.os.isEmpty && !info.arch.isEmpty && !info.machineID.isEmpty && !info.shell.isEmpty)
    let launch = RemoteSessionLaunch(command: "exec /bin/sh -i", environment: ["PS1=", "ENV="],
                                     workingDirectory: "/tmp", columns: 60, rows: 12, labels: ["test": "bridge"])
    let record: SessionRecord = try await bridgeResult("createSession") { first.client.createSession(launch, completion: $0) }
    let session = try await attach(first, id: record.id)
    defer { session.close() }
    session.send(text: "echo bridge-$((40+2))\n")
    try await bridgeWait("output row bridge-42") { bridgeScreen(session).contains("bridge-42") }
    let records: [SessionRecord] = try await bridgeResult("listSessions") { first.client.listSessions($0) }
    #expect(records.map(\.id) == [record.id])
    try await first.stop()
    #expect(kill(record.pid, 0) == 0)
    try await bridgeWait("first connection closed") { !session.state.connected }

    // A bridge restores a socket that a /tmp cleaner removed.
    unlink(directory.socketPath(for: record.id))
    let second = try RunningBridge(directory: directory, host: host)
    let secondInfo = try await second.waitReady()
    #expect(secondInfo.machineID == info.machineID)
    let surviving: [SessionRecord] = try await bridgeResult("list surviving session") { second.client.listSessions($0) }
    #expect(surviving.map(\.id) == [record.id])
    let reattached = try await attach(second, id: record.id)
    defer { reattached.close() }
    try await bridgeWait("saved screen") { bridgeScreen(reattached).contains("bridge-42") }
    let _: Void = try await bridgeResult("terminateSession") {
        second.client.terminateSession(id: record.id, signal: SIGTERM, completion: $0)
    }
    try await bridgeWait("shell exits") { reattached.state.exitStatus != nil }
    reattached.close()
    try await bridgeWait("session removed") { directory.list().isEmpty }
    let empty: [SessionRecord] = try await bridgeResult("list after terminate") { second.client.listSessions($0) }
    #expect(empty.isEmpty)
    try await second.stop()
}

struct BridgeTests {
    @Test func directBridgeSurvivesDisconnectAndReconnect() async throws { try await bridgeFlow() }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TECOLOT_SSH_TEST_HOST"] != nil,
                   "Set TECOLOT_SSH_TEST_HOST to run the SSH bridge test"))
    func sshBridgeSurvivesDisconnectAndReconnect() async throws {
        try await bridgeFlow(host: ProcessInfo.processInfo.environment["TECOLOT_SSH_TEST_HOST"])
    }

    @Test func sessionsUseTheAgentOfTheNewestBridge() async throws {
        let directory = try makeDirectory()
        defer {
            for record in directory.list() { kill(record.pid, SIGTERM) }
            try? FileManager.default.removeItem(at: directory.url)
        }
        let link = directory.url.appendingPathComponent("agent.sock").path
        let seen = directory.url.appendingPathComponent("seen-agent").path
        let first = try RunningBridge(directory: directory, environment: ["SSH_AUTH_SOCK": "/tmp/first-agent"])
        _ = try await first.waitReady()
        let launch = RemoteSessionLaunch(command: "printf '%s' \"$SSH_AUTH_SOCK\" > '\(seen)'; exec /bin/sleep 30")
        _ = try await bridgeResult("createSession") { first.client.createSession(launch, completion: $0) }
        try await bridgeWait("session writes its agent path") { FileManager.default.fileExists(atPath: seen) }
        try await bridgeWait("agent path is complete") { (try? String(contentsOfFile: seen, encoding: .utf8)) == link }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == "/tmp/first-agent")
        try await first.stop()

        let second = try RunningBridge(directory: directory, environment: ["SSH_AUTH_SOCK": "/tmp/second-agent"])
        _ = try await second.waitReady()
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == "/tmp/second-agent")
        try await second.stop()
    }

    @Test func missingSessionErrorsDoNotCloseTheBridge() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.url) }
        let bridge = try RunningBridge(directory: directory)
        _ = try await bridge.waitReady()
        let opened = Mutex<Result<Void, Error>?>(nil)
        let fd = bridge.client.openChannel(sessionID: "123abc") { value in opened.withLock { $0 = value } }
        defer { close(fd) }
        try await bridgeWait("missing session open error") { opened.withLock { $0 != nil } }
        if case .failure(let error)? = opened.withLock({ $0 }),
           let linkError = error as? LinkClientError, case .remote(let message) = linkError {
            #expect(message.failedKind == .openChannel)
        } else { Issue.record("the missing session did not return an open error") }
        do {
            let _: Void = try await bridgeResult("missing session terminate error") {
                bridge.client.terminateSession(id: "123abc", signal: SIGTERM, completion: $0)
            }
            Issue.record("the missing session did not return a terminate error")
        } catch let error as LinkClientError {
            if case .remote(let message) = error { #expect(message.failedKind == .terminateSession) }
            else { Issue.record("the bridge closed after a directory error") }
        }
        let records: [SessionRecord] = try await bridgeResult("list after directory errors") {
            bridge.client.listSessions($0)
        }
        #expect(records.isEmpty)
        try await bridge.stop()
    }

    /// The Sessions window lists, restores and deletes the sessions that the
    /// system ended on a remote host.
    @Test func endedSessionsAreListedRestoredAndDeleted() async throws {
        let directory = try makeDirectory()
        let states = DurableStateDirectory(url: directory.url.appendingPathComponent("states", isDirectory: true))
        defer {
            // SIGKILL: SIGTERM makes a helper save its state into the folder that this removes.
            for record in directory.list() { kill(record.pid, SIGKILL) }
            try? FileManager.default.removeItem(at: directory.url)
        }
        let saved = SessionLaunch(executable: "/bin/sh", environment: ["SECRET=value"], workingDirectory: "/tmp")
        try states.write(DurableSessionState(id: "e0d1", launch: saved, directory: PaneDirectory(path: "/usr", source: .osc7),
                                             title: "first"), scrollback: nil)
        try states.write(DurableSessionState(id: "e0d2", launch: saved, title: "second"), scrollback: nil)
        let bridge = try RunningBridge(directory: directory, environment: ["TECOLOT_STATE_DIR": states.url.path])
        _ = try await bridge.waitReady()

        let ended: [DurableSessionState] = try await bridgeResult("listEndedSessions") {
            bridge.client.listEndedSessions($0)
        }
        #expect(Set(ended.map(\.id)) == ["e0d1", "e0d2"])
        // The launch environment stays on the host.
        #expect(ended.allSatisfy { $0.launch.environment.isEmpty })

        let _: Void = try await bridgeResult("deleteEndedSession") { bridge.client.deleteEndedSession(id: "e0d2", completion: $0) }
        #expect(states.read("e0d2") == nil)

        var launch = RemoteSessionLaunch(command: "exec /bin/sh -i", environment: ["PS1=", "ENV="], columns: 60, rows: 12)
        launch.restoreSessionID = "e0d1"
        let record: SessionRecord = try await bridgeResult("createSession") { bridge.client.createSession(launch, completion: $0) }
        let session = try await attach(bridge, id: record.id)
        defer { session.close() }
        try await bridgeWait("restore separator") { bridgeScreen(session).contains { $0.contains("Restored") } }
        session.send(text: "pwd\n")
        try await bridgeWait("saved directory") { bridgeScreen(session).contains("/usr") }
        #expect(states.read("e0d1") == nil)
        let left: [DurableSessionState] = try await bridgeResult("listEndedSessions after restore") {
            bridge.client.listEndedSessions($0)
        }
        #expect(left.isEmpty)
        try await bridge.stop()
    }

    @Test func bridgeIdleTimeoutExits() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try helperPath())
        process.arguments = ["bridge", "--stdio", "--runtime-dir", directory.url.path, "--idle-timeout", "0.05"]
        process.standardInput = Pipe()
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        try await bridgeWait("idle bridge exits") { !process.isRunning }
        #expect(process.terminationStatus == 0)
        let marker = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(marker == "TECOLOT-BRIDGE 1 \n")
    }
}
