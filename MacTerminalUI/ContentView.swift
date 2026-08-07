//
//  ContentView.swift
//  MacTerminalUI
//
//  Created by Miguel de Icaza on 8/5/25.
//

import AppKit
import SwiftUI
import TerminalProfilesKit

struct ContentView: View {
    @Binding var document: TerminalDocument
    /// nil for untitled windows; document metadata is only persisted for
    /// file-backed sessions so that closing an untitled window never
    /// triggers a save prompt
    var fileURL: URL?
    @State private var controller = TerminalSessionController()
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var themes: ThemeStore

    /// The store's current copy of this session's profile; editing it in
    /// Settings changes this value, which onChange pushes into the session
    private var storedProfile: TerminalProfile? {
        profiles.profile(withID: controller.profile.id)
    }

    var body: some View {
        TerminalSessionView(controller: controller, document: document)
            .background(WindowTabbingConfigurator())
            .onChange(of: controller.themeOverride) { _, newValue in
                if fileURL != nil && document.themeOverride != newValue {
                    document.themeOverride = newValue
                }
            }
            .onChange(of: controller.profile.id) { _, newValue in
                if fileURL != nil && document.profileID != newValue {
                    document.profileID = newValue
                }
            }
            .onChange(of: storedProfile) { _, newValue in
                if let newValue, newValue != controller.profile {
                    controller.applyProfile(newValue)
                }
            }
            .onChange(of: themes.themes) {
                // A user theme was edited/imported: re-resolve colors
                controller.applyAppearance()
            }
            .toolbar {
                ToolbarItem {
                    Button {
                        controller.showThemePicker.toggle()
                    } label: {
                        Label("Theme", systemImage: "paintbrush")
                    }
                    .help("Change the theme of this terminal")
                    .popover(isPresented: Bindable(controller).showThemePicker, arrowEdge: .bottom) {
                        ThemePickerPopover(controller: controller, themes: themes, profiles: profiles)
                    }
                }
            }
    }
}

/// The per-window theme picker: applies the selection to this session only,
/// with escape hatches to make it the profile-wide theme or reset
struct ThemePickerPopover: View {
    var controller: TerminalSessionController
    @ObservedObject var themes: ThemeStore
    @ObservedObject var profiles: ProfileStore

    var body: some View {
        VStack(spacing: 0) {
            ThemeBrowserView(themes: themes,
                             selectedThemeName: controller.effectiveTheme.name) { theme in
                controller.applyThemeOverride(theme.name)
            }
            Divider()
            HStack {
                Button("Reset to Profile Theme") {
                    controller.applyThemeOverride(nil)
                }
                .disabled(controller.themeOverride == nil)
                Spacer()
                Button("Use for All Windows") {
                    var profile = controller.profile
                    profile.themeName = controller.effectiveTheme.name
                    controller.applyThemeOverride(nil)
                    try? profiles.update(profile)
                }
                .help("Makes this theme the profile default, updating every window that uses the profile")
            }
            .padding(10)
        }
        .frame(width: 520, height: 420)
    }
}

struct WindowTabbingConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configureWindow(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureWindow(for: nsView)
    }

    private func configureWindow(for view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.tabbingIdentifier = "TerminalDocument"
            window.tabbingMode = .preferred
        }
    }
}

#Preview {
    ContentView(document: .constant(TerminalDocument(content: "")))
}
