import Darwin
import Testing
@testable import Tecolot

struct TerminalForegroundJobIconResolverTests {
    private func process(_ pid: Int32, _ path: String?, start: UInt64 = 1) -> TerminalForegroundProcess {
        .init(processID: pid, startSeconds: start, startMicroseconds: 0, executablePath: path)
    }

    private func snapshot(_ processes: [TerminalForegroundProcess], group: Int32 = 100) -> TerminalForegroundJobSnapshot {
        .init(processGroup: group, processes: processes)
    }

    @Test func pagerRetainsCommandWhenLeaderExits() {
        var resolver = TerminalForegroundJobIconResolver()
        let git = process(100, "/usr/bin/git")
        let less = process(101, "/usr/bin/less")
        #expect(resolver.executablePath(for: snapshot([git, less]), descriptor: 4) == git.executablePath)
        #expect(resolver.executablePath(for: snapshot([less]), descriptor: 4) == git.executablePath)
        #expect(resolver.executablePath(for: snapshot([less]), descriptor: 4) == git.executablePath)
    }

    @Test func missingLeaderStillShowsPager() {
        var resolver = TerminalForegroundJobIconResolver()
        #expect(resolver.executablePath(for: snapshot([process(101, "/usr/bin/less")]), descriptor: 4) == "/usr/bin/less")
    }

    @Test func recognizedMemberIsSelectedWhenLeaderIsMissingOrAPager() {
        var resolver = TerminalForegroundJobIconResolver()
        #expect(resolver.executablePath(for: snapshot([process(100, "/usr/bin/less"), process(101, "/usr/bin/git")]), descriptor: 4) == "/usr/bin/git")
        #expect(resolver.executablePath(for: snapshot([process(101, "/usr/bin/git")]), descriptor: 4) == "/usr/bin/git")
    }

    @Test func antigravityIsSelectedFromForegroundGroup() {
        var resolver = TerminalForegroundJobIconResolver()
        let agy = process(101, "/Users/example/.local/bin/agy")
        #expect(resolver.executablePath(for: snapshot([process(100, "/usr/bin/less"), agy]), descriptor: 4) == agy.executablePath)
    }

    @Test func newGroupOrDescriptorClearsRememberedCommand() {
        for changesDescriptor in [false, true] {
            var resolver = TerminalForegroundJobIconResolver()
            let less = process(101, "/usr/bin/less")
            _ = resolver.executablePath(for: snapshot([process(100, "/usr/bin/git"), less]), descriptor: 4)
            let next = snapshot([less], group: changesDescriptor ? 100 : 200)
            #expect(resolver.executablePath(for: next, descriptor: changesDescriptor ? 5 : 4) == less.executablePath)
        }
    }

    @Test func reusedPIDOrDisjointMembersClearRememberedCommand() {
        for pager in [process(101, "/usr/bin/less", start: 2), process(102, "/usr/bin/less")] {
            var resolver = TerminalForegroundJobIconResolver()
            _ = resolver.executablePath(for: snapshot([process(100, "/usr/bin/git"), process(101, "/usr/bin/less")]), descriptor: 4)
            #expect(resolver.executablePath(for: snapshot([pager]), descriptor: 4) == pager.executablePath)
        }
    }

    @Test func shellUnknownMemberAndInspectionFailureClearRememberedCommand() {
        for next in [
            snapshot([process(101, "/bin/zsh")]),
            snapshot([process(101, "/usr/bin/less"), process(102, nil)]),
            snapshot([])
        ] {
            var resolver = TerminalForegroundJobIconResolver()
            _ = resolver.executablePath(for: snapshot([process(100, "/usr/bin/git"), process(101, "/usr/bin/less")]), descriptor: 4)
            _ = resolver.executablePath(for: next, descriptor: 4)
            #expect(resolver.executablePath(for: snapshot([process(101, "/usr/bin/less")]), descriptor: 4) == "/usr/bin/less")
        }
        var resolver = TerminalForegroundJobIconResolver()
        _ = resolver.executablePath(for: snapshot([process(100, "/usr/bin/git"), process(101, "/usr/bin/less")]), descriptor: 4)
        #expect(resolver.executablePath(for: nil, descriptor: 4) == nil)
        #expect(resolver.executablePath(for: snapshot([process(101, "/usr/bin/less")]), descriptor: 4) == "/usr/bin/less")
    }

