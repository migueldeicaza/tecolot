//
//  ProfilesSettingsView.swift
//  MacTerminalUI
//
//  The advanced pane: full profile CRUD and every profile field, organized
//  as sections that mirror Terminal.app's Text/Window/Shell/Keyboard/
//  Advanced grouping.
//
import SwiftUI
import SwiftTerm
import TerminalProfilesKit
import UniformTypeIdentifiers

struct ProfilesSettingsView: View {
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var themes: ThemeStore
    @State private var selection: TerminalProfile.ID?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDocument: ProfileExportDocument?

    private var selectedProfile: TerminalProfile? {
        selection.flatMap { profiles.profile(withID: $0) }
    }

    var body: some View {
        HSplitView {
            profileList
                .frame(minWidth: 170, maxWidth: 230)
            detail
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if selection == nil {
                selection = profiles.defaultProfileID
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result {
                let gotAccess = url.startAccessingSecurityScopedResource()
                defer { if gotAccess { url.stopAccessingSecurityScopedResource() } }
                _ = try? profiles.importProfile(from: url)
            }
        }
        .fileExporter(isPresented: $showExporter,
                      document: exportDocument,
                      contentType: .json,
                      defaultFilename: exportDocument?.filename ?? "Profile") { _ in
            exportDocument = nil
        }
    }

    private var profileList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(profiles.profiles) { profile in
                    HStack {
                        Text(profile.name)
                        if profile.id == profiles.defaultProfileID {
                            Spacer()
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help("Default profile")
                        }
                    }
                    .tag(profile.id)
                }
            }
            Divider()
            HStack(spacing: 8) {
                Button {
                    addProfile()
                } label: {
                    Image(systemName: "plus")
                }
                Button {
                    if let selection {
                        try? profiles.delete(selection)
                        self.selection = profiles.defaultProfileID
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil || profiles.profiles.count <= 1)

                Menu {
                    Button("Duplicate") {
                        if let selection, let copy = try? profiles.duplicate(selection) {
                            self.selection = copy.id
                        }
                    }
                    Button("Set as Default") {
                        if let selection {
                            try? profiles.setDefault(selection)
                        }
                    }
                    Divider()
                    Button("Import…") {
                        showImporter = true
                    }
                    Button("Export…") {
                        if let profile = selectedProfile {
                            exportDocument = ProfileExportDocument(profile: profile)
                            showExporter = true
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 30)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let profile = selectedProfile {
            ProfileEditorView(profile: profile) { mutate in
                var updated = profile
                mutate(&updated)
                try? profiles.update(updated)
            }
        } else {
            ContentUnavailableView("Select a profile", systemImage: "person.crop.circle")
        }
    }

    private func addProfile() {
        var name = "New Profile"
        var counter = 2
        while profiles.profile(named: name) != nil {
            name = "New Profile \(counter)"
            counter += 1
        }
        let profile = TerminalProfile(name: name)
        try? profiles.add(profile)
        selection = profile.id
    }
}

/// All profile fields, sectioned like Terminal.app's panes
struct ProfileEditorView: View {
    let profile: TerminalProfile
    let update: ((inout TerminalProfile) -> Void) -> Void

    @EnvironmentObject private var themes: ThemeStore

    var body: some View {
        Form {
            Section {
                TextField("Name:", text: binding(\.name))
            }
            Section("Text") {
                Picker("Theme:", selection: binding(\.themeName)) {
                    ForEach(themes.themes) { theme in
                        Text(theme.name).tag(theme.name)
                    }
                }
                ProfileTextSettingsFields(profile: profile, update: update)
            }
            Section("Window") {
                TextField("Columns:", value: binding(\.columns), format: .number)
                TextField("Rows:", value: binding(\.rows), format: .number)
                Toggle("Limit scrollback", isOn: Binding(
                    get: { profile.scrollbackLines != nil },
                    set: { limited in update { $0.scrollbackLines = limited ? 10_000 : nil } }
                ))
                if profile.scrollbackLines != nil {
                    TextField("Scrollback lines:", value: Binding(
                        get: { profile.scrollbackLines ?? 10_000 },
                        set: { newValue in update { $0.scrollbackLines = max(0, newValue) } }
                    ), format: .number)
                }
            }
            Section("Shell") {
                Picker("Run:", selection: shellKindBinding) {
                    Text("Default login shell").tag(ShellKind.loginShell)
                    Text("Command").tag(ShellKind.command)
                }
                if case .command(let commandLine, let runInShell) = profile.shell {
                    TextField("Command:", text: Binding(
                        get: { commandLine },
                        set: { newValue in update { $0.shell = .command(newValue, runInShell: runInShell) } }
                    ))
                    Toggle("Run inside shell", isOn: Binding(
                        get: { runInShell },
                        set: { newValue in update { $0.shell = .command(commandLine, runInShell: newValue) } }
                    ))
                }
                Picker("When the shell exits:", selection: binding(\.whenShellExits)) {
                    ForEach(ShellExitBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.description).tag(behavior)
                    }
                }
                Picker("Ask before closing:", selection: binding(\.askBeforeClosing)) {
                    ForEach(AskBeforeClosing.allCases, id: \.self) { policy in
                        Text(policy.description).tag(policy)
                    }
                }
            }
            Section("Keyboard") {
                Toggle("Use Option as Meta key", isOn: binding(\.optionAsMetaKey))
                Toggle("Delete sends Control-H", isOn: binding(\.backspaceSendsControlH))
            }
            Section("Advanced") {
                TextField("Declare terminal as:", text: binding(\.termName))
            }
        }
        .formStyle(.grouped)
    }

    private enum ShellKind: Hashable {
        case loginShell, command
    }

    private var shellKindBinding: Binding<ShellKind> {
        Binding(
            get: {
                if case .command = profile.shell { return .command }
                return .loginShell
            },
            set: { kind in
                update {
                    switch kind {
                    case .loginShell:
                        $0.shell = .loginShell
                    case .command:
                        $0.shell = .command("", runInShell: true)
                    }
                }
            }
        )
    }

    private func binding<T>(_ keyPath: WritableKeyPath<TerminalProfile, T>) -> Binding<T> {
        Binding(
            get: { profile[keyPath: keyPath] },
            set: { newValue in update { $0[keyPath: keyPath] = newValue } }
        )
    }
}

/// Font/cursor/opacity fields shared by Appearance and the profile editor
struct ProfileTextSettings: View {
    let profile: TerminalProfile
    let update: ((inout TerminalProfile) -> Void) -> Void

    var body: some View {
        Form {
            ProfileTextSettingsFields(profile: profile, update: update)
        }
        .formStyle(.grouped)
    }
}

struct ProfileTextSettingsFields: View {
    let profile: TerminalProfile
    let update: ((inout TerminalProfile) -> Void) -> Void

    private var fontFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch
        }
    }

