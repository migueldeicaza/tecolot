//
//  SettingsCatalog.swift
//  Tecolot
//
//  Search metadata for every page, section and setting in Settings.
//
import Foundation

/// Names one page, section or setting in the Settings window.
///
/// The declaration order is the order of the sidebar and of the rows on
/// each page. Search uses it to order results with the same score.
enum SettingID: String, CaseIterable, Hashable {
    // General
    case pageGeneral
    case generalSectionStartup
    case generalStartupOpen
    case generalStartupProfile
    case generalStartupGroups
    case generalRestoreRows
    case generalSectionNewWindows
    case generalDefaultProfile
    case generalNewTabsCurrentDirectory
    case generalNewTabsCurrentProfile
    case generalSecureKeyboardEntry
    case generalCopyOnSelection
    case generalUseMetal
    case generalSectionUpdates
    case generalCheckForUpdates
    case generalDownloadUpdates

    // Tabs
    case pageTabs
    case tabsSectionLayout
    case tabsStyle
    case tabsFillAvailableSpace
    case tabsShowIcons
    case tabsCommandDigits
    case tabsSectionLook
    case tabsIconColor
    case tabsGeneratedTitles
    case tabsAnimationStyle
    case tabsSectionSidebar
    case tabsSidebarTextSize
    case tabsSidebarPreserveWidth
    case tabsSidebarGesture

    // Panes
    case pagePanes
    case panesSectionPanes
    case panesPadding
    case panesStyle
    case panesShowHeaders
    case panesBackground
    case panesSectionActivePane
    case panesHighlightActivePane
    case panesHighlightColor

    // Notifications
    case pageNotifications
    case notificationsSectionProgramActivity
    case notificationsNotify
    case notificationsDockBadge
    case notificationsSounds
    case notificationsSectionInTabs
    case notificationsShowInTabs
    case notificationsBounceIcons
    case notificationsAnnounce
    case notificationsScrollSpeed
    case notificationsStatusColor
    case notificationsSectionStates
    case notificationsStateWorking
    case notificationsStateBlocked
    case notificationsStateError
    case notificationsStateDone
    case notificationsSectionFromPrograms
    case notificationsBell
    case notificationsAllowPrograms

    // Data and Crash Reports
    case pageData
    case pageCrashReports

    // Profile: Appearance
    case pageAppearance
    case appearanceFont
    case appearanceCursor
    case appearanceBrightBold
    case appearanceBackgroundOpacity
    case appearanceLightTheme
    case appearanceDarkTheme
    case appearanceWindowChrome

    // Profile: Window
    case pageWindow
    case windowColumns
    case windowRows
    case windowSectionTitle
    case windowTitleSource
    case windowCustomTitle
    case windowTitleActiveTitle
    case windowTitleWorkingDirectory
    case windowTitleFullPath
    case windowTitleProfileName
    case windowTitleDimensions

    // Profile: Shell
    case pageShell
    case shellRun
    case shellCommand
    case shellRunInsideShell
    case shellWhenExits
    case shellAskBeforeClosing
    case shellSession
    case shellEnvironment

    // Profile: Keyboard and Mouse
    case pageKeyboardAndMouse
    case keyboardOptionAsMeta
    case keyboardDeleteSendsControlH
    case keyboardHidePointer
    case keyboardKeyMappings

    // Profile: Terminal
    case pageTerminal
    case terminalDeclareAs
    case terminalTermProgram
    case terminalTermVersion
    case terminalOSC8Links
    case terminalScreenChecksum
    case terminalLimitScrollback
    case terminalScrollbackLines

    // Profiles
    case pageManageProfiles
}

/// What Settings search knows about one page, section or setting.
struct SettingsSearchEntry: Identifiable {
    enum Kind {
        case page
        case section
        case setting
    }

    let id: SettingID
    let kind: Kind
    let destination: SettingsDestination
    /// The titled section that holds a setting.
    var section: SettingID?
    /// The text shown on the row, the section header or the sidebar.
    let title: String
    /// One sentence for the results list. It says what the setting does.
    let summary: String
    /// Other words a person may type. They do not show on screen.
    var keywords: [String] = []
    /// Tells when a row is on the page, for a row that is not always there.
    var note: String?
    /// The row that makes this row appear. Search opens that row when this
    /// row is not on the page.
    var revealedBy: SettingID?
    /// True for rows that exist only when the app can update itself.
    var requiresUpdater = false

