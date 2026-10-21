//
//  PersistentSessionTests.swift
//  TecolotTests
//
//  End to end: the embedded tecolot-sessiond runs the shell, the remote view
//  draws it, and the session survives a detach.
//

import AppKit
import Metal
import Foundation
import Testing
@testable import SwiftTerm
@testable import Tecolot
import TecolotSessionClient
import TecolotSessionDirectory
import TecolotWire

@MainActor
@Suite(.serialized)
struct PersistentSessionTests {
    /// Uses a private runtime directory, so the test never sees real sessions.
    private static let runtimeDirectory: String = {
        let path = "/tmp/tecolot-tests-\(getpid())"
        setenv("TECOLOT_RUNTIME_DIR", path, 1)
        return path
    }()

    private func profile() -> TerminalProfile {
        var profile = TerminalProfile(name: "Persistent Test")
        profile.shell = .command("/bin/sh", runInShell: false)
        profile.columns = 60
        profile.rows = 12
        return profile
    }

    private func screenText(_ session: RemoteSession) -> String {
        session.withState { state, cache in
            (0 ..< Int64(state.rows)).compactMap { offset -> String? in
                let line = state.displayTop + offset
                guard let row = cache[line] else { return nil }
                return cache.text(from: (line, 0), to: (line, row.cells.count - 1))
            }.joined(separator: "\n")
        }
    }

    private func wait(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("timed out: \(what)")
    }

    @Test func helperIsEmbedded() {
        #expect(PersistentSessions.helperPath != nil)
    }

    @Test func sessionRunsInTheHelperAndSurvivesDetach() async throws {
        _ = Self.runtimeDirectory
        let record = try PersistentSessions.create(profile: profile(), workingDirectory: "/tmp",
                                                   columns: 60, rows: 12, cellWidth: 0, cellHeight: 0)
        let directory = try PersistentSessions.directory()
        defer { try? directory.terminate(record.id, signal: SIGKILL) }
        #expect(directory.url.path == Self.runtimeDirectory)

        // First client: type a command and see its output.
        let first = RemoteSession(socket: try directory.connect(record.id), clientName: "test", build: "test")
        let view = RemoteTerminalView(session: first, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        first.start(size: WireGridSize(columns: 60, rows: 12), focused: true)
        try await wait("attached") { first.state.connected }
        first.send(text: "echo persistent-$((40+2))\r")
        try await wait("output") { screenText(first).contains("persistent-42") }

        // The remote view paints the cached rows.
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = .white
        view.setFrameSize(NSSize(width: view.cellSize.width * 60, height: view.cellSize.height * 12))
        view.frameTick()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var lit = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.redComponent > 0.5 { lit += 1 }
            }
        }
        #expect(lit > 0)

        // Detach: the session keeps running.
        first.detach()
        try await Task.sleep(nanoseconds: 200_000_000)
        let listed = PersistentSessions.list()
        #expect(listed.contains { $0.id == record.id && !$0.exited })

        // Second client: the same screen comes back.
        let second = RemoteSession(socket: try directory.connect(record.id), clientName: "test", build: "test")
        second.start(size: WireGridSize(columns: 60, rows: 12), focused: true)
        try await wait("reattached screen") { screenText(second).contains("persistent-42") }

        // Terminate ends the session and its helper.
        second.terminate(signal: SIGHUP)
        try await wait("exit") { second.state.exitStatus != nil }
        second.close()
        try await wait("helper gone") { !PersistentSessions.list().contains { $0.id == record.id } }
    }

    @Test func runtimeResourcesAreCopiedOutOfTheBundle() throws {
        let runtime = try #require(PersistentRuntimeResources.prepare())
        #expect(FileManager.default.fileExists(atPath: runtime.appendingPathComponent("terminfo").path))
        let launch = PersistentSessions.makeLaunch(profile: profile(), workingDirectory: "/tmp",
                                                   columns: 80, rows: 24, cellWidth: 0, cellHeight: 0)
        let bundle = try #require(Bundle.main.resourceURL?.path)
        #expect(!launch.environment.contains { $0.contains(bundle) })
        #expect(launch.environment.contains { $0.hasPrefix("TERMINFO=\(runtime.path)") })
        #expect(launch.labels["profile"] == "Persistent Test")
    }
}

/// The pane path: a workspace whose launch asks for a persistent session
/// shows a RemoteTerminalView, takes key events, follows window resizes and
/// detaches when it closes.
@MainActor
@Suite(.serialized)
struct PersistentPaneTests {
    private func wait(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("timed out: \(what)")
    }

