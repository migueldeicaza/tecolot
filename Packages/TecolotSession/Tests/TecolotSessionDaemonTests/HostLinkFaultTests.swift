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

private enum HostFaultError: Error { case timeout(String) }

func faultWait(_ name: String, _ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw HostFaultError.timeout(name)
}

private final class FaultQueueProbe: @unchecked Sendable {
    let key = DispatchSpecificKey<Bool>()
    init(_ queue: DispatchQueue) { queue.setSpecific(key: key, value: true) }
    var isOnQueue: Bool { DispatchQueue.getSpecific(key: key) == true }
}

final class HostFaultFixture {
    let root: URL
    let remoteRuntime: URL
    let appRuntime: URL
    let stateDirectory: URL
    let server: AskpassServer
    let configuration: HostLinkConfiguration
    let resolved: SSHConfiguration
    private var links: [HostLink] = []

    init(rejectMultiplex: Bool = false, reconnectPrompt: String? = nil, masterError: String? = nil,
         loginPrompt: String? = nil) throws {
        let nonce = String(UInt64.random(in: 0 ... .max), radix: 16)
        root = URL(fileURLWithPath: "/tmp/hf-\(nonce)", isDirectory: true)
        remoteRuntime = URL(fileURLWithPath: "/tmp/tt-\(nonce)", isDirectory: true)
        appRuntime = root.appendingPathComponent("app", isDirectory: true)
        stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let configText = "user test\nhostname fault-host\nport 22\nforwardagent no\n"
        resolved = try SSHConfiguration(destination: "fault-host", output: configText)
        do {
            try RuntimeDirectory.prepare(root)
            try RuntimeDirectory.prepare(home)
            try RuntimeDirectory.prepare(appRuntime)
            try RuntimeDirectory.prepare(stateDirectory)
            let executable = root.appendingPathComponent("fake-ssh")
            try Data(Self.script.utf8).write(to: executable)
            guard chmod(executable.path, 0o700) == 0 else { throw TransportError("chmod fake ssh") }
            server = try AskpassServer(runtimeDirectory: appRuntime)
            let source = try LocalHelperSource(executable: URL(fileURLWithPath: helperPath()), version: "test")
            var config = HostLinkConfiguration(appRuntimeDirectory: appRuntime,
                remoteLayout: try RemoteLayout(baseDirectory: ".tecolot-test-\(nonce)", runtimeDirectory: remoteRuntime.path),
                helperSource: source, build: "test")
            config.sshPath = executable.path
            config.backoffSchedule = [0.02]
            config.idleDelay = 0.02
            config.environment["HOME"] = home.path
            config.environment["TECOLOT_FAKE_STATE"] = stateDirectory.path
            config.environment["TECOLOT_FAKE_REJECT_MULTIPLEX"] = rejectMultiplex ? "1" : "0"
            if let masterError { config.environment["TECOLOT_FAKE_MASTER_ERROR"] = masterError }
            if let loginPrompt { config.environment["TECOLOT_FAKE_LOGIN_PROMPT"] = loginPrompt }
            if let reconnectPrompt { config.environment["TECOLOT_FAKE_RECONNECT_PROMPT"] = reconnectPrompt }
            configuration = config
        } catch {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: remoteRuntime)
            throw error
        }
    }

    func track(_ link: HostLink) { links.append(link) }
    var log: [String] {
        ((try? String(contentsOf: stateDirectory.appendingPathComponent("calls"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }
    var masterPIDs: [Int32] {
        ((try? String(contentsOf: stateDirectory.appendingPathComponent("master-pids"), encoding: .utf8)) ?? "")
            .split(separator: "\n").compactMap { Int32($0) }
    }
    func cleanup() {
        for link in links { link.stop(); link.queue.sync {} }
        server.close()
        // The sessions use a private test directory. Terminate them on every exit path.
        let directory = SessionDirectory(url: remoteRuntime)
        let pids = directory.list().map(\.pid) + masterPIDs
        for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGTERM) }
        for _ in 0..<100 {
            if pids.allSatisfy({ kill($0, 0) != 0 }) { break }
            usleep(10_000)
        }
        try? FileManager.default.removeItem(at: remoteRuntime)
        try? FileManager.default.removeItem(at: root)
    }

    private static let script = #"""
    #!/bin/sh
    state=$TECOLOT_FAKE_STATE
    if [ "$1" = -G ]; then
      printf 'resolve\n' >> "$state/calls"
      printf 'user test\nhostname fault-host\nport 22\nforwardagent no\n'
      exit 0
    fi
    master=0
    control=
    operation=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -M) master=1; shift ;;
        -N|-T|-A) shift ;;
        -S) control=$2; shift 2 ;;
        -O) operation=$2; shift 2 ;;
        -o) shift 2 ;;
        *) shift; break ;;
      esac
    done
    if [ -n "$operation" ]; then
      printf '%s\n' "$operation" >> "$state/calls"
      [ "$operation" != check ] || [ -e "$control" ] || exit 255
      exit 0
    fi
    if [ "$master" = 1 ]; then
      count=0
      [ ! -f "$state/master-count" ] || count=$(cat "$state/master-count")
      count=$((count + 1))
      printf '%s\n' "$count" > "$state/master-count"
      printf '%s\n' "$$" >> "$state/master-pids"
      printf 'master\n' >> "$state/calls"
      if [ "${TECOLOT_FAKE_MASTER_ERROR+x}" = x ]; then
        printf '%s\n' "$TECOLOT_FAKE_MASTER_ERROR" >&2
        exit 255
      fi
      if [ "${TECOLOT_FAKE_LOGIN_PROMPT+x}" = x ]; then
        "$SSH_ASKPASS" "$TECOLOT_FAKE_LOGIN_PROMPT" > /dev/null || exit 255
      fi
      if [ "$count" -gt 1 ] && [ "${TECOLOT_FAKE_RECONNECT_PROMPT+x}" = x ]; then
        rm -f "$control"
        SSH_ASKPASS_PROMPT=$TECOLOT_FAKE_RECONNECT_PROMPT
        export SSH_ASKPASS_PROMPT
        exec "$SSH_ASKPASS" 'Touch your security key or enter password'
      fi
      : > "$control"
      exec /bin/sleep 300
    fi
    if [ -n "$control" ]; then
      printf 'multiplex %s\n' "$*" >> "$state/calls"
      if [ ! -e "$control" ]; then
        printf 'Control socket connect(%s): No such file or directory\nConnection closed by UNKNOWN port 65535\n' "$control" >&2
        exit 255
      fi
      if [ "$TECOLOT_FAKE_REJECT_MULTIPLEX" = 1 ] && [ ! -f "$state/rejected" ]; then
        : > "$state/rejected"
        printf 'session request failed\n' >&2
        exit 255
      fi
    else
      printf 'independent %s\n' "$*" >> "$state/calls"
    fi
    case " $* " in
      *' bridge '*)
        if [ -f "$state/fail-next-bridge" ]; then
          rm "$state/fail-next-bridge"
          printf 'Connection closed\n' >&2
          exit 255
        fi ;;
    esac
    cd "$HOME" || exit 1
    exec "$@"
    """#
}

private func faultScreen(_ session: RemoteSession) -> [String] {
    session.withState { state, cache in
        (0..<Int64(state.rows)).compactMap { offset in
            let line = state.displayTop + offset
            guard let row = cache[line] else { return nil }
            return cache.text(from: (line, 0), to: (line, row.cells.count - 1))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// Has a helper only for Linux on ARM, so that the probe on this Mac finds none.
private struct OtherPlatformSource: RemoteHelperSource {
    let base: LocalHelperSource
    var askpassHelperPath: String? { base.askpassHelperPath }
    func metadata(for binaryID: String) throws -> RemoteHelperMetadata? {
        guard binaryID == "linux-aarch64", let local = try base.metadata(for: "darwin-universal") else { return nil }
        return RemoteHelperMetadata(binaryID: binaryID, version: local.version, sha256: local.sha256,
                                    uncompressedSize: local.uncompressedSize)
    }
    func payload(for binaryID: String, compressed: Bool, cacheDirectory: URL) throws -> RemoteHelperPayload {
        throw TransportError("no helper for \(binaryID)", code: ENOENT)
    }
}

struct HostLinkFaultTests {
    @Test func channelRefusalUsesIndependentConnectionsForQueuedPane() async throws {
        let fixture = try HostFaultFixture(rejectMultiplex: true)
        defer { fixture.cleanup() }
        let registry = HostLinkRegistry()
        let link = registry.link(configuration: fixture.resolved, hostConfiguration: fixture.configuration,
                                 askpassServer: fixture.server)
        fixture.track(link)
        #expect(registry.link(configuration: fixture.resolved, hostConfiguration: fixture.configuration,
                              askpassServer: fixture.server) === link)
        let probe = FaultQueueProbe(link.queue)
        let callbacksOnQueue = Mutex(true)
        let confirmations = Mutex(0)
        let states = Mutex<[String]>([])
        link.onStateChange = { state in
            callbacksOnQueue.withLock { $0 = $0 && probe.isOnQueue }
            states.withLock { $0.append(String(describing: state)) }
        }
        link.confirmInstall = { _, _, reply in
            callbacksOnQueue.withLock { $0 = $0 && probe.isOnQueue }
            confirmations.withLock { $0 += 1 }
            reply(true)
        }
        let completion = Mutex<Result<String, Error>?>(nil)
        let created = Mutex<String?>(nil)
        let launch = RemoteSessionLaunch(command: "exec /bin/sh -i", environment: ["PS1=", "ENV="], columns: 60, rows: 12)
        let fd = link.openPane(sessionID: nil, launch: launch, created: { id in
            callbacksOnQueue.withLock { $0 = $0 && probe.isOnQueue }
            created.withLock { $0 = id }
        }) { result in
            callbacksOnQueue.withLock { $0 = $0 && probe.isOnQueue }
            completion.withLock { $0 = result }
        }
        guard fd >= 0 else { throw TransportError("fault pane socket") }
        let pane = RemoteSession(socket: fd, clientName: "fault-test", build: "test")
        defer { pane.close() }
        pane.start(size: WireGridSize(columns: 60, rows: 12), focused: true)
        do {
            try await faultWait("queued pane completion") { completion.withLock { $0 != nil } }
            let id = try completion.withLock { $0! }.get()
            #expect(created.withLock { $0 } == id)
            try await faultWait("queued pane attach") { pane.state.connected }
        } catch { Issue.record("host states: \(states.withLock { $0 }); ssh calls: \(fixture.log)"); throw error }
        pane.send(text: "echo fallback-$((40+2))\n")
        try await faultWait("pane output") { faultScreen(pane).contains("fallback-42") }
        #expect(fixture.log.filter { $0.hasPrefix("multiplex ") }.count == 1)
        #expect(fixture.log.filter { $0.hasPrefix("independent ") }.count >= 3)
        #expect(fixture.log.filter { $0 == "master" }.count == 1)
        #expect(confirmations.withLock { $0 } == 1)
        #expect(callbacksOnQueue.withLock { $0 })
    }

    @Test func lastReleaseStopsMasterAfterIdleDelay() async throws {
        let fixture = try HostFaultFixture()
        defer { fixture.cleanup() }
        let link = HostLink(destination: "fault-host", configuration: fixture.configuration, askpassServer: fixture.server)
        fixture.track(link)
        let result = Mutex<Result<[SessionRecord], Error>?>(nil)
        let states = Mutex<[String]>([])
        link.onStateChange = { state in states.withLock { $0.append(String(describing: state)) } }
        link.confirmInstall = { _, _, reply in reply(true) }
        link.retain()
        link.retain()
        link.listSessions { value in result.withLock { $0 = value } }
        do { try await faultWait("retained connection") { result.withLock { $0 != nil } } }
        catch { Issue.record("idle test states: \(states.withLock { $0 }); calls: \(fixture.log)"); throw error }
        _ = try result.withLock { $0! }.get()
        let masterPID = try #require(link.masterProcessIdentifier)
        link.release()
        // One reference still owns the connection after the idle delay.
        try await Task.sleep(for: .milliseconds(80))
        #expect(link.masterProcessIdentifier == masterPID)
        #expect(kill(masterPID, 0) == 0)
        link.release()
        try await faultWait("last release enters idle") {
            if case .idle = link.state { return true }
            return false
        }
        try await faultWait("idle master reaped") { kill(masterPID, 0) != 0 }
        #expect(link.masterProcessIdentifier == nil)
        #expect(link.bridgeProcessIdentifier == nil)
        #expect(fixture.log.filter { $0 == "master" }.count == 1)
    }

    @Test func authenticationFailureClosesQueuedPaneWithoutRetry() async throws {
        let fixture = try HostFaultFixture(masterError: "Permission denied (publickey).")
        defer { fixture.cleanup() }
        let link = HostLink(destination: "fault-host", configuration: fixture.configuration, askpassServer: fixture.server)
        fixture.track(link)
        let probe = FaultQueueProbe(link.queue)
        let completion = Mutex<Result<String, Error>?>(nil)
        let callbackOnQueue = Mutex(false)
        link.retain()
        let launch = RemoteSessionLaunch(command: "exec /bin/sh -i", columns: 60, rows: 12)
        let fd = link.openPane(sessionID: nil, launch: launch) { value in
            callbackOnQueue.withLock { $0 = probe.isOnQueue }
            completion.withLock { $0 = value }
        }
        guard fd >= 0 else { throw TransportError("authentication pane socket") }
        defer { close(fd) }
        UnixSocket.setNonBlocking(fd)
        try await faultWait("authentication failure completion") { completion.withLock { $0 != nil } }
        switch try #require(completion.withLock { $0 }) {
        case .success: Issue.record("An unauthenticated connection opened the pane")
        case .failure(let error):
            let ssh = try #require(error as? SSHError)
            #expect(ssh.kind == .authentication)
        }
        if case .failed(let error) = link.state { #expect(error.kind == .authentication) }
        else { Issue.record("Authentication failure did not enter the failed state") }
        try await faultWait("queued pane socket closes") {
            var byte: UInt8 = 0
            return recv(fd, &byte, 1, MSG_DONTWAIT) == 0
        }
        try await faultWait("failed master reaped") { fixture.masterPIDs.allSatisfy { kill($0, 0) != 0 } }
        try await Task.sleep(for: .milliseconds(80))
        #expect(fixture.log.filter { $0 == "master" }.count == 1)
        #expect(fixture.log.filter { $0.hasPrefix("multiplex ") || $0.hasPrefix("independent ") }.isEmpty)
        #expect(link.masterProcessIdentifier == nil)
        #expect(link.bridgeProcessIdentifier == nil)
        #expect(callbackOnQueue.withLock { $0 })
    }

    @Test(arguments: ["", "none"])
    func inactiveReconnectPausesBeforeShowingPrompt(kind: String) async throws {
        let fixture = try HostFaultFixture(reconnectPrompt: kind)
        defer { fixture.cleanup() }
        let link = HostLink(destination: "fault-host", configuration: fixture.configuration, askpassServer: fixture.server)
        fixture.track(link)
        let probe = FaultQueueProbe(link.queue)
        let callbacksOnQueue = Mutex(true)
        let prompts = Mutex(0)
        let dismissals = Mutex(0)
        let result = Mutex<Result<[SessionRecord], Error>?>(nil)
        link.isAppActive = { false }
        link.confirmInstall = { _, _, reply in reply(true) }
        link.askpass = { _, reply in prompts.withLock { $0 += 1 }; reply(nil) }
        link.onAskpassDismiss = { _ in
            callbacksOnQueue.withLock { $0 = $0 && probe.isOnQueue }
            dismissals.withLock { $0 += 1 }
        }
        link.onStateChange = { _ in callbacksOnQueue.withLock { $0 = $0 && probe.isOnQueue } }
        link.retain()
        link.listSessions { value in result.withLock { $0 = value } }
        try await faultWait("initial connection") { result.withLock { $0 != nil } }
        #expect(try result.withLock { $0! }.get().isEmpty)
        let masterPID = try #require(link.masterProcessIdentifier)
        let controlPath = try SSHCommandLine.controlSocketPath(runtimeDirectory: fixture.appRuntime, configuration: fixture.resolved)
        unlink(controlPath)
        #expect(kill(masterPID, SIGTERM) == 0)
        try await faultWait("sign-in needed") {
            if case .signInNeeded = link.state { return true }
            return false
        }
        try await faultWait("prompt dismissed") { dismissals.withLock { $0 } == 1 }
        try await faultWait("reconnect child reaped") { fixture.masterPIDs.allSatisfy { kill($0, 0) != 0 } }
        #expect(fixture.masterPIDs.count == 2)
        #expect(prompts.withLock { $0 } == 0)
        #expect(link.masterProcessIdentifier == nil)
        #expect(link.bridgeProcessIdentifier == nil)
        #expect(callbacksOnQueue.withLock { $0 })
    }

    @Test func deadAdoptedMasterStartsNewLogin() async throws {
        let fixture = try HostFaultFixture()
        defer { fixture.cleanup() }
        // A master that an earlier run of the app left behind.
        let controlPath = try SSHCommandLine.controlSocketPath(runtimeDirectory: fixture.appRuntime,
                                                               configuration: fixture.resolved)
        #expect(FileManager.default.createFile(atPath: controlPath, contents: nil))
        let link = HostLink(destination: "fault-host", configuration: fixture.configuration, askpassServer: fixture.server)
        fixture.track(link)
        let states = Mutex<[String]>([])
        link.onStateChange = { state in states.withLock { $0.append(String(describing: state)) } }
        link.confirmInstall = { _, _, reply in reply(true) }
        let result = Mutex<Result<[SessionRecord], Error>?>(nil)
        link.retain()
        link.listSessions { value in result.withLock { $0 = value } }
        try await faultWait("adopted connection") { result.withLock { $0 != nil } }
        _ = try result.withLock { $0! }.get()
        #expect(fixture.log.filter { $0 == "master" }.isEmpty)
        let generation = link.connectionGeneration
        let bridgePID = try #require(link.bridgeProcessIdentifier)

        // The adopted master ends, then its bridge.
        unlink(controlPath)
        #expect(kill(bridgePID, SIGTERM) == 0)
        do { try await faultWait("new login") { link.connectionGeneration == generation + 1 } }
        catch { Issue.record("states: \(states.withLock { $0 }); calls: \(fixture.log)"); throw error }
        #expect(fixture.log.filter { $0 == "master" }.count == 1)
        #expect(link.masterProcessIdentifier != nil)
    }

    @Test func closedPaneGetsNoSession() async throws {
        let fixture = try HostFaultFixture()
        defer { fixture.cleanup() }
        let link = HostLink(destination: "fault-host", configuration: fixture.configuration, askpassServer: fixture.server)
        fixture.track(link)
        link.confirmInstall = { _, _, reply in reply(true) }
        link.retain()
        let completion = Mutex<Result<String, Error>?>(nil)
        let created = Mutex<String?>(nil)
        let launch = RemoteSessionLaunch(command: "exec /bin/sh -i", columns: 60, rows: 12)
        let fd = link.openPane(sessionID: nil, launch: launch, created: { id in created.withLock { $0 = id } }) { value in
            completion.withLock { $0 = value }
        }
        guard fd >= 0 else { throw TransportError("closed pane socket") }
        // The user closes the tab while the link connects.
        close(fd)
        try await faultWait("closed pane completion") { completion.withLock { $0 != nil } }
        if case .success = try #require(completion.withLock { $0 }) { Issue.record("A closed pane got a session") }
        let listed = Mutex<Result<[SessionRecord], Error>?>(nil)
        link.listSessions { value in listed.withLock { $0 = value } }
        try await faultWait("session list") { listed.withLock { $0 != nil } }
        #expect(try listed.withLock { $0! }.get().isEmpty)
        #expect(created.withLock { $0 } == nil)
    }

    @Test func unreachableHostFailsFirstConnection() async throws {
        let fixture = try HostFaultFixture(masterError: "ssh: Could not resolve hostname fault-host: nodename nor servname provided, or not known")
        defer { fixture.cleanup() }
        let link = HostLink(destination: "fault-host", configuration: fixture.configuration, askpassServer: fixture.server)
        fixture.track(link)
        let result = Mutex<Result<[SessionRecord], Error>?>(nil)
        link.retain()
        link.listSessions { value in result.withLock { $0 = value } }
        try await faultWait("first connection fails") { result.withLock { $0 != nil } }
        switch try #require(result.withLock { $0 }) {
        case .success: Issue.record("An unreachable host listed sessions")
        case .failure(let error): #expect((error as? SSHError)?.kind == .network)
        }
        if case .failed(let error) = link.state { #expect(error.kind == .network) }
        else { Issue.record("The first network error did not enter the failed state: \(link.state)") }
        try await Task.sleep(for: .milliseconds(80))
        #expect(fixture.log.filter { $0 == "master" }.count == 1)
    }

    @Test func unreachableHostRetriesKnownSession() async throws {
        let fixture = try HostFaultFixture(masterError: "ssh: connect to host fault-host port 22: Network is unreachable")
        defer { fixture.cleanup() }
        let link = HostLink(destination: "fault-host", configuration: fixture.configuration, askpassServer: fixture.server)
        fixture.track(link)
        link.retain()
        // A restored pane waits for its session.
        let fd = link.openPane(sessionID: "restored", launch: nil) { _ in }
        guard fd >= 0 else { throw TransportError("restored pane socket") }
        defer { close(fd) }
        try await faultWait("retry with backoff") { fixture.log.filter { $0 == "master" }.count >= 2 }
        if case .failed = link.state { Issue.record("A restored pane stopped its retries") }
    }

    @Test func openPromptPausesMasterTimeout() async throws {
        let fixture = try HostFaultFixture(loginPrompt: "test@fault-host's password: ")
        defer { fixture.cleanup() }
        var configuration = fixture.configuration
        configuration.masterTimeout = 0.3
        let link = HostLink(destination: "fault-host", configuration: configuration, askpassServer: fixture.server)
        fixture.track(link)
        let prompts = Mutex(0)
        link.confirmInstall = { _, _, reply in reply(true) }
        // The user types the password after more than the master timeout.
        link.askpass = { _, reply in
            prompts.withLock { $0 += 1 }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { reply("secret") }
        }
        let result = Mutex<Result<[SessionRecord], Error>?>(nil)
        link.retain()
        link.listSessions { value in result.withLock { $0 = value } }
        try await faultWait("connection after slow prompt") { result.withLock { $0 != nil } }
        _ = try result.withLock { $0! }.get()
        #expect(prompts.withLock { $0 } == 1)
        #expect(fixture.log.filter { $0 == "master" }.count == 1)
    }

    @Test func stopAllEndsMastersBeforeItReturns() async throws {
        let fixture = try HostFaultFixture()
        defer { fixture.cleanup() }
        let registry = HostLinkRegistry()
        let link = registry.link(configuration: fixture.resolved, hostConfiguration: fixture.configuration,
                                 askpassServer: fixture.server)
        fixture.track(link)
        link.confirmInstall = { _, _, reply in reply(true) }
        let result = Mutex<Result<[SessionRecord], Error>?>(nil)
        link.retain()
        link.listSessions { value in result.withLock { $0 = value } }
        try await faultWait("connection") { result.withLock { $0 != nil } }
        _ = try result.withLock { $0! }.get()
        let masterPID = try #require(link.masterProcessIdentifier)

        // The app can exit as soon as this call returns.
        registry.stopAll()
        if case .idle = link.state {} else { Issue.record("stopAll returned before the link stopped: \(link.state)") }
        #expect(link.masterProcessIdentifier == nil)
        try await faultWait("master ends") { kill(masterPID, 0) != 0 }
        try await faultWait("master exit request") { fixture.log.contains("exit") }
    }

    @Test func unsupportedHostTellsWhy() async throws {
        let fixture = try HostFaultFixture()
        defer { fixture.cleanup() }
        var configuration = fixture.configuration
        configuration.helperSource = OtherPlatformSource(
            base: try LocalHelperSource(executable: URL(fileURLWithPath: helperPath()), version: "test"))
        let link = HostLink(destination: "fault-host", configuration: configuration, askpassServer: fixture.server)
        fixture.track(link)
        let completion = Mutex<Result<String, Error>?>(nil)
        let fd = link.openPane(sessionID: nil, launch: RemoteSessionLaunch()) { value in completion.withLock { $0 = value } }
        guard fd >= 0 else { throw TransportError("unsupported pane socket") }
        defer { close(fd) }
        try await faultWait("unsupported completion") { completion.withLock { $0 != nil } }
        guard case .failure(let error) = try #require(completion.withLock { $0 }) else {
            Issue.record("An unsupported host opened a pane"); return
        }
        if case .unsupportedBinary? = error as? RemoteBootstrapError {} else { Issue.record("Wrong error: \(error)") }
        if case .unsupported = link.state {} else { Issue.record("Wrong state: \(link.state)") }
    }
}
#endif