    @Test func inspectorFindsCurrentProcessInItsGroup() {
        let processes = SystemTerminalProcessInspector().foregroundProcesses(in: getpgrp())
        #expect(processes.contains {
            $0.processID == getpid() && $0.startSeconds > 0 && $0.executablePath != nil && $0.didExec == true
        })
        #expect(SystemTerminalProcessInspector().foregroundProcesses(in: -1).isEmpty)
    }

    @Test func missingExecutablePathPollsAtActiveRateInsteadOfSpinning() {
        #expect(
            TerminalPaneWorkspace.localProcessSchedule(
                wantsProgramInfo: true,
                panes: [(schedule: .idle, hasExecutablePath: false)]
            ) == .active
        )
        #expect(
            TerminalPaneWorkspace.localProcessSchedule(
                wantsProgramInfo: true,
                panes: [(schedule: .immediate, hasExecutablePath: false)]
            ) == .immediate
        )
        #expect(
            TerminalPaneWorkspace.localProcessSchedule(
                wantsProgramInfo: false,
                panes: [(schedule: .immediate, hasExecutablePath: false)]
            ) == .idle
        )
    }

    @Test func localProcessSchedulePrioritizesImmediateOverActiveOverFallback() {
        #expect(
            TerminalPaneWorkspace.localProcessSchedule(
                wantsProgramInfo: true,
                panes: [(schedule: .fallback, hasExecutablePath: true)]
            ) == .fallback
        )
        #expect(
            TerminalPaneWorkspace.localProcessSchedule(
                wantsProgramInfo: true,
                panes: [
                    (schedule: .fallback, hasExecutablePath: true),
                    (schedule: .active, hasExecutablePath: true)
                ]
            ) == .active
        )
        #expect(
            TerminalPaneWorkspace.localProcessSchedule(
                wantsProgramInfo: true,
                panes: [(schedule: .fallback, hasExecutablePath: false)]
            ) == .active
        )
        #expect(
            TerminalPaneWorkspace.localProcessSchedule(
                wantsProgramInfo: true,
                panes: [
                    (schedule: .fallback, hasExecutablePath: true),
                    (schedule: .immediate, hasExecutablePath: true)
                ]
            ) == .immediate
        )
    }

    @Test func wakeDeadlineMatchesSchedule() {
        let now = ContinuousClock.now
        #expect(TerminalPaneWorkspace.wakeDeadline(for: .idle, now: now) == nil)
        #expect(TerminalPaneWorkspace.wakeDeadline(for: .immediate, now: now) == now)
        #expect(TerminalPaneWorkspace.wakeDeadline(for: .active, now: now) == now + .seconds(1))
        #expect(TerminalPaneWorkspace.wakeDeadline(for: .fallback, now: now) == now + .seconds(5))
    }

    @Test func earlierDeadlineWinsForTaskRestart() {
        let now = ContinuousClock.now
        // No task: probeActiveImmediately starts right away for active or fallback.
        #expect(
            TerminalPaneWorkspace.nextTaskStartWake(
                schedule: .active, hasTask: false, currentWake: nil,
                probeActiveImmediately: true, now: now
            ) == now
        )
        #expect(
            TerminalPaneWorkspace.nextTaskStartWake(
                schedule: .fallback, hasTask: false, currentWake: nil,
                probeActiveImmediately: true, now: now
            ) == now
        )
        #expect(
            TerminalPaneWorkspace.nextTaskStartWake(
                schedule: .fallback, hasTask: false, currentWake: nil,
                probeActiveImmediately: false, now: now
            ) == now + .seconds(5)
        )
        // During a 5 s fallback wait: resize (probeActiveImmediately) does not restart.
        #expect(
            TerminalPaneWorkspace.nextTaskStartWake(
                schedule: .fallback, hasTask: true, currentWake: now + .seconds(4),
                probeActiveImmediately: true, now: now
            ) == nil
        )
        // During a 5 s fallback wait: new activity pulls wake forward to 1 s.
        #expect(
            TerminalPaneWorkspace.nextTaskStartWake(
                schedule: .active, hasTask: true, currentWake: now + .seconds(4),
                probeActiveImmediately: false, now: now
            ) == now + .seconds(1)
        )
        // During a 1 s active wait: continuous output does not push wake later.
        #expect(
            TerminalPaneWorkspace.nextTaskStartWake(
                schedule: .active, hasTask: true, currentWake: now + .milliseconds(400),
                probeActiveImmediately: false, now: now
            ) == nil
        )
        // During a 1 s active wait: immediate request pulls wake to now.
        #expect(
            TerminalPaneWorkspace.nextTaskStartWake(
                schedule: .immediate, hasTask: true, currentWake: now + .milliseconds(400),
                probeActiveImmediately: false, now: now
            ) == now
        )
        // While a probe runs (currentWake == nil): do not restart.
        #expect(
            TerminalPaneWorkspace.nextTaskStartWake(
                schedule: .immediate, hasTask: true, currentWake: nil,
                probeActiveImmediately: true, now: now
            ) == nil
        )
    }
}
