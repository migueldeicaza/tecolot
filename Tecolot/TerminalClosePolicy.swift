import AppKit
import Darwin
import SwiftTerm

@MainActor
enum TerminalClosePolicy {
    static func quitMessage(runningPaneCount: Int) -> String {
        runningPaneCount == 1
            ? "1 local pane has running processes."
            : "\(runningPaneCount) local panes have running processes."
    }

    static func requiresConfirmation(for controller: TerminalSessionController) -> Bool {
        guard let process = controller.terminal?.process, process.running else {
            return false
        }

        switch controller.profile.askBeforeClosing {
        case .never:
            return false
        case .always:
            return true
        case .onlyIfProcessesRunning:
            return childProcessCount(parentPID: process.shellPid) > 0
        }
    }

    struct PaneState {
        var persistent: Bool
        var running: Bool
        var childProcesses: Int
        var hasRunningTask: Bool {
            !persistent && running && childProcesses > 0
        }
    }

    static func state(for controller: TerminalSessionController) -> PaneState {
        let process = controller.terminal?.process
        return PaneState(
            persistent: controller.isPersistent,
            running: process?.running == true,
            childProcesses: childProcessCount(parentPID: process?.shellPid ?? 0)
        )
    }

    static func runningTaskCount(in controllers: [TerminalSessionController]) -> Int {
        runningTaskCount(states: controllers.map(state(for:)))
    }

    static func runningTaskCount(states: [PaneState]) -> Int {
        states.filter(\.hasRunningTask).count
    }

    nonisolated private static func childProcessCount(parentPID: pid_t) -> Int {
        guard parentPID > 0 else {
            return 0
        }
        var childPIDs = [pid_t](repeating: 0, count: 256)
        let count = childPIDs.withUnsafeMutableBufferPointer { buffer in
            proc_listchildpids(
                parentPID,
                buffer.baseAddress,
                Int32(buffer.count * MemoryLayout<pid_t>.stride)
            )
        }
        return max(0, Int(count))
    }
}