    /// The path shown above the title in the results list.
    var breadcrumb: String {
        var parts: [String] = []
        if destination.isProfileDriven {
            parts.append("Profile")
        }
        if kind != .page {
            parts.append(destination.title)
        }
        if let section {
            parts.append(section.entry.title)
        }
        return parts.joined(separator: " \u{203A} ")
    }
}

extension SettingID {
    /// The row label. Pages use it so that a row and its search result
    /// always have the same text.
    var title: String {
        entry.title
    }

    /// The search metadata of this page, section or setting.
    var entry: SettingsSearchEntry {
        // The catalog has an entry for every case.
        SettingsCatalog.entriesByID[self]!
    }

    /// The rows to show when search opens this entry. A section shows all
    /// its settings, and a page shows none.
    var revealTargets: [SettingID] {
        switch entry.kind {
        case .page:
            return []
        case .section:
            return SettingsCatalog.settingsBySection[self] ?? []
        case .setting:
            return [self]
        }
    }
}

enum SettingsCatalog {
    /// Every entry, in sidebar and row order. Built once.
    static let entries: [SettingsSearchEntry] = SettingID.allCases.map(\.makeEntry)
    static let entriesByID: [SettingID: SettingsSearchEntry] = Dictionary(
        uniqueKeysWithValues: entries.map { ($0.id, $0) }
    )
    /// The settings of each section, in row order.
    static let settingsBySection: [SettingID: [SettingID]] = Dictionary(
        grouping: entries.filter { $0.section != nil },
        by: { $0.section! }
    ).mapValues { $0.map(\.id) }
}

private func pageEntry(
    _ id: SettingID,
    _ destination: SettingsDestination,
    _ summary: String,
    keywords: [String] = []
) -> SettingsSearchEntry {
    SettingsSearchEntry(
        id: id, kind: .page, destination: destination, title: destination.title, summary: summary, keywords: keywords
    )
}

private func sectionEntry(
    _ id: SettingID,
    _ destination: SettingsDestination,
    _ title: String,
    _ summary: String,
    keywords: [String] = [],
    note: String? = nil,
    revealedBy: SettingID? = nil,
    requiresUpdater: Bool = false
) -> SettingsSearchEntry {
    SettingsSearchEntry(
        id: id, kind: .section, destination: destination, title: title, summary: summary, keywords: keywords,
        note: note, revealedBy: revealedBy, requiresUpdater: requiresUpdater
    )
}

private func settingEntry(
    _ id: SettingID,
    _ destination: SettingsDestination,
    in section: SettingID? = nil,
    _ title: String,
    _ summary: String,
    keywords: [String] = [],
    note: String? = nil,
    revealedBy: SettingID? = nil,
    requiresUpdater: Bool = false
) -> SettingsSearchEntry {
    SettingsSearchEntry(
        id: id, kind: .setting, destination: destination, section: section, title: title, summary: summary,
        keywords: keywords, note: note, revealedBy: revealedBy, requiresUpdater: requiresUpdater
    )
}

extension SettingID {
    /// The words people use for the title that a program sets with an
    /// escape sequence. "program title" and "window title" are not here:
    /// Active title and the Window › Title section must come first for them.
    fileprivate static let titleSourceKeywords = [
        "OSC", "OSC 0", "OSC 2", "escape sequence", "terminal title", "xterm title",
        "computed title", "generated title", "automatic title",
    ]

    fileprivate static let titleSourceSummary =
        "Show the running program and folder, or the items of the profile Title section."

    /// The summary of a profile title item. The item always changes the pane
    /// header, and changes tabs and windows only for one Title shows value.
    fileprivate static func titleItemSummary(_ action: String) -> String {
        let source = TabStripPreferences.TitleSource.self
        return "\(action) in the pane header. Tabs and windows also show it when "
            + "“\(source.settingTitle)” is set to “\(source.profile.title)”."
    }

