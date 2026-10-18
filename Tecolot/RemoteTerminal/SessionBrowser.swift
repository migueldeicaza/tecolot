//
//  SessionBrowser.swift
//  Tecolot
//
//  The Sessions window: the persistent sessions on this Mac and on remote
//  hosts, with actions to show, attach to and terminate them. The Ended
//  filter lists the sessions of this Mac that the system ended (log out,
//  restart) and that no window restored; Restore starts each one again.
//

import AppKit
import SwiftUI
import TecolotSessionClient
import TecolotSessionDirectory

enum SessionBrowserWindowID {
    static let value = "sessions"
}

/// One session row of the Sessions window.
struct SessionBrowserRow: Identifiable, Hashable {
    enum Status: Hashable {
        /// A pane of this app shows the session.
        case shownHere
        /// Another app (for example a second copy of Tecolot) shows it.
        case attachedElsewhere
        case detached
        case exited(Int32?)
        /// The system ended the session; its saved state can start it again.
        case ended

        var label: String {
            switch self {
            case .shownHere: return "Shown"
            case .attachedElsewhere: return "Attached elsewhere"
            case .detached: return "Detached"
            case .exited(let code): return code.map { "Exited (\($0))" } ?? "Exited"
            case .ended: return "Ended"
            }
        }
    }

    let record: SessionRecord
    let status: Status
    /// A pane of this app shows the session, also after its program ended.
    let shownHere: Bool
    /// The SSH destination of the host. Nil for this Mac.
    var destination: String? = nil
    /// The saved state of an ended session.
    var endedState: DurableSessionState? = nil

    var id: String { destination.map { "\($0)/\(record.id)" } ?? record.id }

    var ref: SessionRef { SessionRef(id: record.id, destination: destination) }

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
        guard !path.isEmpty else { return "" }
        // A remote home is not the home of this Mac.
        return destination == nil ? (path as NSString).abbreviatingWithTildeInPath : path
    }

    var profile: String { record.labels["profile"] ?? "" }

    var size: String { "\(record.columns)×\(record.rows)" }

    var canAttach: Bool {
        switch status {
        case .exited, .ended: return false
        default: return true
        }
    }

    var isEnded: Bool { endedState != nil }

    /// A row for a session that the system ended.
    static func ended(_ state: DurableSessionState) -> SessionBrowserRow {
        var record = SessionRecord(id: state.id, pid: 0, shellPID: 0, protocolVersion: 0, build: "",
                                   createdAt: state.savedAt, executable: state.launch.executable,
                                   workingDirectory: state.launch.workingDirectory, labels: state.launch.labels,
                                   columns: state.launch.columns, rows: state.launch.rows)
        record.title = state.title
        record.directory = state.directory.map { URL(fileURLWithPath: $0.path).absoluteString } ?? ""
        record.foreground = state.alternateScreenProgram
        record.exited = true
        return SessionBrowserRow(record: record, status: .ended, shownHere: false, endedState: state)
    }

    /// Show brings the pane to the front, or attaches in a new tab.
    var canShow: Bool { shownHere || canAttach }

    static func make(_ record: SessionRecord, shown: Set<String>, destination: String?) -> SessionBrowserRow {
        let shownHere = shown.contains(record.id)
        let status: Status
        if record.exited {
            status = .exited(record.exitCode)
        } else if shownHere {
            status = .shownHere
        } else if record.attachedClients > 0 {
            status = .attachedElsewhere
        } else {
            status = .detached
        }
        return SessionBrowserRow(record: record, status: status, shownHere: shownHere, destination: destination)
    }
}

/// This Mac or a remote host, with its sessions.
struct SessionHost: Identifiable, Hashable {
    enum Kind: Hashable {
        case local
        case remote(String)
    }

    enum State: Hashable {
        case notConnected
        case connecting
        case signingIn
        case gettingSessions
        case confirmInstall(RemoteInstallPrompt)
        case installing
        case loaded
    }

    static let localID = "local"

    let id: String
    let displayName: String
    let kind: Kind
    var state: State
    var sessions: [SessionBrowserRow] = []
    var isExpanded: Bool

    var destination: String? {
        if case .remote(let destination) = kind { return destination }
        return nil
    }

    /// True while the window connects to the host or reads its sessions.
    var isBusy: Bool {
        switch state {
        case .notConnected, .loaded: return false
        default: return true
        }
    }

