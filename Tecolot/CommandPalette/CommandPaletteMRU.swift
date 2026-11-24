import Foundation

/// Stores recently executed command IDs to gently boost frequent actions during search.
@MainActor
final class CommandPaletteMRU {
    nonisolated static let key = "commandPaletteRecentIDs"
    nonisolated static let limit = 25

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var recentIDs: [String] {
        defaults.stringArray(forKey: Self.key) ?? []
    }

    func record(_ commandID: String) {
        guard !commandID.isEmpty else {
            return
        }
        var ids = recentIDs.filter {
            $0 != commandID
        }
        ids.insert(commandID, at: 0)
        if ids.count > Self.limit {
            ids = Array(ids.prefix(Self.limit))
        }
        defaults.set(ids, forKey: Self.key)
    }

    /// Small tie-breaking score bonus for recently run commands (40 down to 2).
    func boost(for commandID: String) -> Int {
        guard let index = recentIDs.firstIndex(of: commandID) else {
            return 0
        }
        return max(2, 40 - index * 2)
    }
}
