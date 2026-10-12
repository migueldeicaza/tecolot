import Foundation

nonisolated struct TerminalForegroundProcess: Sendable {
    struct Identity: Hashable, Sendable {
        let processID: Int32
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    let processID: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let executablePath: String?

    var identity: Identity {
        Identity(processID: processID, startSeconds: startSeconds, startMicroseconds: startMicroseconds)
    }
}

nonisolated struct TerminalForegroundJobSnapshot: Sendable {
    let processGroup: Int32
    let processes: [TerminalForegroundProcess]
}

/// Retains a command icon only while a known pager continues the same job.
nonisolated struct TerminalForegroundJobIconResolver {
    private var descriptor: Int32?
    private var processGroup: Int32?
    private var previousMembers: Set<TerminalForegroundProcess.Identity> = []
    private var commandPath: String?

    mutating func executablePath(for snapshot: TerminalForegroundJobSnapshot?, descriptor: Int32?) -> String? {
        guard let snapshot, let descriptor, !snapshot.processes.isEmpty else {
            self = Self()
            return nil
        }
        let members = Set(snapshot.processes.map(\.identity))
        let continuesJob = self.descriptor == descriptor && processGroup == snapshot.processGroup
            && !previousMembers.isDisjoint(with: members)
        if !continuesJob { commandPath = nil }
        self.descriptor = descriptor
        processGroup = snapshot.processGroup
        previousMembers = members

        let processes = snapshot.processes.sorted { $0.processID < $1.processID }
        let commands = processes.filter { process in
            guard let identity = TerminalAppIconResolver.identity(forExecutablePath: process.executablePath) else { return false }
            return TerminalAppIconResolver.isRecognizedCommand(identity)
        }
        if let command = commands.first(where: { $0.processID == snapshot.processGroup }) ?? commands.first {
            commandPath = command.executablePath
            return commandPath
        }
        let onlyPagers = processes.allSatisfy {
            guard let identity = TerminalAppIconResolver.identity(forExecutablePath: $0.executablePath) else { return false }
            return ["less", "more"].contains(identity)
        }
        if onlyPagers, let commandPath { return commandPath }
        commandPath = nil
        // A live member still supplies an icon when the group leader has exited.
        return (processes.first(where: { $0.processID == snapshot.processGroup && $0.executablePath != nil })
                ?? processes.first(where: { $0.executablePath != nil }))?.executablePath
    }
}
