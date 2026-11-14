import Foundation
import Observation

/// A named collection of tabs, independent of any window.
@Observable
@MainActor
final class TerminalTabGroup: Identifiable {
    let id: UUID
    var name: String
    var isNameCustom: Bool
    var tabs: [TerminalTab] {
        didSet {
            for tab in oldValue where tab.group === self && !tabs.contains(where: {
                $0 === tab
            }) {
                tab.group = nil
            }
            for tab in tabs {
                tab.group = self
            }
        }
    }
    var selection: UUID?
    var isCollapsed = false
    var lastShownAt: Date?

    init(id: UUID = UUID(), name: String, isNameCustom: Bool = false, tabs: [TerminalTab]) {
        self.id = id
        self.name = name
        self.isNameCustom = isNameCustom
        self.tabs = tabs
        selection = tabs.first?.id
        for tab in tabs {
            tab.group = self
        }
    }

    var selectedTab: TerminalTab? {
        tabs.first {
            $0.id == selection
        } ?? tabs.first
    }

    func rename(_ name: String, among groups: [TerminalTabGroup], generator: GroupNameGenerator = GroupNameGenerator()) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
        isNameCustom = !trimmed.isEmpty
        self.name = trimmed.isEmpty ? generator.generate(existingNames: groups.map(\.name)) : trimmed
    }
}

/// Original word lists for short, readable group names.
nonisolated struct GroupNameGenerator {
    static let adjectives = [
        "airy", "amber", "ample", "arctic", "balmy", "blended", "brisk", "bronze",
        "calm", "cheerful", "clear", "cobalt", "copper", "crisp", "curved", "dapper",
        "delicate", "eager", "even", "feathery", "fernlike", "flowing", "gentle", "glassy",
        "golden", "graceful", "granular", "hazy", "hushed", "ivory", "jolly", "lively",
        "mellow", "misty", "nimble", "opal", "pearly", "plucky", "polished", "quiet",
        "rippled", "rounded", "silken", "silver", "smooth", "snowy", "soft", "spacious",
        "speckled", "sprightly", "steady", "tidal", "velvet", "verdant", "warm", "winding"
    ]
    static let nouns = [
        "acorn", "anemone", "arch", "axolotl", "basin", "basket", "bobbin", "brook",
        "cairn", "canopy", "cattail", "chestnut", "coral", "cricket", "dahlia", "dewdrop",
        "driftwood", "egret", "estuary", "feather", "fern", "finch", "floret", "folio",
        "gimbal", "granite", "heron", "hollow", "iris", "juniper", "kettle", "lantern",
        "lichen", "linden", "loom", "lotus", "marigold", "meadow", "mosaic", "nectar",
        "otter", "pebble", "petal", "pollen", "quill", "reed", "rill", "robin",
        "runnel", "seashell", "spindle", "tamarind", "thimble", "trellis", "willow", "wren"
    ]
    var candidate: () -> String = {
        let adjective = adjectives.randomElement() ?? "nimble"
        let noun = nouns.randomElement() ?? "axolotl"
        return "\(adjective)-\(noun)"
    }

    func generate(existingNames: [String]) -> String {
        let names = Set(existingNames.map {
            $0.lowercased()
        })
        var base = "nimble-axolotl"
        for _ in 0..<8 {
            base = candidate().lowercased()
            if !names.contains(base) {
                return base
            }
        }
        var suffix = 2
        while names.contains("\(base)-\(suffix)") {
            suffix += 1
        }
        return "\(base)-\(suffix)"
    }
}
