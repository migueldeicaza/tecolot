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

@MainActor
final class WindowGroupStore: ObservableObject {
    @Published private(set) var groups: [SavedWindowGroup] = []
    private let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? Self.defaultDirectory()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("window-groups.json")
        load()
    }

    @discardableResult
    func saveCurrentWindows(as name: String) -> SavedWindowGroup? {
        let windows = captureWindows()
        guard !windows.isEmpty else { return nil }

        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return nil }
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
        sortAndPersist()
        return group
    }

    func delete(_ id: SavedWindowGroup.ID) {
        groups.removeAll { $0.id == id }
        persist()
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
            firstWindow.setFrame(NSRectFromString(savedWindow.frame), display: true)

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

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([SavedWindowGroup].self, from: data) else {
            return
        }
        groups = decoded.sorted(by: Self.sortByName)
    }

    private func sortAndPersist() {
        groups.sort(by: Self.sortByName)
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(groups) else { return }
        try? data.write(to: fileURL, options: .atomic)
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
                                store.delete(group.id)
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
        store.saveCurrentWindows(as: nameField.stringValue)
    }
}
