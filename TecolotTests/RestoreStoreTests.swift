//
//  RestoreStoreTests.swift
//  TecolotTests
//

import AppKit
import Foundation
import SwiftTerm
import Testing
@testable import Tecolot
import TecolotSessionClient
import TecolotSessionDirectory
import TecolotWire

@MainActor
@Suite(.serialized)
struct RestoreStoreTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("restore-\(UUID().uuidString)", isDirectory: true)
    }

    /// Sets environment variables for one test. Call the result to put back
    /// the old values, so that the next tests do not see these.
    private func setEnvironment(_ values: [String: String]) -> () -> Void {
        let old = values.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (name, value) in values { setenv(name, value, 1) }
        return {
            for (name, value) in old {
                if let value { setenv(name, value, 1) } else { unsetenv(name) }
            }
        }
    }

    private func pane(_ kind: RestorePaneKind, session: String? = nil, directory: String = "/tmp") -> RestorePane {
        RestorePane(id: UUID(), kind: kind, profileID: nil, themeOverride: nil,
                    directory: PaneDirectory(path: directory, source: .osc7), sessionID: session,
                    remoteDestination: kind == .remote ? "user@host" : nil)
    }

    private func wait(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("timed out: \(what)")
    }

    private func host(_ workspace: TerminalPaneWorkspace) -> (TerminalPaneHostView, NSWindow) {
        let document = TerminalDocument(content: "")
        let hostView = TerminalPaneHostView(workspace: workspace, document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        // The tests close their windows; ARC keeps them.
        window.isReleasedWhenClosed = false
        window.contentView = hostView
        hostView.synchronize(revision: workspace.revision, document: document)
        hostView.layoutSubtreeIfNeeded()
        return (hostView, window)
    }

    private func screenText(_ controller: TerminalSessionController) -> [String] {
        controller.terminal?.terminalContentSnapshot(region: .history(maximumScrollbackRows: 100))?
            .rows.map(\.text) ?? []
    }

    // MARK: The file

    @Test func stateRoundTripsWithTheMigrator() throws {
        let tree: RestorePaneNode = .split(.vertical, fraction: 0.3, first: .pane(pane(.local)),
                                           second: .split(.horizontal, fraction: 0.5,
                                                          first: .pane(pane(.persistent, session: "abc")),
                                                          second: .pane(pane(.remote, session: "def"))))
        let state = RestoreState(bootID: "boot", savedAt: Date(timeIntervalSince1970: 1_000_000), windows: [
            RestoreWindow(frame: "{{10, 20}, {800, 600}}", screen: "Built-in", isFullScreen: true,
                          selectedTabIndex: 7, tabs: [RestoreTab(name: "build", root: tree)])])
        let migrator = RestoreStateMigrator()
        let data = try migrator.encodeCurrent(state)
        let decoded = try migrator.decode(data, from: try migrator.sourceVersion(in: data))
        #expect(decoded.windows.first?.tabs == state.windows.first?.tabs)
        // The selected tab is clamped to the tabs that exist.
        #expect(decoded.windows.first?.selectedTabIndex == 0)
        #expect(decoded.windows.first?.isFullScreen == true)
        #expect(throws: (any Error).self) {
            try migrator.decode(Data(#"{"version":9,"windows":[]}"#.utf8), from: 9)
        }
    }

    /// A file that was changed by hand can repeat a pane ID: each pane gets its own.
    @Test func repeatedPaneIDsBecomeUnique() throws {
        let repeated = pane(.local)
        let state = RestoreState(bootID: nil, savedAt: Date(), windows: [
            RestoreWindow(frame: "{{0, 0}, {800, 600}}", selectedTabIndex: 0, tabs: [
                RestoreTab(root: .split(.vertical, fraction: nil, first: .pane(repeated), second: .pane(repeated))),
                RestoreTab(root: .pane(repeated))])])
        let migrator = RestoreStateMigrator()
        let data = try migrator.encodeCurrent(state)
        let decoded = try migrator.decode(data, from: try migrator.sourceVersion(in: data))
        let ids = decoded.windows.flatMap(\.tabs).flatMap(\.root.panes).map(\.id)
        #expect(ids.count == 3)
        #expect(Set(ids).count == 3)
        #expect(ids.first == repeated.id)
    }

    @Test func filterRemovesPanesAndCollapsesSplits() {
        let kept = pane(.local)
        let tree: RestorePaneNode = .split(.vertical, fraction: 0.3, first: .pane(kept),
                                           second: .pane(pane(.persistent, session: "abc")))
        #expect(tree.filter { $0.sessionID != "abc" } == .pane(kept))
        #expect(tree.filter { _ in false } == nil)
        #expect(tree.filter { _ in true } == tree)
    }

    /// A crash during the restore must not restore the same windows two times.
    @Test func savedStateIsReadOneTime() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RestoreStore(directory: directory)
        let state = RestoreState(bootID: nil, savedAt: Date(), windows: [
            RestoreWindow(frame: "{{0, 0}, {800, 600}}", selectedTabIndex: 0, tabs: [RestoreTab(root: .pane(pane(.local)))])])
        RestoreStore.write(state, texts: [], directory: directory, windowsURL: store.windowsURL, panesURL: store.panesURL)
        #expect(store.takeSavedState()?.windows.count == 1)
        #expect(!FileManager.default.fileExists(atPath: store.windowsURL.path))
        #expect(store.takeSavedState() == nil)
    }

    @Test func fileThatDoesNotDecodeIsDeleted() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RestoreStore(directory: directory)
        try DurableStateDirectory.makePrivateDirectory(directory)
        try Data("{not json".utf8).write(to: store.windowsURL)
        #expect(store.takeSavedState() == nil)
        #expect(!FileManager.default.fileExists(atPath: store.windowsURL.path))
    }

    @Test func filesArePrivateAndExcludedFromBackups() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RestoreStore(directory: directory)
        let terminal = Terminal(delegate: SnapshotDelegate(), options: TerminalOptions(cols: 20, rows: 4, scrollback: 10))
        terminal.terminalLock.withLock { terminal.feed(text: "saved\r\n$ ") }
        let paneID = UUID()
        let pending = ScrollbackSnapshot.Pending(paneID: paneID,
                                                 snapshot: terminal.contentSnapshot(region: .history(maximumScrollbackRows: 10)),
                                                 alternateScreenProgram: nil, limit: 1_000)
        let state = RestoreState(bootID: nil, savedAt: Date(), windows: [
            RestoreWindow(frame: "{{0, 0}, {800, 600}}", selectedTabIndex: 0, tabs: [RestoreTab(root: .pane(pane(.local)))])])
        RestoreStore.write(state, texts: [pending], directory: directory, windowsURL: store.windowsURL, panesURL: store.panesURL)
        let textURL = RestoreStore.textURL(in: store.panesURL, for: paneID)
        for url in [store.windowsURL, textURL] {
            #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
        }
        #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        // The prompt line is left out: the new shell shows its own.
        #expect(RestoreStore.takeText(at: textURL)?.text == "saved\n")
        #expect(!FileManager.default.fileExists(atPath: textURL.path))

        // No windows: nothing is written.
        RestoreStore.write(RestoreState(bootID: nil, savedAt: Date(), windows: []), texts: [pending],
                           directory: directory, windowsURL: store.windowsURL, panesURL: store.panesURL)
        #expect(!FileManager.default.fileExists(atPath: store.windowsURL.path))
        #expect(!FileManager.default.fileExists(atPath: store.panesURL.path))
    }

    @Test func oldLayoutFileIsReadOneTime() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent().appendingPathComponent("persistent-layout.json")) }
        let store = RestoreStore(directory: directory)
        let json = #"""
        {"version":1,"windows":[{"frame":"{{1, 2}, {800, 600}}","selectedTabIndex":0,"tabs":[{"root":
        {"split":{"_0":"vertical","fraction":0.4,
          "first":{"pane":{"_0":{"sessionID":"abc","workingDirectory":"/tmp"}}},
          "second":{"pane":{"_0":{"sessionID":"def","remoteDestination":"user@host"}}}}}}]}]}
        """#
        try Data(json.utf8).write(to: store.legacyLayoutURL)
        let state = try #require(store.takeSavedState())
        let panes = try #require(state.windows.first?.tabs.first?.root.panes)
        #expect(panes.map(\.kind) == [.persistent, .remote])
        #expect(panes.map(\.sessionID) == ["abc", "def"])
        #expect(panes.first?.directory?.path == "/tmp")
        #expect(!FileManager.default.fileExists(atPath: store.legacyLayoutURL.path))
    }

    @Test func directoryCheckDoesNotWaitForASlowVolume() async {
        let start = Date()
        let result = await RestoreDirectoryCheck.resolve("/Volumes/slow/project", timeout: 0.2) { _ in
            Thread.sleep(forTimeInterval: 2)
            return true
        }
        #expect(Date().timeIntervalSince(start) < 1.5)
        #expect(result == RestoreDirectoryCheck.Result(path: nil, notFound: true))
        let parent = await RestoreDirectoryCheck.resolve("/tmp/no-such-directory-\(UUID().uuidString)")
        #expect(parent.notFound)
        #expect(parent.path == URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().path
                || parent.path == "/tmp")
        #expect(await RestoreDirectoryCheck.resolve(nil) == RestoreDirectoryCheck.Result(path: nil, notFound: false))
    }

    // MARK: Panes

    /// `ssh` from a local shell: the remote shell's report is for display only.
    @Test func reportFromAnotherHostDoesNotChangeTheDirectory() {
        let controller = TerminalSessionController(startsProcess: false)
        controller.noteDirectoryReport("file://localhost/Users/me/src")
        #expect(controller.currentWorkingDirectory == "/Users/me/src")
        controller.noteDirectoryReport("file://some-server.example.com/home/me")
        #expect(controller.currentWorkingDirectory == "/Users/me/src")
        #expect(controller.displayedDirectory == "/home/me")
    }

    /// A local pane comes back as a local shell in its directory, under its
    /// text and the separator; its file is deleted.
    @Test func localPaneRestoresItsTextAndDirectory() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try DurableStateDirectory.makePrivateDirectory(directory)
        let restored = pane(.local, directory: "/usr/bin")
        let header = ScrollbackHeader(paneID: restored.id.uuidString, savedAt: Date(), columns: 80, rows: 2)
        let rows = [ScrollbackRow(isWrapped: false, cells: "first line".utf8.map { WireCell(.ascii($0)) }),
                    ScrollbackRow(isWrapped: false, cells: "second line".utf8.map {
                        WireCell(.ascii($0), style: WireCellStyle(attribute: WireAttribute(foreground: .ansi(1))))
                    })]
        let textURL = directory.appendingPathComponent("pane.text")
        try ScrollbackFile.encode(rows, header: header).write(to: textURL)
        let restoration = PaneRestoration(pane: restored, savedAt: Date(), macRestarted: true,
                                          textURL: textURL, sessionRunning: false)
        var spec = LaunchSpec()
        spec.restoredTab = RestoredTab(tab: RestoreTab(focusedPaneID: restored.id, root: .pane(restored)),
                                       panes: [restored.id: restoration])
        AppModel.shared.setPendingLaunch(spec)
        let workspace = TerminalPaneWorkspace()
        let (_, window) = host(workspace)
        defer { workspace.terminateAll(); window.close() }
        let controller = try #require(workspace.controllers.first)
        #expect(controller.id == restored.id)
        #expect(!controller.isPersistent)
        try await wait("the replay") { screenText(controller).contains { $0.contains("Restored") } }
        let text = screenText(controller)
        #expect(text.first == "first line")
        #expect(text.dropFirst().first == "second line")
        #expect(text.contains { $0.contains("the Mac restarted") })
        #expect(!FileManager.default.fileExists(atPath: textURL.path))
        try await wait("the shell's directory") {
            controller.restoreDirectory()?.path == "/usr/bin"
        }
    }

    /// A split of persistent panes is captured and rebuilt with the same sessions.
    @Test func splitLayoutIsCapturedAndRestored() async throws {
        let states = temporaryDirectory()
        let restoreEnvironment = setEnvironment(["TECOLOT_RUNTIME_DIR": "/tmp/tecolot-tests-\(getpid())",
                                                 "TECOLOT_STATE_DIR": states.path])
        defer {
            restoreEnvironment()
            try? FileManager.default.removeItem(at: states)
        }
        let profile = AppModel.shared.profiles.defaultProfile
        var spec = LaunchSpec(profileID: profile.id, workingDirectory: "/tmp")
        spec.persistent = true
        AppModel.shared.setPendingLaunch(spec)

        let workspace = TerminalPaneWorkspace()
        let (hostView, window) = host(workspace)
        defer { window.close() }
        let first = try #require(workspace.focusedController)
        workspace.split(first, orientation: .vertical)
        hostView.synchronize(revision: workspace.revision, document: TerminalDocument(content: ""))
        hostView.layoutSubtreeIfNeeded()
        let ids = workspace.controllers.compactMap(\.persistentSessionID)
        #expect(ids.count == 2)
        #expect(Set(ids).count == 2)
        defer {
            for id in ids { try? PersistentSessions.directory().terminate(id, signal: SIGKILL) }
        }

        var texts: [ScrollbackSnapshot.Pending] = []
        let root = try #require(RestoreStore.capture(workspace.root, hostView: hostView, limit: 1_000, texts: &texts))
        guard case .split(.vertical, let fraction, _, _) = root else {
            Issue.record("expected a vertical split, got \(root)")
            return
        }
        #expect(fraction != nil)
        #expect(root.panes.compactMap(\.sessionID) == ids)
        #expect(root.panes.allSatisfy { $0.kind == .persistent })
        // The helper keeps the text of a persistent session.
        #expect(texts.isEmpty)

        // The panes detach, and a new window rebuilds the layout.
        workspace.terminateAll()
        let tab = RestoreTab(focusedPaneID: root.panes.last?.id, root: root)
        let restorations = Dictionary(uniqueKeysWithValues: root.panes.map {
            ($0.id, PaneRestoration(pane: $0, savedAt: Date(), macRestarted: false, textURL: nil, sessionRunning: true))
        })
        var restoreSpec = LaunchSpec()
        restoreSpec.restoredTab = RestoredTab(tab: tab, panes: restorations)
        AppModel.shared.setPendingLaunch(restoreSpec)
        let restored = TerminalPaneWorkspace()
        let (restoredHost, restoredWindow) = host(restored)
        defer { restoredWindow.close() }
        #expect(restored.controllers.compactMap(\.persistentSessionID) == ids)
        #expect(restored.controllers.map(\.id) == root.panes.map(\.id))
        #expect(restored.focusedControllerID == root.panes.last?.id)
        guard case .split(.vertical, _, _) = restored.root.content else {
            Issue.record("expected the restored root to be a vertical split")
            return
        }
        for controller in restored.controllers {
            let session = try #require(controller.persistentView?.session)
            try await wait("attached") { session.state.connected }
        }
        let restoredFraction = restoredHost.dividerFraction(for: restored.root.id)
        #expect(restoredFraction != nil)
        if let fraction, let restoredFraction {
            #expect(abs(Double(restoredFraction) - fraction) < 0.05)
        }
        restored.terminateAll()
    }

    /// The Mac restarted: the helper is gone, and its saved state starts a
    /// new persistent session in the same directory, under the same text.
    @Test func endedPersistentSessionStartsAgainFromItsState() async throws {
        let states = DurableStateDirectory(url: temporaryDirectory())
        let restoreEnvironment = setEnvironment(["TECOLOT_RUNTIME_DIR": "/tmp/tecolot-tests-\(getpid())",
                                                 "TECOLOT_STATE_DIR": states.url.path])
        defer {
            restoreEnvironment()
            try? FileManager.default.removeItem(at: states.url)
        }
        let launch = SessionLaunch(executable: "/bin/sh", environment: [], workingDirectory: "/usr")
        let saved = DurableSessionState(id: "abcdef012345", launch: launch,
                                        directory: PaneDirectory(path: "/usr/lib", source: .osc7),
                                        bootID: "an-earlier-boot")
        let header = ScrollbackHeader(paneID: saved.id, savedAt: Date(), columns: 80, rows: 1)
        try states.write(saved, scrollback: try ScrollbackFile.encode(
            [ScrollbackRow(isWrapped: false, cells: "before the restart".utf8.map { WireCell(.ascii($0)) })], header: header))

        let restored = pane(.persistent, session: saved.id, directory: "/usr/lib")
        var spec = LaunchSpec()
        spec.restoredTab = RestoredTab(tab: RestoreTab(root: .pane(restored)), panes: [restored.id: PaneRestoration(
            pane: restored, savedAt: Date(), macRestarted: true, textURL: nil, sessionRunning: false)])
        AppModel.shared.setPendingLaunch(spec)
        let workspace = TerminalPaneWorkspace()
        let (_, window) = host(workspace)
        defer { window.close() }
        let controller = try #require(workspace.controllers.first)
        #expect(controller.isPersistent)
        try await wait("the new session") { controller.persistentSessionID != nil }
        let newID = try #require(controller.persistentSessionID)
        defer { try? PersistentSessions.directory().terminate(newID, signal: SIGKILL) }
        #expect(newID != saved.id)
        #expect(states.read(saved.id) == nil)
        let record = try #require(PersistentSessions.list().first { $0.id == newID })
        #expect(record.workingDirectory == "/usr/lib")
        workspace.terminateAll()
    }

    // MARK: Sessions window

    @Test func endedFilterListsTheSavedStates() {
        let launch = SessionLaunch(executable: "/bin/zsh", environment: [], labels: ["profile": "Work"])
        var removed: [String] = []
        let model = SessionBrowserModel(list: { [] },
                                        ended: { [DurableSessionState(id: "0abc", launch: launch,
                                                                      directory: PaneDirectory(path: "/tmp/x", source: .osc7),
                                                                      title: "make")] },
                                        removeEnded: { removed.append($0) }, shown: { [] })
        model.refresh()
        #expect(model.rows.isEmpty)
        model.setFilter(.ended)
        #expect(model.rows.map(\.record.id) == ["0abc"])
        let row = model.rows[0]
        #expect(row.status == .ended)
        #expect(!row.canAttach)
        #expect(row.directory == "/tmp/x")
        #expect(row.profile == "Work")
        #expect(model.visibleHosts.map(\.id) == [SessionHost.localID])
        model.deleteEnded([row])
        #expect(removed == ["0abc"])
    }
}

private final class SnapshotDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