    var body: some View {
        Picker("Font:", selection: Binding(
            get: { profile.fontFamily ?? "" },
            set: { newValue in update { $0.fontFamily = newValue.isEmpty ? nil : newValue } }
        )) {
            Text("System Monospaced").tag("")
            ForEach(fontFamilies, id: \.self) { family in
                Text(family).tag(family)
            }
        }
        Stepper("Size: \(Int(profile.fontSize)) pt",
                value: Binding(
                    get: { profile.fontSize },
                    set: { newValue in update { $0.fontSize = newValue } }
                ), in: 6...72)
        Picker("Cursor:", selection: Binding(
            get: { profile.cursorStyle },
            set: { newValue in update { $0.cursorStyle = newValue } }
        )) {
            ForEach(CursorStyle.allStyles, id: \.tagName) { style in
                Text(style.displayName).tag(style)
            }
        }
        Toggle("Use bright colors for bold text", isOn: Binding(
            get: { profile.useBrightColorsForBold },
            set: { newValue in update { $0.useBrightColorsForBold = newValue } }
        ))
    }
}

/// FileDocument wrapper so fileExporter can save a profile
struct ProfileExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var profile: TerminalProfile

    var filename: String {
        profile.name
    }

    init(profile: TerminalProfile) {
        self.profile = profile
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct Envelope: Codable {
            var version: Int
            var profile: TerminalProfile
        }
        let data = try encoder.encode(Envelope(version: 1, profile: profile))
        return FileWrapper(regularFileWithContents: data)
    }
}
