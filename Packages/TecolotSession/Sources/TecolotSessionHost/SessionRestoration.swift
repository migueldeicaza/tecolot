//
// SessionRestoration.swift
// TecolotSessionHost
//
// What a session needs for restoration: the replay of a saved text before
// the shell starts, the directory of the shell, and a copy of the scrollback
// for the durable state. Nothing here runs while the session works, other
// than the directory reports.
//

import Foundation
import SwiftTerm
import TecolotSessionDirectory
import TecolotWire

extension SessionHost {
    /// Feeds the launch's replay to the terminal, then releases it. Call
    /// before the shell starts. A replay that has a sequence other than SGR
    /// is not shown.
    func feedReplayIfNeeded() {
        guard let replay = pendingReplay.withLock({ value in defer { value = nil }; return value }),
              !replay.isEmpty else { return }
        do {
            try ScrollbackFile.validate(replay)
        } catch {
            fputs("replay rejected: \(error)\n", stderr)
            return
        }
        let bytes = ScrollbackFile.terminalBytes(replay)
        terminal.terminalLock.withLock { terminal.feed(text: bytes) }
    }

    /// Records an OSC 7 report. Runs with the terminal lock held.
    func noteDirectoryReport(_ report: String) {
        guard let directory = PaneDirectory.osc7(report, isPaneHost: { [hostNames] host in
            HostNames.contains(host, in: hostNames)
        }) else { return }
        directoryTracker.withLock { $0.report(directory) }
    }

    /// Records an OSC 1337 or OSC 633 directory report.
    func noteOtherDirectoryReport(code: Int, payload: String) {
        guard let directory = PaneDirectory.otherReport(code: code, payload: payload) else { return }
        directoryTracker.withLock { $0.report(directory) }
    }

    /// The directory to restore: the last report from this host, or the
    /// shell's directory when no report came or the last one came from
    /// another host.
    public func restoreDirectory() -> PaneDirectory? {
        let tracker = directoryTracker.withLock { $0 }
        let pid = shellPID
        return tracker.resolved { ProcessDirectory.workingDirectory(of: pid) }
    }

    /// The durable state of this session, and its scrollback file (nil when
    /// `launch.restoreRows` is 0). Copies the normal buffer in one terminal
    /// lock transaction.
    public func durableState(title: String, now: Date = Date()) -> (DurableSessionState, Data?) {
        let limit = min(max(launch.restoreRows ?? 1_000, 0), 100_000)
        let snapshot = terminal.contentSnapshot(region: .history(maximumScrollbackRows: limit), buffer: .normal)
        let program = snapshot.inputState.isAlternateBuffer
            ? ScrollbackCapture.foregroundProgram(ptyDescriptor: process.childfd) : nil
        // `launch` has no replay: the replay is in the scrollback already.
        let state = DurableSessionState(id: id, launch: launch, profileName: launch.labels["profile"],
                                        directory: restoreDirectory(), title: title,
                                        tabName: launch.labels["tabName"], savedAt: now,
                                        alternateScreenProgram: program)
        guard limit > 0 else { return (state, nil) }
        let rows = ScrollbackCapture.rows(snapshot, limit: limit)
        return (state, ScrollbackCapture.encode(rows, of: snapshot, paneID: id, savedAt: now,
                                                alternateScreenProgram: program))
    }
}
