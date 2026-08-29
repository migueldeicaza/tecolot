//
//  ThemeSectionView.swift
//  Tecolot
//
//  Shows and edits the active profile theme without loading the full browser.
//
import AppKit
import SwiftUI

struct ThemeSectionView: View {
    @ObservedObject var themes: ThemeStore
    let selectedThemeName: String
    /// Returns false when the selection could not be stored in the profile;
    /// operations then roll back instead of assuming it took effect.
    let onSelectTheme: (String) -> Bool

    @State private var workingTheme: TerminalTheme
    @State private var nameDraft: String
    @State private var saveTask: Task<Void, Never>?
    @State private var hasPendingSave = false
    @State private var selectionInFlight: String?
    @State private var operationError: String?
    @State private var showsChooser = false
    @FocusState private var nameIsFocused: Bool

    init(
        themes: ThemeStore,
        selectedThemeName: String,
        onSelectTheme: @escaping (String) -> Bool
    ) {
        self.themes = themes
        self.selectedThemeName = selectedThemeName
        self.onSelectTheme = onSelectTheme
        let selectedTheme = themes.theme(named: selectedThemeName)
        _workingTheme = State(initialValue: selectedTheme)
        _nameDraft = State(initialValue: selectedTheme.name)
    }

    private var storedTheme: TerminalTheme {
        themes.theme(named: selectedThemeName)
    }

    private var availableBaseThemeName: String? {
        guard !workingTheme.isBuiltIn,
              let baseThemeName = workingTheme.baseThemeName,
              themes.themes.contains(where: { $0.name == baseThemeName }) else {
            return nil
        }
        return baseThemeName
    }

