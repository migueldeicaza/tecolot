//
//  PaneRestoration.swift
//  Tecolot
//
//  The parts of a pane that RestoreStore saves at quit and brings back at
//  launch: its kind, its directory, and the text of a local pane.
//

import Foundation
import SwiftTerm
import TecolotSessionClient
import TecolotSessionDirectory
import TecolotSessionHost

extension TerminalSessionController {
    /// Records a directory report (OSC 7). A local pane checks the host with
    /// the names of this Mac: the gethostname names, read at each report
    /// because they change with the network, and the full names of
    /// LocalHostNames, which load in the background after the launch. A
    /// remote pane cannot check it: the app does not know the names of the
    /// remote host.
    func noteDirectoryReport(_ report: String?) {
        guard let report, !report.isEmpty else { return }
        let isRemote = remoteDestination != nil
        guard let directory = PaneDirectory.osc7(report, isPaneHost: { host in
            isRemote || HostNames.contains(host, in: HostNames.current()) || LocalHostNames.shared.contains(host)
        }) else { return }
        directoryTracker.report(directory)
    }

    /// The pane for the restore store, or nil to leave it out: a session
    /// that ended does not come back.
    @MainActor
    func restorePane() -> RestorePane? {
        let kind: RestorePaneKind
        if remoteDestination != nil {
            guard !remoteSessionEnded else { return nil }
            kind = .remote
        } else if isPersistent {
            guard persistentView?.session.state.exitStatus == nil else { return nil }
            kind = .persistent
        } else {
            guard terminal != nil else { return nil }
            kind = .local
        }
        return RestorePane(id: id, kind: kind, profileID: profile.id, themeOverride: themeOverride,
                           directory: restoreDirectory(), sessionID: persistentSessionID ?? remotePendingRestore,
                           remoteDestination: remoteDestination, title: panePresentation.title)
    }

    /// The directory to restore. Reads the shell's directory only when no
    /// report came, or the last one came from another host.
    @MainActor
    func restoreDirectory() -> PaneDirectory? {
        let pid: Int32
        if remoteDestination != nil {
            pid = 0
        } else if persistentView != nil {
            pid = persistentShellPID
        } else {
            pid = terminal?.process?.shellPid ?? 0
        }
        return directoryTracker.resolved { pid > 0 ? ProcessDirectory.workingDirectory(of: pid) : nil }
    }

    /// Copies the normal screen and up to `limit` rows of scrollback, in one
    /// lock transaction. Only local panes: the helper keeps the text of a
    /// persistent session.
    @MainActor
    func copyScrollback(limit: Int) -> ScrollbackSnapshot.Pending? {
        guard limit > 0, persistentView == nil, let terminal,
              let snapshot = terminal.terminalContentSnapshot(region: .history(maximumScrollbackRows: limit),
                                                              buffer: .normal) else { return nil }
        let program = snapshot.inputState.isAlternateBuffer
            ? terminal.process.flatMap { ScrollbackCapture.foregroundProgram(ptyDescriptor: $0.childfd) }
            : nil
        return ScrollbackSnapshot.Pending(paneID: id, snapshot: snapshot, alternateScreenProgram: program, limit: limit)
    }

    /// Copies the rows of a remote pane: its screen and up to `limit` rows
    /// above it. A pane that did not attach yet keeps the file from the last
    /// save, also when the file is not read yet. A limit of 0 saves no text.
    @MainActor
    func copyRemoteRows(limit: Int) -> RemoteRowCopy? {
        guard limit > 0, remoteDestination != nil, let view = persistentView else { return nil }
        if let restoredRowsURL { return RemoteRowCopy(paneID: id, rows: .saved(restoredRowsURL)) }
        guard let rows = RemoteRowSnapshot.capture(view.session, sessionID: persistentSessionID ?? "", limit: limit)
        else { return nil }
        return RemoteRowCopy(paneID: id, rows: .captured(rows))
    }