    private func waitForSelection(_ what: String, in view: RemoteTerminalView,
                                  _ condition: (String?) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let text = await withCheckedContinuation { continuation in
                view.selectedText { continuation.resume(returning: $0) }
            }
            if condition(text) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("timed out: \(what)")
    }

    /// True when a visible row is exactly `text` (trailing blanks aside).
    private func screenHasRow(_ session: RemoteSession, _ text: String) -> Bool {
        screen(session).split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == text }
    }

    private func screen(_ session: RemoteSession) -> String {
        session.withState { state, cache in
            (0 ..< Int64(state.rows)).compactMap { offset -> String? in
                let line = state.displayTop + offset
                guard let row = cache[line] else { return nil }
                return cache.text(from: (line, 0), to: (line, row.cells.count - 1))
            }.joined(separator: "\n")
        }
    }

    private func key(_ characters: String, keyCode: UInt16, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil,
                                      characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: keyCode))
    }

    @Test func findLocatesMatchesInScrollback() async throws {
        setenv("TECOLOT_RUNTIME_DIR", "/tmp/tecolot-tests-\(getpid())", 1)
        let profile = AppModel.shared.profiles.defaultProfile
        var spec = LaunchSpec(profileID: profile.id, workingDirectory: "/tmp")
        spec.persistent = true
        AppModel.shared.setPendingLaunch(spec)
        let workspace = TerminalPaneWorkspace()
        let controller = try #require(workspace.focusedController)
        let document = TerminalDocument()
        let hostView = TerminalPaneHostView(workspace: workspace, document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hostView
        hostView.synchronize(revision: workspace.revision, document: document)
        hostView.layoutSubtreeIfNeeded()
        let view = try #require(controller.persistentView)
        view.findPasteboard = NSPasteboard.withUniqueName()
        defer { view.findPasteboard.releaseGlobally() }
        let session = view.session
        let sessionID = try #require(controller.persistentSessionID)
        defer { try? PersistentSessions.directory().terminate(sessionID, signal: SIGKILL) }
        try await wait("attached") { session.state.connected }

        // A unique word far above the visible screen.
        session.send(text: "echo zebra-$((1+1)); seq 1 400\r")
        // The command line also holds "400"; wait for the output row.
        try await wait("output") { screenHasRow(session, "400") }
        view.search(query: "zebra-2", backward: true)
        try await wait("match selected") { view.selectionActive }
        #expect(view.findStatus == "")
        #expect(!session.state.follow)
        // The view scrolled to the match; its rows arrive from the helper.
        try await wait("match shown") { screen(session).contains("zebra-2") }

        view.search(query: "no-such-word", backward: false)
        try await wait("not found") { view.findStatus == "Not found" }

        // The find bar: typing searches, Return goes to the next match and
        // Escape closes the bar.
        view.performFind(.showFindInterface)
        let bar = try #require(view.subviews.compactMap { $0 as? RemoteFindBar }.first)
        bar.query = "seq 1 4"
        bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: bar.field))
        try await waitForSelection("typed match", in: view) { $0 == "seq 1 4" }
        bar.query = "no-such-word"
        bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: bar.field))
        try await wait("typed miss") { view.findStatus == "Not found" && !view.selectionActive }
        bar.query = "zebra-2"
        bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: bar.field))
        try await waitForSelection("typed zebra", in: view) { $0 == "zebra-2" }
        #expect(bar.control(bar.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        try await waitForSelection("next match", in: view) { $0 == "zebra-2" }
        #expect(bar.control(bar.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(bar.superview == nil)
        workspace.terminateAll()
    }

    @Test func promptNavigationScrollsToMarks() async throws {
        setenv("TECOLOT_RUNTIME_DIR", "/tmp/tecolot-tests-\(getpid())", 1)
        let profile = AppModel.shared.profiles.defaultProfile
        var spec = LaunchSpec(profileID: profile.id, workingDirectory: "/tmp")
        spec.persistent = true
        AppModel.shared.setPendingLaunch(spec)
        let workspace = TerminalPaneWorkspace()
        let controller = try #require(workspace.focusedController)
        let document = TerminalDocument()
        let hostView = TerminalPaneHostView(workspace: workspace, document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hostView
        hostView.synchronize(revision: workspace.revision, document: document)
        hostView.layoutSubtreeIfNeeded()
        let view = try #require(controller.persistentView)
        let session = view.session
        let sessionID = try #require(controller.persistentSessionID)
        defer { try? PersistentSessions.directory().terminate(sessionID, signal: SIGKILL) }
        try await wait("attached") { session.state.connected }

        // A row that OSC 133 marks as a prompt, far above the screen.
        session.send(text: "printf '\\033]133;A\\007MARK-ONE\\033]133;B\\007\\n'; seq 1 100\r")
        try await wait("output") { screenHasRow(session, "100") }
        #expect(controller.scrollToPreviousPrompt())
        try await wait("prompt at the top") { screen(session).hasPrefix("MARK-ONE") }
        #expect(!session.state.follow)

        // The Use Metal Renderer setting reaches persistent panes.
        controller.setUseMetalRenderer(false)
        #expect(!view.isUsingMetalRenderer)
        #expect(!controller.useMetalRenderer)
        controller.setUseMetalRenderer(true)
        #expect(view.isUsingMetalRenderer == (MTLCreateSystemDefaultDevice() != nil))
        #expect(view.metalBufferingMode == .perFrameAggregated)
        workspace.terminateAll()
    }

    @Test func imagesAndBidiDrawInPersistentPanes() async throws {
        setenv("TECOLOT_RUNTIME_DIR", "/tmp/tecolot-tests-\(getpid())", 1)
        let profile = AppModel.shared.profiles.defaultProfile
        var spec = LaunchSpec(profileID: profile.id, workingDirectory: "/tmp")
        spec.persistent = true
        AppModel.shared.setPendingLaunch(spec)
        let workspace = TerminalPaneWorkspace()
        let controller = try #require(workspace.focusedController)
        let document = TerminalDocument()
        let hostView = TerminalPaneHostView(workspace: workspace, document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hostView
        hostView.synchronize(revision: workspace.revision, document: document)
        hostView.layoutSubtreeIfNeeded()
        let view = try #require(controller.persistentView)
        let session = view.session
        let sessionID = try #require(controller.persistentSessionID)
        defer { try? PersistentSessions.directory().terminate(sessionID, signal: SIGKILL) }
        try await wait("attached") { session.state.connected }

        // A red Sixel image, a green Kitty image, and a Hebrew line.
        session.send(text: "clear; printf '\\033Pq#0;2;100;0;0#0!40~-!40~-!40~\\033\\\\'; " +
                     "printf '\\033_Gi=5,f=24,s=2,v=2,a=T,q=2,c=4,r=2;AP8AAP8AAP8AAP8A\\033\\\\'; " +
                     "printf '\\nשלום abc\\n'\r")
        try await wait("hebrew") { screen(session).contains("abc") }
        // The renderers draw from the view's snapshot (pixel parity with local
        // panes is tested in SwiftTerm): it has the Sixel slice and the Kitty
        // placement with its pixels once they arrive.
        let owner = try #require(Mirror(reflecting: view).superclassMirror?.descendant("owner") as? ExternalRenderOwner)
        try await wait("sixel slice") {
            view.frameTick()
            return owner.snapshot.rows.contains { !$0.images.isEmpty }
        }
        try await wait("kitty image") {
            view.frameTick()
            let kitty = owner.snapshot.kitty.renderSnapshot
            return kitty.placements.contains { $0.imageId == 5 } && kitty.imagesById[5]?.width == 2
        }
        let slice = try #require(owner.snapshot.rows.lazy.compactMap(\.images.first).first)
        let scale = window.backingScaleFactor
        // 40 × 18 device pixels, shown at the display's density.
        #expect(abs(CGFloat(slice.pixelWidth) - 40 / scale) <= 1)
        #expect(slice.col == 0)
        // The Hebrew row is reordered: its first visual column is not column 0.
        let hebrewRow = try #require(screen(session).split(separator: "\n", omittingEmptySubsequences: false)
            .firstIndex { $0.contains("abc") })
        view.frameTick()
        #expect(view.baseDirection(row: hebrewRow) == .rightToLeft)
        #expect(view.logicalColumn(forVisualColumn: 0, row: hebrewRow) != 0)
        workspace.terminateAll()
    }

    @Test func progressAndNotificationsReachPersistentPanes() async throws {
        setenv("TECOLOT_RUNTIME_DIR", "/tmp/tecolot-tests-\(getpid())", 1)
        TestNotifications.install()
        let profile = AppModel.shared.profiles.defaultProfile
        var spec = LaunchSpec(profileID: profile.id, workingDirectory: "/tmp")
        spec.persistent = true
        AppModel.shared.setPendingLaunch(spec)
        let workspace = TerminalPaneWorkspace()
        let controller = try #require(workspace.focusedController)
        let document = TerminalDocument()
        let hostView = TerminalPaneHostView(workspace: workspace, document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hostView
        hostView.synchronize(revision: workspace.revision, document: document)
        hostView.layoutSubtreeIfNeeded()
        let view = try #require(controller.persistentView)
        let session = view.session
        let sessionID = try #require(controller.persistentSessionID)
        defer { try? PersistentSessions.directory().terminate(sessionID, signal: SIGKILL) }
        try await wait("attached") { session.state.connected }

        session.send(text: "printf '\\033]9;4;1;40\\a\\033]777;notify;Build;Done\\a'\r")
        try await wait("progress") { view.progressReport == Terminal.ProgressReport(state: .set, progress: 40) }
        try await wait("notification") { !TestNotifications.contents(for: controller).isEmpty }
        let content = try #require(TestNotifications.contents(for: controller).first)
        #expect(content.title == "Build")
        #expect(content.body == "Done")
        session.send(text: "printf '\\033]9;4;0\\a'\r")
        try await wait("progress removed") { view.progressReport == nil }
        workspace.terminateAll()
    }

    @Test func persistentPaneTypesResizesAndDetaches() async throws {
        setenv("TECOLOT_RUNTIME_DIR", "/tmp/tecolot-tests-\(getpid())", 1)
        let profile = AppModel.shared.profiles.defaultProfile
        var spec = LaunchSpec(profileID: profile.id, workingDirectory: "/tmp")
        spec.persistent = true
        AppModel.shared.setPendingLaunch(spec)

        let workspace = TerminalPaneWorkspace()
        let controller = try #require(workspace.focusedController)
        let document = TerminalDocument()
        let hostView = TerminalPaneHostView(workspace: workspace, document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hostView
        hostView.synchronize(revision: workspace.revision, document: document)
        hostView.layoutSubtreeIfNeeded()

        let view = try #require(controller.persistentView)
        #expect(controller.terminal == nil)
        #expect(controller.isPersistent)
        let sessionID = try #require(controller.persistentSessionID)
        let session = view.session
        try await wait("attached") { session.state.connected }
        #expect(window.makeFirstResponder(view))

        // Typing goes through keyDown and the input method to the helper.
        for character in "echo ui-$((1+1))" {
            view.keyDown(with: try key(String(character), keyCode: 0, in: window))
        }
        view.keyDown(with: try key("\r", keyCode: 36, in: window))
        try await wait("command output") { screen(session).contains("ui-2") }

        // The helper follows the view's grid.
        window.setContentSize(NSSize(width: 900, height: 500))
        hostView.layoutSubtreeIfNeeded()
        let grid = view.gridSize
        try await wait("resize") { session.state.columns == grid.columns && session.state.rows == grid.rows }

        // Export text comes from the helper and includes scrollback.
        view.keyDown(with: try key("\r", keyCode: 36, in: window))
        for character in "seq 1 300" {
            view.keyDown(with: try key(String(character), keyCode: 0, in: window))
        }
        view.keyDown(with: try key("\r", keyCode: 36, in: window))
        // The command line also holds "300"; wait for the output row.
        try await wait("seq output") { screenHasRow(session, "300") }
        var exported: String?
        view.bufferText { exported = $0 }
        try await wait("buffer text") { exported != nil }
        #expect(exported?.contains("\n1\n2\n3\n") == true)
        #expect(exported?.contains("ui-2") == true)

        // Clear to Start empties the screen and the scrollback.
        controller.clearToStart()
        try await wait("cleared") {
            let state = session.state
            return state.endLine - state.firstLine == Int64(state.rows) && !screen(session).contains("300")
        }

        // A dropped connection offers Reconnect; reconnecting shows the session again.
        for character in "echo again-$((2+3))" {
            view.keyDown(with: try key(String(character), keyCode: 0, in: window))
        }
        view.keyDown(with: try key("\r", keyCode: 36, in: window))
        try await wait("again") { screen(session).contains("again-5") }
        session.close()
        try await wait("disconnect banner") { view.bannerText == "Disconnected from the session." }
        controller.reconnectPersistentSession()
        #expect(view.bannerText == nil)
        #expect(view.session !== session)
        try await wait("reconnected screen") { screen(view.session).contains("again-5") }

        // Closing the pane detaches; the session keeps running.
        workspace.terminateAll()
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(PersistentSessions.list().contains { $0.id == sessionID && !$0.exited })
        #expect(view.bannerText == nil)
        try PersistentSessions.directory().terminate(sessionID, signal: SIGKILL)
        try await wait("ended") { !PersistentSessions.list().contains { $0.id == sessionID } }
    }
}
