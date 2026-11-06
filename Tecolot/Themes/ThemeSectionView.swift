//
//  ThemeSectionView.swift
//  Tecolot
//
//  The Light Mode and Dark Mode theme rows of the profile Appearance page.
//  Each row shows small theme cards in groups (Custom, Default, Favorites).
//  A click selects the theme for that mode; a context menu edits,
//  duplicates or deletes it. "New" opens the editor for a new theme.
//
import AppKit
import SwiftUI

/// The groups of cards in one mode row. A pure function, so that tests can
/// check it.
nonisolated enum ThemeModeGroups {
    struct Group: Identifiable, Equatable {
        let title: String
        let themes: [TerminalTheme]
        var id: String { title }
    }

    static func groups(
        themes: [TerminalTheme],
        favorites: Set<String>,
        defaultName: String,
        activeName: String
    ) -> [Group] {
        func byName(_ lhs: TerminalTheme, _ rhs: TerminalTheme) -> Bool {
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        let custom = themes.filter { !$0.isBuiltIn }.sorted(by: byName)
        let defaults = themes.filter { $0.name == defaultName }
        var favorite = themes
            .filter { $0.isBuiltIn && $0.name != defaultName && favorites.contains($0.name) }
            .sorted(by: byName)

        // Always show the active theme, so that the selection is visible.
        let shown = Set((custom + defaults + favorite).map(\.name))
        if !shown.contains(activeName), let active = themes.first(where: { $0.name == activeName }) {
            favorite.insert(active, at: 0)
        }

        return [
            Group(title: "Custom", themes: custom),
            Group(title: "Default", themes: defaults),
            Group(title: "Favorites", themes: favorite)
        ].filter { !$0.themes.isEmpty }
    }
}

/// One mode row: a Form section with a header that has a "New" button.
struct ThemeModeSection: View {
    let isDark: Bool
    let profile: TerminalProfile
    @ObservedObject var themes: ThemeStore
    /// Reports whether the change was stored.
    let update: ((inout TerminalProfile) -> Void) -> Bool

    @EnvironmentObject private var themeIndex: ThemeCatalogIndex
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var systemAppearance: SystemAppearance

    @State private var editorRequest: EditorRequest?
    @State private var showsChooser = false
    @State private var selectedPreviewPage: ThemePreviewPage? = .shell
    @State private var themePendingDeletion: TerminalTheme?
    @State private var operationError: String?

    private struct EditorRequest: Identifiable {
        let id = UUID()
        let theme: TerminalTheme
        /// The user theme that the editor replaces; nil for a new theme.
        let existingUserThemeName: String?
    }

    private var activeName: String {
        profile.themeName(isDark: isDark)
    }

    private var groups: [ThemeModeGroups.Group] {
        ThemeModeGroups.groups(
            themes: themes.themes,
            favorites: themes.favorites,
            defaultName: TerminalProfile.defaultThemeName(isDark: isDark),
            activeName: activeName
        )
    }

    var body: some View {
        Section {
            strip
                .sheet(item: $editorRequest) { request in
                    ThemeEditorView(
                        theme: request.theme,
                        themes: themes,
                        existingUserThemeName: request.existingUserThemeName,
                        onSave: { saved in
                            didSave(saved, replacing: request.existingUserThemeName)
                        }
                    )
                }
                .sheet(isPresented: $showsChooser) {
                    ThemeChooserSheet(
                        themes: themes,
                        themeIndex: themeIndex,
                        selectedThemeName: activeName,
                        selectedPreviewPage: $selectedPreviewPage,
                        onSelectTheme: chooseFromCatalog
                    )
                }
                .confirmationDialog(
                    "Delete \u{201C}\(themePendingDeletion?.name ?? "")\u{201D}?",
                    isPresented: Binding(
                        get: { themePendingDeletion != nil },
                        set: { if !$0 { themePendingDeletion = nil } }
                    ),
                    presenting: themePendingDeletion
                ) { theme in
                    Button("Delete", role: .destructive) { delete(theme) }
                } message: { _ in
                    Text("Profiles that use this theme change to another theme.")
                }
                .alert("Theme Operation Failed", isPresented: Binding(
                    get: { operationError != nil },
                    set: { if !$0 { operationError = nil } }
                )) {
                    Button("OK", role: .cancel) { operationError = nil }
                } message: {
                    Text(operationError ?? "")
                }
        } header: {
            header
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(isDark ? "Dark Mode" : "Light Mode")
                .font(.headline)
            if systemAppearance.isDark == isDark {
                Text("\u{2014} Active")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("New", systemImage: "plus.circle", action: newTheme)
                .buttonStyle(.borderless)
                .help(isDark ? "Make a new dark theme" : "Make a new light theme")
        }
    }

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { offset, group in
                        if offset > 0 {
                            Divider()
                                .frame(height: 70)
                                .padding(.top, 22)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.title)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(group.themes) { theme in
                                    card(for: theme)
                                        .id(theme.name)
                                }
                            }
                        }
                    }
                    Divider()
                        .frame(height: 70)
                        .padding(.top, 22)
                    ThemeBrowseCard { showsChooser = true }
                        .padding(.top, 22)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.automatic)
            .onAppear { proxy.scrollTo(activeName, anchor: .center) }
        }
    }

    private func card(for theme: TerminalTheme) -> some View {
        ThemeModeCard(theme: theme, isSelected: theme.name == activeName)
            .onTapGesture { select(theme.name) }
            .contextMenu {
                Button("Edit…") { edit(theme) }
                Button("Duplicate") { duplicate(theme) }
                if theme.isBuiltIn {
                    Button(themes.isFavorite(theme.name) ? "Remove from Favorites" : "Add to Favorites") {
                        toggleFavorite(theme.name)
                    }
                }
                if !theme.isBuiltIn {
                    Divider()
                    Button("Delete…", role: .destructive) {
                        themePendingDeletion = theme
                    }
                }
            }
    }

    // MARK: Actions

    @discardableResult
    private func select(_ name: String) -> Bool {
        guard name != activeName else { return true }
        return update { $0.setThemeName(name, isDark: isDark) }
    }

    private func newTheme() {
        // Start from the theme of this row when it agrees with the mode,
        // else from the default theme of the mode.
        let current = themes.theme(named: activeName)
        var draft = current.isDark == isDark
            ? current
            : themes.theme(named: TerminalProfile.defaultThemeName(isDark: isDark))
        draft.name = themes.newThemeName(isDark: isDark)
        draft.isBuiltIn = false
        draft.baseThemeName = nil
        editorRequest = EditorRequest(theme: draft, existingUserThemeName: nil)
    }

    private func edit(_ theme: TerminalTheme) {
        if theme.isBuiltIn {
            // A built-in theme does not change: the editor makes a copy.
            editorRequest = EditorRequest(theme: themes.fork(of: theme), existingUserThemeName: nil)
        } else {
            editorRequest = EditorRequest(theme: theme, existingUserThemeName: theme.name)
        }
    }

    private func duplicate(_ theme: TerminalTheme) {
        let copy = themes.duplicate(of: theme)
        do {
            try themes.saveUserTheme(copy)
            editorRequest = EditorRequest(theme: copy, existingUserThemeName: copy.name)
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func toggleFavorite(_ name: String) {
        do {
            try themes.toggleFavorite(name)
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func delete(_ theme: TerminalTheme) {
        do {
            try themes.deleteUserTheme(named: theme.name)
            let base = theme.baseThemeName.flatMap { name in
                themes.themes.first { $0.name == name }?.name
            }
            try profiles.replaceThemeName(theme.name) { slotIsDark in
                base ?? TerminalProfile.defaultThemeName(isDark: slotIsDark)
            }
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func didSave(_ saved: TerminalTheme, replacing oldName: String?) {
        do {
            if let oldName, oldName != saved.name {
                try profiles.replaceThemeName(oldName) { _ in saved.name }
            }
        } catch {
            operationError = error.localizedDescription
        }
        select(saved.name)
    }

    private func chooseFromCatalog(_ name: String) {
        guard select(name) else { return }
        let theme = themes.theme(named: name)
        if theme.isBuiltIn && !themes.isFavorite(name)
            && name != TerminalProfile.defaultThemeName(isDark: isDark) {
            toggleFavorite(name)
        }
    }
}

/// A small preview of a theme: "Aa" in the text color, "~/" on the
/// selection color, "_" on the cursor color, and the eight normal ANSI
/// colors. The name is under the card.
struct ThemeModeCard: View {
    let theme: TerminalTheme
    let isSelected: Bool

    static let size = CGSize(width: 112, height: 66)

    var body: some View {
        VStack(spacing: 6) {
            face
                .frame(width: Self.size.width, height: Self.size.height)
                .background(theme.background.swiftUIColor, in: .rect(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.separator, lineWidth: 1)
                }
                .padding(3)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 13)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
            Text(theme.name)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: Self.size.width + 6)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(theme.name))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var face: some View {
        ThemeIconFace(theme: theme)
    }
}

/// The small design of a theme: "Aa" in the text color, "~/" on the
/// selection color, "_" on the cursor color, and the eight normal ANSI
/// colors. The Appearance cards and the "Icon" sample page use it.
struct ThemeIconFace: View {
    let theme: TerminalTheme
    /// Multiplies all sizes. 1 is the size of the Appearance cards.
    var scale: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            HStack(spacing: 6 * scale) {
                Text("Aa")
                    .font(.system(size: 17 * scale))
                    .foregroundStyle(theme.foreground.swiftUIColor)
                Spacer(minLength: 0)
                Text("~/")
                    .font(.system(size: 12 * scale, weight: .medium, design: .monospaced))
                    .foregroundStyle((theme.selectionText ?? theme.foreground).swiftUIColor)
                    .padding(.horizontal, 4 * scale)
                    .padding(.vertical, 2 * scale)
                    .background(
                        ThemeEditorView.effectiveSelectionBackground(of: theme).swiftUIColor,
                        in: .rect(cornerRadius: 4 * scale)
                    )
                Text("_")
                    .font(.system(size: 11 * scale, weight: .bold, design: .monospaced))
                    .foregroundStyle((theme.cursorText ?? theme.background).swiftUIColor)
                    .frame(width: 11 * scale, height: 20 * scale, alignment: .bottom)
                    .background(
                        (theme.cursor ?? theme.foreground).swiftUIColor,
                        in: .rect(cornerRadius: 3 * scale)
                    )
            }
            HStack(spacing: -4 * scale) {
                ForEach(0..<min(8, theme.ansi.count), id: \.self) { index in
                    Circle()
                        .fill(theme.ansi[index].swiftUIColor)
                        .overlay(Circle().strokeBorder(theme.background.swiftUIColor.opacity(0.6), lineWidth: 1))
                        .frame(width: 15 * scale, height: 15 * scale)
                }
            }
        }
        .padding(.horizontal, 9 * scale)
    }
}

/// The last card of a row: opens the catalog of all themes.
private struct ThemeBrowseCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: "square.grid.2x2")
                    .font(.title2)
                Text("Browse…")
                    .font(.callout)
            }
            .foregroundStyle(.secondary)
            .frame(width: 80, height: ThemeModeCard.size.height)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Choose from all themes")
    }
}

