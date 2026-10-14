//
//  SessionBrowser.swift
//  Tecolot
//
//  The Sessions window: every persistent session on this Mac, with actions
//  to show, attach to and terminate them.
//

import AppKit
import SwiftUI
import TecolotSessionDirectory

enum SessionBrowserWindowID {
    static let value = "sessions"
}

/// One row of the Sessions window.
struct SessionBrowserRow: Identifiable, Hashable {
    enum Status: Hashable {
        /// A pane of this app shows the session.
        case shownHere
        /// Another app (for example a second copy of Tecolot) shows it.
        case attachedElsewhere
        case detached
        case exited(Int32?)

        var label: String {
            switch self {
            case .shownHere: return "Shown"
            case .attachedElsewhere: return "Attached elsewhere"
            case .detached: return "Detached"
            case .exited(let code): return code.map { "Exited (\($0))" } ?? "Exited"
            }
        }
    }

    let record: SessionRecord
    let status: Status
    /// A pane of this app shows the session, also after its program ended.
    let shownHere: Bool

    var id: String { record.id }

    /// The program in front, else the shell.
    var command: String {
        if let foreground = record.foreground, !foreground.isEmpty {
            return foreground.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        return (record.executable as NSString).lastPathComponent
    }

    var title: String { record.title }

    var directory: String {
        let path = URL(string: record.directory)?.path ?? record.workingDirectory ?? ""
        return path.isEmpty ? "" : (path as NSString).abbreviatingWithTildeInPath
    }

    var profile: String { record.labels["profile"] ?? "" }

    var size: String { "\(record.columns)×\(record.rows)" }

    var canAttach: Bool {
        if case .exited = status { return false }
        return true
    }

    /// Show brings the pane to the front, or attaches in a new tab.
    var canShow: Bool { shownHere || canAttach }
}

@MainActor
@Observable
final class SessionBrowserModel {
    private(set) var rows: [SessionBrowserRow] = []
    var selection: Set<String> = []

    @ObservationIgnored private let list: () -> [SessionRecord]
    @ObservationIgnored private let shown: () -> Set<String>
    @ObservationIgnored private var timer: Timer?

    init(list: @escaping () -> [SessionRecord] = PersistentSessions.list,
         shown: @escaping () -> Set<String> = { TerminalSessionRegistry.shared.shownPersistentSessionIDs() }) {
        self.list = list
        self.shown = shown
    }

    /// Reads the sessions again. Newest first. The table draws again only
    /// when a row changed.
    func refresh() {
        let shown = shown()
        let newRows = list()
            .sorted { $0.createdAt > $1.createdAt }
            .map { record in
                let shownHere = shown.contains(record.id)
                let status: SessionBrowserRow.Status
                if record.exited {
                    status = .exited(record.exitCode)
                } else if shownHere {
                    status = .shownHere
                } else if record.attachedClients > 0 {
                    status = .attachedElsewhere
                } else {
                    status = .detached
                }
                return SessionBrowserRow(record: record, status: status, shownHere: shownHere)
            }
        if newRows != rows {
            rows = newRows
        }
        let kept = selection.intersection(rows.map(\.id))
        if kept != selection {
            selection = kept
        }
    }

    /// Reads the sessions every two seconds while the window is open.
    func startRefreshing() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopRefreshing() {
        timer?.invalidate()
        timer = nil
    }

    func rows(for ids: Set<String>) -> [SessionBrowserRow] {
        rows.filter { ids.contains($0.id) }
    }

    // MARK: Actions

    /// Shows the pane of a session that this app shows, else attaches to the
    /// session in a new tab.
    func open(_ row: SessionBrowserRow) {
        Self.show(row.record)
    }

    func openInNewWindow(_ row: SessionBrowserRow) {
        guard row.canAttach else { return }
        WindowOpener.openWindow(spec: Self.attachSpec(row.record))
    }

    /// Shows the pane of a session that this app shows, else attaches to the
    /// session in a new tab of the front terminal window.
    static func show(_ record: SessionRecord) {
        if let controller = TerminalSessionRegistry.shared.controller(showingPersistentSession: record.id) {
            controller.reveal()
            return
        }
        guard !record.exited else { return }
        WindowOpener.openTab(spec: attachSpec(record))
    }

