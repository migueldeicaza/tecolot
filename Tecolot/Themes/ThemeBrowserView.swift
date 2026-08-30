//
//  ThemeBrowserView.swift
//  Tecolot
//
//  A searchable grid of theme cards with an alternate 2D map display.
//  Selecting a card or a map marker reports the theme to the owner; the
//  browser itself holds no terminal state so it can back the per-window
//  picker popover and the Appearance settings pane alike.
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

enum ThemeBrowserDisplayMode: String {
    case grid
    case twoDimensional
    case threeDimensional

    /// Preserve the old map choice when a person first opens this version.
    static func storedValue(_ value: String?) -> ThemeBrowserDisplayMode {
        switch value {
        case ThemeBrowserDisplayMode.grid.rawValue:
            .grid
        case "map", ThemeBrowserDisplayMode.twoDimensional.rawValue:
            .twoDimensional
        case ThemeBrowserDisplayMode.threeDimensional.rawValue:
            .threeDimensional
        default:
            .grid
        }
    }
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
        compute(themes: themes, favorites: favorites, query: query, page: page, order: nil)
    }

    /// Sort-mode-aware variant: `order` sorts each section in place of the
    /// alphabetical default; favorites-first sectioning is preserved.
    static func compute(
        themes: [TerminalTheme],
        favorites: Set<String>,
        query: String,
        page: ThemeBrowserPage?,
        order: (([TerminalTheme]) -> [TerminalTheme])?
    ) -> ThemeBrowserSections {
        let matching = themes.filter { matches($0.name, query: query) }
        let sort = order ?? { $0.sorted(by: alphabetically) }
        let favoriteThemes = sort(matching.filter { favorites.contains($0.name) })
        var otherThemes = matching.filter { !favorites.contains($0.name) }
        if let page {
            otherThemes = otherThemes.filter { page.contains($0.name) }
        }
        return ThemeBrowserSections(
            favorites: favoriteThemes,
            others: sort(otherThemes)
        )
    }

    /// The one search predicate for both browser displays: the grid sections
    /// and the map's marker dimming must always match the same theme set
    static func matches(_ name: String, query: String) -> Bool {
        query.isEmpty || name.localizedCaseInsensitiveContains(query)
    }

    private static func alphabetically(_ left: TerminalTheme, _ right: TerminalTheme) -> Bool {
        left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
    }
}

// Persisted-view-preference keys; read once per browser instance so one
// browser's mode changes never live-flip another open browser (file-scope so
// @State default expressions can reference them)
private let displayModeDefaultsKey = "themeBrowserDisplayMode"
private let plotModeDefaultsKey = "themeBrowserPlotMode"

struct ThemeBrowserView: View {
    @ObservedObject var themes: ThemeStore
    /// The metrics/plot engine; passed explicitly because the browser is
    /// hosted inside an NSToolbar popover, where environment-object
    /// propagation is not guaranteed
    @ObservedObject var themeIndex: ThemeCatalogIndex
    /// Name of the currently active theme (shown selected)
    var selectedThemeName: String
    var onSelect: (TerminalTheme) -> Void
    var style: ThemeBrowserStyle = .paged
    var samplePage: ThemePreviewPage = .shell
    var sampleSelection: Binding<ThemePreviewPage?>? = nil
    var onDone: (() -> Void)? = nil

    @State private var query = ""
    @State private var page: ThemeBrowserPage = .popular
    @State private var sortMode: ThemeSortMode = .name
    @State private var pinnedThemeName: String?
    /// Exploratory camera positions last for this browser presentation only.
    @State private var cameraByMode: [ThemePlotMode: ThemeCamera] = [:]
    @State private var editorPresentation: ThemeEditorPresentation?
    @State private var showImporter = false
    @State private var importError: String?
    // Per-instance display state, seeded from and persisted to UserDefaults;
    // deliberately not @AppStorage so mode changes stay local to this browser
    @State private var displayMode: ThemeBrowserDisplayMode = ThemeBrowserDisplayMode.storedValue(
        UserDefaults.standard.string(forKey: displayModeDefaultsKey)
    )
    @State private var plotMode: ThemePlotMode = ThemePlotMode(
        rawValue: UserDefaults.standard.string(forKey: plotModeDefaultsKey) ?? ""
    ) ?? .brightnessAndColorfulness