    var meta: String {
        switch state {
        case .loaded: return sessions.count == 1 ? "1 session" : "\(sessions.count) sessions"
        case .notConnected: return "Not connected"
        default: return ""
        }
    }

    static func local(sessions: [SessionBrowserRow] = []) -> SessionHost {
        SessionHost(id: localID, displayName: "This Mac", kind: .local, state: .loaded,
                    sessions: sessions, isExpanded: true)
    }

    static func remote(_ destination: String) -> SessionHost {
        SessionHost(id: destination, displayName: destination, kind: .remote(destination),
                    state: .notConnected, isExpanded: false)
    }
}

/// One row of the table: a host, a session, or a line under a host.
enum SessionBrowserItem: Identifiable, Hashable {
    case host(SessionHost)
    case session(SessionBrowserRow)
    /// The progress of a host, or the text for a host without sessions.
    case status(SessionHost)

    var id: String {
        switch self {
        case .host(let host): return "host\u{0}\(host.id)"
        case .session(let row): return row.id
        case .status(let host): return "status\u{0}\(host.id)"
        }
    }
}

enum SessionBrowserFilter: Hashable {
    case running
    case ended
}

@MainActor
@Observable
final class SessionBrowserModel {
    static let shared = SessionBrowserModel(defaults: .standard)
    static let hostsKey = "sessionBrowserRemoteHosts"
    /// Seconds between two reads of the sessions on a remote host.
    static let remoteRefreshInterval: TimeInterval = 5

    private(set) var hosts: [SessionHost] = [.local()]
    var selection: Set<String> = []
    private(set) var filter = SessionBrowserFilter.running
    /// The ended sessions of this Mac, newest first.
    private(set) var endedRows: [SessionBrowserRow] = []

    /// The sessions of all hosts, or the ended sessions.
    var rows: [SessionBrowserRow] { filter == .ended ? endedRows : hosts.flatMap(\.sessions) }

    /// The host rows that the table shows. The Ended filter shows this Mac only.
    var visibleHosts: [SessionHost] {
        guard filter == .ended else { return hosts }
        var local = SessionHost.local(sessions: endedRows)
        local.isExpanded = host(SessionHost.localID)?.isExpanded ?? true
        return [local]
    }

    /// The Sessions window, for sheets.
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private let list: () -> [SessionRecord]
    @ObservationIgnored private let ended: () -> [DurableSessionState]
    /// Changes when a state is added or removed. The timer reads the states
    /// again only then: each state holds the full launch environment.
    @ObservationIgnored private let endedSignature: () -> [String]
    @ObservationIgnored private var endedStates: [DurableSessionState] = []
    @ObservationIgnored private var loadedSignature: [String]?
    @ObservationIgnored private let removeEnded: (String) -> Void
    @ObservationIgnored private let shown: () -> Set<String>
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var remoteTimer: Timer?
    @ObservationIgnored private var connections: [String: Connection] = [:]

    /// The connection to a remote host. A new attempt changes `token`, so
    /// that the answers of an earlier attempt do nothing.
    private struct Connection {
        let observer = UUID()
        var token = UUID()
        var link: HostLink?
        var listing = false
        /// The user did not let Tecolot install its helper.
        var declinedInstall = false
    }

    /// `defaults` keeps the remote hosts between launches; nil keeps no hosts.
    init(list: @escaping () -> [SessionRecord] = PersistentSessions.list,
         ended: @escaping () -> [DurableSessionState] = { RestoreStore.localSessionStates.list() },
         endedSignature: @escaping () -> [String] = {
             (try? FileManager.default.contentsOfDirectory(atPath: RestoreStore.localSessionStates.url.path))?.sorted() ?? []
         },
         removeEnded: @escaping (String) -> Void = { RestoreStore.localSessionStates.remove($0) },
         shown: @escaping () -> Set<String> = { TerminalSessionRegistry.shared.shownPersistentSessionIDs() },
         defaults: UserDefaults? = nil) {
        self.list = list
        self.ended = ended
        self.endedSignature = endedSignature
        self.removeEnded = removeEnded
        self.shown = shown
        self.defaults = defaults
        for destination in defaults?.stringArray(forKey: Self.hostsKey) ?? []
        where (try? SSHConfiguration.validate(destination)) != nil && host(destination) == nil {
            hosts.append(.remote(destination))
        }
    }

