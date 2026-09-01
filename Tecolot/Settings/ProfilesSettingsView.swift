//
//  ProfilesSettingsView.swift
//  Tecolot
//
//  Profile management. Profile settings live in the separate sidebar pages.
//
import SwiftUI
import AppKit
import SwiftTerm
import UniformTypeIdentifiers

struct ProfilesSettingsView: View {
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var themes: ThemeStore
    @Binding var activeProfileID: TerminalProfile.ID?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDocument: ProfileExportDocument?
    @State private var errorMessage: String?
    @State private var renameTarget: TerminalProfile?
    @State private var renameText = ""

    private var selectedProfile: TerminalProfile? {
        activeProfileID.flatMap { profiles.profile(withID: $0) }
    }

    var body: some View {
        Group {
            if profiles.profiles.isEmpty {
                ContentUnavailableView {
                    Label("No Profiles", systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text("Create a profile to customize terminal settings.")
                } actions: {
                    Button("Create Profile", action: addProfile)
                }
            } else {
                profileList
            }
        }
        .onAppear {
            repairActiveProfileSelection()
        }
        .onChange(of: profiles.profiles.map(\.id)) {
            repairActiveProfileSelection()
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                let gotAccess = url.startAccessingSecurityScopedResource()
                defer { if gotAccess { url.stopAccessingSecurityScopedResource() } }
                do {
                    activeProfileID = try profiles.importProfile(from: url).id
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
        .alert("Rename Profile", isPresented: renamePresentation) {
            TextField("Name", text: $renameText)
            Button("Rename", action: renameProfile)
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {
                renameTarget = nil
            }
        } message: {
            Text("Enter a new name for the profile.")
        }
    }

    private var profileList: some View {
        VStack(spacing: 0) {
            List(selection: $activeProfileID) {
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
                    deleteSelectedProfile()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(activeProfileID == nil || profiles.profiles.count <= 1)

                Menu {
                    Button("Duplicate", action: duplicateSelectedProfile)
                        .disabled(selectedProfile == nil)
                    Button("Rename…", action: presentRename)
                        .disabled(selectedProfile == nil)
                    Button("Set as Default", action: setSelectedProfileAsDefault)
                        .disabled(selectedProfile == nil)
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
                    Button("Export…", action: exportSelectedProfile)
                        .disabled(selectedProfile == nil)
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

    private func addProfile() {
        var profile = profiles.defaultProfile
        profile.id = UUID()
        profile.name = uniqueName(basedOn: "New Profile")
        do {
            try profiles.add(profile)
            activeProfileID = profile.id
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
            activeProfileID = profile.id
        } catch {
            report(error)
        }
    }

    private func deleteSelectedProfile() {
        guard let activeProfileID else { return }
        do {
            try profiles.delete(activeProfileID)
            self.activeProfileID = profiles.defaultProfileID
        } catch {
            report(error)
        }
    }

    private func duplicateSelectedProfile() {
        guard let activeProfileID else { return }
        do {
            self.activeProfileID = try profiles.duplicate(activeProfileID).id
        } catch {
            report(error)
        }
    }

    private func presentRename() {
        guard let profile = selectedProfile else { return }
        renameTarget = profile
        renameText = profile.name
    }

    private func renameProfile() {
        guard let renameTarget else { return }
        do {
            try profiles.rename(
                renameTarget.id,
                to: renameText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            self.renameTarget = nil
        } catch {
            report(error)
        }
    }

    private func setSelectedProfileAsDefault() {
        guard let activeProfileID else { return }
        do {
            try profiles.setDefault(activeProfileID)
        } catch {
            report(error)
        }
    }

    private func exportSelectedProfile() {
        guard let profile = selectedProfile else { return }
        exportDocument = ProfileExportDocument(profile: profile)
        showExporter = true
    }

    private func repairActiveProfileSelection() {
        if let activeProfileID,
           profiles.profile(withID: activeProfileID) != nil {
            return
        }
        activeProfileID = profiles.profiles.isEmpty ? nil : profiles.defaultProfileID
    }

    private func uniqueName(basedOn base: String) -> String {
        var name = base
        var number = 2
        while profiles.profile(named: name) != nil {
            name = "\(base) \(number)"
            number += 1
        }
        return name
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

    private var renamePresentation: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }
}

enum ProfileSettingsSection {
    case text
    case window
    case shell
    case keyboard
    case advanced

    init?(destination: SettingsDestination) {
        switch destination {
        case .text: self = .text
        case .window: self = .window
        case .shell: self = .shell
        case .keyboard: self = .keyboard
        case .advanced: self = .advanced
        case .general, .profiles, .data: return nil
        }
    }

    var title: String {
        switch self {
        case .text: return "Appearance"
        case .window: return "Window"
        case .shell: return "Shell"
        case .keyboard: return "Keyboard"
        case .advanced: return "Advanced"
        }
    }
}

/// A single group of settings for the active profile.
struct ProfileSettingsPage: View {
    let section: ProfileSettingsSection
    let profile: TerminalProfile
    /// Reports whether the change was stored; most controls ignore the
    /// result, but theme operations roll back on failure.
    let update: ((inout TerminalProfile) -> Void) -> Bool

    @EnvironmentObject private var themes: ThemeStore

    /// Adapter for child views that have no rollback path of their own.
    private var updateIgnoringResult: ((inout TerminalProfile) -> Void) -> Void {
        { mutate in _ = update(mutate) }
    }

    var body: some View {
        Group {
            switch section {
            case .text:
                textSettings
            case .window:
                windowSettings
            case .shell:
                shellSettings
            case .keyboard:
                keyboardSettings
            case .advanced:
                advancedSettings
            }
        }
        .formStyle(.grouped)
        .navigationTitle(section.title)
    }

    private var textSettings: some View {
        Form {
            Section {
                ProfileTextSettings(profile: profile, update: updateIgnoringResult)
                    .padding(.horizontal)
                    .frame(maxHeight: 190)
            }
            Section {
                ThemeSectionView(
                    themes: themes,
                    selectedThemeName: profile.themeName,
                    onSelectTheme: { themeName in
                        update { $0.themeName = themeName }
                    }
                )
            } header: {
                Text("Theme")
            }
            Section {
                Toggle(
                    "Match window chrome to theme",
                    isOn: binding(\.useThemeColorsForWindowChrome)
                )
            } header: {
                Text("Window chrome")
            } footer: {
                Text("Applies the theme to the title bar, tabs, and toolbar controls. Turn this off to follow the system appearance.")
            }
        }
    }

    @ViewBuilder
    private var windowSettings: some View {
        Form {
            Section {
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
            Section("Title") {
                TextField("Custom title:", text: Binding(
                    get: { profile.titleOverride ?? "" },
                    set: { newValue in update { $0.titleOverride = newValue.isEmpty ? nil : newValue } }
                ), prompt: Text("Default"))
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
    }

    @ViewBuilder
    private var shellSettings: some View {
        Form {
            Section {
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
        }
    }

    @ViewBuilder
    private var keyboardSettings: some View {
        Form {
            Section {
                Toggle("Use Option as Meta key", isOn: binding(\.optionAsMetaKey))
                Toggle("Delete sends Control-H", isOn: binding(\.backspaceSendsControlH))
            }
            Section("Key Mappings"){
                TerminalKeyBindingsEditor(profile: profile, update: updateIgnoringResult)
            }
        }
    }

    @ViewBuilder
    private var advancedSettings: some View {
        Form {
            Section {
                LabeledContent("Declare terminal as:") {
                    TerminalNameComboBox(text: binding(\.termName))
                }
                if profile.termName == "xterm-ghostty" {
                    TextField("TERM_PROGRAM:", text: binding(\.termProgram))
                    TextField("TERM_VERSION:", text: binding(\.termVersion))
                }
                Picker("Bell:", selection: binding(\.bellStyle)) {
                    ForEach(BellStyle.allCases, id: \.tagName) { style in
                        Text(style.displayName).tag(style)
                    }
                }
            }
            Section {
                Text("Tecolot inherits the app environment, then applies these changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(profile.environmentVariables) { variable in
                    EnvironmentVariableRow(variable: variable) { replacement in
                        update { profile in
                            guard let index = profile.environmentVariables.firstIndex(where: { $0.id == replacement.id }) else {
                                return
                            }
                            profile.environmentVariables[index] = replacement
                        }
                    } remove: {
                        update { profile in
                            profile.environmentVariables.removeAll { $0.id == variable.id }
                        }
                    }
                }
                Button("Add Environment Variable") {
                    update {
                        $0.environmentVariables.append(TerminalEnvironmentVariable(name: "", value: ""))
                    }
                }
            } header: {
                Text("Environment")
            } footer: {
                Text("Unset removes an inherited value. An empty value is passed as an empty string. Later entries with the same name win.")
            }
        }
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

private struct TerminalNameComboBox: NSViewRepresentable {
    private static let fallbackValue = "xterm-256color"
    private static let values = [
        fallbackValue,
        "xterm-color",
        "xterm",
        "vt100",
        "xterm-ghostty"
    ]

    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, fallbackValue: Self.fallbackValue)
    }

    func makeNSView(context: Context) -> NSComboBox {
        let comboBox = NSComboBox()
        comboBox.addItems(withObjectValues: Self.values)
        comboBox.isEditable = true
        comboBox.completes = true
        comboBox.delegate = context.coordinator
        comboBox.stringValue = text
        comboBox.setAccessibilityLabel(String(localized: "Declare terminal as"))
        return comboBox
    }

    func updateNSView(_ comboBox: NSComboBox, context: Context) {
        context.coordinator.text = $text
        if comboBox.stringValue != text {
            comboBox.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var text: Binding<String>
        let fallbackValue: String

        init(text: Binding<String>, fallbackValue: String) {
            self.text = text
            self.fallbackValue = fallbackValue
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox else { return }
            text.wrappedValue = comboBox.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard
                let comboBox = notification.object as? NSComboBox,
                comboBox.stringValue.isEmpty
            else { return }
            comboBox.stringValue = fallbackValue
            text.wrappedValue = fallbackValue
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard
                let comboBox = notification.object as? NSComboBox,
                let selectedValue = comboBox.objectValueOfSelectedItem as? String
            else { return }
            comboBox.stringValue = selectedValue
            text.wrappedValue = selectedValue
        }
    }
}

private struct EnvironmentVariableRow: View {
    let variable: TerminalEnvironmentVariable
    let update: (TerminalEnvironmentVariable) -> Void
    let remove: () -> Void

    var body: some View {
        HStack {
            TextField("Name", text: Binding(
                get: { variable.name },
                set: { newName in
                    var replacement = variable
                    replacement.name = newName
                    update(replacement)
                }
            ))
            .frame(minWidth: 120)

            if variable.value != nil {
                TextField("Value", text: Binding(
                    get: { variable.value ?? "" },
                    set: { newValue in
                        var replacement = variable
                        replacement.value = newValue
                        update(replacement)
                    }
                ))
            }

            Toggle("Unset", isOn: Binding(
                get: { variable.value == nil },
                set: { isUnset in
                    var replacement = variable
                    replacement.value = isUnset ? nil : ""
                    update(replacement)
                }
            ))
            .toggleStyle(.checkbox)

            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove environment variable")
        }
    }
}

struct TerminalKeyBindingsEditor: View {
    let profile: TerminalProfile
    let update: ((inout TerminalProfile) -> Void) -> Void

    var body: some View {
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

/// Font, cursor, and opacity fields for the Text settings page.
struct ProfileTextSettings: View {
    let profile: TerminalProfile
    let update: ((inout TerminalProfile) -> Void) -> Void

    var body: some View {
        ProfileTextSettingsFields(profile: profile, update: update)
    }
}

struct ProfileTextSettingsFields: View {
    let profile: TerminalProfile
    let update: ((inout TerminalProfile) -> Void) -> Void
    @State private var fontPanelManager = FontPanelManager()
    @State private var backgroundOpacityPreview: Double
    @State private var isEditingBackgroundOpacity = false

    init(
        profile: TerminalProfile,
        update: @escaping ((inout TerminalProfile) -> Void) -> Void
    ) {
        self.profile = profile
        self.update = update
        _backgroundOpacityPreview = State(initialValue: profile.backgroundOpacity)
    }

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
            Slider(
                value: $backgroundOpacityPreview,
                in: 0.3...1.0,
                onEditingChanged: backgroundOpacityEditingChanged
            )
            .frame(maxWidth: 200)
        }
        .onChange(of: backgroundOpacityPreview) { _, newValue in
            TerminalSessionRegistry.shared.previewBackgroundOpacity(
                newValue,
                forProfileID: profile.id
            )
        }
        .onChange(of: profile.backgroundOpacity) { _, newValue in
            if !isEditingBackgroundOpacity {
                backgroundOpacityPreview = newValue
            }
        }
        .onChange(of: profile.id) { oldID, _ in
            TerminalSessionRegistry.shared.previewBackgroundOpacity(nil, forProfileID: oldID)
            backgroundOpacityPreview = profile.backgroundOpacity
        }
        .onDisappear {
            TerminalSessionRegistry.shared.previewBackgroundOpacity(nil, forProfileID: profile.id)
        }
    }

    private func backgroundOpacityEditingChanged(_ isEditing: Bool) {
        isEditingBackgroundOpacity = isEditing
        guard !isEditing else { return }
        update { $0.backgroundOpacity = backgroundOpacityPreview }
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

#Preview("Profiles") {
    @Previewable @State var activeProfileID: TerminalProfile.ID? = SettingsPreviewData.profiles.defaultProfileID

    ProfilesSettingsView(activeProfileID: $activeProfileID)
        .environmentObject(SettingsPreviewData.profiles)
        .environmentObject(SettingsPreviewData.themes)
        .environmentObject(SettingsPreviewData.themeIndex)
        .frame(width: 640, height: 520)
}

#Preview("Text Settings") {
    ProfileSettingsPagePreview(section: .text)
        .environmentObject(SettingsPreviewData.themes)
        .environmentObject(SettingsPreviewData.themeIndex)
        .frame(width: 720, height: 720)
}

#Preview("Window Settings") {
    ProfileSettingsPagePreview(section: .window)
        .environmentObject(SettingsPreviewData.themes)
        .frame(width: 560, height: 430)
}

#Preview("Shell Settings") {
    ProfileSettingsPagePreview(section: .shell)
        .environmentObject(SettingsPreviewData.themes)
        .frame(width: 560, height: 430)
}

#Preview("Keyboard Settings") {
    ProfileSettingsPagePreview(section: .keyboard)
        .environmentObject(SettingsPreviewData.themes)
        .frame(width: 560, height: 430)
}

#Preview("Advanced Settings") {
    ProfileSettingsPagePreview(section: .advanced)
        .environmentObject(SettingsPreviewData.themes)
        .frame(width: 680, height: 480)
}

#Preview("Key Bindings Editor") {
    TerminalKeyBindingsEditor(profile: SettingsPreviewData.profile, update: { _ in })
        .padding()
        .frame(width: 560)
}

#Preview("Key Binding Row") {
    TerminalKeyBindingRow(
        keyBinding: SettingsPreviewData.keyBinding,
        update: { _ in },
        remove: {}
    )
    .padding()
    .frame(width: 560)
}

#Preview("Text Controls") {
    Form {
        ProfileTextSettings(profile: SettingsPreviewData.profile, update: { _ in })
    }
    .formStyle(.grouped)
        .frame(width: 560, height: 250)

}

#Preview("Text Fields") {
    Form {
        ProfileTextSettingsFields(profile: SettingsPreviewData.profile, update: { _ in })
    }
    .formStyle(.grouped)
    .frame(width: 560, height: 250)
}

/// Keeps profile-page preview changes local to the preview canvas.
private struct ProfileSettingsPagePreview: View {
    let section: ProfileSettingsSection
    @State private var profile = SettingsPreviewData.profile

    var body: some View {
        ProfileSettingsPage(section: section, profile: profile, update: apply)
    }

    private func apply(_ mutate: (inout TerminalProfile) -> Void) -> Bool {
        mutate(&profile)
        return true
    }
}
