//
//  ContentView.swift
//  Tecolot
//
//  Created by Miguel de Icaza on 8/5/25.
//

import AppKit
import SwiftUI

struct ContentView: View {
    @Binding var document: TerminalDocument
    /// nil for untitled windows; document metadata is only persisted for
    /// file-backed sessions so that closing an untitled window never
    /// triggers a save prompt
    var fileURL: URL?
    @State private var workspace = TerminalPaneWorkspace()
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var themes: ThemeStore

    private var rootController: TerminalSessionController? {
        workspace.controllers.first
    }

    var body: some View {
        TerminalPaneContainer(
            workspace: workspace,
            document: document,
            revision: workspace.revision
        )
            .background(WindowTabbingConfigurator())
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
            .onAppear(perform: configureBufferPersistence)
            .onChange(of: fileURL) {
                configureBufferPersistence()
            }
            .onChange(of: rootController?.id) {
                configureBufferPersistence()
            }
            .onChange(of: rootController?.themeOverride) { _, newValue in
                if fileURL != nil && document.themeOverride != newValue {
                    document.themeOverride = newValue
                }
            }
            .onChange(of: rootController?.profile.id) { _, newValue in
                if fileURL != nil, let newValue, document.profileID != newValue {
                    document.profileID = newValue
                }
            }
            .onChange(of: profiles.profiles) {
                for controller in workspace.controllers {
                    if let stored = profiles.profile(withID: controller.profile.id),
                       stored != controller.profile {
                        controller.applyProfile(stored)
                    }
                }
            }
            .onChange(of: themes.themes) {
                // A user theme was edited/imported: re-resolve colors
                for controller in workspace.controllers {
                    controller.applyAppearance()
                }
            }
            .toolbar {
                ToolbarItem {
                    Button {
                        workspace.focusedController?.showThemePicker.toggle()
                    } label: {
                        Label("Theme", systemImage: "paintbrush")
                    }
                    .help("Change the theme of this terminal")
                    .disabled(workspace.focusedController == nil)
                    .popover(isPresented: themePickerBinding, arrowEdge: .bottom) {
                        if let controller = workspace.focusedController {
                            ThemePickerPopover(
                                controller: controller,
                                themes: themes,
                                profiles: profiles
                            )
                        }
                    }
                }
            }
    }

    private var themePickerBinding: Binding<Bool> {
        Binding(
            get: { workspace.focusedController?.showThemePicker ?? false },
            set: { workspace.focusedController?.showThemePicker = $0 }
        )
    }

    private func configureBufferPersistence() {
        guard let controller = rootController else { return }
        guard fileURL != nil else {
            controller.bufferSnapshotHandler = nil
            return
        }
        controller.bufferSnapshotHandler = { content in
            if document.content != content {
                document.content = content
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
    @State private var errorMessage: String?

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
                    do {
                        try profiles.update(profile)
                        controller.applyThemeOverride(nil)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .help("Makes this theme the profile default, updating every window that uses the profile")
            }
            .padding(10)
        }
        .frame(width: 520, height: 420)
        .alert("Could Not Change Profile Theme", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
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
            TerminalWindowSizeStore.shared.configure(window)
        }
    }
}

#Preview {
    ContentView(document: .constant(TerminalDocument(content: "")))
}