    func host(_ id: String) -> SessionHost? {
        hosts.first { $0.id == id }
    }

    private func update(_ id: String, _ change: (inout SessionHost) -> Void) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        var host = hosts[index]
        change(&host)
        // The table draws again only when a host changed.
        if host != hosts[index] { hosts[index] = host }
    }

    /// The rows under a host row.
    func children(of host: SessionHost) -> [SessionBrowserItem] {
        if filter == .ended { return endedRows.isEmpty ? [.status(host)] : endedRows.map { .session($0) } }
        if host.state == .loaded && !host.sessions.isEmpty { return host.sessions.map { .session($0) } }
        if host.state == .notConnected { return [] }
        return [.status(host)]
    }

    /// Only session rows can be selected.
    func select(_ ids: Set<String>) {
        let sessions = Set(rows.map(\.id))
        let kept = ids.intersection(sessions)
        if kept != selection { selection = kept }
    }

    /// Reads the sessions on this Mac again. Newest first. The table draws
    /// again only when a row changed.
    func setFilter(_ filter: SessionBrowserFilter) {
        guard filter != self.filter else { return }
        self.filter = filter
        selection = []
        refresh()
    }

    /// `reloadEnded` reads the ended states again also when no state was
    /// added or removed (it also deletes the old states).
    func refresh(reloadEnded: Bool = true) {
        if filter == .ended {
            let signature = endedSignature()
            if reloadEnded || signature != loadedSignature {
                endedStates = ended()
                loadedSignature = signature
            }
            // A state that a running session has is not ended: a pane uses it now.
            let running = Set(list().map(\.id))
            let rows = endedStates.filter { !running.contains($0.id) }.map(SessionBrowserRow.ended)
            if rows != endedRows { endedRows = rows }
            select(selection)
            return
        }
        let shown = shown()
        let local = list()
            .sorted { $0.createdAt > $1.createdAt }
            .map { SessionBrowserRow.make($0, shown: shown, destination: nil) }
        update(SessionHost.localID) { $0.sessions = local }
        for host in hosts {
            guard let destination = host.destination, host.state == .loaded else { continue }
            let shown = TerminalSessionRegistry.shared.shownPersistentSessionIDs(destination: destination)
            let sessions = host.sessions.map { SessionBrowserRow.make($0.record, shown: shown, destination: destination) }
            update(host.id) { $0.sessions = sessions }
        }
        select(selection)
    }

    /// Reads the sessions on this Mac every two seconds, and on remote hosts
    /// that show their sessions every five seconds, while the window is open.
    func startRefreshing() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(reloadEnded: false) }
        }
        remoteTimer?.invalidate()
        remoteTimer = Timer.scheduledTimer(withTimeInterval: Self.remoteRefreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRemoteHosts() }
        }
    }

    func stopRefreshing() {
        timer?.invalidate()
        timer = nil
        remoteTimer?.invalidate()
        remoteTimer = nil
    }

    private func refreshRemoteHosts() {
        // The Ended filter shows only this Mac.
        guard filter != .ended else { return }
        for host in hosts where host.destination != nil && host.state == .loaded && host.isExpanded {
            listSessions(host.id)
        }
    }

    func rows(for ids: Set<String>) -> [SessionBrowserRow] {
        rows.filter { ids.contains($0.id) }
    }

    // MARK: Hosts

    func setExpanded(_ id: String, _ expanded: Bool) {
        guard let host = host(id), host.isExpanded != expanded || (expanded && host.state == .notConnected) else { return }
        guard host.destination != nil else {
            update(id) { $0.isExpanded = expanded }
            return
        }
        if expanded {
            if host.state == .notConnected { connect(id) } else { update(id) { $0.isExpanded = true } }
        } else if host.isBusy {
            // Collapsing a host that connects is the same as Cancel.
            cancel(id)
        } else {
            // A loaded host keeps its connection and its rows.
            update(id) { $0.isExpanded = false }
        }
    }

    /// Asks for a destination, then shows the sessions of that host.
    func connectToHost() {
        guard let destination = RemoteDestinationPanel.run() else { return }
        let id = addHost(destination)
        if host(id)?.state == .notConnected { connect(id) } else { update(id) { $0.isExpanded = true } }
    }

    /// Adds a section for `destination`, or uses the section that exists.
    @discardableResult
    func addHost(_ destination: String) -> String {
        if host(destination) == nil {
            hosts.append(.remote(destination))
            saveHosts()
        }
        return destination
    }

    private func saveHosts() {
        defaults?.set(hosts.compactMap(\.destination), forKey: Self.hostsKey)
    }

    /// Connects to the host and reads its sessions. `then` runs after the
    /// sessions are read.
    func connect(_ id: String, then: (@MainActor () -> Void)? = nil) {
        guard let destination = host(id)?.destination else { return }
        var connection = connections[id] ?? Connection()
        connection.token = UUID()
        connections[id] = connection
        let token = connection.token
        update(id) { $0.state = .connecting; $0.isExpanded = true }
        RemoteHosts.shared.link(destination: destination) { [weak self] result in
            guard let self, self.connections[id]?.token == token else { return }
            switch result {
            case .failure(let error):
                self.fail(id, error, action: "Cannot connect to \(destination)")
            case .success(let link):
                self.connections[id]?.link = link
                RemoteHosts.shared.observe(link: link, observer: connection.observer,
                    state: { [weak self] state in self?.linkChanged(id, state: state, token: token) },
                    notice: { _ in },
                    window: { [weak self] in self?.window },
                    install: { [weak self] prompt in self?.installChanged(id, prompt: prompt, token: token) })
                // A link that failed before fails at once until it connects again.
                if case .failed = link.state { link.reconnectNow() }
                self.listSessions(id, then: then)
            }
        }
    }

    private func linkChanged(_ id: String, state: HostLinkState, token: UUID) {
        guard connections[id]?.token == token, let host = host(id), host.isBusy else { return }
        let next: SessionHost.State
        switch state {
        case .authenticating: next = .signingIn
        case .connected: next = .gettingSessions
        case .installing: next = .installing
        case .confirmInstall:
            if case .confirmInstall = host.state { return }
            next = .connecting
        default: next = .connecting
        }
        update(id) { $0.state = next }
    }

    private func installChanged(_ id: String, prompt: RemoteInstallPrompt?, token: UUID) {
        guard connections[id]?.token == token, let host = host(id), host.isBusy else { return }
        if let prompt {
            update(id) { $0.state = .confirmInstall(prompt) }
        } else if case .confirmInstall = host.state {
            update(id) { $0.state = .connecting }
        }
    }

    func answerInstall(_ id: String, prompt: RemoteInstallPrompt, accepted: Bool) {
        if !accepted { connections[id]?.declinedInstall = true }
        RemoteHosts.shared.answerInstall(id: prompt.id, accepted: accepted)
    }

    private func listSessions(_ id: String, then: (@MainActor () -> Void)? = nil) {
        guard let destination = host(id)?.destination, let connection = connections[id],
              let link = connection.link, !connection.listing else { return }
        let token = connection.token
        connections[id]?.listing = true
        link.listSessions { [weak self] result in
            Task { @MainActor in
                guard let self, self.connections[id]?.token == token else { return }
                self.connections[id]?.listing = false
                switch result {
                case .failure(let error):
                    self.fail(id, error, action: "Cannot list sessions on \(destination)")
                case .success(let records):
                    let shown = TerminalSessionRegistry.shared.shownPersistentSessionIDs(destination: destination)
                    let sessions = records.sorted { $0.createdAt > $1.createdAt }
                        .map { SessionBrowserRow.make($0, shown: shown, destination: destination) }
                    self.update(id) { $0.state = .loaded; $0.sessions = sessions }
                    self.select(self.selection)
                    then?()
                }
            }
        }
    }

    /// Stops the connection and collapses the section.
    func cancel(_ id: String) {
        disconnect(id)
    }

    /// Ends the connection of the window to the host. Panes that show
    /// sessions of the host keep their connection.
    func disconnect(_ id: String) {
        if let connection = connections.removeValue(forKey: id), let link = connection.link {
            RemoteHosts.shared.removeObserver(link: link, observer: connection.observer)
        }
        update(id) { $0.state = .notConnected; $0.sessions = []; $0.isExpanded = false }
        select(selection)
    }

    private func fail(_ id: String, _ error: Error, action: String) {
        let declined = connections[id]?.declinedInstall == true
        disconnect(id)
        // After Not Now, the section closes without an error.
        guard !declined else { return }
        Self.showError(error, action: action, in: window)
    }

    static func showError(_ error: Error, action: String, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = action
        if let ssh = error as? SSHError {
            alert.informativeText = ssh.stderr.isEmpty ? ssh.message : ssh.message + "\n\n" + ssh.stderr
        } else {
            alert.informativeText = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
        alert.alertStyle = .warning
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: Remove Tecolot from a host

    /// Asks the user, then ends the sessions on the host, deletes the helper
    /// and removes the section. Connects first to count the sessions.
    func removeTecolot(from id: String) {
        guard let host = host(id), host.destination != nil else { return }
        guard host.state == .loaded else {
            connect(id) { [weak self] in self?.removeTecolot(from: id) }
            return
        }
        Task { @MainActor in
            guard await DestructiveAlert.run(Self.removeAlert(for: host), in: window) == .alertFirstButtonReturn else { return }
            await remove(id)
        }
    }

    static func removeAlert(for host: SessionHost) -> NSAlert {
        let name = host.displayName
        let directory = RemoteHosts.helperDirectory
        let count = host.sessions.filter(\.canAttach).count
        let alert = NSAlert()
        alert.messageText = "Remove Tecolot from \(name)?"
        if count > 0 {
            let sessions = count == 1 ? "1 session" : "\(count) sessions"
            alert.informativeText = "\(sessions) on \(name) end. The helper in \(directory) is deleted. You cannot undo this."
        } else {
            alert.informativeText = "The helper in \(directory) is deleted. You cannot undo this."
        }
        let remove = alert.addButton(withTitle: "Remove")
        let cancel = alert.addButton(withTitle: "Cancel")
        remove.hasDestructiveAction = true
        remove.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        return alert
    }

    private func remove(_ id: String) async {
        guard let host = host(id), let link = connections[id]?.link else { return }
        do {
            for row in host.sessions where row.canAttach {
                try await Self.terminate(row.record.id, on: link)
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                link.removeHelper { continuation.resume(with: $0) }
            }
        } catch {
            Self.showError(error, action: "Cannot remove Tecolot from \(host.displayName)", in: window)
            listSessions(id)
            return
        }
        RemoteHosts.shared.forgetInstallApproval(for: link)
        disconnect(id)
        // The bridge runs the helper that is deleted.
        link.stop()
        hosts.removeAll { $0.id == id }
        connections.removeValue(forKey: id)
        saveHosts()
        select(selection)
    }

    private static func terminate(_ sessionID: String, on link: HostLink) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            link.terminateSession(id: sessionID) { continuation.resume(with: $0) }
        }
    }

    // MARK: Session actions

    /// Shows the pane of a session that this app shows, else attaches to the
    /// session in a new tab.
    func open(_ row: SessionBrowserRow) {
        Self.show(row.record, destination: row.destination)
    }

    func openInNewWindow(_ row: SessionBrowserRow) {
        guard row.canAttach else { return }
        WindowOpener.openWindow(spec: Self.attachSpec(row.record, destination: row.destination))
    }

    /// Shows the pane of a session that this app shows, else attaches to the
    /// session in a new tab of the front terminal window.
    static func show(_ record: SessionRecord, destination: String? = nil) {
        if let controller = TerminalSessionRegistry.shared.controller(showingPersistentSession: record.id,
                                                                      destination: destination) {
            controller.reveal()
            return
        }
        guard !record.exited else { return }
        WindowOpener.openTab(spec: attachSpec(record, destination: destination))
    }

    /// Ends the sessions after the user confirms.
    func terminate(_ rows: [SessionBrowserRow]) {
        let running = rows.filter(\.canAttach)
        guard !running.isEmpty else { return }
        Task { @MainActor in
            guard await SessionTermination.confirm(running.map(\.ref), in: window) else { return }
            await terminateNow(running)
        }
    }

    private func terminateNow(_ rows: [SessionBrowserRow]) async {
        var failure: Error?
        var remoteHosts = Set<String>()
        for row in rows {
            guard let destination = row.destination else {
                try? PersistentSessions.directory().terminate(row.record.id)
                continue
            }
            guard let link = connections[destination]?.link else { continue }
            remoteHosts.insert(destination)
            do { try await Self.terminate(row.record.id, on: link) } catch { failure = failure ?? error }
        }
        refresh()
        remoteHosts.forEach { listSessions($0) }
        if let failure { Self.showError(failure, action: "Cannot terminate the session", in: window) }
    }

    /// Starts each ended session again in a new tab, in its directory and
    /// under its text. The tab deletes the state when the new session starts.
    func restoreEnded(_ rows: [SessionBrowserRow]) {
        for row in rows {
            guard let state = row.endedState else { continue }
            WindowOpener.openTab(spec: RestoreStore.launchSpec(restoring: state))
        }
    }

    /// Deletes the saved state of ended sessions.
    func deleteEnded(_ rows: [SessionBrowserRow]) {
        for row in rows where row.isEnded { removeEnded(row.record.id) }
        refresh()
    }

    func copyIDs(_ rows: [SessionBrowserRow]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rows.map(\.record.id).joined(separator: "\n"), forType: .string)
    }

    static func attachSpec(_ record: SessionRecord, destination: String? = nil) -> LaunchSpec {
        var spec = LaunchSpec()
        spec.attachSessionID = record.id
        if let destination {
            spec.remoteDestination = destination
            spec.persistent = true
        }
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
        _model = State(initialValue: model ?? SessionBrowserModel.shared)
    }

    private var selectedRows: [SessionBrowserRow] { model.rows(for: model.selection) }

    var body: some View {
        table
            .frame(minWidth: 760, minHeight: 240)
            .background(WindowReader { model.window = $0 })
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Picker("Sessions", selection: Binding(get: { model.filter }, set: { model.setFilter($0) })) {
                        Text("Running").tag(SessionBrowserFilter.running)
                        Text("Ended").tag(SessionBrowserFilter.ended)
                    }
                    .pickerStyle(.segmented)
                    .help("Ended lists the sessions that the system ended at log out or restart")
                }
                if model.filter == .ended {
                    ToolbarItemGroup {
                        Button("Restore", systemImage: "arrow.counterclockwise") {
                            model.restoreEnded(selectedRows)
                        }
                        .help("Start the session again in a new tab, with its directory and text")
                        .disabled(selectedRows.isEmpty)
                        Button("Delete", systemImage: "trash") {
                            model.deleteEnded(selectedRows)
                        }
                        .help("Delete the saved state of the session")
                        .disabled(selectedRows.isEmpty)
                    }
                } else {
                ToolbarItemGroup {
                    Button("Connect to Host…", systemImage: "plus") {
                        model.connectToHost()
                    }
                    .help("Connect to a host and list its sessions")
                    Button("Show", systemImage: "macwindow") {
                        selectedRows.forEach(model.open)
                    }
                    .help("Show the session, or attach to it in a new tab")
                    .disabled(selectedRows.allSatisfy { !$0.canShow })
                    Button("Terminate", systemImage: "xmark.octagon") {
                        model.terminate(selectedRows)
                    }
                    .help("End the session and its programs")
                    .disabled(selectedRows.allSatisfy { !$0.canAttach })
                }
                }
            }
            .onAppear { model.startRefreshing() }
            .onDisappear { model.stopRefreshing() }
    }

    private var selection: Binding<Set<String>> {
        Binding(get: { model.selection }, set: { model.select($0) })
    }

    private func expanded(_ id: String) -> Binding<Bool> {
        Binding(get: { model.host(id)?.isExpanded ?? false }, set: { model.setExpanded(id, $0) })
    }

    private var table: some View {
        Table(of: SessionBrowserItem.self, selection: selection) {
            TableColumn("Program") { item in
                switch item {
                case .host(let host): hostCell(host)
                case .session(let row):
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.command)
                        if !row.title.isEmpty, row.title != row.command {
                            Text(row.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                case .status(let host): statusCell(host)
                }
            }
            .width(min: 120, ideal: 210)
            TableColumn("Directory") { item in
                switch item {
                case .host(let host): toggleArea(host)
                case .session(let row): Text(row.directory).lineLimit(1).truncationMode(.head)
                case .status(let host): statusActions(host)
                }
            }
            .width(min: 100, ideal: 160, max: 320)
            TableColumn("Profile") { item in
                if case .session(let row) = item { Text(row.profile) } else { hostFiller(item) }
            }
            .width(min: 60, ideal: 80)
            TableColumn("Size") { item in
                if case .session(let row) = item { Text(row.size).monospacedDigit() } else { hostFiller(item) }
            }
            .width(min: 50, ideal: 60)
            TableColumn("Started") { item in
                if case .session(let row) = item {
                    // The rows change only when a session changes: the time
                    // updates by itself.
                    TimelineView(.everyMinute) { _ in
                        Text(row.record.createdAt, format: .relative(presentation: .named))
                    }
                } else { hostFiller(item) }
            }
            .width(min: 80, ideal: 110)
            TableColumn("Status") { item in
                switch item {
                case .host(let host): hostMenu(host)
                case .session(let row): Text(row.status.label).lineLimit(1)
                case .status: EmptyView()
                }
            }
            .width(min: 130, ideal: 140)
        } rows: {
            ForEach(model.visibleHosts) { host in
                DisclosureTableRow(SessionBrowserItem.host(host), isExpanded: expanded(host.id)) {
                    ForEach(model.children(of: host)) { item in
                        TableRow(item)
                    }
                }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let rows = model.rows(for: ids)
            if !rows.isEmpty, rows.allSatisfy(\.isEnded) {
                Button("Restore in New Tab") { model.restoreEnded(rows) }
                Divider()
                Button("Copy Session ID") { model.copyIDs(rows) }
                Divider()
                Button("Delete") { model.deleteEnded(rows) }
            } else if !rows.isEmpty {
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
            }
        } primaryAction: { ids in
            let rows = model.rows(for: ids)
            if rows.allSatisfy(\.isEnded) { model.restoreEnded(rows) } else { rows.forEach(model.open) }
        }
    }

    // MARK: Host rows

    private func toggle(_ host: SessionHost) {
        model.setExpanded(host.id, !host.isExpanded)
    }

    /// A click anywhere on a host row opens or closes it.
    private func toggleArea(_ host: SessionHost) -> some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { toggle(host) }
    }

    @ViewBuilder
    private func hostFiller(_ item: SessionBrowserItem) -> some View {
        if case .host(let host) = item { toggleArea(host) }
    }

    private func hostCell(_ host: SessionHost) -> some View {
        HStack(spacing: 6) {
            Text(host.displayName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Text(host.meta)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle(host) }
    }

    @ViewBuilder
    private func hostMenu(_ host: SessionHost) -> some View {
        HStack {
            toggleArea(host)
            if host.destination != nil {
                Menu {
                    Button("Disconnect") { model.disconnect(host.id) }
                        .disabled(host.state == .notConnected)
                    Divider()
                    Button("Remove Tecolot from Host…") { model.removeTecolot(from: host.id) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Actions for \(host.displayName)")
            }
        }
    }

    // MARK: Status rows

    private func statusText(_ host: SessionHost) -> String {
        switch host.state {
        case .loaded:
            return model.filter == .ended ? "No ended sessions." : "No persistent sessions are running."
        case .connecting: return "Connecting to \(host.displayName)…"
        case .signingIn: return "Signing in…"
        case .gettingSessions: return "Getting sessions…"
        case .installing: return "Installing the Tecolot helper…"
        case .confirmInstall(let prompt): return prompt.title
        case .notConnected: return ""
        }
    }

    private func statusCell(_ host: SessionHost) -> some View {
        HStack(spacing: 6) {
            if host.isBusy, !isConfirmingInstall(host) {
                ProgressView().controlSize(.small)
            }
            Text(statusText(host))
                .foregroundStyle(host.isBusy && !isConfirmingInstall(host) ? .primary : .secondary)
                .lineLimit(1)
                .help(helpText(host))
        }
    }

    private func isConfirmingInstall(_ host: SessionHost) -> Bool {
        if case .confirmInstall = host.state { return true }
        return false
    }

    private func helpText(_ host: SessionHost) -> String {
        if case .confirmInstall(let prompt) = host.state { return prompt.text }
        return statusText(host)
    }

    @ViewBuilder
    private func statusActions(_ host: SessionHost) -> some View {
        if case .confirmInstall(let prompt) = host.state {
            HStack(spacing: 6) {
                Button("Not Now") { model.answerInstall(host.id, prompt: prompt, accepted: false) }
                Button("Install") { model.answerInstall(host.id, prompt: prompt, accepted: true) }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        } else if host.isBusy {
            Button("Cancel") { model.cancel(host.id) }
                .controlSize(.small)
        }
    }
}

/// Gives the window of a SwiftUI view.
private struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { ReaderView(found: found) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        let found: (NSWindow?) -> Void
        init(found: @escaping (NSWindow?) -> Void) {
            self.found = found
            super.init(frame: .zero)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            found(window)
        }
    }
}
