import AppKit
import TecolotSessionClient

/// Keeps the most recent SSH destinations first.
struct RecentRemoteDestinations {
    static let limit = 10
    static let key = "recentRemoteDestinations"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var destinations: [String] {
        var seen = Set<String>()
        return Array((defaults.stringArray(forKey: Self.key) ?? []).filter {
            (try? SSHConfiguration.validate($0)) != nil && seen.insert($0).inserted
        }.prefix(Self.limit))
    }

    func record(_ destination: String) {
        guard (try? SSHConfiguration.validate(destination)) != nil else {
            return
        }
        let updated = [destination] + destinations.filter {
            $0 != destination
        }
        defaults.set(Array(updated.prefix(Self.limit)), forKey: Self.key)
    }

    func remove(_ destination: String) {
        defaults.set(destinations.filter {
            $0 != destination
        }, forKey: Self.key)
    }
}

@MainActor
enum RemoteDestinationPanel {
    /// Shows the Connect to Host panel over the front window and waits for
    /// the answer. Nil if the user cancels.
    static func run() -> String? {
        let recent = RecentRemoteDestinations()
        let model = RemoteDestinationPickerModel(
            recents: recent.destinations,
            aliases: (try? SSHHostAliases.list()) ?? [],
            removeRecent: recent.remove
        )
        let window = RemoteDestinationWindow(model: model)
        var result: String?
        window.onFinish = { [weak window] in
            result = $0
            // Not the session of another window, for example an alert.
            if NSApp.modalWindow === window {
                NSApp.stopModal()
            }
        }
        window.place(over: NSApp.keyWindow ?? NSApp.mainWindow)
        NSApp.runModal(for: window)
        window.orderOut(nil)
        if let result {
            recent.record(result)
        }
        return result
    }
}
