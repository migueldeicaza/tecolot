//
//  SettingsAnchor.swift
//  Tecolot
//
//  Marks where each setting is on screen so that search can show it.
//
import AppKit
import SwiftUI

extension View {
    /// Marks this row as the place of a setting. Rows that belong to the
    /// same setting, such as a caption under a toggle, use the same ID.
    func settingsAnchor(_ id: SettingID) -> some View {
        background(SettingsAnchorMarker(id: id))
    }
}

/// Keeps the marker views of the rows that are on screen.
@MainActor
final class SettingsAnchorRegistry {
    static let shared = SettingsAnchorRegistry()

    private var views: [SettingID: NSHashTable<SettingsAnchorView>] = [:]

    func add(_ view: SettingsAnchorView) {
        let table = views[view.settingID] ?? .weakObjects()
        table.add(view)
        views[view.settingID] = table
    }

    func remove(_ view: SettingsAnchorView, from id: SettingID) {
        views[id]?.remove(view)
    }

    /// The marker views of a setting in one window, from top to bottom.
    func views(for id: SettingID, in window: NSWindow) -> [SettingsAnchorView] {
        (views[id]?.allObjects ?? [])
            .filter { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }
            .sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
    }

    /// Every marker view in the window.
    func views(in window: NSWindow) -> [SettingsAnchorView] {
        views.values.flatMap(\.allObjects).filter { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }
    }

    /// The settings that have a row in the window.
    func ids(in window: NSWindow) -> Set<SettingID> {
        Set(views.keys.filter { !views(for: $0, in: window).isEmpty })
    }
}

final class SettingsAnchorView: NSView {
    var settingID: SettingID {
        didSet {
            guard settingID != oldValue else {
                return
            }
            SettingsAnchorRegistry.shared.remove(self, from: oldValue)
            SettingsAnchorRegistry.shared.add(self)
        }
    }

    init(settingID: SettingID) {
        self.settingID = settingID
        super.init(frame: .zero)
        SettingsAnchorRegistry.shared.add(self)
    }

    @available(*, unavailable) required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Runs when the row leaves its window, for example on a page change.
    var onLeaveWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            onLeaveWindow?()
            onLeaveWindow = nil
        }
    }

    /// The marker never takes clicks from the row above it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private struct SettingsAnchorMarker: NSViewRepresentable {
    let id: SettingID

    func makeNSView(context: Context) -> SettingsAnchorView {
        SettingsAnchorView(settingID: id)
    }

    func updateNSView(_ view: SettingsAnchorView, context: Context) {
        view.settingID = id
    }
}