    /// Ends the sessions after the user confirms.
    func terminate(_ rows: [SessionBrowserRow]) {
        let running = rows.filter(\.canAttach)
        guard !running.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = running.count == 1 ? "Terminate this session?" : "Terminate \(running.count) sessions?"
        alert.informativeText = "The shell and the programs that it runs end. You cannot undo this."
        alert.addButton(withTitle: "Terminate")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for row in running {
            try? PersistentSessions.directory().terminate(row.id)
        }
        refresh()
    }

    func copyIDs(_ rows: [SessionBrowserRow]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rows.map(\.id).joined(separator: "\n"), forType: .string)
    }

    static func attachSpec(_ record: SessionRecord) -> LaunchSpec {
        var spec = LaunchSpec()
        spec.attachSessionID = record.id
        if let profileID = record.labels["profileID"].flatMap(UUID.init(uuidString:)) {
            spec.profileID = profileID
        }
        return spec
    }
}

struct SessionBrowserView: View {
    @State private var model: SessionBrowserModel

    @MainActor
    init(model: SessionBrowserModel? = nil) {
        _model = State(initialValue: model ?? SessionBrowserModel())
    }

    var body: some View {
        Group {
            if model.rows.isEmpty {
                ContentUnavailableView(
                    "No Persistent Sessions",
                    systemImage: "terminal",
                    description: Text("Use File > New Persistent Tab to start a session that keeps running when its pane closes.")
                )
            } else {
                table
            }
        }
        .frame(minWidth: 760, minHeight: 240)
        .toolbar {
            ToolbarItemGroup {
                Button("Show", systemImage: "macwindow") {
                    model.rows(for: model.selection).forEach(model.open)
                }
                .help("Show the session, or attach to it in a new tab")
                .disabled(model.rows(for: model.selection).allSatisfy { !$0.canShow })
                Button("Terminate", systemImage: "xmark.octagon") {
                    model.terminate(model.rows(for: model.selection))
                }
                .help("End the session and its programs")
                .disabled(model.rows(for: model.selection).allSatisfy { !$0.canAttach })
            }
        }
        .onAppear { model.startRefreshing() }
        .onDisappear { model.stopRefreshing() }
    }

    private var table: some View {
        Table(model.rows, selection: $model.selection) {
            TableColumn("Program") { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.command)
                    if !row.title.isEmpty, row.title != row.command {
                        Text(row.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .width(min: 100, ideal: 150)
            TableColumn("Directory") { row in Text(row.directory).lineLimit(1).truncationMode(.head) }
                .width(min: 100, ideal: 160, max: 320)
            TableColumn("Profile") { row in Text(row.profile) }
                .width(min: 60, ideal: 80)
            TableColumn("Size") { row in Text(row.size).monospacedDigit() }
                .width(min: 50, ideal: 60)
            TableColumn("Started") { row in
                // The rows change only when a session changes: the time
                // updates by itself.
                TimelineView(.everyMinute) { _ in
                    Text(row.record.createdAt, format: .relative(presentation: .named))
                }
            }
            .width(min: 80, ideal: 110)
            TableColumn("Status") { row in Text(row.status.label).lineLimit(1) }
                .width(min: 130, ideal: 140)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let rows = model.rows(for: ids)
            Button(rows.contains(where: \.shownHere) ? "Show" : "Attach in New Tab") {
                rows.forEach(model.open)
            }
            .disabled(rows.allSatisfy { !$0.canShow })
            Button("Attach in New Window") { rows.forEach(model.openInNewWindow) }
                .disabled(rows.allSatisfy { !$0.canAttach })
            Divider()
            Button("Copy Session ID") { model.copyIDs(rows) }
            Divider()
            Button("Terminate…") { model.terminate(rows) }
                .disabled(rows.allSatisfy { !$0.canAttach })
        } primaryAction: { ids in
            model.rows(for: ids).forEach(model.open)
        }
    }
}
