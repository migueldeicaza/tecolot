import AppKit
import SwiftTerm
import TecolotSessionClient
import TecolotSessionDirectory
import TecolotWire

/// Probes a group without materializing dormant workspaces or opening host connections.
@MainActor
enum GroupSessionEnder {
    struct Pane {
        let id: UUID
        let label: String
        let kind: RestorePaneKind
        let session: SessionRef?
        let local: TerminalClosePolicy.PaneState?
        let info: SessionInfoMessage?
        let program: String?
        var unavailableReason: String? = nil
        var tabID: UUID? = nil
    }

    struct Probe {
        var busyProgram: String?
        var unavailable: String?
    }

    struct Plan {
        let panes: [Pane]
        let busy: [String]
        let sessions: [SessionRef]
        let unavailable: [String]
        var needsConfirmation: Bool {
            !busy.isEmpty || panes.contains {
                $0.kind != .local || $0.local.map(TerminalClosePolicy.requiresConfirmation(state:)) == true
            }
        }
    }

    enum Decision {
        case cancel
        case endSessions
        case closeLeavingUnavailable
    }

    enum Failure: LocalizedError {
        case groupChanged
        case hostUnavailable(String)
        var errorDescription: String? {
            switch self {
            case .groupChanged:
                return "The group's panes changed. Run the command again to check them."
            case .hostUnavailable(let host):
                return "The host \(host) is not connected."
            }
        }
    }

    private static var pending = Set<UUID>()

    static func panes(in group: TerminalTabGroup) -> [Pane] {
        group.tabs.flatMap { tab in
            if let workspace = tab.loadedWorkspace {
                return workspace.controllers.map { controller in
                    let saved = controller.restorePane()
                    let kind: RestorePaneKind = controller.remoteDestination != nil ? .remote : (controller.isPersistent ? .persistent : .local)
                    let sessionID = controller.persistentSessionID ?? saved?.sessionID
                    let local = kind == .local ? TerminalClosePolicy.state(for: controller) : nil
                    let program = local?.hasRunningTask == true
                        ? localProgram(descriptor: controller.terminal?.process?.childfd, fallback: controller.panePresentation.executablePath)
                        : controller.panePresentation.executablePath
                    return Pane(
                        id: controller.id,
                        label: "\(tab.title) › \(controller.panePresentation.title)",
                        kind: kind,
                        session: sessionID.map {
                            SessionRef(id: $0, destination: controller.remoteDestination)
                        },
                        local: local,
                        info: controller.persistentView?.session.state.info,
                        program: program,
                        unavailableReason: kind == .remote && sessionID == nil ? "the session on \(controller.remoteDestination ?? "the host") is still starting; its session ID is not available yet" : nil,
                        tabID: tab.id
                    )
                }
            }
            return (tab.savedSpec?.restoredTab?.tab.root.panes ?? []).map { pane in
                Pane(
                    id: pane.id,
                    label: "\(tab.title) › \(pane.title ?? "Terminal")",
                    kind: pane.kind,
                    session: pane.sessionID.map {
                        SessionRef(id: $0, destination: pane.remoteDestination)
                    },
                    local: nil,
                    info: nil,
                    program: nil,
                    tabID: tab.id
                )
            }
        }
    }

    /// Checks the live foreground job even when tab icons and their polling are disabled.
    static func localProgram(descriptor: Int32?, fallback: String?, inspector: any TerminalProcessInspecting = SystemTerminalProcessInspector()) -> String? {
        guard let descriptor, let group = inspector.foregroundProcessGroup(for: descriptor) else {
            return fallback
        }
        let processes = inspector.foregroundProcesses(in: group)
        return (processes.first {
            $0.processID == group
        } ?? processes.first)?.executablePath ?? fallback
    }

    /// Uses the helper's foreground report, also used by the Sessions window.
    static func probe(_ pane: Pane, record: SessionRecord?, unavailable: String? = nil) -> Probe {
        if pane.kind == .local {
            return Probe(busyProgram: pane.local?.hasRunningTask == true ? (pane.program ?? "running process") : nil)
        }
        if let unavailable {
            return Probe(unavailable: unavailable)
        }
        if let info = pane.info {
            let busy = info.hasChildren || (info.foreground.map {
                $0.pid != info.shellPID
            } ?? false)
            return Probe(busyProgram: busy ? (info.foreground?.name ?? "running process") : nil)
        }
        guard let record, !record.exited, let foreground = record.foreground, !foreground.isEmpty else {
            return Probe()
        }
        let program = (foreground as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let shell = (record.executable as NSString).lastPathComponent
        return Probe(busyProgram: program == shell ? nil : foreground)
    }

    static func plan(_ panes: [Pane], fetch: (SessionRef) async -> (SessionRecord?, String?)) async -> Plan {
        var busy: [String] = []
        var sessions: [SessionRef] = []
        var unavailable: [String] = []
        var results: [SessionRef: (SessionRecord?, String?)] = [:]
        for pane in panes {
            var record: SessionRecord?
            var error = pane.unavailableReason
            if let session = pane.session {
                if let cached = results[session] {
                    (record, error) = cached
                } else {
                    (record, error) = await fetch(session)
                    results[session] = (record, error)
                }
                if error == nil, !sessions.contains(session) {
                    sessions.append(session)
                }
            }
            let result = probe(pane, record: record, unavailable: error)
            if let program = result.busyProgram {
                busy.append("\(pane.label) — \(program)")
            }
            if let error = result.unavailable {
                unavailable.append("\(pane.label) — \(error)")
            }
        }
        return Plan(panes: panes, busy: busy, sessions: sessions, unavailable: unavailable)
    }

    static func makeAlert(_ plan: Plan) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close Group and End Sessions?"
        var text = "The group's shells and programs will end. Ending persistent and remote sessions cannot be undone."
        if !plan.busy.isEmpty {
            text += "\n\n\(plan.busy.count) busy \(plan.busy.count == 1 ? "pane" : "panes"):\n" + plan.busy.joined(separator: "\n")
        }
        if !plan.unavailable.isEmpty {
            text += "\n\nThese sessions cannot be checked or ended without connecting to their hosts:\n" + plan.unavailable.joined(separator: "\n")
            text += "\n\nYou can end the available sessions and close the group, leaving these sessions running."
        }
        alert.informativeText = text
        let end = alert.addButton(withTitle: "End Sessions")
        end.hasDestructiveAction = true
        end.keyEquivalent = ""
        end.isEnabled = plan.unavailable.isEmpty
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        if !plan.unavailable.isEmpty {
            let close = alert.addButton(withTitle: "Close Group Without Ending Unavailable Sessions")
            close.hasDestructiveAction = true
            close.keyEquivalent = ""
        }
        return alert
    }

