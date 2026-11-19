import Foundation

/// State machine driving the Command Palette's scope stack, filtering, selection, and live previews.
@MainActor
final class CommandPaletteModel {
    private let catalog: CommandPaletteCatalog
    let mru: CommandPaletteMRU

    private(set) var stack: [PaletteScopeFrame] = []
    private(set) var items: [PaletteDisplayItem] = []
    private(set) var selectedIndex: Int?

    /// Reverts any live preview (such as Theme Picker) if the user cancels or pops without committing.
    private var activePreviewRevert: (@MainActor () -> Void)?

    /// Background task and cache for non-blocking directory listing in Go to Directory.
    private(set) var directoryLoadTask: Task<Void, Never>?
    private(set) var isDirectoryLoadPending = false
    private var directoryLoadGeneration: UInt64 = 0
    private var directoryNamesCache: [String: [String]] = [:]

    var onItemsChanged: (() -> Void)?
    var onScopeChanged: (() -> Void)?
    var onQueryReplaced: ((String) -> Void)?
    var onRequestDismiss: ((Bool) -> Void)?

    var currentFrame: PaletteScopeFrame {
        stack.last ?? PaletteScopeFrame(scope: .root, query: "", selectedRowID: nil)
    }

    var currentScope: PaletteScope {
        currentFrame.scope
    }

    var query: String {
        currentFrame.query
    }

    var isAtRoot: Bool {
        stack.count <= 1
    }

    var selectedRow: PaletteRow? {
        guard let selectedIndex, items.indices.contains(selectedIndex) else {
            return nil
        }
        return items[selectedIndex].row
    }

    init(catalog: CommandPaletteCatalog, mru: CommandPaletteMRU? = nil) {
        self.catalog = catalog
        self.mru = mru ?? CommandPaletteMRU()
    }

    func reset(initialScope: PaletteScope = .root) {
        cancelDirectoryLoad()
        directoryNamesCache.removeAll()
        revertPreviewIfNeeded()
        let resolvedScope: PaletteScope
        if case .directoryPicker(nil) = initialScope {
            resolvedScope = .directoryPicker(
                initialPath: CommandPaletteCatalog.normalizedDirectoryPath(catalog.context.activePane?.currentWorkingDirectory)
            )
        } else {
            resolvedScope = initialScope
        }
        if case .root = resolvedScope {
            stack = [PaletteScopeFrame(scope: .root, query: "", selectedRowID: nil)]
        } else {
            // Keep root underneath so Backspace on empty input can pop back to the root palette.
            stack = [
                PaletteScopeFrame(scope: .root, query: "", selectedRowID: nil),
                PaletteScopeFrame(scope: resolvedScope, query: resolvedScope.initialQuery, selectedRowID: nil)
            ]
        }
        installPreviewRevertIfNeeded(for: resolvedScope)
        rebuild(preferredSelectionID: nil)
        onScopeChanged?()
    }

    func setQuery(_ newQuery: String) {
        guard !stack.isEmpty else {
            return
        }
        guard stack[stack.count - 1].query != newQuery else {
            return
        }
        stack[stack.count - 1].query = newQuery
        rebuild(preferredSelectionID: nil)
    }

    func moveSelection(by delta: Int) {
        let selectable = items.indices.filter {
            items[$0].isSelectable
        }
        guard !selectable.isEmpty else {
            selectedIndex = nil
            return
        }
        let next: Int
        if let current = selectedIndex, let pos = selectable.firstIndex(of: current) {
            let clamped = max(0, min(selectable.count - 1, pos + delta))
            next = selectable[clamped]
        } else {
            next = delta >= 0 ? selectable.first! : selectable.last!
        }
        selectIndex(next, triggerPreview: true)
    }

    func selectIndex(_ index: Int?, triggerPreview: Bool) {
        guard let index, items.indices.contains(index), items[index].isSelectable else {
            selectedIndex = nil
            return
        }
        let changed = selectedIndex != index
        selectedIndex = index
        if !stack.isEmpty {
            stack[stack.count - 1].selectedRowID = items[index].row?.id
        }
        if changed, triggerPreview {
            items[index].row?.onPreview?()
        }
    }

    func executeSelected() {
        guard let selectedIndex else {
            return
        }
        execute(at: selectedIndex)
    }

    func execute(at index: Int) {
        guard !isDirectoryLoadPending else {
            return
        }
        guard items.indices.contains(index), let row = items[index].row else {
            return
        }
        if row.isCommand, case .root = currentScope {
            mru.record(row.id)
        }
        // Clear pending preview revert before committing the chosen row.
        activePreviewRevert = nil
        let outcome = row.onExecute()
        switch outcome {
        case .dismiss(let restoreFocus):
            onRequestDismiss?(restoreFocus)
        case .push(let nextScope):
            push(nextScope)
        case .pop:
            pop()
        case .stayAndReload:
            rebuild(preferredSelectionID: row.id)
        }
    }

