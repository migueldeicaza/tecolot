import AppKit
import Darwin
import SwiftTerm

@MainActor
enum TerminalClosePolicy {
    static func quitMessage(runningPaneCount: Int) -> String {
        runningPaneCount == 1
            ? "1 local pane asks for confirmation before closing."
            : "\(runningPaneCount) local panes ask for confirmation before closing."
    }

    static func requiresConfirmation(for controller: TerminalSessionController) -> Bool {
        requiresConfirmation(state: state(for: controller))
    }

    static func requiresConfirmation(state: PaneState) -> Bool {
        guard !state.persistent, state.running else {
            return false
        }
        switch state.askBeforeClosing {
        case .never:
            return false
        case .always:
            return true
        case .onlyIfProcessesRunning:
            return state.childProcesses > 0
        }
    }

    static func confirmationCount(in controllers: [TerminalSessionController]) -> Int {
        controllers.filter {
            requiresConfirmation(for: $0)
        }.count
    }

    struct PaneState {
        var persistent: Bool
        var running: Bool
        var childProcesses: Int
        var askBeforeClosing: AskBeforeClosing = .onlyIfProcessesRunning
        var hasRunningTask: Bool {
            !persistent && running && childProcesses > 0
        }
    }

    static func state(for controller: TerminalSessionController) -> PaneState {
        let process = controller.terminal?.process
        return PaneState(
            persistent: controller.isPersistent,
            running: process?.running == true,
            childProcesses: childProcessCount(parentPID: process?.shellPid ?? 0),
            askBeforeClosing: controller.profile.askBeforeClosing
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

