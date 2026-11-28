import AppKit
import Foundation
import Observation
import SwiftUI

extension Notification.Name {
    static let appShortcutsDidChange = Notification.Name("AppShortcutStoreDidChange")
}

/// Persists user overrides for application command shortcuts and drives
/// SwiftUI `Commands`, Command Palette labels, and Settings → Shortcuts.
@MainActor
@Observable
final class AppShortcutStore {
    nonisolated static let overridesDefaultsKey = "appShortcutOverrides"
    nonisolated static let corruptOverridesBackupKey = "appShortcutOverrides.corruptBackup"

    static let shared = AppShortcutStore()

    /// Distinguishes an explicit user-cleared binding from "use default".
    private enum StoredOverride: Codable, Equatable {
        case bound(KeyCombo)
        case unbound
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var overrides: [AppShortcutID: StoredOverride] = [:]
    @ObservationIgnored private var unknownOverrides: [String: RawJSONValue] = [:]
    @ObservationIgnored private var unreadableRawData: Data?

    /// Effective active binding per action (absent means unbound).
    private(set) var effectiveShortcuts: [AppShortcutID: KeyCombo] = [:]

    /// Actions that share the same active `KeyCombo` with each action.
    private(set) var conflictsByAction: [AppShortcutID: [AppShortcutID]] = [:]

    /// Number of actions whose binding differs from the built-in default.
    private(set) var customizedCount = 0

    /// True while a shortcut recorder button in Settings is capturing keystrokes.
    /// Observed by `SettingsKeyHandler` so Escape / Command-F are not stolen.
    var isRecording = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadOverrides()
        rebuildDerivedState()
    }

    // MARK: - Queries

    func shortcut(for id: AppShortcutID) -> KeyCombo? {
        effectiveShortcuts[id]
    }

    func swiftUIShortcut(for id: AppShortcutID) -> KeyboardShortcut? {
        effectiveShortcuts[id]?.swiftUIShortcut
    }

    func displayString(for id: AppShortcutID) -> String? {
        effectiveShortcuts[id]?.displayString
    }

    /// Formats a tooltip as `"Title (⌘T)"`, or plain `"Title"` when the action is unbound.
    func toolTip(_ title: String, for id: AppShortcutID) -> String {
        if let shortcut = displayString(for: id) {
            return "\(title) (\(shortcut))"
        }
        return title
    }

    func isCustomized(_ id: AppShortcutID) -> Bool {
        overrides[id] != nil
    }

    func conflicts(for id: AppShortcutID) -> [AppShortcutID] {
        conflictsByAction[id] ?? []
    }

    /// Returns true if any catalog action is currently bound to `combo`.
    func isBound(_ combo: KeyCombo) -> Bool {
        effectiveShortcuts.values.contains(combo)
    }

    func matches(_ event: NSEvent, action id: AppShortcutID) -> Bool {
        guard let combo = effectiveShortcuts[id] else {
            return false
        }
        return combo.matches(event)
    }

    // MARK: - Mutations

    func setShortcut(_ combo: KeyCombo?, for id: AppShortcutID) {
        let defaultValue = id.descriptor.defaultShortcut
        if combo == defaultValue {
            overrides.removeValue(forKey: id)
        } else if let combo {
            overrides[id] = .bound(combo)
        } else {
            overrides[id] = .unbound
        }
        commitMutation()
    }

    func reset(_ id: AppShortcutID) {
        guard overrides.removeValue(forKey: id) != nil else {
            return
        }
        commitMutation()
    }

    func resetAll() {
        guard !overrides.isEmpty else {
            return
        }
        overrides.removeAll()
        commitMutation()
    }

    /// Unbinds every other action that currently shares the same active shortcut as `id`.
    func resolveConflicts(keeping id: AppShortcutID) {
        let others = conflicts(for: id)
        guard !others.isEmpty else {
            return
        }
        for other in others {
            if other.descriptor.defaultShortcut == nil {
                overrides.removeValue(forKey: other)
            } else {
                overrides[other] = .unbound
            }
        }
        commitMutation()
    }

    private func commitMutation() {
        persistOverrides()
        rebuildDerivedState()
        NotificationCenter.default.post(name: .appShortcutsDidChange, object: self)
    }

    // MARK: - Filtering & Reverse Key Search

    struct FilteredSection: Identifiable, Equatable {
        let category: AppShortcutCategory
        let items: [AppShortcutDescriptor]

        var id: AppShortcutCategory {
            category
        }
    }

    /// Filters actions by name/keywords OR by key combination (e.g. `cmd+k`, `⌘K`, `ctrl+tab`).
    func filteredSections(matching rawQuery: String) -> [FilteredSection] {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return AppShortcutCategory.allCases.compactMap { category in
                guard let items = AppShortcutCatalog.byCategory[category], !items.isEmpty else {
                    return nil
                }
                return FilteredSection(category: category, items: items)
            }
        }