    private var effectiveSelectionBackground: ProfileColor {
        workingTheme.selectionBackground
            ?? ProfileColor(swiftUIColor: Color(nsColor: .selectedTextBackgroundColor))
            ?? workingTheme.foreground
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ThemeHeaderRow(
                theme: workingTheme,
                nameDraft: $nameDraft,
                nameFocus: $nameIsFocused,
                baseThemeName: availableBaseThemeName,
                onRename: commitRename,
                onRevert: revertToBaseTheme,
                onDuplicate: duplicateTheme,
                onDelete: deleteTheme,
                onChoose: showThemeChooser
            )

            ThemePreview(theme: workingTheme, fontSize: 12, extended: true)
                .frame(maxWidth: .infinity)
                .frame(height: 150)
                .clipShape(.rect(cornerRadius: 8))

            ThemeMainColors(
                background: colorBinding(\.background),
                foreground: colorBinding(\.foreground),
                selection: optionalColorBinding(
                    \.selectionBackground,
                    effective: effectiveSelectionBackground
                ),
                cursor: optionalColorBinding(
                    \.cursor,
                    effective: workingTheme.cursor ?? workingTheme.foreground
                )
            )

            ThemeANSIColors(colors: (0..<16).map(ansiColorBinding(at:)))
        }
        .onChange(of: nameIsFocused) { wasFocused, isFocused in
            if wasFocused && !isFocused {
                commitRename()
            }
        }
        .onChange(of: selectedThemeName) { oldName, newName in
            selectedThemeChanged(from: oldName, to: newName)
        }
        .onChange(of: storedTheme) { _, newTheme in
            storedThemeChanged(to: newTheme)
        }
        .onDisappear(perform: flushPendingChanges)
        .sheet(isPresented: $showsChooser) {
            ThemeChooserSheet(
                themes: themes,
                selectedThemeName: selectedThemeName,
                onSelectTheme: selectTheme
            )
        }
        .alert("Theme Operation Failed", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("OK", role: .cancel) {
                operationError = nil
            }
        } message: {
            Text(operationError ?? "")
        }
    }

    private func colorBinding(
        _ keyPath: WritableKeyPath<TerminalTheme, ProfileColor>
    ) -> Binding<Color> {
        Binding(
            get: { workingTheme[keyPath: keyPath].swiftUIColor },
            set: { newColor in
                guard let profileColor = ProfileColor(swiftUIColor: newColor) else { return }
                applyEdit { $0[keyPath: keyPath] = profileColor }
            }
        )
    }

    private func optionalColorBinding(
        _ keyPath: WritableKeyPath<TerminalTheme, ProfileColor?>,
        effective: ProfileColor
    ) -> Binding<Color> {
        Binding(
            get: { (workingTheme[keyPath: keyPath] ?? effective).swiftUIColor },
            set: { newColor in
                guard let profileColor = ProfileColor(swiftUIColor: newColor) else { return }
                applyEdit { $0[keyPath: keyPath] = profileColor }
            }
        )
    }

    private func ansiColorBinding(at index: Int) -> Binding<Color> {
        Binding(
            get: {
                guard workingTheme.ansi.indices.contains(index) else {
                    return workingTheme.foreground.swiftUIColor
                }
                return workingTheme.ansi[index].swiftUIColor
            },
            set: { newColor in
                guard let profileColor = ProfileColor(swiftUIColor: newColor) else { return }
                applyEdit { theme in
                    guard theme.ansi.indices.contains(index) else { return }
                    theme.ansi[index] = profileColor
                }
            }
        )
    }

    private func applyEdit(_ mutate: (inout TerminalTheme) -> Void) {
        if workingTheme.isBuiltIn {
            let original = workingTheme
            var fork = themes.fork(of: original)
            mutate(&fork)
            workingTheme = fork
            nameDraft = fork.name
            selectionInFlight = fork.name
            do {
                try themes.saveUserTheme(fork)
                if !onSelectTheme(fork.name) {
                    selectionInFlight = nil
                    try? themes.deleteUserTheme(named: fork.name)
                    workingTheme = original
                    nameDraft = original.name
                }
            } catch {
                selectionInFlight = nil
                workingTheme = original
                nameDraft = original.name
                operationError = error.localizedDescription
            }
            return
        }

        var changed = workingTheme
        mutate(&changed)
        guard changed != workingTheme else { return }
        workingTheme = changed
        scheduleSave()
    }

    private func scheduleSave() {
        hasPendingSave = true
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            flushPendingChanges()
        }
    }

    private func flushPendingChanges() {
        saveTask?.cancel()
        saveTask = nil
        guard hasPendingSave, !workingTheme.isBuiltIn else { return }
        do {
            try themes.saveUserTheme(workingTheme, replacing: workingTheme.name)
            hasPendingSave = false
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func commitRename() {
        flushPendingChanges()
        let oldName = workingTheme.name
        let newName = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard newName != oldName else {
            nameDraft = oldName
            return
        }
        guard !newName.isEmpty else {
            nameDraft = oldName
            operationError = "Enter a theme name."
            return
        }
        guard !themes.themes.contains(where: {
            $0.name != oldName
                && $0.name.localizedCaseInsensitiveCompare(newName) == .orderedSame
        }) else {
            nameDraft = oldName
            operationError = "A theme with this name already exists."
            return
        }

        var renamed = workingTheme
        renamed.name = newName
        selectionInFlight = newName
        do {
            try themes.saveUserTheme(renamed, replacing: oldName)
            if onSelectTheme(newName) {
                workingTheme = renamed
                nameDraft = newName
            } else {
                selectionInFlight = nil
                try? themes.saveUserTheme(workingTheme, replacing: newName)
                nameDraft = oldName
            }
        } catch {
            selectionInFlight = nil
            nameDraft = oldName
            operationError = error.localizedDescription
        }
    }

    private func revertToBaseTheme() {
        guard let baseThemeName = availableBaseThemeName else { return }
        flushPendingChanges()
        do {
            try themes.deleteUserTheme(named: workingTheme.name)
            selectTheme(baseThemeName)
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func duplicateTheme() {
        flushPendingChanges()
        let copy = themes.duplicate(of: workingTheme)
        do {
            try themes.saveUserTheme(copy)
            selectTheme(copy.name)
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func deleteTheme() {
        guard !workingTheme.isBuiltIn else { return }
        flushPendingChanges()
        let nextName = availableBaseThemeName ?? TerminalTheme.fallback.name
        do {
            try themes.deleteUserTheme(named: workingTheme.name)
            selectTheme(nextName)
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func showThemeChooser() {
        showsChooser = true
    }

    private func selectTheme(_ name: String) {
        flushPendingChanges()
        // Selecting the already-active theme fires no selection change, so the
        // in-flight marker would never be cleared and block store reseeds.
        if name != selectedThemeName {
            selectionInFlight = name
        }
        if !onSelectTheme(name) {
            selectionInFlight = nil
            reseed(with: themes.theme(named: selectedThemeName))
        }
    }

    private func selectedThemeChanged(from oldName: String, to newName: String) {
        if oldName != newName {
            flushPendingChanges()
        }
        if selectionInFlight == newName {
            selectionInFlight = nil
        }
        reseed(with: themes.theme(named: newName))
    }

    private func storedThemeChanged(to newTheme: TerminalTheme) {
        guard !hasPendingSave, selectionInFlight == nil else { return }
        guard newTheme != workingTheme else { return }
        reseed(with: newTheme)
    }

    private func reseed(with theme: TerminalTheme) {
        saveTask?.cancel()
        saveTask = nil
        hasPendingSave = false
        workingTheme = theme
        nameDraft = theme.name
    }
}

struct ThemeChooserSheet: View {
    @ObservedObject var themes: ThemeStore
    let selectedThemeName: String
    let onSelectTheme: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text("Choose a Theme")
                .font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            Divider()
            ThemeBrowserView(
                themes: themes,
                selectedThemeName: selectedThemeName,
                onSelect: { onSelectTheme($0.name) },
                style: .all,
                onDone: { dismiss() }
            )
        }
        .frame(width: 640, height: 520)
    }
}

private struct ThemeHeaderRow: View {
    let theme: TerminalTheme
    @Binding var nameDraft: String
    let nameFocus: FocusState<Bool>.Binding
    let baseThemeName: String?
    let onRename: () -> Void
    let onRevert: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    let onChoose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if theme.isBuiltIn {
                Text(theme.name)
                    .font(.headline)
            } else {
                TextField("Theme name", text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.headline)
                    .focused(nameFocus)
                    .onSubmit {
                        onRename()
                        nameFocus.wrappedValue = false
                    }
                    .frame(minWidth: 100, maxWidth: 180)
            }
            Spacer(minLength: 4)
            if let baseThemeName {
                Button("Revert to \(baseThemeName)", action: onRevert)
            }
            Button("Duplicate", action: onDuplicate)
            if !theme.isBuiltIn {
                Button("Delete", role: .destructive, action: onDelete)
            }
            Button("Change Theme…", action: onChoose)
        }
        .controlSize(.small)
    }
}

private struct ThemeMainColors: View {
    let background: Binding<Color>
    let foreground: Binding<Color>
    let selection: Binding<Color>
    let cursor: Binding<Color>

    var body: some View {
        HStack(spacing: 16) {
            ThemeColorSwatch("Background", color: background)
            ThemeColorSwatch("Text", color: foreground)
            ThemeColorSwatch("Selection", color: selection)
            ThemeColorSwatch("Cursor", color: cursor)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ThemeANSIColors: View {
    let colors: [Binding<Color>]

    private static let names: [LocalizedStringKey] = [
        "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
        "bright black", "bright red", "bright green", "bright yellow",
        "bright blue", "bright magenta", "bright cyan", "bright white"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ANSI Colors")
                .font(.headline)
            Grid(horizontalSpacing: 8, verticalSpacing: 10) {
                GridRow {
                    ForEach(0..<8, id: \.self) { index in
                        ThemeColorSwatch(Self.names[index], color: colors[index])
                    }
                }
                GridRow {
                    ForEach(8..<16, id: \.self) { index in
                        ThemeColorSwatch(Self.names[index], color: colors[index])
                    }
                }
            }
        }
    }
}

private struct ThemeColorSwatch: View {
    let label: LocalizedStringKey
    let color: Binding<Color>

    init(_ label: LocalizedStringKey, color: Binding<Color>) {
        self.label = label
        self.color = color
    }

    var body: some View {
        VStack(spacing: 4) {
            ColorPicker(label, selection: color, supportsOpacity: false)
                .labelsHidden()
                .accessibilityLabel(Text(label))
            Text(label)
                .font(.caption2)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview("Theme Section") {
    @Previewable @State var selectedThemeName = SettingsPreviewData.profile.themeName

    Form {
        Section {
            ThemeSectionView(
                themes: SettingsPreviewData.themes,
                selectedThemeName: selectedThemeName,
                onSelectTheme: { selectedThemeName = $0; return true }
            )
        } header: {
            Text("Theme")
        }
    }
    .formStyle(.grouped)
    .frame(width: 720, height: 520)
}