    /// The switch has no default case, so a new ID without metadata does
    /// not compile. Use `entry`, which reads the catalog that is built once.
    fileprivate var makeEntry: SettingsSearchEntry {
        switch self {
        // MARK: General
        case .pageGeneral:
            return pageEntry(self, .general, "Choose what opens at startup, how new tabs start, and how the app updates.",
                        keywords: ["preferences", "app"])
        case .generalSectionStartup:
            return sectionEntry(self, .general, "Startup", "Choose what Tecolot opens when it starts.",
                           keywords: ["launch", "open at login", "restore"])
        case .generalStartupOpen:
            return settingEntry(self, .general, in: .generalSectionStartup, "Open",
                           "Start with the default profile, a profile you choose, or groups you choose.",
                           keywords: ["startup", "launch", "on start", "new group", "restore groups"])
        case .generalStartupProfile:
            return settingEntry(self, .general, in: .generalSectionStartup, "Profile",
                           "Choose the profile for the group that opens at startup.",
                           keywords: ["startup profile", "launch"],
                           note: "Shown when Open is set to a new group with this profile.",
                           revealedBy: .generalStartupOpen)
        case .generalStartupGroups:
            return settingEntry(self, .general, in: .generalSectionStartup, "Startup groups",
                           "Choose the groups that open at startup.",
                           keywords: ["launch", "restore groups", "workspaces"],
                           note: "Shown when Open is set to these groups.",
                           revealedBy: .generalStartupOpen)
        case .generalRestoreRows:
            return settingEntry(self, .general, in: .generalSectionStartup, "Restore rows when a saved session opens",
                           "Set how many rows of terminal text come back with a saved session.",
                           keywords: ["scrollback", "history", "restore text", "lines", "session restore"])
        case .generalSectionNewWindows:
            return sectionEntry(self, .general, "New windows and tabs",
                           "Choose the profile and working directory for new windows and tabs.",
                           keywords: ["new tab", "new window"])
        case .generalDefaultProfile:
            return settingEntry(self, .general, in: .generalSectionNewWindows, "Default profile",
                           "Choose the profile for new windows and wherever no profile is given.",
                           keywords: ["new window profile", "standard profile"])
        case .generalNewTabsCurrentDirectory:
            return settingEntry(self, .general, in: .generalSectionNewWindows,
                           "Open with the working directory of the current tab",
                           "Start new tabs in the folder of the tab you are in.",
                           keywords: ["cwd", "folder", "current directory", "inherit directory", "pwd", "path"])
        case .generalNewTabsCurrentProfile:
            return settingEntry(self, .general, in: .generalSectionNewWindows, "Use the profile of the current window",
                           "Start new tabs with the profile of the window you are in.",
                           keywords: ["inherit profile", "new tab profile"])
        case .generalSecureKeyboardEntry:
            return settingEntry(self, .general, "Secure keyboard entry",
                           "Stop other apps from reading what you type.",
                           keywords: ["input", "password", "keylogger", "secure input", "privacy", "security"])
        case .generalCopyOnSelection:
            return settingEntry(self, .general, "Copy on selection",
                           "Copy text to the clipboard when you finish selecting it.",
                           keywords: ["clipboard", "copy on select", "pasteboard", "auto copy", "select to copy"])
        case .generalUseMetal:
            return settingEntry(self, .general, "Use Metal",
                           "Draw terminal text with the GPU.",
                           keywords: ["rendering", "renderer", "gpu", "graphics", "performance", "hardware acceleration"])
        case .generalSectionUpdates:
            return sectionEntry(self, .general, "Updates", "Choose how Tecolot checks for and downloads updates.",
                           keywords: ["software update", "sparkle", "new version"], requiresUpdater: true)
        case .generalCheckForUpdates:
            return settingEntry(self, .general, in: .generalSectionUpdates, "Check for updates automatically",
                           "Look for new versions of Tecolot in the background.",
                           keywords: ["software update", "auto update", "new version"], requiresUpdater: true)
        case .generalDownloadUpdates:
            return settingEntry(self, .general, in: .generalSectionUpdates, "Download updates automatically",
                           "Download new versions when Tecolot finds them.",
                           keywords: ["software update", "auto update", "install updates"], requiresUpdater: true)

        // MARK: Tabs
        case .pageTabs:
            return pageEntry(self, .tabs, "Choose where tabs go, how they look, and how the tab sidebar works.",
                        keywords: ["tab bar", "sidebar"])
        case .tabsSectionLayout:
            return sectionEntry(self, .tabs, "Layout", "Choose where tabs go and what they show.",
                           keywords: ["tab bar", "position"])
        case .tabsStyle:
            return settingEntry(self, .tabs, in: .tabsSectionLayout, "Tab style",
                           "Show tabs above the terminal or in a sidebar on the left or right.",
                           keywords: ["vertical tabs", "horizontal tabs", "sidebar", "tab bar position", "side tabs"])
        case .tabsFillAvailableSpace:
            return settingEntry(self, .tabs, in: .tabsSectionLayout, "Fill available space",
                           "Stretch tabs to use the full width of the tab bar.",
                           keywords: ["tab width", "wide tabs", "stretch", "expand"],
                           note: "Shown when tabs are above the terminal.",
                           revealedBy: .tabsStyle)
        case .tabsShowIcons:
            return settingEntry(self, .tabs, in: .tabsSectionLayout, "Show tab icons",
                           "Choose how many program icons each tab shows.",
                           keywords: ["program icons", "glyphs", "hide icons", "icon count"])
        case .tabsCommandDigits:
            return settingEntry(self, .tabs, in: .tabsSectionLayout, "Use Command-1 through Command-9 to select tabs",
                           "Switch to a tab by its position with Command and a number.",
                           keywords: ["shortcut", "keyboard", "cmd", "switch tabs", "number keys", "hotkey"])
        case .tabsSectionLook:
            return sectionEntry(self, .tabs, "Look", "Choose tab colors, titles and animation.",
                           keywords: ["appearance"])
        case .tabsIconColor:
            return settingEntry(self, .tabs, in: .tabsSectionLook, "Use color for tab icons",
                           "Color tab icons always, only for active tabs or panes, or never.",
                           keywords: ["colour", "monochrome", "gray icons", "tint"])
        case .tabsGeneratedTitles:
            return settingEntry(self, .tabs, in: .tabsSectionLook, TabStripPreferences.TitleSource.settingTitle,
                           Self.titleSourceSummary,
                           keywords: Self.titleSourceKeywords + ["tab name", "rename", "prefer generated tab titles"])
        case .tabsAnimationStyle:
            return settingEntry(self, .tabs, in: .tabsSectionLook, "Animation style",
                           "Make tab animations natural or snappy, or turn them off.",
                           keywords: ["motion", "turn off animations", "disable animation", "speed"])
        case .tabsSectionSidebar:
            return sectionEntry(self, .tabs, "Sidebar", "Set the text size, width and gesture of the tab sidebar.",
                           keywords: ["vertical tabs", "side tabs"],
                           note: "Shown when tabs are on the side.",
                           revealedBy: .tabsStyle)
        case .tabsSidebarTextSize:
            return settingEntry(self, .tabs, in: .tabsSectionSidebar, "Sidebar text size",
                           "Set the size of tab names in the sidebar.",
                           keywords: ["font size", "larger text", "smaller text", "vertical tabs"],
                           note: "Shown when tabs are on the side.",
                           revealedBy: .tabsStyle)
        case .tabsSidebarPreserveWidth:
            return settingEntry(self, .tabs, in: .tabsSectionSidebar, "Preserve width when resizing sidebar",
                           "Keep the terminal the same width when the sidebar changes size.",
                           keywords: ["window width", "resize", "vertical tabs"],
                           note: "Shown when tabs are on the side.",
                           revealedBy: .tabsStyle)
        case .tabsSidebarGesture:
            return settingEntry(self, .tabs, in: .tabsSectionSidebar, "Use a gesture to toggle the sidebar",
                           "Show or hide the sidebar with a swipe or an Option-swipe.",
                           keywords: ["trackpad", "swipe", "hide sidebar", "show sidebar", "vertical tabs"],
                           note: "Shown when tabs are on the side.",
                           revealedBy: .tabsStyle)

        // MARK: Panes
        case .pagePanes:
            return pageEntry(self, .panes, "Set pane padding, style, headers and the active pane highlight.",
                        keywords: ["splits", "split view"])
        case .panesSectionPanes:
            return sectionEntry(self, .panes, "Panes", "Set pane padding, style, headers and background.",
                           keywords: ["splits"])
        case .panesPadding:
            return settingEntry(self, .panes, in: .panesSectionPanes, "Padding",
                           "Set the space between terminal text and the pane edge.",
                           keywords: ["margin", "inset", "spacing", "terminal padding", "border space"])
        case .panesStyle:
            return settingEntry(self, .panes, in: .panesSectionPanes, "Pane style",
                           "Choose comfortable panes, or compact panes with no spacing, round corners or shadows.",
                           keywords: ["compact", "comfortable", "cards", "rounded corners", "shadows", "gaps"])
        case .panesShowHeaders:
            return settingEntry(self, .panes, in: .panesSectionPanes, "Show pane headers",
                           "Show a header with the title above each pane.",
                           keywords: ["title bar", "pane title", "hide headers"])
        case .panesBackground:
            return settingEntry(self, .panes, in: .panesSectionPanes, "Background",
                           "Choose what shows behind comfortable panes.",
                           keywords: ["backdrop", "behind panes", "wallpaper", "canvas"])
        case .panesSectionActivePane:
            return sectionEntry(self, .panes, "Active pane", "Highlight the pane that has focus and choose the color.",
                           keywords: ["focus", "focused pane", "border"])
        case .panesHighlightActivePane:
            return settingEntry(self, .panes, in: .panesSectionActivePane, "Highlight active pane",
                           "Draw an outline around the pane that has focus.",
                           keywords: ["focus ring", "border", "outline", "focused pane", "show border on active pane"])
        case .panesHighlightColor:
            return settingEntry(self, .panes, in: .panesSectionActivePane, "Highlight color",
                           "Choose the outline color, or follow the system accent color.",
                           keywords: ["colour", "accent", "focus ring color", "border color", "opacity"])

        // MARK: Notifications
        case .pageNotifications:
            return pageEntry(self, .notifications,
                        "Choose how Tecolot tells you about program activity, the bell and program notifications.",
                        keywords: ["alerts", "sounds", "badges"])
        case .notificationsSectionProgramActivity:
            return sectionEntry(self, .notifications, "Program activity",
                           "Get system notifications, Dock badges and sounds for program activity.",
                           keywords: ["alerts", "agents"])
        case .notificationsNotify:
            return settingEntry(self, .notifications, in: .notificationsSectionProgramActivity,
                           "Notify when a program finishes or needs attention",
                           "Show a system notification while Tecolot is not in front.",
                           keywords: ["alert", "notify when done", "notify when blocked", "banner", "command finished",
                                      "claude notification", "agent"])
        case .notificationsDockBadge:
            return settingEntry(self, .notifications, in: .notificationsSectionProgramActivity, "Badge Dock icon",
                           "Show a count on the Dock icon for programs that need attention.",
                           keywords: ["app icon badge", "count", "red dot"])
        case .notificationsSounds:
            return settingEntry(self, .notifications, in: .notificationsSectionProgramActivity, "Play sounds",
                           "Play a sound when a program finishes or needs attention.",
                           keywords: ["audio", "mute", "chime", "silent", "quiet"])
        case .notificationsSectionInTabs:
            return sectionEntry(self, .notifications, "In tabs", "Choose how tabs show program activity.",
                           keywords: ["tab indicator", "status"])
        case .notificationsShowInTabs:
            return settingEntry(self, .notifications, in: .notificationsSectionInTabs, "Show activity in tabs",
                           "Show the state of each program on its tab.",
                           keywords: ["status badge", "indicator", "spinner", "busy"])
        case .notificationsBounceIcons:
            return settingEntry(self, .notifications, in: .notificationsSectionInTabs, "Bounce tab icons",
                           "Bounce the icon of a tab when its program needs attention.",
                           keywords: ["animation", "attention", "jump"])
        case .notificationsAnnounce:
            return settingEntry(self, .notifications, in: .notificationsSectionInTabs, "Announce messages in tabs",
                           "Scroll messages from programs across their tabs.",
                           keywords: ["ticker", "marquee", "scrolling text", "status message"])
        case .notificationsScrollSpeed:
            return settingEntry(self, .notifications, in: .notificationsSectionInTabs, "Message scroll speed",
                           "Set how fast messages scroll across tabs.",
                           keywords: ["ticker speed", "marquee speed"])
        case .notificationsStatusColor:
            return settingEntry(self, .notifications, in: .notificationsSectionInTabs, "Use color for status badges",
                           "Color the activity badges on tabs.",
                           keywords: ["colour", "monochrome", "indicator color"])
        case .notificationsSectionStates:
            return sectionEntry(self, .notifications, "States",
                           "Choose the program states that show on tabs and send notifications.",
                           keywords: ["working", "blocked", "error", "done"])
        case .notificationsStateWorking:
            return settingEntry(self, .notifications, in: .notificationsSectionStates, "Working",
                           "Show on the tab when a program is working.",
                           keywords: ["busy", "running", "in progress"])
        case .notificationsStateBlocked:
            return settingEntry(self, .notifications, in: .notificationsSectionStates, "Blocked",
                           "Show and notify when a program waits for you.",
                           keywords: ["waiting", "needs input", "needs attention", "permission"])
        case .notificationsStateError:
            return settingEntry(self, .notifications, in: .notificationsSectionStates, "Error",
                           "Show and notify when a program fails.",
                           keywords: ["failed", "failure", "crash"])
        case .notificationsStateDone:
            return settingEntry(self, .notifications, in: .notificationsSectionStates, "Done",
                           "Show and notify when a program finishes.",
                           keywords: ["finished", "complete", "success"])
        case .notificationsSectionFromPrograms:
            return sectionEntry(self, .notifications, "From programs",
                           "Choose what the bell does and whether programs can send notifications.",
                           keywords: ["bell", "osc 9", "osc 777"])
        case .notificationsBell:
            return settingEntry(self, .notifications, in: .notificationsSectionFromPrograms, "Bell",
                           "Choose what happens when a program rings the terminal bell.",
                           keywords: ["beep", "audible bell", "visual bell", "alert sound", "BEL", "mute bell"])
        case .notificationsAllowPrograms:
            return settingEntry(self, .notifications, in: .notificationsSectionFromPrograms,
                           "Allow programs to send notifications",
                           "Let terminal programs show system notifications with OSC 9 or OSC 777.",
                           keywords: ["osc 9", "osc 777", "escape sequence", "desktop notification"])

        // MARK: Data and Crash Reports
        case .pageData:
            return pageEntry(self, .data, "Find and repair profile, theme and preference files that have problems.",
                        keywords: ["recovery", "backup", "restore", "reset preferences", "damaged", "corrupt"])
        case .pageCrashReports:
            return pageEntry(self, .crashReports, "Read the crash reports that Tecolot saved and find where they are stored.",
                        keywords: ["crash log", "diagnostics", "bug report"])

        // MARK: Profile: Appearance
        case .pageAppearance:
            return pageEntry(self, .appearance, "Choose the font, cursor, themes and window colors of a profile.",
                        keywords: ["text", "colors", "themes", "look"])
        case .appearanceFont:
            return settingEntry(self, .appearance, "Font",
                           "Choose the terminal typeface and its size.",
                           keywords: ["typeface", "font size", "font family", "monospaced", "text size", "typography"])
        case .appearanceCursor:
            return settingEntry(self, .appearance, "Cursor",
                           "Choose a block, bar or underline cursor, steady or blinking.",
                           keywords: ["caret", "cursor shape", "cursor style", "blink", "block", "bar", "underline"])
        case .appearanceBrightBold:
            return settingEntry(self, .appearance, "Use bright colors for bold text",
                           "Draw bold text with the bright form of its color.",
                           keywords: ["bold is bright", "intense colors", "ansi colors"])
        case .appearanceBackgroundOpacity:
            return settingEntry(self, .appearance, "Background opacity",
                           "Make the terminal background more or less transparent.",
                           keywords: ["transparency", "transparent", "translucent", "see through", "alpha"])
        case .appearanceLightTheme:
            return settingEntry(self, .appearance, "Light mode",
                           "Choose or make the theme for the system light appearance.",
                           keywords: ["light theme", "color scheme", "colors", "palette", "new theme",
                                      "extended palette", "256 colors", "color cube", "xterm colors"])
        case .appearanceDarkTheme:
            return settingEntry(self, .appearance, "Dark mode",
                           "Choose or make the theme for the system dark appearance.",
                           keywords: ["dark theme", "color scheme", "colors", "palette", "new theme",
                                      "extended palette", "256 colors", "color cube", "xterm colors"])
        case .appearanceWindowChrome:
            return settingEntry(self, .appearance, "Match window chrome to theme",
                           "Use the theme colors for the title bar, tabs and toolbar controls.",
                           keywords: ["title bar color", "toolbar color", "window color", "tab bar color"])

        // MARK: Profile: Window
        case .pageWindow:
            return pageEntry(self, .window, "Set the size of new windows and what the window title shows.",
                        keywords: ["size", "title"])
        case .windowColumns:
            return settingEntry(self, .window, "Columns",
                           "Set the width of new windows in characters.",
                           keywords: ["window width", "window size", "initial size", "cols", "80"])
        case .windowRows:
            return settingEntry(self, .window, "Rows",
                           "Set the height of new windows in lines.",
                           keywords: ["window height", "window size", "initial size", "lines", "24"])
        case .windowSectionTitle:
            return sectionEntry(self, .window, "Title", "Choose what the pane header, and the tab and window titles, show.",
                           keywords: ["window title", "title bar", "tab title"])
        case .windowTitleSource:
            return settingEntry(self, .window, in: .windowSectionTitle, TabStripPreferences.TitleSource.settingTitle,
                           Self.titleSourceSummary + " This setting applies to all profiles.",
                           keywords: Self.titleSourceKeywords)
        case .windowCustomTitle:
            return settingEntry(self, .window, in: .windowSectionTitle, "Custom title",
                           Self.titleItemSummary("Show your own text"),
                           keywords: ["window name", "rename window", "title override"])
        case .windowTitleActiveTitle:
            return settingEntry(self, .window, in: .windowSectionTitle, "Active title",
                           Self.titleItemSummary("Show the title that the running program sets"),
                           keywords: ["program title", "process name", "terminal title"])
        case .windowTitleWorkingDirectory:
            return settingEntry(self, .window, in: .windowSectionTitle, "Working directory",
                           Self.titleItemSummary("Show the name of the current folder"),
                           keywords: ["cwd", "folder", "path", "current directory"])
        case .windowTitleFullPath:
            return settingEntry(self, .window, in: .windowSectionTitle, "Full path",
                           Self.titleItemSummary("Show the full path of the current folder"),
                           keywords: ["cwd", "folder", "absolute path", "directory"])
        case .windowTitleProfileName:
            return settingEntry(self, .window, in: .windowSectionTitle, "Profile name",
                           Self.titleItemSummary("Show the name of the profile"))
        case .windowTitleDimensions:
            return settingEntry(self, .window, in: .windowSectionTitle, "Dimensions",
                           Self.titleItemSummary("Show the columns and rows of the terminal"),
                           keywords: ["size", "columns", "rows", "80x24"])

        // MARK: Profile: Shell
        case .pageShell:
            return pageEntry(self, .shell, "Choose what a profile runs, what happens when it exits, and its environment.",
                        keywords: ["command", "login shell", "environment"])
        case .shellRun:
            return settingEntry(self, .shell, "Run",
                           "Start the default login shell or a command you choose.",
                           keywords: ["login shell", "startup command", "zsh", "bash", "fish", "program", "custom shell"])
        case .shellCommand:
            return settingEntry(self, .shell, "Command",
                           "Type the command that the profile runs.",
                           keywords: ["startup command", "custom shell", "program", "ssh"],
                           note: "Shown when Run is set to Command.",
                           revealedBy: .shellRun)
        case .shellRunInsideShell:
            return settingEntry(self, .shell, "Run inside shell",
                           "Start the command from your login shell so that it has your shell setup.",
                           keywords: ["login shell", "shell wrapper", "rc files", "path"],
                           note: "Shown when Run is set to Command.",
                           revealedBy: .shellRun)
        case .shellWhenExits:
            return settingEntry(self, .shell, "When the shell exits",
                           "Close the pane or keep it open when the shell ends.",
                           keywords: ["close on exit", "keep open", "close window", "process ended"])
        case .shellAskBeforeClosing:
            return settingEntry(self, .shell, "Ask before closing",
                           "Choose when Tecolot asks before it closes a pane.",
                           keywords: ["confirm close", "warning", "prompt", "running process", "quit confirmation"])
        case .shellSession:
            return settingEntry(self, .shell, "Shell session",
                           "Keep the shell running after you close its pane or quit Tecolot.",
                           keywords: ["persistent session", "attach", "detach", "background", "tmux", "keep running"])
        case .shellEnvironment:
            return settingEntry(self, .shell, "Environment",
                           "Add, change or unset environment variables for the profile.",
                           keywords: ["environment variables", "env", "export", "PATH", "unset", "variables"])

        // MARK: Profile: Keyboard and Mouse
        case .pageKeyboardAndMouse:
            return pageEntry(self, .keyboardAndMouse, "Set the Option and Delete keys, the pointer and key mappings.",
                        keywords: ["keys", "shortcuts", "input"])
        case .keyboardOptionAsMeta:
            return settingEntry(self, .keyboardAndMouse, "Option key as Meta",
                           "Select the Option keys that send Meta, for programs such as Emacs. The other key types the characters of the keyboard layout.",
                           keywords: ["use option as meta", "alt", "escape prefix", "esc+", "emacs", "special characters",
                                      "left option", "right option", "altgr", "layout", "norwegian", "german", "pipe"])
        case .keyboardDeleteSendsControlH:
            return settingEntry(self, .keyboardAndMouse, "Delete sends Control-H",
                           "Send Control-H, not DEL, when you press Delete.",
                           keywords: ["backspace", "ctrl-h", "^H", "erase"])
        case .keyboardHidePointer:
            return settingEntry(self, .keyboardAndMouse, "Hide pointer while typing",
                           "Hide the mouse pointer until you move the mouse.",
                           keywords: ["mouse", "cursor", "hide mouse"])
        case .keyboardKeyMappings:
            return settingEntry(self, .keyboardAndMouse, "Key mappings",
                           "Make a key send text or an escape sequence.",
                           keywords: ["key bindings", "keybindings", "shortcuts", "remap", "send text", "escape sequence",
                                      "hotkey"])

        // MARK: Profile: Terminal
        case .pageTerminal:
            return pageEntry(self, .terminal, "Set the terminal type, links, screen reports and scrollback.",
                        keywords: ["TERM", "emulation", "scrollback"])
        case .terminalDeclareAs:
            return settingEntry(self, .terminal, "Declare terminal as",
                           "Set the TERM value that programs see.",
                           keywords: ["TERM", "terminfo", "xterm-256color", "terminal type", "emulation"])
        case .terminalTermProgram:
            return settingEntry(self, .terminal, "TERM_PROGRAM",
                           "Set the TERM_PROGRAM value that programs see.",
                           keywords: ["environment", "terminal name", "ghostty"],
                           note: "Shown when the terminal is declared as xterm-ghostty.",
                           revealedBy: .terminalDeclareAs)
        case .terminalTermVersion:
            return settingEntry(self, .terminal, "TERM_VERSION",
                           "Set the TERM_VERSION value that programs see.",
                           keywords: ["environment", "terminal version", "ghostty", "TERM_PROGRAM_VERSION"],
                           note: "Shown when the terminal is declared as xterm-ghostty.",
                           revealedBy: .terminalDeclareAs)
        case .terminalOSC8Links:
            return settingEntry(self, .terminal, "Enable OSC 8 links",
                           "Let programs make text into links.",
                           keywords: ["hyperlinks", "urls", "clickable links", "escape sequence"])
        case .terminalScreenChecksum:
            return settingEntry(self, .terminal, "Allow programs to read screen contents",
                           "Answer DECRQCRA screen checksum requests, which test tools use.",
                           keywords: ["DECRQCRA", "checksum", "vttest", "esctest", "security", "privacy"])
        case .terminalLimitScrollback:
            return settingEntry(self, .terminal, "Limit scrollback",
                           "Keep a set number of lines of history, not all of them.",
                           keywords: ["history", "buffer", "unlimited scrollback", "memory", "lines"])
        case .terminalScrollbackLines:
            return settingEntry(self, .terminal, "Scrollback lines",
                           "Set how many lines of history the terminal keeps.",
                           keywords: ["history size", "buffer size", "scroll buffer"],
                           note: "Shown when Limit scrollback is on.",
                           revealedBy: .terminalLimitScrollback)

        // MARK: Profiles
        case .pageManageProfiles:
            return pageEntry(self, .manageProfiles, "Add, duplicate, rename, import, export and delete profiles.",
                        keywords: ["new profile", "delete profile", "import profile", "export profile", "presets",
                                   "default profile"])
        }
    }
}
