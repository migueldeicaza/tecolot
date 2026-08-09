//
//  WindowGroups.swift
//  Tecolot
//
//  Persists named arrangements of terminal windows and tabs.
//

import AppKit
import Combine
import Foundation
import SwiftUI
import TerminalProfilesKit

struct SavedTerminalTab: Codable, Equatable, Sendable {
    var profileID: UUID?
    var workingDirectory: String?
    var themeOverride: String?
}

struct SavedTerminalWindow: Codable, Equatable, Sendable {
    var frame: String
    var tabs: [SavedTerminalTab]
    var selectedTabIndex: Int
}

struct SavedWindowGroup: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var windows: [SavedTerminalWindow]

    init(id: UUID = UUID(), name: String, windows: [SavedTerminalWindow]) {
        self.id = id
        self.name = name
        self.windows = windows
    }
}

private struct WindowGroupsDocumentV1: Codable {
    var version: Int
    var groups: [SavedWindowGroup]
}

private struct WindowGroupsMigrator: VersionedDocumentMigrator {
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
        guard groups.allSatisfy({ !$0.name.isEmpty }) else {
            throw VersionedPersistenceError.invalidDocument("A window group has no name.")
        }
    }

    func encodeCurrent(_ groups: [SavedWindowGroup]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(WindowGroupsDocumentV1(version: currentVersion, groups: groups))
    }
}

private enum WindowGroupError: LocalizedError {
    case noTerminalWindows
    case invalidName

    var errorDescription: String? {
        switch self {
        case .noTerminalWindows: return "There are no terminal windows to save."
        case .invalidName: return "Enter a name for the window group."
        }
    }
}

@MainActor
final class WindowGroupStore: ObservableObject {
    @Published private(set) var groups: [SavedWindowGroup] = []
    private let fileURL: URL
    private let directory: URL
    private let backupDirectory: URL
    private let issueCenter: PersistenceIssueCenter?
    private var aggregateIsReadOnly = false

    init(
        directory: URL? = nil,
        issueCenter: PersistenceIssueCenter? = nil,
        backupDirectory: URL? = nil
    ) {
        let base = directory ?? Self.defaultDirectory()
        self.directory = base
        fileURL = base.appendingPathComponent("window-groups.json")
        self.backupDirectory = backupDirectory ?? base.appendingPathComponent("Backups")
        self.issueCenter = issueCenter
        load()
    }

    @discardableResult
    func saveCurrentWindows(as name: String) throws -> SavedWindowGroup? {
        try ensureWritable()
        let windows = captureWindows()
        guard !windows.isEmpty else { throw WindowGroupError.noTerminalWindows }

        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { throw WindowGroupError.invalidName }
        let group: SavedWindowGroup
        if let index = groups.firstIndex(where: {
            $0.name.localizedCaseInsensitiveCompare(normalizedName) == .orderedSame
        }) {
            group = SavedWindowGroup(
                id: groups[index].id,
                name: normalizedName,
                windows: windows
            )
            groups[index] = group
        } else {
            group = SavedWindowGroup(name: normalizedName, windows: windows)
            groups.append(group)
        }
        do {
            try sortAndPersist()
        } catch {
            load()
            reportWriteFailure(error)
            throw error
        }
        return group
    }

    func delete(_ id: SavedWindowGroup.ID) throws {
        try ensureWritable()
        let oldGroups = groups
        groups.removeAll { $0.id == id }
        do {
            try persist()
        } catch {
            groups = oldGroups
            reportWriteFailure(error)
            throw error
        }
    }

    @discardableResult
    func open(_ group: SavedWindowGroup) -> Bool {
        var openedAny = false
        for savedWindow in group.windows {
            guard let firstTab = savedWindow.tabs.first,
                  let firstWindow = WindowOpener.openWindow(spec: launchSpec(for: firstTab)) else {
                continue
            }
            openedAny = true
            TerminalWindowSizeStore.shared.restoreWindowGroupFrame(
                NSRectFromString(savedWindow.frame),
                to: firstWindow
            )

            var openedWindows = [firstWindow]
            for tab in savedWindow.tabs.dropFirst() {
                if let window = WindowOpener.openTab(
                    spec: launchSpec(for: tab),
                    targetWindow: firstWindow
                ) {
                    openedWindows.append(window)
                }
            }
            if openedWindows.indices.contains(savedWindow.selectedTabIndex) {
                openedWindows[savedWindow.selectedTabIndex].makeKeyAndOrderFront(nil)
            }
        }
        return openedAny
    }

