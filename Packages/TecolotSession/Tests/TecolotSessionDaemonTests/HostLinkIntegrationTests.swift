#if canImport(Darwin)
import Foundation
import Synchronization
import Testing
import TecolotSessionClient
import TecolotSessionDirectory
import TecolotTransport
import TecolotWire
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private enum HostTestError: Error { case timedOut(String), command(String) }
private func hostWait(_ name: String, timeout: TimeInterval = 30, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw HostTestError.timedOut(name)
}
private func hostResult<T: Sendable>(_ name: String = "operation", _ begin: (@escaping @Sendable (Result<T, Error>) -> Void) -> Void) async throws -> T {
    let result = Mutex<Result<T, Error>?>(nil)
    begin { value in result.withLock { $0 = value } }
    try await hostWait(name) { result.withLock { $0 != nil } }
    return try result.withLock { $0! }.get()
}
private func hostCommand(_ path: String, _ arguments: [String]) throws -> String {
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw HostTestError.command(arguments.joined(separator: " ")) }
    return String(decoding: data, as: UTF8.self)
}
private func hostScreen(_ session: RemoteSession) -> [String] {
    session.withState { state, cache in
        (0..<Int64(state.rows)).compactMap { offset in
            let line = state.displayTop + offset
            guard let row = cache[line] else { return nil }
            return cache.text(from: (line, 0), to: (line, row.cells.count - 1))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
private func hostAttach(_ link: HostLink, id: String?, launch: RemoteSessionLaunch? = nil) async throws -> (RemoteSession, String) {
    let result = Mutex<Result<String, Error>?>(nil)
    let fd = link.openPane(sessionID: id, launch: launch) { value in result.withLock { $0 = value } }
    guard fd >= 0 else { throw TransportError("pane socket") }
    let session = RemoteSession(socket: fd, clientName: "host-test", build: "test")
    session.start(size: WireGridSize(columns: 60, rows: 12), focused: true)
    do {
        try await hostWait("pane completion") { result.withLock { $0 != nil } }
        let sessionID = try result.withLock { $0! }.get()
        try await hostWait("pane attach") { session.state.connected }
        return (session, sessionID)
    } catch { session.close(); throw error }
}
private func expectOneMaster(_ link: HostLink, runtime: URL, destination: String) throws {
    let config = try SSHConfiguration.resolve(destination: destination)
    let socket = try SSHCommandLine.controlSocketPath(runtimeDirectory: runtime, configuration: config)
    let output = try hostCommand("/bin/ps", ["-axo", "pid=,command="])
    let masters = output.split(separator: "\n").filter { $0.contains("ssh -M -N -S " + socket) }
    #expect(masters.count == 1, "\(output)")
    #expect(masters.first?.contains(String(link.masterProcessIdentifier ?? -1)) == true)
}

struct HostLinkIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TECOLOT_SSH_TEST_HOST"] != nil,
                   "Set TECOLOT_SSH_TEST_HOST to run host link tests"))
    func installPaneAndReconnect() async throws {
        let destination = ProcessInfo.processInfo.environment["TECOLOT_SSH_TEST_HOST"]!
        let nonce = String(UInt64.random(in: 0 ... .max), radix: 16)
        let base = ".tecolot-test-\(nonce)", remoteRuntime = "/tmp/tt-\(nonce)"
        let appRuntime = URL(fileURLWithPath: "/tmp/th-\(nonce)", isDirectory: true)
        try RuntimeDirectory.prepare(appRuntime)
        let server = try AskpassServer(runtimeDirectory: appRuntime)
        let source = try LocalHelperSource(executable: URL(fileURLWithPath: helperPath()), version: "test")
        var config = HostLinkConfiguration(appRuntimeDirectory: appRuntime,
            remoteLayout: try RemoteLayout(baseDirectory: base, runtimeDirectory: remoteRuntime), helperSource: source, build: "test")
        config.extraSSHOptions = ["BatchMode=yes"]
        config.backoffSchedule = [0.05, 0.1]
        let link = HostLink(destination: destination, configuration: config, askpassServer: server)
        let confirmations = Mutex(0), installs = Mutex(0), states = Mutex<[String]>([])
        link.confirmInstall = { _, _, reply in confirmations.withLock { $0 += 1 }; reply(true) }
        link.onStateChange = { state in
            states.withLock { $0.append(String(describing: state)) }
            if case .installing = state { installs.withLock { $0 += 1 } }
        }
        let second = HostLink(destination: destination, configuration: config, askpassServer: server)
        let secondInstalls = Mutex(0)
        second.confirmInstall = { _, _, reply in Issue.record("second link asked to install"); reply(true) }
        second.onStateChange = { state in if case .installing = state { secondInstalls.withLock { $0 += 1 } } }
        var records: [SessionRecord] = []
        defer {
            link.stop(); second.stop()
            link.queue.sync {}; second.queue.sync {}
            server.close()
            let cleanup = "for p in $(ps -axo pid=,comm=,args= | awk '$2 ~ /tecolot-sessiond$/ && index($0, \"--runtime-dir \(remoteRuntime) --foreground\") {print $1}'); do kill -TERM \"$p\" 2>/dev/null || :; done; rm -rf -- \"$HOME/\(base)\" \(remoteRuntime)"
            _ = try? hostCommand("/usr/bin/ssh", ["-T", "-o", "BatchMode=yes", destination, cleanup])
            try? FileManager.default.removeItem(at: appRuntime)
        }
        link.retain()
        let launch = RemoteSessionLaunch(command: "exec /bin/sh -i", environment: ["PS1=", "ENV="], columns: 60, rows: 12)
        let pane: RemoteSession, id: String
        do { (pane, id) = try await hostAttach(link, id: nil, launch: launch) }
        catch { Issue.record("host states: \(states.withLock { $0 })"); throw error }
        defer { pane.close() }
        pane.send(text: "echo bridge-$((40+2))\n")
        try await hostWait("bridge-42") { hostScreen(pane).contains("bridge-42") }
        #expect(confirmations.withLock { $0 } == 1)
        #expect(installs.withLock { $0 } > 0)
        records = try await hostResult("list before drops") { link.listSessions($0) }
        #expect(records.map(\.id) == [id])
        try expectOneMaster(link, runtime: appRuntime, destination: destination)
        let masterPID = try #require(link.masterProcessIdentifier)
        let bridgePID = try #require(link.bridgeProcessIdentifier)
        let generation = link.connectionGeneration
        #expect(kill(bridgePID, SIGTERM) == 0)
        try await hostWait("bridge reconnect") { link.connectionGeneration > generation }
        try await hostWait("pane closes on bridge drop") { !pane.state.connected }
        #expect(link.masterProcessIdentifier == masterPID)
        try expectOneMaster(link, runtime: appRuntime, destination: destination)
        let (reopened, reopenedID) = try await hostAttach(link, id: id)
        defer { reopened.close() }
        #expect(reopenedID == id)
        try await hostWait("saved output") { hostScreen(reopened).contains("bridge-42") }
        let nextGeneration = link.connectionGeneration
        #expect(kill(masterPID, SIGTERM) == 0)
        do { try await hostWait("master reconnect") { link.connectionGeneration > nextGeneration } }
        catch { Issue.record("states after master drop: \(states.withLock { $0 })"); throw error }
        try await hostWait("pane closes on master drop") { !reopened.state.connected }
        #expect(link.masterProcessIdentifier != masterPID)
        try expectOneMaster(link, runtime: appRuntime, destination: destination)
        link.checkLiveness()
        let (afterDrop, _) = try await hostAttach(link, id: id)
        defer { afterDrop.close() }
        try await hostWait("output after master drop") { hostScreen(afterDrop).contains("bridge-42") }
        let stoppedPID = try #require(link.masterProcessIdentifier)
        link.stop()
        try await hostWait("stop") { if case .idle = link.state { return true }; return false }
        try await hostWait("master process ends") { kill(stoppedPID, 0) != 0 }
        second.retain()
        let listed: [SessionRecord] = try await hostResult("second link list") { second.listSessions($0) }
        #expect(listed.map(\.id) == [id])
        #expect(secondInstalls.withLock { $0 } == 0)
        try expectOneMaster(second, runtime: appRuntime, destination: destination)
        let _: Void = try await hostResult("second link terminate") { second.terminateSession(id: id, signal: SIGTERM, completion: $0) }
        second.stop()
        try await hostWait("second stops") { if case .idle = second.state { return true }; return false }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TECOLOT_SSH_TEST_HOST"] != nil,
                   "Set TECOLOT_SSH_TEST_HOST to test private master reuse"))
    func reusesPrivateMasterFromEarlierRun() async throws {
        let destination = ProcessInfo.processInfo.environment["TECOLOT_SSH_TEST_HOST"]!
        let nonce = String(UInt64.random(in: 0 ... .max), radix: 16)
        let base = ".tecolot-test-\(nonce)", remoteRuntime = "/tmp/tt-\(nonce)"
        let runtime = URL(fileURLWithPath: "/tmp/th-\(nonce)", isDirectory: true)
        try RuntimeDirectory.prepare(runtime)
        let server = try AskpassServer(runtimeDirectory: runtime)
        let resolved = try SSHConfiguration.resolve(destination: destination)
        let socket = try SSHCommandLine.controlSocketPath(runtimeDirectory: runtime, configuration: resolved)
        let builder = SSHCommandLine(configuration: resolved, extraOptions: ["BatchMode=yes"])
        let oldMaster = Process()
        oldMaster.executableURL = URL(fileURLWithPath: builder.sshPath)
        oldMaster.arguments = builder.master(controlPath: socket)
        oldMaster.standardInput = FileHandle.nullDevice
        oldMaster.standardOutput = FileHandle.nullDevice
        oldMaster.standardError = FileHandle.nullDevice
        let source = try LocalHelperSource(executable: URL(fileURLWithPath: helperPath()), version: "test")
        let config = HostLinkConfiguration(appRuntimeDirectory: runtime,
            remoteLayout: try RemoteLayout(baseDirectory: base, runtimeDirectory: remoteRuntime), helperSource: source, build: "test")
        let link = HostLink(destination: destination, configuration: config, askpassServer: server)
        link.confirmInstall = { _, _, reply in reply(true) }
        defer {
            link.stop(); link.queue.sync {}; server.close()
            if oldMaster.isRunning { oldMaster.terminate() }
            _ = try? hostCommand("/usr/bin/ssh", ["-T", "-o", "BatchMode=yes", destination,
                "rm -rf -- \"$HOME/\(base)\" \(remoteRuntime)"])
            try? FileManager.default.removeItem(at: runtime)
        }
        try oldMaster.run()
        try await hostWait("existing control socket") { FileManager.default.fileExists(atPath: socket) }
        link.retain()
        let sessions: [SessionRecord] = try await hostResult("adopted master list") { link.listSessions($0) }
        #expect(sessions.isEmpty)
        #expect(link.masterProcessIdentifier == oldMaster.processIdentifier)
        try expectOneMaster(link, runtime: runtime, destination: destination)
        link.stop()
        try await hostWait("adopted master exits") { !oldMaster.isRunning }
    }

}

#endif
