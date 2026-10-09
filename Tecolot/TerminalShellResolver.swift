import Darwin
import Foundation

enum TerminalShellDialect: CaseIterable, Sendable {
    case bash, zsh, fish, nushell, elvish, unknown
}

/// Only inspect the foreground group leader. An ancestor cannot tell us the
/// parser behind SSH, a multiplexer, or a foreground application.
protocol TerminalProcessInspecting {
    func foregroundProcessGroup(for fileDescriptor: Int32) -> pid_t?
    func executablePath(for processID: pid_t) -> String?
}

struct SystemTerminalProcessInspector: TerminalProcessInspecting {
    nonisolated init() {}

    nonisolated func foregroundProcessGroup(for fileDescriptor: Int32) -> pid_t? {
        guard fileDescriptor >= 0 else { return nil }
        let processGroup = tcgetpgrp(fileDescriptor)
        return processGroup > 0 ? processGroup : nil
    }

    nonisolated func executablePath(for processID: pid_t) -> String? {
        guard processID > 0 else { return nil }
        // PROC_PIDPATHINFO_MAXSIZE is defined as 4 * MAXPATHLEN in proc_info.h;
        // Swift's C importer does not expose that macro.
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = buffer.withUnsafeMutableBytes {
            proc_pidpath(processID, $0.baseAddress, UInt32($0.count))
        }
        guard count > 0 else { return nil }
        return String(bytes: buffer.prefix(Int(count)).prefix { $0 != 0 }, encoding: .utf8)
    }
}

struct TerminalShellResolver {
    var processInspector: any TerminalProcessInspecting = SystemTerminalProcessInspector()

    /// Resolve on every insertion, including after a nested shell or exec.
    /// This is best effort: the foreground process can change after inspection.
    func dialect(for fileDescriptor: Int32?) -> TerminalShellDialect {
        guard let fileDescriptor,
              let processGroup = processInspector.foregroundProcessGroup(for: fileDescriptor),
              processGroup > 0,
              let path = processInspector.executablePath(for: processGroup) else { return .unknown }
        switch path.split(separator: "/").last {
        case "bash": return .bash
        case "zsh": return .zsh
        case "fish": return .fish
        case "nu": return .nushell
        case "elvish": return .elvish
        default: return .unknown
        }
    }
}