    func group(withID id: UUID?) -> SavedWindowGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    private func captureWindows() -> [SavedTerminalWindow] {
        var visitedTabGroups = Set<ObjectIdentifier>()
        var result: [SavedTerminalWindow] = []

        for window in NSApp.windows where !TerminalSessionRegistry.shared.controllers(for: window).isEmpty {
            let tabWindows: [NSWindow]
            let selectedWindow: NSWindow
            if let tabGroup = window.tabGroup {
                let identifier = ObjectIdentifier(tabGroup)
                guard visitedTabGroups.insert(identifier).inserted else { continue }
                tabWindows = tabGroup.windows.filter {
                    !TerminalSessionRegistry.shared.controllers(for: $0).isEmpty
                }
                selectedWindow = tabGroup.selectedWindow ?? window
            } else {
                tabWindows = [window]
                selectedWindow = window
            }

            let tabs = tabWindows.compactMap { tabWindow -> SavedTerminalTab? in
                guard let controller = TerminalSessionRegistry.shared.controller(for: tabWindow) else {
                    return nil
                }
                return SavedTerminalTab(
                    profileID: controller.profile.id,
                    workingDirectory: controller.currentWorkingDirectory,
                    themeOverride: controller.themeOverride
                )
            }
            guard !tabs.isEmpty else { continue }
            result.append(
                SavedTerminalWindow(
                    frame: NSStringFromRect(selectedWindow.frame),
                    tabs: tabs,
                    selectedTabIndex: tabWindows.firstIndex(of: selectedWindow) ?? 0
                )
            )
        }
        return result
    }

    private func launchSpec(for tab: SavedTerminalTab) -> LaunchSpec {
        LaunchSpec(
            profileID: tab.profileID,
            workingDirectory: tab.workingDirectory,
            themeOverride: tab.themeOverride
        )
    }

    func load() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            aggregateIsReadOnly = true
            groups = []
            issueCenter?.replaceIssues(in: .windowGroups, with: [PersistenceIssue(
                domain: .windowGroups,
                sourceURL: fileURL,
                kind: .unreadable,
                message: error.localizedDescription,
                supportedVersion: 1
            )])
            return
        }
        let result = VersionedFileLoader.load(
            from: fileURL,
            domain: .windowGroups,
            backupRoot: backupDirectory,
            migrator: WindowGroupsMigrator()
        )
        aggregateIsReadOnly = result.issue != nil
        groups = (result.value ?? []).sorted(by: Self.sortByName)
        issueCenter?.replaceIssues(
            in: .windowGroups,
            with: result.issue.map { [$0] } ?? []
        )
    }

    private func sortAndPersist() throws {
        groups.sort(by: Self.sortByName)
        try persist()
    }

    private func persist() throws {
        let data = try WindowGroupsMigrator().encodeCurrent(groups)
        try data.write(to: fileURL, options: .atomic)
        issueCenter?.resolve(domain: .windowGroups, sourceURL: fileURL)
    }

    private func reportWriteFailure(_ error: Error) {
        issueCenter?.report(PersistenceIssue(
            domain: .windowGroups,
            sourceURL: fileURL,
            kind: .writeFailed,
            message: error.localizedDescription,
            supportedVersion: 1
        ))
    }

    private func ensureWritable() throws {
        guard !aggregateIsReadOnly else {
            throw PersistenceMutationError.recoveryRequired(.windowGroups)
        }
    }

    private static func sortByName(_ first: SavedWindowGroup, _ second: SavedWindowGroup) -> Bool {
        first.name.localizedCaseInsensitiveCompare(second.name) == .orderedAscending
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.tirania.Tecolot")
    }
}

struct WindowGroupCommands: Commands {
    @ObservedObject var store: WindowGroupStore
    @State private var commandState = TerminalCommandState()

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Menu("Window Groups") {
                ForEach(store.groups) { group in
                    Button(group.name) {
                        store.open(group)
                    }
                }
                if !store.groups.isEmpty {
                    Divider()
                }
                Button("Save Windows as Group…", action: saveCurrentWindows)
                    .disabled(commandState.controller == nil)
                if !store.groups.isEmpty {
                    Menu("Delete Window Group") {
                        ForEach(store.groups) { group in
                            Button(group.name, role: .destructive) {
                                do {
                                    try store.delete(group.id)
                                } catch {
                                    presentError(error)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func saveCurrentWindows() {
        let nameField = NSTextField(string: "")
        nameField.placeholderString = "Group name"
        nameField.frame = NSRect(x: 0, y: 0, width: 280, height: 24)

        let alert = NSAlert()
        alert.messageText = "Save Window Group"
        alert.informativeText = "Enter a name for the current windows and tabs."
        alert.accessoryView = nameField
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.saveCurrentWindows(as: nameField.stringValue)
        } catch {
            presentError(error)
        }
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "Could Not Save Window Groups"
        alert.runModal()
    }
}
