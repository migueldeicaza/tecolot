import AppKit
import Testing
import TecolotSessionDirectory
import TecolotWire
@testable import Tecolot

@MainActor
struct GroupSessionEnderTests {
    private func pane(
        _ kind: RestorePaneKind,
        local: TerminalClosePolicy.PaneState? = nil,
        info: SessionInfoMessage? = nil,
        session: SessionRef? = nil
    ) -> GroupSessionEnder.Pane {
        GroupSessionEnder.Pane(
            id: UUID(),
            label: "Build › Pane",
            kind: kind,
            session: session,
            local: local,
            info: info,
            program: "make"
        )
    }

    private struct ForegroundProbe: TerminalProcessInspecting {
        func foregroundProcessGroup(for fileDescriptor: Int32) -> pid_t? {
            fileDescriptor == 9 ? 42 : nil
        }
        func executablePath(for processID: pid_t) -> String? {
            "/usr/bin/make"
        }
    }

    @Test func busyLocalProgramDoesNotDependOnIconPolling() {
        #expect(GroupSessionEnder.localProgram(descriptor: 9, fallback: nil, inspector: ForegroundProbe()) == "/usr/bin/make")
        #expect(GroupSessionEnder.localProgram(descriptor: nil, fallback: "cached", inspector: ForegroundProbe()) == "cached")
    }

    @Test func localBusyProbeIgnoresClosePreferencesAndPersistentState() {
        let busy = pane(.local, local: .init(persistent: false, running: true, childProcesses: 1))
        #expect(GroupSessionEnder.probe(busy, record: nil).busyProgram == "make")
        #expect(GroupSessionEnder.probe(pane(.local, local: .init(persistent: false, running: true, childProcesses: 0)), record: nil).busyProgram == nil)
        #expect(GroupSessionEnder.probe(pane(.local), record: nil).busyProgram == nil)
    }

    @Test(arguments: [RestorePaneKind.persistent, .remote])
    func helperBusyProbeUsesForegroundAndChildren(kind: RestorePaneKind) {
        let foreground = WireProcess(pid: 2, name: "make", path: "/usr/bin/make")
        let busy = SessionInfoMessage(shellPID: 1, shellName: "zsh", foreground: foreground, hasChildren: false)
        #expect(GroupSessionEnder.probe(pane(kind, info: busy), record: nil).busyProgram == "make")
        let idle = SessionInfoMessage(shellPID: 1, shellName: "zsh", foreground: WireProcess(pid: 1, name: "zsh", path: "/bin/zsh"), hasChildren: false)
        #expect(GroupSessionEnder.probe(pane(kind, info: idle), record: nil).busyProgram == nil)
        var children = idle
        children.hasChildren = true
        #expect(GroupSessionEnder.probe(pane(kind, info: children), record: nil).busyProgram != nil)
    }

    @Test(arguments: [RestorePaneKind.persistent, .remote])
    func detachedHelperProbeUsesSessionBrowserMetadata(kind: RestorePaneKind) {
        var record = SessionRecord(id: "s", pid: 1, shellPID: 2, protocolVersion: 1, build: "test", createdAt: Date(), executable: "/bin/zsh", workingDirectory: nil, labels: [:], columns: 80, rows: 24)
        record.foreground = "-zsh"
        #expect(GroupSessionEnder.probe(pane(kind), record: record).busyProgram == nil)
        record.foreground = "make"
        #expect(GroupSessionEnder.probe(pane(kind), record: record).busyProgram == "make")
        record.exited = true
        #expect(GroupSessionEnder.probe(pane(kind), record: record).busyProgram == nil)
    }

    @Test func confirmationListsBusyPanesAndReservesEscapeForCancel() async {
        let busy = pane(.local, local: .init(persistent: false, running: true, childProcesses: 1))
        let plan = await GroupSessionEnder.plan([busy]) { _ in
            (nil, nil)
        }
        let alert = GroupSessionEnder.makeAlert(plan)
        #expect(plan.needsConfirmation)
        #expect(alert.informativeText.contains("1 busy pane:\nBuild › Pane — make"))
        #expect(alert.buttons[0].title == "End Sessions" && alert.buttons[0].hasDestructiveAction)
        #expect(alert.buttons[0].keyEquivalent.isEmpty)
        #expect(alert.buttons[1].keyEquivalent == "\u{1b}")
    }

