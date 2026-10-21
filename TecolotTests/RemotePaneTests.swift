import AppKit
import Foundation
import Testing
@testable import Tecolot
import TecolotSessionDirectory
import TecolotSessionClient
import TecolotWire

private enum RemotePaneTestError: Error { case timedOut(String), cleanupFailed }

@MainActor
@Suite(.serialized)
struct RemotePaneTests {
    private func wait(_ name: String, timeout: TimeInterval = 60, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw RemotePaneTestError.timedOut(name)
    }

    private func rows(_ session: RemoteSession) -> [String] {
        session.withState { state, cache in
            (0..<Int64(state.rows)).compactMap { offset in
                let line = state.displayTop + offset
                guard let row = cache[line] else { return nil }
                return cache.text(from: (line, 0), to: (line, row.cells.count - 1))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TECOLOT_SSH_TEST_HOST"] != nil,
                   "Set TECOLOT_SSH_TEST_HOST to run the remote pane test"))
    func remotePaneTypesDetachesAttachesAndTerminates() async throws {
        let destination = try #require(ProcessInfo.processInfo.environment["TECOLOT_SSH_TEST_HOST"])
        try SSHConfiguration.validate(destination)
        let base = ".tecolot-test-\(getpid())"
        let runtime = "/tmp/tr-\(getpid())"
        let names = ["TECOLOT_REMOTE_BASE_DIRECTORY", "TECOLOT_REMOTE_RUNTIME_DIRECTORY", "TECOLOT_RUNTIME_DIR"]
        let previous = names.map { getenv($0).map { String(cString: $0) } }
        setenv(names[0], base, 1)
        setenv(names[1], runtime, 1)
        setenv(names[2], "/tmp/ta-\(getpid())", 1)
        var workspaces: [TerminalPaneWorkspace] = []
        defer {
            for workspace in workspaces { workspace.terminateAll() }
            RemoteHosts.shared.shutdown()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                "-o", "ServerAliveInterval=2", "-o", "ServerAliveCountMax=2", destination,
                "for p in $(ps -axo pid=,comm=,args= | awk '$2 ~ /tecolot-sessiond$/ && index($0, \"--runtime-dir \(runtime) --foreground\") {print $1}'); do kill -TERM \"$p\" 2>/dev/null || :; done; rm -rf -- \"$HOME/\(base)\" \(runtime)"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                #expect(process.terminationStatus == 0, "Remote test directory cleanup failed")
            } catch { Issue.record("Remote test cleanup failed: \(error)") }
            for (name, value) in zip(names, previous) {
                if let value { setenv(name, value, 1) } else { unsetenv(name) }
            }
        }
        let link: HostLink = try await withCheckedThrowingContinuation { continuation in
            RemoteHosts.shared.link(destination: destination) { continuation.resume(with: $0) }
        }
        // Only the private test directory can be installed without a panel.
        link.confirmInstall = { _, _, reply in reply(true) }
        link.askpass = { _, reply in reply(nil) }
        let profile = AppModel.shared.profiles.defaultProfile
        func open(_ id: String?) throws -> (TerminalPaneWorkspace, TerminalSessionController, NSWindow) {
            var spec = LaunchSpec(profileID: profile.id)
            spec.remoteDestination = destination
            spec.attachSessionID = id
            AppModel.shared.setPendingLaunch(spec)
            let workspace = TerminalPaneWorkspace()
            workspaces.append(workspace)
            let controller = try #require(workspace.focusedController)
            let document = TerminalDocument()
            let host = TerminalPaneHostView(workspace: workspace, document: document)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            host.synchronize(revision: workspace.revision, document: document)
            host.layoutSubtreeIfNeeded()
            return (workspace, controller, window)
        }
        let (firstWorkspace, first, window) = try open(nil)
        try await wait("remote screen") { first.persistentView?.session.state.connected == true && first.persistentSessionID != nil }
        let view = try #require(first.persistentView)
        #expect(window.makeFirstResponder(view))
        view.insertText("echo remote-$((40+2))", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await wait("remote-42 output row") { rows(view.session).contains("remote-42") }
        // A bridge restart must attach the pane to the new connection.
        let oldSession = view.session
        let generation = link.connectionGeneration
        let bridgePID = try #require(link.bridgeProcessIdentifier)
        #expect(kill(bridgePID, SIGTERM) == 0)
        try await wait("automatic remote reconnect") {
            link.connectionGeneration > generation && view.session !== oldSession &&
                view.session.state.connected && rows(view.session).contains("remote-42")
        }
        let id = try #require(first.persistentSessionID)
        firstWorkspace.terminateAll()
        let (secondWorkspace, second, secondWindow) = try open(id)
        defer { secondWorkspace.terminateAll(); _ = secondWindow }
        try await wait("reattached screen") {
            guard let session = second.persistentView?.session else { return false }
            return session.state.connected && rows(session).contains("remote-42")
        }
        #expect(second.persistentSessionID == id)
        second.terminateSessionNow()
        try await wait("remote session exit") { second.persistentView?.session.state.exitStatus != nil }
    }
    @Test func disconnectedPaneIgnoresTextFromInputAndCommands() async throws {
        setenv("TECOLOT_RUNTIME_DIR", "/tmp/tecolot-tests-\(getpid())", 1)
        var spec = LaunchSpec()
        spec.persistent = true
        AppModel.shared.setPendingLaunch(spec)
        let controller = TerminalSessionController()
        controller.resolveLaunchIfNeeded(document: TerminalDocument())
        let view = try #require(controller.makePersistentView())
        let id = try #require(controller.persistentSessionID)
        defer {
            controller.terminate()
            try? PersistentSessions.directory().terminate(id, signal: SIGKILL)
        }
        try await wait("local test screen") { view.session.state.connected }
        view.remoteInputEnabled = false
        view.insertText("echo blocked-$((40+2))\r", replacementRange: NSRange(location: NSNotFound, length: 0))
        controller.sendLiteralText("echo blocked-$((40+2))\r")
        view.remoteInputEnabled = true
        controller.sendLiteralText("echo allowed-$((40+2))\r")
        try await wait("allowed output") { rows(view.session).contains("allowed-42") }
        #expect(!rows(view.session).contains("blocked-42"))
    }

}
