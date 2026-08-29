//
//  ThemeBrowserView.swift
//  Tecolot
//
//  A searchable grid of theme cards. Selecting a card reports the theme to
//  the owner; the browser itself holds no terminal state so it can back the
//  per-window picker popover and the Appearance settings pane alike.
//
import SwiftUI
import UniformTypeIdentifiers

private struct ThemeEditorPresentation: Identifiable {
    let id = UUID ()
    let theme: TerminalTheme
    let existingUserThemeName: String?
}

enum ThemeBrowserStyle {
    case paged
    case all
}

struct ThemeBrowserSections: Equatable {
    var favorites: [TerminalTheme]
    var others: [TerminalTheme]

    static func compute(
        themes: [TerminalTheme],
        favorites: Set<String>,
        query: String,
        page: ThemeBrowserPage?
    ) -> ThemeBrowserSections {
        let matching = themes.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
        }
        let favoriteThemes = matching
            .filter { favorites.contains($0.name) }
            .sorted(by: alphabetically)
        var otherThemes = matching.filter { !favorites.contains($0.name) }
        if let page {
            otherThemes = otherThemes.filter { page.contains($0.name) }
        }
        return ThemeBrowserSections(
            favorites: favoriteThemes,
            others: otherThemes.sorted(by: alphabetically)
        )
    }

    private static func alphabetically(_ left: TerminalTheme, _ right: TerminalTheme) -> Bool {
        left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
    }
}

struct ThemeBrowserView: View {
    @ObservedObject var themes: ThemeStore
    /// Name of the currently active theme (shown selected)
    var selectedThemeName: String
    var onSelect: (TerminalTheme) -> Void
    var style: ThemeBrowserStyle = .paged
    var onDone: (() -> Void)? = nil

    @State private var query = ""
    @State private var page: ThemeBrowserPage = .popular
    @State private var editorPresentation: ThemeEditorPresentation?
    @State private var showImporter = false
    @State private var importError: String?

    private let columns = [GridItem(.adaptive(minimum: 148, maximum: 200), spacing: 10)]

    private var sections: ThemeBrowserSections {
        ThemeBrowserSections.compute(
            themes: themes.themes,
            favorites: themes.favorites,
            query: query,
            page: style == .paged ? page : nil
        )
    }

    private var othersTitle: String {
        switch style {
        case .paged: page.title
        case .all: "All Themes"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search themes", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding([.horizontal, .top], 10)

            if style == .paged {
                Picker("Themes", selection: $page) {
                    ForEach(ThemeBrowserPage.allCases) { page in
                        Text(page.title).tag(page)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 10)
                .padding(.top, 8)
            }

            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    if sections.favorites.isEmpty {
                        ForEach(sections.others) { theme in
                            themeCell(theme)
                        }
                    } else {
                        Section {
                            ForEach(sections.favorites) { theme in
                                themeCell(theme)
                            }
                        } header: {
                            ThemeBrowserSectionHeader(title: "Favorites")
                        }
                        Section {
                            ForEach(sections.others) { theme in
                                themeCell(theme)
                            }
                        } header: {
                            ThemeBrowserSectionHeader(title: othersTitle)
                        }
                    }
                }
                .padding(10)
            }
            Divider()
            HStack {
                Button("Import Theme…") {
                    showImporter = true
                }
                Spacer()
                Link(
                    "Get More Themes…",
                    destination: URL(string: "https://github.com/mbadolato/iTerm2-Color-Schemes")!
                )
                if let onDone {
                    Button("Done", action: onDone)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(10)
        }
        .sheet(item: $editorPresentation) { presentation in
            ThemeEditorView(theme: presentation.theme,
                            themes: themes,
                            existingUserThemeName: presentation.existingUserThemeName)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importTypes) { result in
            importTheme(result)
        }
        .alert("Theme Operation Failed", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) {
                importError = nil
            }
        } message: {
            Text(importError ?? "")
        }
    }

    private func themeCell(_ theme: TerminalTheme) -> some View {
        ThemeCard(
            theme: theme,
            isSelected: theme.name == selectedThemeName,
            isFavorite: themes.isFavorite(theme.name),
            onSelect: { onSelect(theme) },
            onToggleFavorite: { toggleFavorite(theme.name) }
        )
        .contextMenu {
            Button(themes.isFavorite(theme.name) ? "Remove from Favorites" : "Add to Favorites") {
                toggleFavorite(theme.name)
            }
            Button(theme.isBuiltIn ? "Duplicate & Edit…" : "Edit…") {
                presentEditor(for: theme)
            }
            if !theme.isBuiltIn {
                Button("Delete User Theme", role: .destructive) {
                    do {
                        try themes.deleteUserTheme(named: theme.name)
                    } catch {
                        importError = error.localizedDescription
                    }
                }
            }
        }
    }

    private var importTypes: [UTType] {
        [.json, UTType (filenameExtension: "itermcolors") ?? .propertyList, .propertyList]
    }

    private func presentEditor(for theme: TerminalTheme) {
        if theme.isBuiltIn {
            // duplicate(of:) records the built-in as the copy's base theme
            editorPresentation = ThemeEditorPresentation(theme: themes.duplicate(of: theme),
                                                         existingUserThemeName: nil)
        } else {
            editorPresentation = ThemeEditorPresentation(theme: theme, existingUserThemeName: theme.name)
        }
    }

    private func toggleFavorite(_ name: String) {
        do {
            try themes.toggleFavorite(name)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func importTheme(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let gotAccess = url.startAccessingSecurityScopedResource()
        defer {
            if gotAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            try themes.importTheme(from: url)
        } catch {
            importError = error.localizedDescription
        }
    }
}

private struct ThemeBrowserSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
    }
}

enum ThemeBrowserPage: CaseIterable, Identifiable {
    case popular
    case more

    static let popularThemeNames: Set<String> = [
        "Atom One Dark",
        "Ayu Mirage",
        "Catppuccin Mocha",
        "Dracula",
        "GitHub Dark Default",
        "Gruvbox Dark",
        "iTerm2 Solarized Dark",
        "iTerm2 Solarized Light",
        "Monokai Pro",
        "Nord",
        "Rose Pine",
        "TokyoNight"
    ]

    var id: Self { self }

    var title: String {
        switch self {
        case .popular: return "Popular"
        case .more: return "More"
        }
    }

    func contains(_ themeName: String) -> Bool {
        switch self {
        case .popular:
            Self.popularThemeNames.contains(themeName)
        case .more:
            !Self.popularThemeNames.contains(themeName)
        }
    }
}
