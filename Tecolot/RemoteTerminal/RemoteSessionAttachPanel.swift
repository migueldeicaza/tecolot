//
//  RemoteSessionAttachPanel.swift
//  Tecolot
//
//  Lets the user select a running SSH session and attach to it in a
//  new tab.
//

import AppKit
import TecolotSessionDirectory
import TecolotSessionClient

@MainActor
enum RemoteSessionAttachPanel {
    static func run() {
        guard let destination = RemoteDestinationPanel.run() else { return }
        RemoteHosts.shared.link(destination: destination) { result in
            switch result {
            case .failure(let error): showError(error, action: "Cannot connect to \(destination)")
            case .success(let link):
                // Keep the connection while the list and its actions are open.
                link.retain()
                link.listSessions { result in
                    Task { @MainActor in
                        switch result {
                        case .failure(let error):
                            link.release()
                            showError(error, action: "Cannot list sessions on \(destination)")
                        case .success(let sessions):
                            show(sessions: sessions, destination: destination, link: link)
                        }
                    }
                }
            }
        }
    }

    private static func show(sessions: [SessionRecord], destination: String, link: HostLink) {
        let alert = NSAlert()
        alert.messageText = "Attach to Session on \(destination)"
        alert.informativeText = sessions.isEmpty
            ? "No persistent sessions are running."
            : "Choose a session to show in a new tab."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 26), pullsDown: false)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        for record in sessions {
            popup.addItem(withTitle: title(for: record, formatter: formatter))
        }
        popup.isEnabled = !sessions.isEmpty
        alert.accessoryView = popup
        alert.addButton(withTitle: "Attach").isEnabled = !sessions.isEmpty
        alert.addButton(withTitle: "Terminate").isEnabled = !sessions.isEmpty
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard sessions.indices.contains(popup.indexOfSelectedItem) else {
            link.release()
            return
        }
        let record = sessions[popup.indexOfSelectedItem]
        switch response {
        case .alertFirstButtonReturn:
            var spec = LaunchSpec()
            spec.attachSessionID = record.id
            spec.remoteDestination = destination
            spec.persistent = true
            if let profileID = record.labels["profileID"].flatMap(UUID.init(uuidString:)) {
                spec.profileID = profileID
            }
            WindowOpener.openTab(spec: spec)
            link.release()
        case .alertSecondButtonReturn:
            link.terminateSession(id: record.id) { result in
                Task { @MainActor in
                    link.release()
                    if case .failure(let error) = result {
                        showError(error, action: "Cannot terminate the session")
                    }
                }
            }
        default:
            link.release()
        }
    }

    private static func showError(_ error: Error, action: String) {
        let alert = NSAlert()
        alert.messageText = action
        if let ssh = error as? SSHError {
            alert.informativeText = ssh.stderr.isEmpty ? ssh.message : ssh.message + "\n\n" + ssh.stderr
        } else {
            alert.informativeText = String(describing: error)
        }
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// For example: "vim — ~/src/app — Default — started 3 min. ago — attached".
    static func title(for record: SessionRecord, formatter: RelativeDateTimeFormatter) -> String {
        var parts: [String] = []
        let shell = (record.executable as NSString).lastPathComponent
        let command = record.foreground.flatMap { $0.isEmpty ? nil : $0.trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
        parts.append(command ?? shell)
        let directory = URL(string: record.directory)?.path ?? record.workingDirectory
        if let directory, !directory.isEmpty {
            parts.append(directory)
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