    private let columns = [GridItem(.adaptive(minimum: 148, maximum: 200), spacing: 10)]

    /// The stored sort mode keeps an empty similarity anchor; the real
    /// anchor is resolved here on every render, so anything sorted by
    /// "Similar to Current" re-sorts the moment the current theme changes.
    private var resolvedSortMode: ThemeSortMode {
        if case .similarity = sortMode {
            return .similarity(to: selectedThemeName)
        }
        return sortMode
    }

    private var sections: ThemeBrowserSections {
        let mode = resolvedSortMode
        return ThemeBrowserSections.compute(
            themes: themes.themes,
            favorites: themes.favorites,
            query: query,
            page: style == .paged ? page : nil,
            order: mode == .name ? nil : { themeIndex.sorted($0, by: mode) }
        )
    }

    private var othersTitle: String {
        switch style {
        case .paged: page.title
        case .all: "All Themes"
        }
    }

    var body: some View {
        VStack {
            HStack {
                TextField("Search themes", text: $query)
                    .textFieldStyle(.roundedBorder)
                Picker("Display", selection: displayModeSelection) {
                    Text("List")
                        .tag(ThemeBrowserDisplayMode.grid)
                    Text("2D")
                        .tag(ThemeBrowserDisplayMode.twoDimensional)
                        .help("Show two-dimensional theme spaces")
                    Text("3D")
                        .tag(ThemeBrowserDisplayMode.threeDimensional)
                        .help("Show three-dimensional theme spaces")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding([.horizontal, .top], 10)

            switch displayMode {
            case .grid:
                gridContent
            case .twoDimensional, .threeDimensional:
                mapContent
            }

            Divider()
            HStack {
                Button("Import Theme…") {
                    showImporter = true
                }
                if displayMode == .grid {
                    sortMenu
                    if let sampleSelection {
                        Picker("Sample", selection: sampleSelection) {
                            ForEach(ThemePreviewPage.allCases) { page in
                                Text(page.title).tag(Optional(page))
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
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
        .onChange(of: displayMode) { _, newValue in
            UserDefaults.standard.set(newValue.rawValue, forKey: displayModeDefaultsKey)
        }
        .onChange(of: plotMode) { _, newValue in
            UserDefaults.standard.set(newValue.rawValue, forKey: plotModeDefaultsKey)
        }
        .onChange(of: resolvedSimilaritySpaceAvailable) { _, available in
            guard available == false, plotMode == .similaritySpace3D else { return }
            plotMode = .colorSpace3D
        }
        .onAppear {
            normalizePlot(for: displayMode)
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

    // MARK: - Grid display

    @ViewBuilder
    private var gridContent: some View {
        // Computed once per body pass; each access re-filters and re-sorts
        let sections = sections
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
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sortMode) {
                ForEach(sortModes, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label("Sort: \(sortMode.title)", systemImage: "arrow.up.arrow.down")
        }
        .fixedSize()
    }

    /// Menu entries. The similarity entry carries an empty anchor on
    /// purpose: the stored state and the Picker tag stay identical however
    /// often the selection moves, and resolvedSortMode substitutes the
    /// current theme when the sort actually runs.
    private var sortModes: [ThemeSortMode] {
        [
            .name, .backgroundLightness, .backgroundHue, .backgroundChroma,
            .foregroundContrast, .ansiVisibility, .ansiDistinctness,
            .colorfulness, .dynamicRange, .temperature, .hueDiversity,
            .brightPairSeparation, .cursorVisibility, .selectionVisibility,
            .similarity(to: "")
        ]
    }

    // MARK: - Map display

    /// Similarity Space needs a stable three-component basis. Keep a stored
    /// selection while indexing is in progress so the picker does not jump.
    private var resolvedSimilaritySpaceAvailable: Bool? {
        guard let catalog = themeIndex.catalog else { return nil }
        return catalog.similarity3D != nil
    }

    /// Color and palette space are always valid. Similarity Space appears
    /// after the catalog has its third PCA component.
    private var availableThreeDimensionalModes: [ThemePlotMode] {
        var modes: [ThemePlotMode] = [.colorSpace3D, .paletteSpace3D]
        if resolvedSimilaritySpaceAvailable == true
            || (resolvedSimilaritySpaceAvailable == nil && plotMode == .similaritySpace3D) {
            modes.append(.similaritySpace3D)
        }
        return modes
    }

    /// The top picker owns the display choice. Changing to a map display
    /// keeps its natural paired plot when possible.
    private var displayModeSelection: Binding<ThemeBrowserDisplayMode> {
        Binding(
            get: { displayMode },
            set: { newMode in
                displayMode = newMode
                normalizePlot(for: newMode)
            }
        )
    }

    private func normalizePlot(for display: ThemeBrowserDisplayMode) {
        switch display {
        case .grid:
            break
        case .twoDimensional:
            if plotMode.isThreeDimensional {
                plotMode = plotMode.flattened2DMode
            } else if !ThemePlotMode.v1Tabs.contains(plotMode) {
                plotMode = .brightnessAndColorfulness
            }
        case .threeDimensional:
            guard !plotMode.isThreeDimensional else { return }
            let pairedMode = plotMode.paired3DMode
            plotMode = pairedMode.flatMap { availableThreeDimensionalModes.contains($0) ? $0 : nil }
                ?? .colorSpace3D
        }
    }

    @ViewBuilder
    private var mapContent: some View {
        // The map always plots the full catalog; Popular/More do not apply
        GeometryReader { proxy in
            Picker("Plot", selection: $plotMode) {
                ForEach(
                    displayMode == .threeDimensional
                        ? availableThreeDimensionalModes
                        : ThemePlotMode.v1Tabs
                ) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .frame(width: max(0, proxy.size.width - 20))
            .pickerStyle(.segmented)
        }
        .frame(height: 28)
        .padding(.horizontal, 10)
        .padding(.top, 8)

        if plotMode.isThreeDimensional {
            ThemeSpace3DView(
                themes: themes.themes,
                metrics: themeIndex.metrics,
                catalog: themeIndex.catalog,
                mode: plotMode,
                query: query,
                selectedThemeName: selectedThemeName,
                pinnedThemeName: $pinnedThemeName,
                cameraByMode: $cameraByMode,
                onSelect: onSelect,
                onShowSimilar: { showSimilarThemes(to: $0) }
            )
        } else {
            ThemeMapView(
                themes: themes.themes,
                metrics: themeIndex.metrics,
                catalog: themeIndex.catalog,
                mode: plotMode,
                query: query,
                selectedThemeName: selectedThemeName,
                pinnedThemeName: $pinnedThemeName,
                onSelect: onSelect,
                onShowSimilar: { showSimilarThemes(to: $0) }
            )
        }
    }

    private func showSimilarThemes(to name: String) {
        displayMode = .twoDimensional
        plotMode = .similarityMap
        pinnedThemeName = name
    }

    // MARK: - Cells and actions

    private func themeCell(_ theme: TerminalTheme) -> some View {
        ThemeCard(
            theme: theme,
            isSelected: theme.name == selectedThemeName,
            isFavorite: themes.isFavorite(theme.name),
            samplePage: samplePage,
            onSelect: { onSelect(theme) },
            onToggleFavorite: { toggleFavorite(theme.name) }
        )
        .contextMenu {
            Button(themes.isFavorite(theme.name) ? "Remove from Favorites" : "Add to Favorites") {
                toggleFavorite(theme.name)
            }
            Button("Show Similar Themes") {
                showSimilarThemes(to: theme.name)
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

#Preview("Theme Browser") {
    @Previewable @State var selectedSample: ThemePreviewPage? = .shell

    ThemeBrowserView(
        themes: SettingsPreviewData.themes,
        themeIndex: SettingsPreviewData.themeIndex,
        selectedThemeName: SettingsPreviewData.profile.themeName,
        onSelect: { _ in },
        style: .all,
        samplePage: selectedSample ?? .shell,
        sampleSelection: $selectedSample,
        onDone: {}
    )
    .frame(width: 760, height: 560)
}
