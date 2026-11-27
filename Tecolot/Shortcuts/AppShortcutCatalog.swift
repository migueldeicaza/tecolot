import Foundation

/// Logical grouping shown on the Settings → Shortcuts page.
nonisolated enum AppShortcutCategory: String, CaseIterable, Identifiable, Sendable {
    case app
    case windowsAndGroups
    case tabs
    case panes
    case view
    case terminal
    case findAndEdit

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .app:
            return "App"
        case .windowsAndGroups:
            return "Windows & Groups"
        case .tabs:
            return "Tabs"
        case .panes:
            return "Panes"
        case .view:
            return "View"
        case .terminal:
            return "Terminal"
        case .findAndEdit:
            return "Find & Edit"
        }
    }
}

/// Stable identifier for every configurable SwiftUI command shortcut in Tecolot.
nonisolated enum AppShortcutID: String, CaseIterable, Hashable, Codable, Identifiable, Sendable {
    // App
    case commandPalette
    case settings
    case activity
    case secureKeyboardEntry

    // Windows & Groups
    case newWindow
    case newGroup
    case goToGroup
    case previousGroup
    case nextGroup
    case renameGroup
    case duplicateGroup
    case closeWindow
    case closeGroup
    case closeGroupAndEndSessions
    case mergeAllWindows

    // Tabs
    case newTab
    case newPersistentTab
    case newPersistentWindow
    case newRemoteSession
    case attachToSession
    case renameTab
    case closeTab
    case previousTab
    case nextTab
    case selectPreviousTab
    case selectNextTab
    case moveTabBackward
    case moveTabForward
    case moveTabToNewWindow
    case goToDirectory

    // Panes
    case splitPaneRight
    case splitPaneDown
    case splitPaneLeft
    case splitPaneUp
    case closePane
    case zoomSplit
    case selectPreviousSplit
    case selectNextSplit
    case selectSplitAbove
    case selectSplitBelow
    case selectSplitLeft
    case selectSplitRight
    case equalizeSplits
    case moveDividerUp
    case moveDividerDown
    case moveDividerLeft
    case moveDividerRight

    // View
    case changeTheme
    case toggleTabStyle
    case toggleSidebar
    case showPaneHeaders
    case biggerFont
    case smallerFont
    case defaultFontSize

    // Terminal
    case clearToStart
    case scrollToPreviousPrompt
    case scrollToNextPrompt
    case softReset
    case hardReset
    case allowMouseReporting
    case optionAsMetaKey
    case exportBuffer
    case exportSelection
    case printTerminal

    // Find & Edit
    case find
    case findNext
    case findPrevious
    case pasteEscaped

    var id: Self {
        self
    }

    var descriptor: AppShortcutDescriptor {
        AppShortcutCatalog.descriptorsByID[self]!
    }
}

/// Static metadata and built-in default binding for one configurable command.
nonisolated struct AppShortcutDescriptor: Identifiable, Equatable, Sendable {
    let id: AppShortcutID
    let category: AppShortcutCategory
    let title: String
    let defaultShortcut: KeyCombo?
    let keywords: [String]

    init(
        _ id: AppShortcutID,
        category: AppShortcutCategory,
        title: String,
        default defaultShortcut: KeyCombo?,
        keywords: [String] = []
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.defaultShortcut = defaultShortcut
        self.keywords = keywords
    }
}

