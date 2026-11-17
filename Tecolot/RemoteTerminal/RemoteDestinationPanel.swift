import AppKit
import TecolotSessionClient

/// Keeps the most recent SSH destinations first.
struct RecentRemoteDestinations {
    static let limit = 10
    static let key = "recentRemoteDestinations"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var destinations: [String] {
        var seen = Set<String>()
        return Array((defaults.stringArray(forKey: Self.key) ?? []).filter {
            (try? SSHConfiguration.validate($0)) != nil && seen.insert($0).inserted
        }.prefix(Self.limit))
    }

    func record(_ destination: String) {
        guard (try? SSHConfiguration.validate(destination)) != nil else { return }
        let updated = [destination] + destinations.filter { $0 != destination }
        defaults.set(Array(updated.prefix(Self.limit)), forKey: Self.key)
    }
}

@MainActor
enum RemoteDestinationPanel {
    static func run() -> String? {
        let recent = RecentRemoteDestinations()
        let aliases = (try? SSHHostAliases.list()) ?? []
        var seen = Set<String>()
        let choices = (recent.destinations + aliases).filter { seen.insert($0).inserted }
        let field = NSComboBox(frame: NSRect(x: 0, y: 0, width: 420, height: 26))
        field.addItems(withObjectValues: choices)
        field.completes = true
        field.placeholderString = "user@host or SSH Host alias"
        field.stringValue = recent.destinations.first ?? ""
        let alert = NSAlert()
        alert.messageText = "Remote Destination"
        alert.informativeText = "Enter an SSH destination or choose a recent destination or Host alias."
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        while alert.runModal() == .alertFirstButtonReturn {
            let destination = field.stringValue
            do {
                try SSHConfiguration.validate(destination)
                recent.record(destination)
                return destination
            } catch {
                let problem = NSAlert()
                problem.messageText = "Invalid SSH destination"
                problem.informativeText = "Enter a host name, user@host, or Host alias. Do not use spaces or start with a hyphen."
                problem.runModal()
            }
        }
        return nil
    }
}