    /// Keeps cancellation and partial availability decisions separate from termination.
    @discardableResult
    static func perform(
        _ plan: Plan,
        confirm: (Plan) async -> Decision,
        end: (SessionRef) async throws -> Void,
        validate: (Set<SessionRef>) throws -> Void = { _ in },
        close: () -> Void
    ) async throws -> Bool {
        let decision = plan.needsConfirmation ? await confirm(plan) : .endSessions
        guard decision != .cancel else {
            return false
        }
        guard plan.unavailable.isEmpty || decision == .closeLeavingUnavailable else {
            return false
        }
        var ending = Set<SessionRef>()
        for session in plan.sessions {
            try validate(ending)
            ending.insert(session)
            try await end(session)
        }
        try validate(ending)
        close()
        return true
    }

    /// Only panes belonging to sessions this operation ended may disappear.
    /// Additions, reorderings and replacement session identities remain stale.
    static func matches(_ initial: [Pane], current: [Pane], ending: Set<SessionRef>) -> Bool {
        let currentIDs = Set(current.map(\.id))
        let expected = initial.filter { pane in
            currentIDs.contains(pane.id) || !(pane.session.map(ending.contains) ?? false)
        }
        return expected.count == current.count && zip(expected, current).allSatisfy {
            $0.id == $1.id && $0.kind == $1.kind && $0.session == $1.session && $0.tabID == $1.tabID
        }
    }

    static func request(_ group: TerminalTabGroup, manager: TerminalWindowManager, in window: NSWindow?) {
        guard pending.insert(group.id).inserted else {
            return
        }
        Task { @MainActor in
            defer { pending.remove(group.id) }
            // Local metadata is read once. Remote queries use existing connections only.
            let local: Result<[SessionRecord], Error>
            do {
                let directory = try PersistentSessions.directory()
                local = await Task.detached {
                    Result<[SessionRecord], Error> {
                        directory.list()
                    }
                }.value
            } catch {
                local = .failure(error)
            }
            var remote: [String: [SessionRecord]] = [:]
            var failures: [String: String] = [:]
            let initial = panes(in: group)
            let plan = await plan(initial) { session in
                guard let destination = session.destination else {
                    switch local {
                    case .success(let records):
                        return (records.first {
                            $0.id == session.id
                        }, nil)
                    case .failure(let error):
                        return (nil, "This Mac: \(error.localizedDescription)")
                    }
                }
                if let records = remote[destination] {
                    return (records.first {
                        $0.id == session.id
                    }, nil)
                }
                if let error = failures[destination] {
                    return (nil, error)
                }
                guard let link = RemoteHosts.shared.connectedLink(destination: destination) else {
                    let error = "\(destination) is not connected"
                    failures[destination] = error
                    return (nil, error)
                }
                do {
                    let records = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[SessionRecord], Error>) in
                        link.listSessions {
                            continuation.resume(with: $0)
                        }
                    }
                    remote[destination] = records
                    return (records.first {
                        $0.id == session.id
                    }, nil)
                } catch {
                    failures[destination] = "\(destination): \(error.localizedDescription)"
                    return (nil, failures[destination])
                }
            }
            do {
                try await perform(plan, confirm: { plan in
                    switch await DestructiveAlert.run(makeAlert(plan), in: window, confirmsWithReturn: true) {
                    case .alertFirstButtonReturn:
                        return .endSessions
                    case .alertThirdButtonReturn:
                        return .closeLeavingUnavailable
                    default:
                        return .cancel
                    }
                }, end: { session in
                    try await SessionTermination.end(session)
                }, validate: { ending in
                    let current = panes(in: group)
                    guard
                        matches(initial, current: current, ending: ending),
                        manager.groups.contains(where: {
                            $0 === group
                        }) || current.isEmpty && !ending.isEmpty else {
                        throw Failure.groupChanged
                    }
                }, close: {
                    if
                        manager.groups.contains(where: {
                            $0 === group
                        }) {
                        manager.closeGroup(group)
                    }
                })
            } catch {
                let alert = NSAlert(error: error)
                _ = await DestructiveAlert.run(alert, in: window)
            }
        }
    }
}