/// Single source of truth for every customizable command's category, label, and default shortcut.
nonisolated enum AppShortcutCatalog {
    static let all: [AppShortcutDescriptor] = [
        // MARK: App
        AppShortcutDescriptor(
            .commandPalette,
            category: .app,
            title: "Command Palette…",
            default: KeyCombo("p", modifiers: [.command, .shift]),
            keywords: ["actions", "search", "commands"]
        ),
        AppShortcutDescriptor(
            .settings,
            category: .app,
            title: "Settings…",
            default: KeyCombo(",", modifiers: [.command]),
            keywords: ["preferences", "config"]
        ),
        AppShortcutDescriptor(
            .activity,
            category: .app,
            title: "Activity",
            default: KeyCombo(".", modifiers: [.command]),
            keywords: ["notifications", "status", "agents"]
        ),
        AppShortcutDescriptor(
            .secureKeyboardEntry,
            category: .app,
            title: "Secure Keyboard Entry",
            default: nil,
            keywords: ["password", "privacy", "security"]
        ),

        // MARK: Windows & Groups
        AppShortcutDescriptor(
            .newWindow,
            category: .windowsAndGroups,
            title: "New Window",
            default: KeyCombo("n", modifiers: [.command])
        ),
        AppShortcutDescriptor(
            .newGroup,
            category: .windowsAndGroups,
            title: "New Group",
            default: KeyCombo("n", modifiers: [.command, .shift]),
            keywords: ["workspace", "session"]
        ),
        AppShortcutDescriptor(
            .goToGroup,
            category: .windowsAndGroups,
            title: "Go to Group…",
            default: KeyCombo("k", modifiers: [.command]),
            keywords: ["change group", "switch group", "workspace"]
        ),
        AppShortcutDescriptor(
            .previousGroup,
            category: .windowsAndGroups,
            title: "Previous Group",
            default: nil,
            keywords: ["cycle group", "workspace"]
        ),
        AppShortcutDescriptor(
            .nextGroup,
            category: .windowsAndGroups,
            title: "Next Group",
            default: nil,
            keywords: ["cycle group", "workspace"]
        ),
        AppShortcutDescriptor(
            .renameGroup,
            category: .windowsAndGroups,
            title: "Rename Group…",
            default: nil
        ),
        AppShortcutDescriptor(
            .duplicateGroup,
            category: .windowsAndGroups,
            title: "Duplicate Group",
            default: nil,
            keywords: ["clone"]
        ),
        AppShortcutDescriptor(
            .closeWindow,
            category: .windowsAndGroups,
            title: "Close Window",
            default: KeyCombo("w", modifiers: [.command, .shift])
        ),
        AppShortcutDescriptor(
            .closeGroup,
            category: .windowsAndGroups,
            title: "Close Group",
            default: KeyCombo("w", modifiers: [.command, .option, .shift])
        ),
        AppShortcutDescriptor(
            .closeGroupAndEndSessions,
            category: .windowsAndGroups,
            title: "Close Group and End Sessions",
            default: nil,
            keywords: ["terminate", "kill"]
        ),
        AppShortcutDescriptor(
            .mergeAllWindows,
            category: .windowsAndGroups,
            title: "Merge All Windows",
            default: nil,
            keywords: ["combine"]
        ),

        // MARK: Tabs
        AppShortcutDescriptor(
            .newTab,
            category: .tabs,
            title: "New Tab",
            default: KeyCombo("t", modifiers: [.command])
        ),
        AppShortcutDescriptor(
            .newPersistentTab,
            category: .tabs,
            title: "New Persistent Tab",
            default: KeyCombo("t", modifiers: [.command, .option]),
            keywords: ["session", "detach", "tmux"]
        ),
        AppShortcutDescriptor(
            .newPersistentWindow,
            category: .tabs,
            title: "New Persistent Window",
            default: nil,
            keywords: ["session", "detach"]
        ),
        AppShortcutDescriptor(
            .newRemoteSession,
            category: .tabs,
            title: "New Remote Session…",
            default: KeyCombo("t", modifiers: [.command, .option, .shift]),
            keywords: ["ssh", "host", "connect"]
        ),
        AppShortcutDescriptor(
            .attachToSession,
            category: .tabs,
            title: "Attach to Session…",
            default: nil,
            keywords: ["sessions", "browser", "reconnect"]
        ),
        AppShortcutDescriptor(
            .renameTab,
            category: .tabs,
            title: "Rename Tab…",
            default: nil,
            keywords: ["title", "name"]
        ),
        AppShortcutDescriptor(
            .closeTab,
            category: .tabs,
            title: "Close Tab",
            default: KeyCombo("w", modifiers: [.command, .option])
        ),
        AppShortcutDescriptor(
            .previousTab,
            category: .tabs,
            title: "Previous Tab",
            default: KeyCombo("[", modifiers: [.command, .shift])
        ),
        AppShortcutDescriptor(
            .nextTab,
            category: .tabs,
            title: "Next Tab",
            default: KeyCombo("]", modifiers: [.command, .shift])
        ),
        AppShortcutDescriptor(
            .selectPreviousTab,
            category: .tabs,
            title: "Select Previous Tab",
            default: KeyCombo(.tab, modifiers: [.control, .shift])
        ),
        AppShortcutDescriptor(
            .selectNextTab,
            category: .tabs,
            title: "Select Next Tab",
            default: KeyCombo(.tab, modifiers: [.control])
        ),
        AppShortcutDescriptor(
            .moveTabBackward,
            category: .tabs,
            title: "Move Tab Backward",
            default: KeyCombo(.pageUp, modifiers: [.control, .shift]),
            keywords: ["reorder"]
        ),
        AppShortcutDescriptor(
            .moveTabForward,
            category: .tabs,
            title: "Move Tab Forward",
            default: KeyCombo(.pageDown, modifiers: [.control, .shift]),
            keywords: ["reorder"]
        ),
        AppShortcutDescriptor(
            .moveTabToNewWindow,
            category: .tabs,
            title: "Move Tab to New Window",
            default: nil,
            keywords: ["detach", "pop out"]
        ),
        AppShortcutDescriptor(
            .goToDirectory,
            category: .tabs,
            title: "Go to Directory…",
            default: KeyCombo("g", modifiers: [.command, .shift]),
            keywords: ["cd", "folder", "path"]
        ),

        // MARK: Panes
        AppShortcutDescriptor(
            .splitPaneRight,
            category: .panes,
            title: "Split Pane",
            default: KeyCombo("d", modifiers: [.command]),
            keywords: ["split right", "vertical"]
        ),
        AppShortcutDescriptor(
            .splitPaneDown,
            category: .panes,
            title: "Split Pane Horizontally",
            default: KeyCombo("d", modifiers: [.command, .shift]),
            keywords: ["split down", "horizontal"]
        ),
        AppShortcutDescriptor(
            .splitPaneLeft,
            category: .panes,
            title: "Split Pane Left",
            default: nil,
            keywords: ["vertical", "divide"]
        ),
        AppShortcutDescriptor(
            .splitPaneUp,
            category: .panes,
            title: "Split Pane Up",
            default: nil,
            keywords: ["horizontal", "divide", "above"]
        ),
        AppShortcutDescriptor(
            .closePane,
            category: .panes,
            title: "Close / Close Pane",
            default: KeyCombo("w", modifiers: [.command]),
            keywords: ["close split"]
        ),
        AppShortcutDescriptor(
            .zoomSplit,
            category: .panes,
            title: "Zoom Split",
            default: KeyCombo(.returnKey, modifiers: [.command, .shift]),
            keywords: ["maximize", "pane"]
        ),
        AppShortcutDescriptor(
            .selectPreviousSplit,
            category: .panes,
            title: "Select Previous Split",
            default: KeyCombo("[", modifiers: [.command]),
            keywords: ["focus previous pane"]
        ),
        AppShortcutDescriptor(
            .selectNextSplit,
            category: .panes,
            title: "Select Next Split",
            default: KeyCombo("]", modifiers: [.command]),
            keywords: ["focus next pane"]
        ),
        AppShortcutDescriptor(
            .selectSplitAbove,
            category: .panes,
            title: "Select Split Above",
            default: KeyCombo(.upArrow, modifiers: [.command, .option]),
            keywords: ["focus pane up"]
        ),
        AppShortcutDescriptor(
            .selectSplitBelow,
            category: .panes,
            title: "Select Split Below",
            default: KeyCombo(.downArrow, modifiers: [.command, .option]),
            keywords: ["focus pane down"]
        ),
        AppShortcutDescriptor(
            .selectSplitLeft,
            category: .panes,
            title: "Select Split Left",
            default: KeyCombo(.leftArrow, modifiers: [.command, .option]),
            keywords: ["focus pane left"]
        ),
        AppShortcutDescriptor(
            .selectSplitRight,
            category: .panes,
            title: "Select Split Right",
            default: KeyCombo(.rightArrow, modifiers: [.command, .option]),
            keywords: ["focus pane right"]
        ),
        AppShortcutDescriptor(
            .equalizeSplits,
            category: .panes,
            title: "Equalize Split",
            default: KeyCombo("=", modifiers: [.command, .control]),
            keywords: ["balance"]
        ),
        AppShortcutDescriptor(
            .moveDividerUp,
            category: .panes,
            title: "Move Divider Up",
            default: KeyCombo(.upArrow, modifiers: [.command, .control]),
            keywords: ["resize split"]
        ),
        AppShortcutDescriptor(
            .moveDividerDown,
            category: .panes,
            title: "Move Divider Down",
            default: KeyCombo(.downArrow, modifiers: [.command, .control]),
            keywords: ["resize split"]
        ),
        AppShortcutDescriptor(
            .moveDividerLeft,
            category: .panes,
            title: "Move Divider Left",
            default: KeyCombo(.leftArrow, modifiers: [.command, .control]),
            keywords: ["resize split"]
        ),
        AppShortcutDescriptor(
            .moveDividerRight,
            category: .panes,
            title: "Move Divider Right",
            default: KeyCombo(.rightArrow, modifiers: [.command, .control]),
            keywords: ["resize split"]
        ),

        // MARK: View
        AppShortcutDescriptor(
            .changeTheme,
            category: .view,
            title: "Change Theme…",
            default: KeyCombo("t", modifiers: [.command, .control]),
            keywords: ["colors", "palette"]
        ),
        AppShortcutDescriptor(
            .toggleTabStyle,
            category: .view,
            title: "Toggle Tab Style",
            default: KeyCombo("s", modifiers: [.command, .shift]),
            keywords: ["vertical", "horizontal", "sidebar"]
        ),
        AppShortcutDescriptor(
            .toggleSidebar,
            category: .view,
            title: "Toggle Sidebar",
            default: KeyCombo("/", modifiers: [.command]),
            keywords: ["hide sidebar", "show sidebar"]
        ),
        AppShortcutDescriptor(
            .showPaneHeaders,
            category: .view,
            title: "Show Pane Headers",
            default: nil,
            keywords: ["title bar", "cards"]
        ),
        AppShortcutDescriptor(
            .biggerFont,
            category: .view,
            title: "Bigger Font",
            default: KeyCombo("=", modifiers: [.command]),
            keywords: ["increase font size", "zoom in", "plus"]
        ),
        AppShortcutDescriptor(
            .smallerFont,
            category: .view,
            title: "Smaller Font",
            default: KeyCombo("-", modifiers: [.command]),
            keywords: ["decrease font size", "zoom out"]
        ),
        AppShortcutDescriptor(
            .defaultFontSize,
            category: .view,
            title: "Default Font Size",
            default: KeyCombo("0", modifiers: [.command]),
            keywords: ["reset font size"]
        ),

        // MARK: Terminal
        AppShortcutDescriptor(
            .clearToStart,
            category: .terminal,
            title: "Clear to Start",
            default: KeyCombo("k", modifiers: [.command, .control]),
            keywords: ["clear terminal", "scrollback"]
        ),
        AppShortcutDescriptor(
            .scrollToPreviousPrompt,
            category: .terminal,
            title: "Scroll to Previous Prompt",
            default: KeyCombo(.upArrow, modifiers: [.command]),
            keywords: ["jump prompt"]
        ),
        AppShortcutDescriptor(
            .scrollToNextPrompt,
            category: .terminal,
            title: "Scroll to Next Prompt",
            default: KeyCombo(.downArrow, modifiers: [.command]),
            keywords: ["jump prompt"]
        ),
        AppShortcutDescriptor(
            .softReset,
            category: .terminal,
            title: "Soft Reset",
            default: nil,
            keywords: ["decstr", "reset terminal"]
        ),
        AppShortcutDescriptor(
            .hardReset,
            category: .terminal,
            title: "Hard Reset",
            default: nil,
            keywords: ["ris", "reset terminal"]
        ),
        AppShortcutDescriptor(
            .allowMouseReporting,
            category: .terminal,
            title: "Allow Mouse Reporting",
            default: KeyCombo("r", modifiers: [.command])
        ),
        AppShortcutDescriptor(
            .optionAsMetaKey,
            category: .terminal,
            title: "Use Option as Meta Key",
            default: nil,
            keywords: ["alt", "emacs"]
        ),
        AppShortcutDescriptor(
            .exportBuffer,
            category: .terminal,
            title: "Export Buffer…",
            default: nil,
            keywords: ["save scrollback"]
        ),
        AppShortcutDescriptor(
            .exportSelection,
            category: .terminal,
            title: "Export Selection…",
            default: nil
        ),
        AppShortcutDescriptor(
            .printTerminal,
            category: .terminal,
            title: "Print…",
            default: nil,
            keywords: ["pdf"]
        ),

        // MARK: Find & Edit
        AppShortcutDescriptor(
            .find,
            category: .findAndEdit,
            title: "Find…",
            default: KeyCombo("f", modifiers: [.command]),
            keywords: ["search"]
        ),
        AppShortcutDescriptor(
            .findNext,
            category: .findAndEdit,
            title: "Find Next",
            default: KeyCombo("g", modifiers: [.command])
        ),
        AppShortcutDescriptor(
            .findPrevious,
            category: .findAndEdit,
            title: "Find Previous",
            default: KeyCombo("g", modifiers: [.command, .control])
        ),
        AppShortcutDescriptor(
            .pasteEscaped,
            category: .findAndEdit,
            title: "Paste Escaped",
            default: KeyCombo("v", modifiers: [.command, .control]),
            keywords: ["shell", "quote"]
        )
    ]

    static let descriptorsByID: [AppShortcutID: AppShortcutDescriptor] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) }
    )

    static let byCategory: [AppShortcutCategory: [AppShortcutDescriptor]] = Dictionary(
        grouping: all,
        by: \.category
    )
}
