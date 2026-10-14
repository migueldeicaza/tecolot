//
//  PersistentLayoutTests.swift
//  TecolotTests
//

import AppKit
import Foundation
import Testing
@testable import Tecolot
import TecolotSessionClient
import TecolotSessionDirectory

@MainActor
struct PersistentLayoutTests {
    private func pane(_ id: String?, directory: String = "/tmp") -> SavedPaneNode {
        .pane(SavedPane(sessionID: id, profileID: nil, themeOverride: nil, workingDirectory: directory))
    }

    @Test func pruningDropsEndedSessionsAndCollapsesSplits() {
        let tree: SavedPaneNode = .split(.vertical, fraction: 0.3,
                                         first: pane("aaa"),
                                         second: .split(.horizontal, fraction: 0.5,
                                                        first: pane("bbb"), second: pane(nil)))
        // Every session runs: nothing changes.
        #expect(tree.pruned(liveSessions: ["aaa", "bbb"]) == tree)
        // "bbb" ended: its split collapses to the local pane.
        #expect(tree.pruned(liveSessions: ["aaa"]) ==
                .split(.vertical, fraction: 0.3, first: pane("aaa"), second: pane(nil)))
        // Only local panes are left: the layout keeps them, but the tab has
        // no persistent pane, so the layout drops the tab.
        let layout = SavedLayout(windows: [SavedLayoutWindow(frame: "{{0, 0}, {800, 600}}",
                                                             tabs: [SavedPaneTree(root: tree)],
                                                             selectedTabIndex: 0)])
        #expect(layout.pruned(liveSessions: []).windows.isEmpty)
        #expect(layout.pruned(liveSessions: ["bbb"]).windows.first?.tabs.first?.root.panes.count == 2)
    }

    @Test func selectedTabFollowsPruning() {
        let layout = SavedLayout(windows: [SavedLayoutWindow(
            frame: "{{0, 0}, {800, 600}}",
            tabs: [SavedPaneTree(root: pane("gone")), SavedPaneTree(root: pane("live"))],
            selectedTabIndex: 1)])
        let pruned = layout.pruned(liveSessions: ["live"])
        #expect(pruned.windows.first?.tabs.count == 1)
        #expect(pruned.windows.first?.selectedTabIndex == 0)
    }

    @Test func layoutRoundTripsThroughTheFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("layout-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PersistentLayoutStore(url: url)
        let layout = SavedLayout(windows: [SavedLayoutWindow(
            frame: "{{10, 20}, {800, 600}}",
            tabs: [SavedPaneTree(root: .split(.horizontal, fraction: 0.25, first: pane("abc"), second: pane(nil)))],
            selectedTabIndex: 0)])
        store.save(layout)
        #expect(store.load() == layout)
        store.save(SavedLayout())
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func oldPaneJSONHasNoRemoteDestination() throws {
        let json = Data(#"{"sessionID":"local","workingDirectory":"/tmp"}"#.utf8)
        let pane = try JSONDecoder().decode(SavedPane.self, from: json)
        #expect(pane.sessionID == "local")
        #expect(pane.remoteDestination == nil)
    }

    @Test func remoteLayoutRoundTripsAndSurvivesLocalPruning() throws {
        let remote = SavedPane(sessionID: "remote-id", profileID: nil, themeOverride: "theme",
                               workingDirectory: "/home/user", remoteDestination: "user@host")
        let pending = SavedPane(sessionID: nil, profileID: nil, themeOverride: nil,
                                workingDirectory: nil, remoteDestination: "other-host")
        let layout = SavedLayout(windows: [SavedLayoutWindow(
            frame: "{{0, 0}, {800, 600}}",
            tabs: [SavedPaneTree(root: .split(.vertical, fraction: 0.4,
                                             first: .pane(remote), second: pane("ended-local"))),
                   SavedPaneTree(root: .pane(pending))],
            selectedTabIndex: 1)])
        let encoded = try JSONEncoder().encode(layout)
        #expect(try JSONDecoder().decode(SavedLayout.self, from: encoded) == layout)
        let pruned = layout.pruned(liveSessions: [])
        #expect(pruned.windows.first?.tabs.map(\.root) == [.pane(remote), .pane(pending)])
        #expect(pruned.windows.first?.selectedTabIndex == 1)
    }

    private func wait(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("timed out: \(what)")
    }

    /// A split of persistent panes is captured and rebuilt with the same sessions.
    @Test func splitLayoutIsCapturedAndRestored() async throws {
        setenv("TECOLOT_RUNTIME_DIR", "/tmp/tecolot-tests-\(getpid())", 1)
        let profile = AppModel.shared.profiles.defaultProfile
        var spec = LaunchSpec(profileID: profile.id, workingDirectory: "/tmp")
        spec.persistent = true
        AppModel.shared.setPendingLaunch(spec)

        func host(_ workspace: TerminalPaneWorkspace) -> (TerminalPaneHostView, NSWindow) {
            let document = TerminalDocument(content: "")
            let hostView = TerminalPaneHostView(workspace: workspace, document: document)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = hostView
            hostView.synchronize(revision: workspace.revision, document: document)
            hostView.layoutSubtreeIfNeeded()
            return (hostView, window)
        }

        let workspace = TerminalPaneWorkspace()
        let (hostView, _) = host(workspace)
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

        let tree = SavedPaneTree(root: try #require(PersistentLayoutStore.capture(workspace.root, hostView: hostView)))
        guard case .split(.vertical, let fraction, _, _) = tree.root else {
            Issue.record("expected a vertical split, got \(tree.root)")
            return
        }
        #expect(fraction != nil)
        #expect(tree.root.panes.compactMap(\.sessionID) == ids)

        // The panes detach, and a new window rebuilds the layout.
        workspace.terminateAll()
        var restoreSpec = LaunchSpec()
        restoreSpec.paneTree = tree
        AppModel.shared.setPendingLaunch(restoreSpec)
        let restored = TerminalPaneWorkspace()
        let (restoredHost, _) = host(restored)
        #expect(restored.controllers.compactMap(\.persistentSessionID) == ids)
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
}