    func push(_ scope: PaletteScope) {
        if !stack.isEmpty {
            stack[stack.count - 1].selectedRowID = selectedRow?.id
        }
        let resolvedScope: PaletteScope
        if case .directoryPicker(nil) = scope {
            resolvedScope = .directoryPicker(
                initialPath: CommandPaletteCatalog.normalizedDirectoryPath(catalog.context.activePane?.currentWorkingDirectory)
            )
        } else {
            resolvedScope = scope
        }
        stack.append(PaletteScopeFrame(scope: resolvedScope, query: resolvedScope.initialQuery, selectedRowID: nil))
        installPreviewRevertIfNeeded(for: resolvedScope)
        rebuild(preferredSelectionID: nil)
        onScopeChanged?()
    }

    @discardableResult
    func pop() -> Bool {
        guard stack.count > 1 else {
            return false
        }
        revertPreviewIfNeeded()
        stack.removeLast()
        let restoredID = stack.last?.selectedRowID
        rebuild(preferredSelectionID: restoredID)
        onScopeChanged?()
        return true
    }

    /// Backspace when input is already empty pops the current scope chip, restoring parent query.
    @discardableResult
    func handleBackspaceOnEmpty() -> Bool {
        guard query.isEmpty, stack.count > 1 else {
            return false
        }
        return pop()
    }

    /// Two-stage Escape: clears non-empty text first, then pops sub-view, then dismisses palette.
    func handleEscape() {
        if !query.isEmpty {
            setQuery("")
            onQueryReplaced?("")
            return
        }
        if pop() {
            return
        }
        cancelAndDismiss()
    }

    func cancelAndDismiss() {
        cancelDirectoryLoad()
        revertPreviewIfNeeded()
        onRequestDismiss?(true)
    }

    func cancelDirectoryLoad() {
        directoryLoadTask?.cancel()
        directoryLoadTask = nil
        isDirectoryLoadPending = false
        directoryLoadGeneration &+= 1
    }

    /// Tab completes highlighted directory or SSH destination when the row supports completion.
    @discardableResult
    func tabComplete() -> Bool {
        guard !isDirectoryLoadPending else {
            return false
        }
        guard let completion = selectedRow?.completionText, completion != query else {
            return false
        }
        setQuery(completion)
        onQueryReplaced?(completion)
        return true
    }

    // MARK: - Preview Revert

    private func installPreviewRevertIfNeeded(for scope: PaletteScope) {
        if case .themePicker(let originalOverride, let controllerID) = scope {
            activePreviewRevert = { [weak catalog] in
                let pane = catalog?.context.activeWorkspace?.controllers.first {
                    $0.id == controllerID
                }
                    ?? catalog?.context.activePane
                pane?.applyThemeOverride(originalOverride)
            }
        }
    }

    func revertPreviewIfNeeded() {
        let revert = activePreviewRevert
        activePreviewRevert = nil
        revert?()
    }

    // MARK: - Rebuild & Ranking

    func rebuild(preferredSelectionID: String?) {
        cancelDirectoryLoad()
        let frame = currentFrame

        if case .directoryPicker = frame.scope {
            rebuildDirectoryScope(query: frame.query, preferredSelectionID: preferredSelectionID)
            return
        }

        let builtItems: [PaletteDisplayItem]
        let autoSelectID: String?

        if case .root = frame.scope {
            (builtItems, autoSelectID) = buildRootItems(query: frame.query)
        } else {
            (builtItems, autoSelectID) = catalog.rows(for: frame.scope, query: frame.query)
        }

        applyBuiltItems(builtItems, autoSelectID: autoSelectID, preferredSelectionID: preferredSelectionID)
    }

    private func applyBuiltItems(
        _ builtItems: [PaletteDisplayItem],
        autoSelectID: String?,
        preferredSelectionID: String?
    ) {
        items = builtItems

        let targetID = preferredSelectionID ?? autoSelectID
        if
            let targetID, let found = items.firstIndex(where: {
                $0.row?.id == targetID
            }) {
            selectedIndex = found
        } else {
            selectedIndex = items.firstIndex(where: \.isSelectable)
        }

        if !stack.isEmpty {
            stack[stack.count - 1].selectedRowID = selectedRow?.id
        }
        onItemsChanged?()
    }