        let keyFilter = KeyQueryFilter.parse(trimmed)
        let textTokens = trimmed.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)

        return AppShortcutCategory.allCases.compactMap { category in
            let items = (AppShortcutCatalog.byCategory[category] ?? []).filter { descriptor in
                if let keyFilter {
                    guard let active = effectiveShortcuts[descriptor.id] else {
                        return false
                    }
                    return keyFilter.matches(active)
                }
                return Self.matchesText(descriptor: descriptor, active: effectiveShortcuts[descriptor.id], tokens: textTokens)
            }
            return items.isEmpty ? nil : FilteredSection(category: category, items: items)
        }
    }

    private static func matchesText(
        descriptor: AppShortcutDescriptor,
        active: KeyCombo?,
        tokens: [String]
    ) -> Bool {
        var haystackParts = [
            descriptor.title.lowercased(),
            descriptor.category.title.lowercased()
        ]
        haystackParts.append(contentsOf: descriptor.keywords.map { $0.lowercased() })
        if let active {
            haystackParts.append(active.displayString.lowercased())
            haystackParts.append(active.accessibilityLabel.lowercased())
        }
        let haystack = haystackParts.joined(separator: " ")
        return tokens.allSatisfy { haystack.contains($0) }
    }

    // MARK: - Persistence & Derived State

    /// Lossless JSON value used to preserve override keys written by newer builds.
    private enum RawJSONValue: Codable, Equatable {
        case null
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case array([RawJSONValue])
        case object([String: RawJSONValue])

        init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if single.decodeNil() {
                self = .null
            } else if let value = try? single.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? single.decode(Int.self) {
                self = .int(value)
            } else if let value = try? single.decode(Double.self) {
                self = .double(value)
            } else if let value = try? single.decode(String.self) {
                self = .string(value)
            } else if let value = try? single.decode([RawJSONValue].self) {
                self = .array(value)
            } else if let value = try? single.decode([String: RawJSONValue].self) {
                self = .object(value)
            } else {
                throw DecodingError.dataCorruptedError(in: single, debugDescription: "Unsupported JSON value")
            }
        }

        func encode(to encoder: Encoder) throws {
            var single = encoder.singleValueContainer()
            switch self {
            case .null:
                try single.encodeNil()
            case .bool(let value):
                try single.encode(value)
            case .int(let value):
                try single.encode(value)
            case .double(let value):
                try single.encode(value)
            case .string(let value):
                try single.encode(value)
            case .array(let value):
                try single.encode(value)
            case .object(let value):
                try single.encode(value)
            }
        }
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? {
            nil
        }

        init(_ stringValue: String) {
            self.stringValue = stringValue
        }

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }

    /// Decodes each saved key individually so one corrupted or future-format entry
    /// never wipes out the user's other valid shortcut overrides, while preserving
    /// unknown keys written by newer builds.
    private struct LossyOverrides: Decodable {
        let known: [AppShortcutID: StoredOverride]
        let unknown: [String: RawJSONValue]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            var decodedKnown: [AppShortcutID: StoredOverride] = [:]
            var decodedUnknown: [String: RawJSONValue] = [:]
            for key in container.allKeys {
                if let id = AppShortcutID(rawValue: key.stringValue) {
                    if let value = try? container.decode(StoredOverride.self, forKey: key) {
                        decodedKnown[id] = value
                    }
                } else if let rawValue = try? container.decode(RawJSONValue.self, forKey: key) {
                    decodedUnknown[key.stringValue] = rawValue
                }
            }
            known = decodedKnown
            unknown = decodedUnknown
        }
    }

    private struct PersistedOverrides: Encodable {
        let known: [AppShortcutID: StoredOverride]
        let unknown: [String: RawJSONValue]

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: DynamicKey.self)
            for (rawID, rawValue) in unknown {
                try container.encode(rawValue, forKey: DynamicKey(rawID))
            }
            for (id, stored) in known {
                try container.encode(stored, forKey: DynamicKey(id.rawValue))
            }
        }
    }

    private func loadOverrides() {
        guard let data = defaults.data(forKey: Self.overridesDefaultsKey) else {
            overrides = [:]
            unknownOverrides = [:]
            unreadableRawData = nil
            return
        }
        guard let decoded = try? JSONDecoder().decode(LossyOverrides.self, from: data) else {
            overrides = [:]
            unknownOverrides = [:]
            unreadableRawData = data
            return
        }
        unreadableRawData = nil
        unknownOverrides = decoded.unknown
        var loaded: [AppShortcutID: StoredOverride] = [:]
        for (id, stored) in decoded.known {
            // Drop stale overrides that already match the built-in default.
            let defaultValue = id.descriptor.defaultShortcut
            switch stored {
            case .bound(let combo) where combo == defaultValue:
                continue
            case .unbound where defaultValue == nil:
                continue
            default:
                loaded[id] = stored
            }
        }
        overrides = loaded
    }

    private func persistOverrides() {
        if let corruptData = unreadableRawData {
            defaults.set(corruptData, forKey: Self.corruptOverridesBackupKey)
            unreadableRawData = nil
        }
        if overrides.isEmpty && unknownOverrides.isEmpty {
            defaults.removeObject(forKey: Self.overridesDefaultsKey)
            return
        }
        let payload = PersistedOverrides(known: overrides, unknown: unknownOverrides)
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: Self.overridesDefaultsKey)
        }
    }

    private func rebuildDerivedState() {
        var nextEffective: [AppShortcutID: KeyCombo] = [:]
        var actionsByCombo: [KeyCombo: [AppShortcutID]] = [:]

        for descriptor in AppShortcutCatalog.all {
            let resolved: KeyCombo?
            switch overrides[descriptor.id] {
            case .bound(let combo):
                resolved = combo
            case .unbound:
                resolved = nil
            case nil:
                resolved = descriptor.defaultShortcut
            }
            if let resolved {
                nextEffective[descriptor.id] = resolved
                actionsByCombo[resolved, default: []].append(descriptor.id)
            }
        }

        var nextConflicts: [AppShortcutID: [AppShortcutID]] = [:]
        for (_, group) in actionsByCombo where group.count > 1 {
            for id in group {
                nextConflicts[id] = group.filter { $0 != id }
            }
        }

        effectiveShortcuts = nextEffective
        conflictsByAction = nextConflicts
        customizedCount = overrides.count
    }
}

