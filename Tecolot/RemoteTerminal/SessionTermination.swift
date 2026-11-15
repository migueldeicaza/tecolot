//
//  SessionTermination.swift
//  Tecolot
//
//  The one confirmation before persistent sessions end: the Sessions window,
//  its context menu and Terminal > Terminate Session use it.
//

import AppKit
import TecolotSessionClient
import TecolotSessionDirectory
import TecolotWire

/// A persistent session on this Mac or on a remote host.
struct SessionRef: Hashable {
    let id: String
    /// The SSH destination as the user entered it. Nil for this Mac.
    let destination: String?
}

@MainActor
enum SessionTermination {
    /// Ends a helper session through the same path used by the Sessions window.
    static func end(_ session: SessionRef, link: HostLink? = nil) async throws {
        try await ignoringMissingSession(session) {
            if let destination = session.destination {
                guard let link = link ?? RemoteHosts.shared.connectedLink(destination: destination) else {
                    throw GroupSessionEnder.Failure.hostUnavailable(destination)
                }
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    link.terminateSession(id: session.id) {
                        continuation.resume(with: $0)
                    }
                }
            } else {
                let directory = try PersistentSessions.directory()
                try await Task.detached {
                    try directory.terminate(session.id)
                }.value
            }
        }
    }

    /// Older bridges report directory errors as unavailable with their exact description.
    static func ignoringMissingSession(_ session: SessionRef, operation: () async throws -> Void) async throws {
        do {
            try await operation()
        } catch SessionDirectoryError.noSuchSession {
            // Already ended.
        } catch LinkClientError.remote(let error) where
            error.code == .unavailable && error.message == "no session \(session.id)" {
            // Already ended on the remote host.
        }
    }

    static func title(for sessions: [SessionRef]) -> String {
        guard sessions.count == 1, let session = sessions.first else {
            return "Terminate \(sessions.count) sessions?"
        }
        if let destination = session.destination {
            return "Terminate this session on \(destination)?"
        }
        return "Terminate this session?"
    }

    static func makeAlert(for sessions: [SessionRef]) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title(for: sessions)
        alert.informativeText = "The shell and the programs that it runs end. You cannot undo this."
        let terminate = alert.addButton(withTitle: "Terminate")
        let cancel = alert.addButton(withTitle: "Cancel")
        // Return and Escape cancel. A destructive button is never the default.
        terminate.hasDestructiveAction = true
        terminate.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        return alert
    }

    /// Asks the user to confirm. A sheet on `window`, else an app-modal alert.
    static func confirm(_ sessions: [SessionRef], in window: NSWindow?) async -> Bool {
        guard !sessions.isEmpty else {
            return false
        }
        return await DestructiveAlert.run(makeAlert(for: sessions), in: window) == .alertFirstButtonReturn
    }
}

/// Session termination keeps Return on Cancel. Group-ending confirmations
/// opt into Return on their enabled primary action. Escape always cancels.
@MainActor
enum DestructiveAlert {
    static func run(_ alert: NSAlert, in window: NSWindow?, confirmsWithReturn: Bool = false) async -> NSApplication.ModalResponse {
        // Session-termination alerts give Cancel Return, so add Escape explicitly.
        let returnMonitor = confirmsWithReturn ? ConfirmationKeyboard.install(on: alert) : nil
        defer { returnMonitor.map(NSEvent.removeMonitor) }
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak alert] event in
            guard
                let alert, event.window === alert.window, event.keyCode == 53,
                alert.buttons.count > 1 else {
                return event
            }
            alert.buttons[1].performClick(nil)
            return nil
        }
        defer { monitor.map(NSEvent.removeMonitor) }
        if let window, window.attachedSheet == nil {
            return await alert.beginSheetModal(for: window)
        }
        return alert.runModal()
    }
}