    private func rebuildDirectoryScope(query: String, preferredSelectionID: String?) {
        let pane = catalog.context.activePane
        guard pane?.canChangeDirectory != false else {
            applyBuiltItems(
                [.hint("Go to Directory is only available at a local shell prompt")],
                autoSelectID: nil,
                preferredSelectionID: nil
            )
            return
        }

        let resolved = CommandPaletteCatalog.resolveDirectoryQuery(
            query,
            baseDirectory: pane?.currentWorkingDirectory
        )
        let cachedNames = directoryNamesCache[resolved.searchDir]
        let generation = directoryLoadGeneration
        isDirectoryLoadPending = true

        // Clear selection immediately so Return/Tab cannot act on rows from the previous query.
        if items.isEmpty {
            applyBuiltItems([.hint("Loading directories…")], autoSelectID: nil, preferredSelectionID: nil)
        } else {
            selectedIndex = nil
            onItemsChanged?()
        }

        directoryLoadTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                CommandPaletteCatalog.listDirectories(resolved: resolved, cachedNames: cachedNames)
            }.value
            guard !Task.isCancelled, let self, self.directoryLoadGeneration == generation else {
                return
            }
            self.isDirectoryLoadPending = false
            self.directoryLoadTask = nil
            self.directoryNamesCache[resolved.searchDir] = result.allNames
            let (builtItems, autoSelectID) = self.catalog.makeDirectoryPickerItems(
                entries: result.entries,
                filterPrefix: resolved.filterPrefix
            )
            self.applyBuiltItems(builtItems, autoSelectID: autoSelectID, preferredSelectionID: preferredSelectionID)
        }
    }

    private func buildRootItems(query rawQuery: String) -> ([PaletteDisplayItem], String?) {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let commands = catalog.commandRows()

        // Empty query: display the full curated command catalog grouped by section (matching Rex).
        if trimmed.isEmpty {
            var display: [PaletteDisplayItem] = []
            var currentSection: String?
            for row in commands {
                if row.section != currentSection {
                    currentSection = row.section
                    if let title = row.section {
                        display.append(.sectionHeader(title))
                    }
                }
                display.append(.row(row))
            }
            return (display, commands.first?.id)
        }

        // Non-empty query: search across Groups, Tabs, Commands, and Settings.
        struct ScoredRow {
            let score: Int
            let originalIndex: Int
            let row: PaletteRow
        }

        func filterRows(_ rows: [PaletteRow], applyMRU: Bool) -> [ScoredRow] {
            var results: [ScoredRow] = []
            for (index, var row) in rows.enumerated() {
                guard
                    let match = CommandPaletteSearch.match(
                        query: trimmed,
                        title: row.title,
                        subtitle: row.subtitle,
                        keywords: row.keywords
                    ) else {
                    continue
                }
                row.matchRanges = match.titleRanges
                row.subtitleMatchRanges = match.subtitleRanges
                let boost = applyMRU ? mru.boost(for: row.id) : 0
                results.append(ScoredRow(score: match.score + boost, originalIndex: index, row: row))
            }
            results.sort { lhs, rhs in
                lhs.score != rhs.score ? lhs.score > rhs.score : lhs.originalIndex < rhs.originalIndex
            }
            return results
        }

        let matchedGroups = filterRows(catalog.groupRows(), applyMRU: false)
        let matchedTabs = filterRows(catalog.tabRows(), applyMRU: false)
        let matchedCommands = filterRows(commands, applyMRU: true)
        let matchedSettings: [ScoredRow] = catalog.settingsRows(for: trimmed).enumerated().map { index, item in
            var row = item
            var score = 150
            if let match = CommandPaletteSearch.match(query: trimmed, title: row.title, subtitle: row.subtitle) {
                row.matchRanges = match.titleRanges
                row.subtitleMatchRanges = match.subtitleRanges
                score = min(match.score, 420)
            }
            return ScoredRow(score: score, originalIndex: index, row: row)
        }

        struct RankedSection {
            let title: String
            let bestScore: Int
            let tieBreaker: Int // lower wins when scores tie: Commands (0) < Groups (1) < Tabs (2) < Settings (3)
            let rows: [PaletteRow]
        }

        var sections: [RankedSection] = []

        if !matchedGroups.isEmpty {
            sections.append(RankedSection(
                title: "Groups",
                bestScore: matchedGroups[0].score,
                tieBreaker: 1,
                rows: matchedGroups.map(\.row)
            ))
        }

        if !matchedTabs.isEmpty {
            sections.append(RankedSection(
                title: "Tabs",
                bestScore: matchedTabs[0].score,
                tieBreaker: 2,
                rows: matchedTabs.map(\.row)
            ))
        }

        if !matchedCommands.isEmpty {
            var sectionOrder: [String] = []
            var bySection: [String: [ScoredRow]] = [:]
            for scored in matchedCommands {
                let label = scored.row.section ?? "Commands"
                if bySection[label] == nil {
                    sectionOrder.append(label)
                }
                bySection[label, default: []].append(scored)
            }
            for section in sectionOrder {
                let group = bySection[section] ?? []
                if let first = group.first {
                    sections.append(RankedSection(
                        title: section,
                        bestScore: first.score,
                        tieBreaker: 0,
                        rows: group.map(\.row)
                    ))
                }
            }
        }

        if !matchedSettings.isEmpty {
            sections.append(RankedSection(
                title: "Settings",
                bestScore: matchedSettings[0].score,
                tieBreaker: 3,
                rows: matchedSettings.map(\.row)
            ))
        }

        sections.sort { lhs, rhs in
            lhs.bestScore != rhs.bestScore ? lhs.bestScore > rhs.bestScore : lhs.tieBreaker < rhs.tieBreaker
        }

        var display: [PaletteDisplayItem] = []
        for section in sections {
            display.append(.sectionHeader(section.title))
            display.append(contentsOf: section.rows.map {
                .row($0)
            })
        }

        if display.isEmpty {
            return ([.hint("No Results")], nil)
        }

        let firstSelectableID = display.first(where: \.isSelectable)?.row?.id
        return (display, firstSelectableID)
    }
}
