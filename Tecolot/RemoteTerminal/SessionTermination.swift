//
//  SessionTermination.swift
//  Tecolot
//
//  The one confirmation before persistent sessions end: the Sessions window,
//  its context menu and Terminal > Terminate Session use it.
//

import AppKit

/// A persistent session on this Mac or on a remote host.
struct SessionRef: Hashable {
    let id: String
    /// The SSH destination as the user entered it. Nil for this Mac.
    let destination: String?
}

@MainActor
enum SessionTermination {
    static func title(for sessions: [SessionRef]) -> String {
        guard sessions.count == 1, let session = sessions.first else {
            return "Terminate \(sessions.count) sessions?"
        }
        if let destination = session.destination { return "Terminate this session on \(destination)?" }
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
        guard !sessions.isEmpty else { return false }
        return await DestructiveAlert.run(makeAlert(for: sessions), in: window) == .alertFirstButtonReturn
    }
}

/// Shows an alert whose first button is destructive and whose second button
/// (Cancel) has Return. Escape also cancels.
@MainActor
enum DestructiveAlert {
    static func run(_ alert: NSAlert, in window: NSWindow?) async -> NSApplication.ModalResponse {
        // Return took the Escape key equivalent of Cancel, so a monitor adds it again.
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak alert] event in
            guard let alert, event.window === alert.window, event.keyCode == 53,
                  alert.buttons.count > 1 else { return event }
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
