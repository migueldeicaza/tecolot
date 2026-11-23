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

    @Test func shellIsIdleOnlyWhenItIsAloneInTheGroup() {
        let zsh = process(100, "/bin/zsh")
        #expect(TerminalPaneWorkspace.isIdleShell(snapshot([zsh]), shellPid: 100))
        // A prompt runs $(__git_ps1): git is in the shell's group.
        #expect(!TerminalPaneWorkspace.isIdleShell(snapshot([zsh, process(101, "/usr/bin/git")]), shellPid: 100))
        #expect(!TerminalPaneWorkspace.isIdleShell(snapshot([process(200, "/usr/bin/vim")], group: 200), shellPid: 100))
        #expect(!TerminalPaneWorkspace.isIdleShell(nil, shellPid: 100))
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
            $0.processID == getpid() && $0.startSeconds > 0 && $0.executablePath != nil
        })
        #expect(SystemTerminalProcessInspector().foregroundProcesses(in: -1).isEmpty)
    }
}
