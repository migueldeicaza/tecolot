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

struct ThemeBrowserView: View {
    @ObservedObject var themes: ThemeStore
    /// Name of the currently active theme (shown selected)
    var selectedThemeName: String
    var onSelect: (TerminalTheme) -> Void

    @State private var query = ""
    @State private var page: ThemeBrowserPage = .popular
    @State private var editorPresentation: ThemeEditorPresentation?
    @State private var showImporter = false
    @State private var importError: String?

    private let columns = [GridItem(.adaptive(minimum: 148, maximum: 200), spacing: 10)]

    private var matchingThemes: [TerminalTheme] {
        let matching = themes.themes(matching: query)
        // Favorites first, then the rest, both alphabetical
        let favorites = matching.filter { themes.isFavorite($0.name) }
        let others = matching.filter { !themes.isFavorite($0.name) }
        return favorites + others
    }

    private var visibleThemes: [TerminalTheme] {
        guard query.isEmpty else { return matchingThemes }
        return matchingThemes.filter { page.contains($0.name) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search themes", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding([.horizontal, .top], 10)

            Picker("Themes", selection: $page) {
                ForEach(ThemeBrowserPage.allCases) { page in
                    Text(page.title).tag(page)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 10)
            .padding(.top, 8)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(visibleThemes) { theme in
                        themeCell(theme)
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
        Button {
            onSelect(theme)
        } label: {
            ThemeCard(theme: theme,
                      isSelected: theme.name == selectedThemeName,
                      isFavorite: themes.isFavorite(theme.name))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(themes.isFavorite(theme.name) ? "Remove from Favorites" : "Add to Favorites") {
                do {
                    try themes.toggleFavorite(theme.name)
                } catch {
                    importError = error.localizedDescription
                }
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
            var copy = theme
            copy.name = duplicateName(for: theme.name)
            copy.isBuiltIn = false
            editorPresentation = ThemeEditorPresentation(theme: copy, existingUserThemeName: nil)
        } else {
            editorPresentation = ThemeEditorPresentation(theme: theme, existingUserThemeName: theme.name)
        }
    }

    private func duplicateName(for base: String) -> String {
        var name = "\(base) copy"
        var number = 2
        while themes.themes.contains(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) {
            name = "\(base) copy \(number)"
            number += 1
        }
        return name
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

private enum ThemeBrowserPage: CaseIterable, Identifiable {
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
