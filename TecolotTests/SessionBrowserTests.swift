import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Tecolot
import TecolotSessionDirectory

@MainActor
struct SessionBrowserTests {
    private func record(_ id: String, minutesAgo: Double, attached: Int = 0, exited: Bool = false,
                        foreground: String? = nil) -> SessionRecord {
        var record = SessionRecord(id: id, pid: 1, shellPID: 2, protocolVersion: 1, build: "test",
                                   createdAt: Date().addingTimeInterval(-minutesAgo * 60),
                                   executable: "/bin/zsh", workingDirectory: "/tmp",
                                   labels: ["profile": "Default", "profileID": UUID().uuidString],
                                   columns: 80, rows: 24)
        record.attachedClients = attached
        record.exited = exited
        record.exitCode = exited ? 0 : nil
        record.foreground = foreground
        record.directory = "file:///tmp/project"
        return record
    }

    @Test func rowsShowWhereEachSessionIs() {
        let records = [
            record("old", minutesAgo: 30),
            record("here", minutesAgo: 20, attached: 1, foreground: "vim"),
            record("elsewhere", minutesAgo: 10, attached: 1),
            record("done", minutesAgo: 5, exited: true),
        ]
        let model = SessionBrowserModel(list: { records }, shown: { ["here"] })
        model.selection = ["gone", "old"]
        model.refresh()
        // Newest first.
        #expect(model.rows.map(\.id) == ["done", "elsewhere", "here", "old"])
        #expect(model.rows.map(\.status) == [.exited(0), .attachedElsewhere, .shownHere, .detached])
        #expect(model.rows.map(\.canAttach) == [false, true, true, true])
        #expect(model.rows.map(\.canShow) == [false, true, true, true])
        #expect(model.rows.map(\.shownHere) == [false, false, true, false])
        // Sessions that went away leave the selection.
        #expect(model.selection == ["old"])

        let here = model.rows[2]
        #expect(here.command == "vim")
        #expect(here.directory == "/tmp/project")
        #expect(here.size == "80×24")
        #expect(model.rows[3].command == "zsh")

        // The window draws the rows (written for a visual check).
        let view = NSHostingView(rootView: SessionBrowserView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        model.refresh()
        view.layoutSubtreeIfNeeded()
        if let output = ProcessInfo.processInfo.environment["TECOLOT_SNAPSHOT_DIR"],
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: output).appendingPathComponent("session-browser.png"))
        }

        let spec = SessionBrowserModel.attachSpec(here.record)
        #expect(spec.attachSessionID == "here")
        #expect(spec.profileID == UUID(uuidString: here.record.labels["profileID"]!))
    }

    /// The Sessions window is in front when it attaches a session in a new
    /// tab: the tab joins a terminal window.
    @Test func newTabsJoinATerminalWindow() {
        let sessions = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                                styleMask: [.titled], backing: .buffered, defer: true)
        let terminal = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                                styleMask: [.titled], backing: .buffered, defer: true)
        let controller = TerminalSessionController(startsProcess: false)
        TerminalSessionRegistry.shared.register(controller: controller, workspace: nil, for: terminal)
        defer { TerminalSessionRegistry.shared.unregister(controller: controller, from: terminal) }
        #expect(WindowOpener.frontTerminalWindow(in: [sessions, terminal]) === terminal)
        #expect(WindowOpener.frontTerminalWindow(in: [sessions]) == nil)
    }

    /// A pane can still show a session whose program ended: Show brings
    /// that pane to the front.
    @Test func exitedSessionsThatAPaneShowsCanBeShown() {
        let records = [record("done", minutesAgo: 5, exited: true)]
        let model = SessionBrowserModel(list: { records }, shown: { ["done"] })
        model.refresh()
        let row = model.rows[0]
        #expect(row.status == .exited(0))
        #expect(row.shownHere && row.canShow && !row.canAttach)
    }

    /// The window reads the sessions every two seconds; the table draws
    /// again only when a session changed.
    @Test func refreshChangesTheRowsOnlyWhenASessionChanged() {
        final class Counter { var value = 0 }
        var records = [record("a", minutesAgo: 5), record("b", minutesAgo: 1)]
        let model = SessionBrowserModel(list: { records }, shown: { [] })
        model.selection = ["a"]
        model.refresh()
        let changes = Counter()
        func observe() {
            withObservationTracking {
                _ = model.rows
                _ = model.selection
            } onChange: {
                changes.value += 1
            }
        }
        observe()
        model.refresh()
        #expect(changes.value == 0)

        records[0].title = "vim"
        model.refresh()
        #expect(changes.value == 1)
        #expect(model.rows.last?.title == "vim")
        #expect(model.selection == ["a"])
    }
}