/// Parses reverse key queries like `"cmd+k"`, `"shift+cmd+p"`, `"ctrl+tab"`, `"⌘k"`, `"⌥⌘←"`.
nonisolated struct KeyQueryFilter: Equatable, Sendable {
    let modifiers: ShortcutModifiers
    let keyToken: String?

    static func parse(_ query: String) -> KeyQueryFilter? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        var mods: ShortcutModifiers = []
        var remainder = ""

        // Extract any macOS glyph modifiers directly (e.g. "⇧⌘P", "⌃⇥").
        for ch in trimmed {
            switch ch {
            case "⌃":
                mods.insert(.control)
            case "⌥":
                mods.insert(.option)
            case "⇧":
                mods.insert(.shift)
            case "⌘":
                mods.insert(.command)
            default:
                remainder.append(ch)
            }
        }

        if !mods.isEmpty {
            let cleaned = remainder.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "+-")))
            return KeyQueryFilter(
                modifiers: mods,
                keyToken: cleaned.isEmpty ? nil : cleaned.lowercased()
            )
        }

        // Require explicit '+' delimiter for textual modifier queries (e.g. "cmd+k",
        // "shift+cmd+p", "ctrl+tab") so normal phrases like "command palette" or
        // "option as meta" are searched as command text instead of key combos.
        guard trimmed.contains("+") else {
            return nil
        }

        // Preserve a trailing literal "+" key (e.g. "cmd++" -> ["cmd", "+"]).
        let endsWithPlusKey = trimmed.hasSuffix("++")
        let normalized = endsWithPlusKey ? String(trimmed.dropLast(2)) : trimmed

        let rawParts = normalized
            .lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !rawParts.isEmpty else {
            return nil
        }

        var keyParts: [String] = []
        for part in rawParts {
            switch part {
            case "cmd", "command", "super":
                mods.insert(.command)
            case "ctrl", "control":
                mods.insert(.control)
            case "opt", "option", "alt":
                mods.insert(.option)
            case "shift":
                mods.insert(.shift)
            default:
                keyParts.append(part)
            }
        }
        if endsWithPlusKey {
            keyParts.append("+")
        }

        // Only treat as a key-combo query if at least one modifier was named.
        guard !mods.isEmpty, keyParts.count <= 1 else {
            return nil
        }

        return KeyQueryFilter(modifiers: mods, keyToken: keyParts.first)
    }

    func matches(_ combo: KeyCombo) -> Bool {
        if let keyToken {
            guard combo.modifiers == modifiers else {
                return false
            }
            return combo.key.searchAliases.contains { alias in
                if combo.key.isFunctionKey {
                    return alias == keyToken
                }
                return alias == keyToken || (keyToken.count >= 2 && alias.hasPrefix(keyToken))
            }
        }
        // Modifier-only query like "cmd" or "⌃⌘": match any shortcut containing those modifiers.
        return combo.modifiers.isSuperset(of: modifiers)
    }
}

extension View {
    /// Applies the user's configured keyboard shortcut for a SwiftUI command,
    /// or removes the shortcut when explicitly cleared.
    @MainActor
    func appShortcut(_ id: AppShortcutID, store: AppShortcutStore? = nil) -> some View {
        keyboardShortcut((store ?? .shared).swiftUIShortcut(for: id))
    }
}