    /// Shows the saved rows of a restored remote pane until the pane
    /// attaches. The rows come from the cache that the app saved at quit
    /// (spec-restoration.md section 6.2). Each session that the pane opens
    /// before it attaches gets them too (`preloadRestoredRows`).
    @MainActor
    func showRestoredRows() {
        guard let url = restoredRowsURL else { return }
        Task { [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) { RestoreStore.readRows(at: url) }.value
            guard let self, let snapshot, self.restoredRowsURL == url else { return }
            self.restoredRows = snapshot
            self.persistentView?.session.preload(snapshot)
        }
    }

    /// Shows the saved rows in a new session of a pane that did not attach yet.
    @MainActor
    func preloadRestoredRows(in session: RemoteSession) {
        if let restoredRows { session.preload(restoredRows) }
    }

    /// Deletes the saved rows after the pane attached.
    @MainActor
    func removeRestoredRows() {
        guard let url = restoredRowsURL else { return }
        restoredRowsURL = nil
        restoredRows = nil
        RestoreStore.shared.removeRows(at: url)
    }

    /// Reads the saved text and checks the saved directory on background
    /// tasks. The shell starts when both are ready, under the text and the
    /// separator line.
    @MainActor
    func beginLocalRestore(_ restoration: PaneRestoration) {
        awaitingRestore = true
        let path = restoration.pane.directory?.path
        let textURL = restoration.textURL
        let limit = RestoreStore.restoredRowsLimit
        Task { [weak self] in
            async let directory = RestoreDirectoryCheck.resolve(path)
            async let saved = Task.detached(priority: .userInitiated) {
                textURL.flatMap(RestoreStore.takeText(at:))
            }.value
            let (check, text) = await (directory, saved)
            guard let self else { return }
            var replay = ""
            if limit > 0, let text { replay = DurableStateDirectory.lastLines(text.text, limit: limit) }
            let program = text?.header.alternateScreenProgram ?? restoration.pane.alternateScreenProgram
            replay += RestoreSeparator.line(savedAt: restoration.savedAt, reason: restoration.reason,
                                            directoryNotFound: check.notFound, program: program)
            replayText = replay
            launchDirectory = check.path
            awaitingRestore = false
            scheduleStartIfNeeded()
        }
    }

    /// Starts a new persistent session in place of one that ended, in its
    /// saved directory and under its saved text. The helper saved them when
    /// the system ended it; without them the session starts with only the
    /// separator ("the session ended").
    @MainActor
    func startReplacementSession(for restoration: PaneRestoration) {
        guard let helperPath = PersistentSessions.helperPath else {
            showReplacementError(PersistentSessionError.helperMissing)
            return
        }
        let base = PersistentSessions.makeLaunch(profile: profile, workingDirectory: nil, columns: profile.columns,
                                                 rows: profile.rows, cellWidth: 0, cellHeight: 0)
        let states = RestoreStore.shared.sessionStates
        let oldID = restoration.pane.sessionID
        let pane = restoration.pane
        let limit = RestoreStore.restoredRowsLimit
        Task { [weak self] in
            let state = await Task.detached { oldID.flatMap { states.read($0) } }.value
            let check = await RestoreDirectoryCheck.resolve(state?.directory?.path ?? pane.directory?.path
                                                            ?? state?.launch.workingDirectory)
            var launch = base
            if let path = check.path { launch.workingDirectory = path }
            if let state {
                launch.replay = await Task.detached {
                    states.replay(for: state, rowLimit: limit, remote: false, directoryNotFound: check.notFound)
                }.value
            } else {
                launch.replay = RestoreSeparator.line(savedAt: nil, reason: .sessionEnded,
                                                      directoryNotFound: check.notFound,
                                                      program: pane.alternateScreenProgram)
            }
            let ready = launch
            // The pane can close while the checks run: then no session starts.
            guard self != nil else { return }
            let result = await Task.detached {
                Result { try PersistentSessions.directory().create(ready, helperPath: helperPath) }
            }.value
            guard let self else {
                // The pane closed during the create. End the new session and
                // keep the state, so that the Sessions window can restore it.
                if case .success(let record) = result { try? PersistentSessions.directory().terminate(record.id) }
                return
            }
            switch result {
            case .success(let record):
                if let state { states.remove(state.id) }
                attachReplacementSession(record.id)
            case .failure(let error):
                showReplacementError(error)
            }
        }
    }
}