    @Test(arguments: AskBeforeClosing.allCases, [false, true])
    func idleLocalConfirmationMatchesPlainClose(preference: AskBeforeClosing, running: Bool) async throws {
        let state = TerminalClosePolicy.PaneState(
            persistent: false, running: running, childProcesses: 0, askBeforeClosing: preference
        )
        let plan = await GroupSessionEnder.plan([pane(.local, local: state)]) { _ in (nil, nil) }
        let expected = TerminalClosePolicy.requiresConfirmation(state: state)
        #expect(plan.needsConfirmation == expected)
        var asked = false
        var closed = false
        try await GroupSessionEnder.perform(plan, confirm: { _ in
            asked = true
            return .cancel
        }, end: { _ in }, close: { closed = true })
        #expect(asked == expected)
        #expect(closed == !expected)
    }

    @Test func idleLocalGroupSkipsConfirmationButHelperGroupsConfirm() async throws {
        for kind in [RestorePaneKind.local, .persistent, .remote] {
            let plan = await GroupSessionEnder.plan([pane(kind)]) { _ in
                (nil, nil)
            }
            var asked = false
            var closed = false
            try await GroupSessionEnder.perform(plan, confirm: { _ in asked = true
                return .endSessions
            }, end: { _ in }, close: {
                closed = true
            })
            #expect(asked == (kind != .local))
            #expect(closed)
        }
    }

    @Test func cancelEndAndUnavailableDecisionsAreDistinct() async throws {
        let available = SessionRef(id: "local", destination: nil)
        let missing = SessionRef(id: "remote", destination: "offline")
        let panes = [pane(.persistent, session: available), pane(.remote, session: missing)]
        let plan = await GroupSessionEnder.plan(panes) { ref in
            (nil, ref == missing ? "offline is not connected" : nil)
        }
        #expect(plan.sessions == [available])
        #expect(plan.unavailable.count == 1)
        let alert = GroupSessionEnder.makeAlert(plan)
        #expect(!alert.buttons[0].isEnabled)
        #expect(alert.buttons.count == 3)
        #expect(alert.informativeText.contains("offline is not connected"))
        for decision in [GroupSessionEnder.Decision.cancel, .endSessions, .closeLeavingUnavailable] {
            var ended: [SessionRef] = []
            var closed = false
            try await GroupSessionEnder.perform(plan, confirm: { _ in
                decision
            }, end: {
                ended.append($0)
            }, close: {
                closed = true
            })
            #expect(closed == (decision == .closeLeavingUnavailable))
            #expect(ended == (closed ? [available] : []))
        }
        let connected = await GroupSessionEnder.plan([pane(.persistent, session: available)]) { _ in
            (nil, nil)
        }
        var ended: [SessionRef] = []
        var closed = false
        try await GroupSessionEnder.perform(connected, confirm: { _ in
            .endSessions
        }, end: {
            ended.append($0)
        }, close: {
            closed = true
        })
        #expect(closed && ended == [available])
    }

    @Test func dormantProbeAndCloseNeverStartShellsOrAttachHosts() async throws {
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        let saved = RestoreTab(root: .split(
            .horizontal,
            fraction: 0.5,
            first: .pane(RestorePane(id: UUID(), kind: .persistent, sessionID: "local")),
            second: .pane(RestorePane(id: UUID(), kind: .remote, sessionID: "remote", remoteDestination: "offline"))
        ))
        let tab = TerminalTab(dormant: RestoreStore.launchSpec(for: RestoredTab(tab: saved, panes: [:])), startsProcesses: false)
        let group = manager.newGroup(tab: tab)
        let panes = GroupSessionEnder.panes(in: group)
        #expect(tab.isDormant && panes.count == 2)
        var probes = 0
        let plan = await GroupSessionEnder.plan(panes) { ref in probes += 1
            return (nil, ref.destination == nil ? nil : "offline")
        }
        var ended: [SessionRef] = []
        try await GroupSessionEnder.perform(plan, confirm: { _ in
            .closeLeavingUnavailable
        }, end: {
            ended.append($0)
        }, close: {
            manager.closeGroup(group)
        })
        #expect(probes == 2 && ended == [SessionRef(id: "local", destination: nil)])
        #expect(tab.isDormant && manager.groups.isEmpty)
    }
}