struct ThemeChooserSheet: View {
    @ObservedObject var themes: ThemeStore
    @ObservedObject var themeIndex: ThemeCatalogIndex
    let selectedThemeName: String
    @Binding var selectedPreviewPage: ThemePreviewPage?
    let onSelectTheme: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draftThemeName: String

    init(
        themes: ThemeStore,
        themeIndex: ThemeCatalogIndex,
        selectedThemeName: String,
        selectedPreviewPage: Binding<ThemePreviewPage?>,
        onSelectTheme: @escaping (String) -> Void
    ) {
        self.themes = themes
        self.themeIndex = themeIndex
        self.selectedThemeName = selectedThemeName
        _selectedPreviewPage = selectedPreviewPage
        self.onSelectTheme = onSelectTheme
        _draftThemeName = State(initialValue: selectedThemeName)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Choose a Theme")
                .font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            Divider()
            ThemeBrowserView(
                themes: themes,
                themeIndex: themeIndex,
                selectedThemeName: draftThemeName,
                onSelect: { draftThemeName = $0.name },
                style: .all,
                samplePage: selectedPreviewPage ?? .shell,
                sampleSelection: $selectedPreviewPage
            )
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Choose") {
                    onSelectTheme(draftThemeName)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 780, height: 620)
    }
}

#Preview("Theme Modes") {
    @Previewable @State var profile = SettingsPreviewData.profile

    Form {
        ThemeModeSection(isDark: false, profile: profile, themes: SettingsPreviewData.themes) {
            $0(&profile)
            return true
        }
        ThemeModeSection(isDark: true, profile: profile, themes: SettingsPreviewData.themes) {
            $0(&profile)
            return true
        }
    }
    .formStyle(.grouped)
    .environmentObject(SettingsPreviewData.themeIndex)
    .environmentObject(SettingsPreviewData.profiles)
    .environmentObject(SystemAppearance(isDark: false))
    .frame(width: 720, height: 520)
}

#Preview("Theme Chooser") {
    @Previewable @State var selectedPreviewPage: ThemePreviewPage? = .shell

    ThemeChooserSheet(
        themes: SettingsPreviewData.themes,
        themeIndex: SettingsPreviewData.themeIndex,
        selectedThemeName: SettingsPreviewData.profile.darkThemeName,
        selectedPreviewPage: $selectedPreviewPage,
        onSelectTheme: { _ in }
    )
}
