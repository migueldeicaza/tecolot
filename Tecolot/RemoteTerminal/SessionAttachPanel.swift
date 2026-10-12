//
//  SessionAttachPanel.swift
//  Tecolot
//
//  Lets the user pick a running persistent session and attach to it in a
//  new tab.
//

import AppKit
import TecolotSessionDirectory

enum SessionAttachPanel {
    static func run() {
        let sessions = PersistentSessions.list()
        let alert = NSAlert()
        guard !sessions.isEmpty else {
            alert.messageText = "No persistent sessions are running"
            alert.informativeText = "Use New Persistent Tab to start a session that keeps running when its pane closes."
            alert.runModal()
            return
        }
        alert.messageText = "Attach to Session"
        alert.informativeText = "Choose a running session to show in a new tab."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 26), pullsDown: false)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        for record in sessions {
            popup.addItem(withTitle: title(for: record, formatter: formatter))
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Attach")
        alert.addButton(withTitle: "Terminate")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        let record = sessions[popup.indexOfSelectedItem]
        switch response {
        case .alertFirstButtonReturn:
            var spec = LaunchSpec()
            spec.attachSessionID = record.id
            if let profileID = record.labels["profileID"].flatMap(UUID.init(uuidString:)) {
                spec.profileID = profileID
            }
            WindowOpener.openTab(spec: spec)
        case .alertSecondButtonReturn:
            try? PersistentSessions.directory().terminate(record.id)
        default:
            break
        }
    }

    /// For example: "vim — ~/src/app — Default — started 3 min. ago — attached".
    static func title(for record: SessionRecord, formatter: RelativeDateTimeFormatter) -> String {
        var parts: [String] = []
        let shell = (record.executable as NSString).lastPathComponent
        let command = record.foreground.flatMap { $0.isEmpty ? nil : $0.trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
        parts.append(command ?? shell)
        let directory = URL(string: record.directory)?.path ?? record.workingDirectory
        if let directory, !directory.isEmpty {
            parts.append((directory as NSString).abbreviatingWithTildeInPath)
        } else if !record.title.isEmpty {
            parts.append(record.title)
        }
        if let profile = record.labels["profile"], !profile.isEmpty {
            parts.append(profile)
        }
        parts.append("started \(formatter.localizedString(for: record.createdAt, relativeTo: Date()))")
        if record.attachedClients > 0 { parts.append("attached") }
        if record.exited { parts.append("exited") }
        return parts.joined(separator: " — ")
    }
}
