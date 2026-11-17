//
//  WindowGroups.swift
//  Tecolot
//
//  Read-only migration of shipped Window Groups into durable groups.
//

import Foundation

nonisolated struct SavedTerminalTab: Codable, Equatable, Sendable {
    var profileID: UUID?
    var workingDirectory: String?
    var themeOverride: String?
}

nonisolated struct SavedTerminalWindow: Codable, Equatable, Sendable {
    var frame: String
    var tabs: [SavedTerminalTab]
    var selectedTabIndex: Int
}

nonisolated struct SavedWindowGroup: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var windows: [SavedTerminalWindow]

    init(id: UUID = UUID(), name: String, windows: [SavedTerminalWindow]) {
        self.id = id
        self.name = name
        self.windows = windows
    }
}

private nonisolated struct WindowGroupsDocumentV1: Codable {
    var version: Int
    var groups: [SavedWindowGroup]
}

nonisolated struct WindowGroupsMigrator: VersionedDocumentMigrator {
    let currentVersion = 1

    func sourceVersion(in data: Data) throws -> Int {
        try PersistenceVersionProbe.optionalVersion(in: data) ?? 0
    }

    func decode(_ data: Data, from sourceVersion: Int) throws -> [SavedWindowGroup] {
        let groups: [SavedWindowGroup]
        switch sourceVersion {
        case 0:
            groups = try JSONDecoder().decode([SavedWindowGroup].self, from: data)
        case 1:
            groups = try JSONDecoder().decode(WindowGroupsDocumentV1.self, from: data).groups
        default:
            throw VersionedPersistenceError.invalidDocument("Unsupported window-group schema.")
        }
        return groups.map { group in
            var group = group
            group.name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
            group.windows = group.windows.map { window in
                var window = window
                if window.tabs.isEmpty {
                    window.selectedTabIndex = 0
                } else {
                    window.selectedTabIndex = min(max(window.selectedTabIndex, 0), window.tabs.count - 1)
                }
                return window
            }
            return group
        }
    }

    func validate(_ groups: [SavedWindowGroup]) throws {
        guard
            groups.allSatisfy({
                !$0.name.isEmpty
            }) else {
            throw VersionedPersistenceError.invalidDocument("A window group has no name.")
        }
    }

    func encodeCurrent(_ groups: [SavedWindowGroup]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(WindowGroupsDocumentV1(version: currentVersion, groups: groups))
    }
}
