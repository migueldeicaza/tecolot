//
//  ProfilesSettingsView.swift
//  Tecolot
//
//  The advanced pane: full profile CRUD and every profile field, organized
//  as sections that mirror Terminal.app's Text/Window/Shell/Keyboard/
//  Advanced grouping.
//
import SwiftUI
import AppKit
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
    @State private var errorMessage: String?

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
                selection = profiles.profiles.isEmpty ? nil : profiles.defaultProfileID
            }
        }
        .onChange(of: profiles.profiles.map(\.id)) {
            guard let selection,
                  profiles.profile(withID: selection) == nil else { return }
            self.selection = profiles.profiles.isEmpty ? nil : profiles.defaultProfileID
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                let gotAccess = url.startAccessingSecurityScopedResource()
                defer { if gotAccess { url.stopAccessingSecurityScopedResource() } }
                do {
                    selection = try profiles.importProfile(from: url).id
                } catch {
                    report(error)
                }
            case .failure(let error):
                report(error)
            }
        }
        .fileExporter(isPresented: $showExporter,
                      document: exportDocument,
                      contentType: .json,
                      defaultFilename: exportDocument?.filename ?? "Profile") { result in
            if case .failure(let error) = result {
                report(error)
            }
            exportDocument = nil
        }
        .alert("Could Not Change Profile", isPresented: errorPresentation) {
            Button("OK") {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
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
                        do {
                            try profiles.delete(selection)
                            self.selection = profiles.defaultProfileID
                        } catch {
                            report(error)
                        }
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil || profiles.profiles.count <= 1)

                Menu {
                    Button("Duplicate") {
                        if let selection {
                            do {
                                self.selection = try profiles.duplicate(selection).id
                            } catch {
                                report(error)
                            }
                        }
                    }
                    Button("Set as Default") {
                        if let selection {
                            do {
                                try profiles.setDefault(selection)
                            } catch {
                                report(error)
                            }
                        }
                    }
                    Menu("New from Preset") {
                        Button("Pro") {
                            addPreset(name: "Pro", theme: "Pro", fontSize: 12)
                        }
                        Button("Homebrew") {
                            addPreset(name: "Homebrew", theme: "Homebrew", fontSize: 13)
                        }
                        Button("Man Page") {
                            addPreset(name: "Man Page", theme: "Man Page", fontSize: 12)
                        }
                        Button("Solarized Light") {
                            addPreset(
                                name: "Solarized Light",
                                theme: "iTerm2 Solarized Light",
                                fontSize: 12
                            )
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
                update(profile, mutate: mutate)
            }
        } else {
            ContentUnavailableView {
                Label("No Profiles", systemImage: "person.crop.circle")
            } description: {
                Text("Create a profile to customize terminal settings.")
            } actions: {
                Button("Create Profile", action: addProfile)
            }
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
        do {
            try profiles.add(profile)
            selection = profile.id
        } catch {
            report(error)
        }
    }

    private func addPreset(name: String, theme: String, fontSize: Double) {
        var uniqueName = name
        var counter = 2
        while profiles.profile(named: uniqueName) != nil {
            uniqueName = "\(name) \(counter)"
            counter += 1
        }
        var profile = TerminalProfile(name: uniqueName)
        profile.themeName = themes.theme(named: theme).name
        profile.fontSize = fontSize
        do {
            try profiles.add(profile)
            selection = profile.id
        } catch {
            report(error)
        }
    }

    private func update(
        _ profile: TerminalProfile,
        mutate: (inout TerminalProfile) -> Void
    ) {
        var updated = profile
        mutate(&updated)
        do {
            try profiles.update(updated)
        } catch {
            report(error)
        }
    }

    private var errorPresentation: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func report(_ error: Error) {
        errorMessage = error.localizedDescription
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
                GroupBox("Title") {
                    TextField("Custom title:", text: Binding(
                        get: { profile.titleOverride ?? "" },
                        set: { newValue in update { $0.titleOverride = newValue.isEmpty ? nil : newValue } }
                    ))
                    ForEach(TerminalTitleComponent.allCases, id: \.self) { component in
                        Toggle(titleComponentLabel(component), isOn: Binding(
                            get: { profile.titleComponents.contains(component) },
                            set: { isEnabled in
                                update {
                                    if isEnabled {
                                        $0.titleComponents.insert(component)
                                    } else {
                                        $0.titleComponents.remove(component)
                                    }
                                }
                            }
                        ))
                    }
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
                TerminalKeyBindingsEditor(profile: profile, update: update)
            }
            Section("Advanced") {
                TextField("Declare terminal as:", text: binding(\.termName))
                Picker("Bell:", selection: binding(\.bellStyle)) {
                    ForEach(BellStyle.allCases, id: \.tagName) { style in
                        Text(style.displayName).tag(style)
                    }
                }
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

    private func titleComponentLabel(_ component: TerminalTitleComponent) -> String {
        switch component {
        case .activeTitle: return "Active title"
        case .workingDirectory: return "Working directory"
        case .fullPath: return "Full path"
        case .profileName: return "Profile name"
        case .dimensions: return "Dimensions"
        }
    }
}

struct TerminalKeyBindingsEditor: View {
    let profile: TerminalProfile
    let update: ((inout TerminalProfile) -> Void) -> Void

    var body: some View {
        GroupBox("Key mappings") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(profile.keyBindings) { keyBinding in
                    TerminalKeyBindingRow(
                        keyBinding: keyBinding,
                        update: { replace(keyBinding.id, with: $0) },
                        remove: { remove(keyBinding.id) }
                    )
                }

                Button("Add Key Mapping", systemImage: "plus", action: add)
                    .buttonStyle(.borderless)
            }
        }
    }

    private func add() {
        update {
            $0.keyBindings.append(
                TerminalKeyBinding(key: "", modifiers: [.command], action: .sendText)
            )
        }
    }

    private func replace(_ id: UUID, with keyBinding: TerminalKeyBinding) {
        update { profile in
            guard let index = profile.keyBindings.firstIndex(where: { $0.id == id }) else { return }
            profile.keyBindings[index] = keyBinding
        }
    }

    private func remove(_ id: UUID) {
        update { $0.keyBindings.removeAll { $0.id == id } }
    }
}

private struct TerminalKeyBindingRow: View {
    let keyBinding: TerminalKeyBinding
    let update: (TerminalKeyBinding) -> Void
    let remove: () -> Void

    var body: some View {
        HStack {
            TextField("Key", text: valueBinding(\.key))
                .frame(width: 70)
                .accessibilityLabel("Key")

            Menu(modifierLabel) {
                Toggle("Command", isOn: modifierBinding(.command))
                Toggle("Shift", isOn: modifierBinding(.shift))
                Toggle("Option", isOn: modifierBinding(.option))
                Toggle("Control", isOn: modifierBinding(.control))
            }
            .frame(width: 90)

            Picker("Action", selection: valueBinding(\.action)) {
                ForEach(TerminalKeyAction.allCases, id: \.self) { action in
                    Text(action.displayName).tag(action)
                }
            }
            .labelsHidden()

            TextField("Value", text: valueBinding(\.value))
                .disabled(!keyBinding.action.usesValue)
                .accessibilityLabel("Text or escape sequence")

            Button("Remove", systemImage: "minus.circle", action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
    }

    private var modifierLabel: String {
        var labels: [String] = []
        if keyBinding.modifiers.contains(.control) { labels.append("⌃") }
        if keyBinding.modifiers.contains(.option) { labels.append("⌥") }
        if keyBinding.modifiers.contains(.shift) { labels.append("⇧") }
        if keyBinding.modifiers.contains(.command) { labels.append("⌘") }
        return labels.isEmpty ? "None" : labels.joined()
    }

    private func valueBinding<Value>(
        _ keyPath: WritableKeyPath<TerminalKeyBinding, Value>
    ) -> Binding<Value> {
        Binding(
            get: { keyBinding[keyPath: keyPath] },
            set: { newValue in
                var changed = keyBinding
                changed[keyPath: keyPath] = newValue
                update(changed)
            }
        )
    }

    private func modifierBinding(_ modifier: TerminalKeyModifiers) -> Binding<Bool> {
        Binding(
            get: { keyBinding.modifiers.contains(modifier) },
            set: { enabled in
                var changed = keyBinding
                if enabled {
                    changed.modifiers.insert(modifier)
                } else {
                    changed.modifiers.remove(modifier)
                }
                update(changed)
            }
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
    @State private var fontPanelManager = FontPanelManager()

    var body: some View {
        HStack {
            Button(action: showFontPanel) {
                LabeledContent("Font:") {
                    Text(fontDescription)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)

            if profile.fontFamily != nil {
                Button(action: resetFont) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Use system monospaced font")
            }
        }
        .onAppear(perform: configureFontPanel)
        .onChange(of: profile) {
            configureFontPanel()
        }
        Picker("Cursor:", selection: Binding(
            get: { profile.cursorStyle },
            set: { newValue in update { $0.cursorStyle = newValue } }
        )) {
            ForEach(CursorStyle.allCases, id: \.tagName) { style in
                Text(style.displayName).tag(style)
            }
        }
        Toggle("Use bright colors for bold text", isOn: Binding(
            get: { profile.useBrightColorsForBold },
            set: { newValue in update { $0.useBrightColorsForBold = newValue } }
        ))
        LabeledContent("Background opacity:") {
            Slider(value: Binding(
                get: { profile.backgroundOpacity },
                set: { newValue in update { $0.backgroundOpacity = newValue } }
            ), in: 0.3...1.0)
            .frame(maxWidth: 200)
        }
    }

    private var fontDescription: String {
        let fontName = profile.fontFamily.flatMap {
            NSFont(name: $0, size: CGFloat(profile.fontSize))?.displayName
        } ?? profile.fontFamily ?? "System Monospaced"
        return "\(fontName) - \(Int(profile.fontSize)) pt"
    }

    private func showFontPanel() {
        configureFontPanel()
        fontPanelManager.showFontPanel(
            fontName: profile.fontFamily,
            size: CGFloat(profile.fontSize)
        )
    }

    private func configureFontPanel() {
        fontPanelManager.onSelect = { font in
            guard font.pointSize.isFinite, font.pointSize > 0 else { return }
            update {
                $0.fontFamily = font.fontName
                $0.fontSize = Double(font.pointSize)
            }
        }
    }

    private func resetFont() {
        update { $0.fontFamily = nil }
    }
}

@MainActor
final class FontPanelManager: NSObject {
    var onSelect: ((NSFont) -> Void)?
    private var currentFont: NSFont

    override init() {
        currentFont = NSFont.monospacedSystemFont(
            ofSize: NSFont.systemFontSize,
            weight: .regular
        )
        super.init()
    }

    func showFontPanel(fontName: String?, size: CGFloat) {
        currentFont = resolveFont(fontName: fontName, size: size)

        let manager = NSFontManager.shared
        let panel = NSFontPanel.shared

        if panel.isVisible {
            complete()
            return
        }

        panel.delegate = self
        manager.target = self
        manager.action = #selector(changeFont(_:))
        panel.setPanelFont(currentFont, isMultiple: false)
        panel.makeKeyAndOrderFront(nil)
    }

    private func resolveFont(fontName: String?, size: CGFloat) -> NSFont {
        guard let fontName,
              let font = NSFont(name: fontName, size: size) else {
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return font
    }

    @objc private func changeFont(_ sender: NSFontManager?) {
        guard let sender else { return }
        let font = sender.convert(currentFont)
        guard font.isFixedPitch else { return }
        currentFont = font
        onSelect?(font)
    }

    private func complete() {
        let manager = NSFontManager.shared
        if manager.target === self {
            manager.target = nil
        }

        let panel = NSFontPanel.shared
        if panel.delegate === self {
            panel.delegate = nil
        }
        panel.orderOut(nil)
    }
}

extension FontPanelManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        complete()
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
