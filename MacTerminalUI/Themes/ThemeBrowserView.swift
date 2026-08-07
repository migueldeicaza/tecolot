//
//  ThemeBrowserView.swift
//  MacTerminalUI
//
//  A searchable grid of theme cards. Selecting a card reports the theme to
//  the owner; the browser itself holds no terminal state so it can back the
//  per-window picker popover and the Appearance settings pane alike.
//
import SwiftUI
import TerminalProfilesKit

struct ThemeBrowserView: View {
    @ObservedObject var themes: ThemeStore
    /// Name of the currently active theme (shown selected)
    var selectedThemeName: String
    var onSelect: (TerminalTheme) -> Void

    @State private var query = ""

    private let columns = [GridItem(.adaptive(minimum: 148, maximum: 200), spacing: 10)]

    private var visibleThemes: [TerminalTheme] {
        let matching = themes.themes(matching: query)
        // Favorites first, then the rest, both alphabetical
        let favorites = matching.filter { themes.isFavorite($0.name) }
        let others = matching.filter { !themes.isFavorite($0.name) }
        return favorites + others
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search themes", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding([.horizontal, .top], 10)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(visibleThemes) { theme in
                        themeCell(theme)
                    }
                }
                .padding(10)
            }
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
                themes.toggleFavorite(theme.name)
            }
            if !theme.isBuiltIn {
                Button("Delete User Theme", role: .destructive) {
                    try? themes.deleteUserTheme(named: theme.name)
                }
            }
        }
    }
}
