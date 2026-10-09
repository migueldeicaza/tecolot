import Darwin
import Foundation

enum TerminalShellDialect: CaseIterable, Sendable {
    case bash, zsh, fish, nushell, elvish, unknown
}

/// Shell detection uses the leader. Icon selection can inspect all group members.
protocol TerminalProcessInspecting {
    func foregroundProcessGroup(for fileDescriptor: Int32) -> pid_t?
    func executablePath(for processID: pid_t) -> String?
    func foregroundProcesses(in processGroup: pid_t) -> [TerminalForegroundProcess]
}

extension TerminalProcessInspecting {
    func foregroundProcesses(in processGroup: pid_t) -> [TerminalForegroundProcess] {
        guard let path = executablePath(for: processGroup) else { return [] }
        return [.init(processID: processGroup, startSeconds: 0, startMicroseconds: 0, executablePath: path)]
    }
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

    nonisolated func foregroundProcesses(in processGroup: pid_t) -> [TerminalForegroundProcess] {
        guard processGroup > 0 else { return [] }
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(processGroup), nil, 0)
        guard bytes > 0 else { return [] }
        // Leave space for processes that start between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.stride + 32)
        let count = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(processGroup), $0.baseAddress, Int32($0.count))
        }
        guard count > 0 else { return [] }
        return pids.prefix(Int(count) / MemoryLayout<pid_t>.stride).filter { $0 > 0 }.sorted().compactMap { pid in
            var info = proc_bsdinfo()
            let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize,
                  info.pbi_pgid == UInt32(processGroup) else { return nil }
            let path = executablePath(for: pid)
            // Reject a PID that was reused while its executable path was read.
            var current = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &current, infoSize) == infoSize,
                  current.pbi_pgid == info.pbi_pgid,
                  current.pbi_start_tvsec == info.pbi_start_tvsec,
                  current.pbi_start_tvusec == info.pbi_start_tvusec else { return nil }
            return .init(processID: pid, startSeconds: info.pbi_start_tvsec,
                         startMicroseconds: info.pbi_start_tvusec, executablePath: path)
        }
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
