//
//  TerminalProfile.swift
//  Tecolot
//
//  A profile bundles the behavioral settings of a terminal window: which
//  theme to use, font, window geometry, the shell to run and what happens
//  when it exits. Colors live in the referenced TerminalTheme, not here.
//
import Foundation
@preconcurrency import SwiftTerm

/// What to run when a terminal session starts
public enum ShellCommand: Codable, Equatable, Sendable {
    /// The user's login shell from the password database, run with the
    /// "-shellname" argv[0] login idiom
    case loginShell
    /// A specific command; when runInShell is true it is executed via the
    /// user's shell ("shell -lc command"), otherwise argv-split and exec'ed
    case command(String, runInShell: Bool)
}

/// What happens to the window when the shell process exits
public enum ShellExitBehavior: String, Codable, CaseIterable, Sendable, CustomStringConvertible {
    case closeWindow
    case closeIfExitedCleanly
    case keepOpen

    public var description: String {
        switch self {
        case .closeWindow:
            return "Close the window"
        case .closeIfExitedCleanly:
            return "Close if the shell exited cleanly"
        case .keepOpen:
            return "Don't close the window"
        }
    }
}

/// Whether a profile's shells keep running when their pane closes
public enum SessionPersistence: String, Codable, CaseIterable, Sendable, CustomStringConvertible {
    /// The shell runs in the app and ends when its pane closes
    case standard
    /// The shell runs in a persistent session (tecolot-sessiond): closing the
    /// pane or quitting the app detaches, and File > Sessions > Attach to Session
    /// shows it again
    case persistent

    public var description: String {
        switch self {
        case .standard:
            return "End when the pane closes"
        case .persistent:
            return "Keep running (persistent session)"
        }
    }
}

/// Whether closing a window with a live process asks for confirmation
public enum AskBeforeClosing: String, Codable, CaseIterable, Sendable, CustomStringConvertible {
    case always
    case never
    case onlyIfProcessesRunning

    public var description: String {
        switch self {
        case .always:
            return "Always"
        case .never:
            return "Never"
        case .onlyIfProcessesRunning:
            return "Only if there are running processes"
        }
    }
}

/// A component that can appear in a terminal window title.
///
/// Raw string values are persisted so future versions can add components
/// without changing the profile document format.
/// The Option keys that are Meta while a profile's `optionAsMetaKey` is
/// true. The raw values are stored in profiles: do not change them. Tecolot
/// owns this type, so that a change to SwiftTerm's `OptionMetaSide` does not
/// change the stored choice.
public enum OptionMetaKeySide: String, Codable, CaseIterable, Sendable {
    /// The left and the right Option keys are Meta.
    case both
    /// The left Option key is Meta; the right one goes to the layout.
    case left
    /// The right Option key is Meta; the left one goes to the layout.
    case right
}

#if os(macOS)
    extension OptionMetaKeySide {
        /// The value for SwiftTerm's `optionAsMetaSide`.
        var terminalSide: OptionMetaSide {
            switch self {
            case .both: return .both
            case .left: return .left
            case .right: return .right
            }
        }
    }
#endif

public enum TerminalTitleComponent: String, Codable, CaseIterable, Hashable, Sendable {
    case activeTitle
    case workingDirectory
    case fullPath
    case profileName
    case dimensions
}

public struct TerminalKeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command = TerminalKeyModifiers(rawValue: 1 << 0)
    public static let shift = TerminalKeyModifiers(rawValue: 1 << 1)
    public static let option = TerminalKeyModifiers(rawValue: 1 << 2)
    public static let control = TerminalKeyModifiers(rawValue: 1 << 3)
}

public enum TerminalKeyAction: String, Codable, CaseIterable, Sendable {
    case sendText
    case sendEscapeSequence
    case scrollPageUp
    case scrollPageDown
    case scrollLineUp
    case scrollLineDown

    public var displayName: String {
        switch self {
        case .sendText:
            return "Send text"
        case .sendEscapeSequence:
            return "Send escape sequence"
        case .scrollPageUp:
            return "Scroll one page up"
        case .scrollPageDown:
            return "Scroll one page down"
        case .scrollLineUp:
            return "Scroll one line up"
        case .scrollLineDown:
            return "Scroll one line down"
        }
    }

    public var usesValue: Bool {
        self == .sendText || self == .sendEscapeSequence
    }
}

public struct TerminalKeyBinding: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    /// A printable key or a named key such as "up", "pageup", or "f1".
    public var key: String
    public var modifiers: TerminalKeyModifiers
    public var action: TerminalKeyAction
    /// Text to send. Escape-sequence actions add ESC before this value.
    public var value: String

    public init(
        id: UUID = UUID(),
        key: String,
        modifiers: TerminalKeyModifiers = [],
        action: TerminalKeyAction = .sendText,
        value: String = ""
    ) {
        self.id = id
        self.key = key
        self.modifiers = modifiers
        self.action = action
        self.value = value
    }
}

/// How a profile makes palette colors 16-255 (the 6x6x6 color cube and
/// the gray ramp). Colors 0-15 always come from the theme.
public enum ExtendedPaletteMode: String, Codable, CaseIterable, Sendable {
    /// The standard xterm colors, the same for all themes.
    case standard
    /// Colors from the theme, interpolated in LAB. The cube and the gray
    /// ramp go from dark to light, also on a light theme.
    case theme
    /// Colors from the theme, interpolated in LAB. The cube and the gray
    /// ramp go from the background to the foreground, so on a light theme
    /// they go from light to dark. On a dark theme this is the same as
    /// `theme`.
    case themeHarmonious

    public var title: String {
        switch self {
        case .standard:
            "Standard"
        case .theme:
            "From Theme"
        case .themeHarmonious:
            "From Theme, Background to Foreground"
        }
    }

    public var strategy: Ansi256PaletteStrategy {
        switch self {
        case .standard:
            .xterm
        case .theme:
            .base16Lab
        case .themeHarmonious:
            .base16LabHarmonious
        }
    }
}

public struct TerminalProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    /// Display name, unique within a store
    public var name: String

    // MARK: Appearance
    /// Name of the TerminalTheme used when the system is in Light Mode.
    /// The JSON key stays "themeName": profiles from older versions have
    /// one theme only, and older versions read this key.
    public var lightThemeName: String
    /// Name of the TerminalTheme used when the system is in Dark Mode
    public var darkThemeName: String
    /// How palette colors 16-255 are made in Light Mode
    public var lightExtendedPalette: ExtendedPaletteMode
    /// How palette colors 16-255 are made in Dark Mode
    public var darkExtendedPalette: ExtendedPaletteMode
    /// Font family name; nil uses the system monospaced font
    public var fontFamily: String?
    /// Font size in points
    public var fontSize: Double
    /// Line height multiplier (1.0 is the font's natural line height)
    public var lineSpacing: Double
    /// macOS font smoothing (false approximates "thin strokes")
    public var fontSmoothing: Bool
    /// Render bold text using the bright variant of the ANSI color
    public var useBrightColorsForBold: Bool
    /// Cursor shape and blink
    public var cursorStyle: CursorStyle
    /// Opacity of the default background, 0...1; values below 1 need a
    /// non-opaque host window
    public var backgroundOpacity: Double
    /// Use the terminal theme for the macOS title bar, tabs, and toolbar controls
    public var useThemeColorsForWindowChrome: Bool

    // MARK: Window
    /// Initial window width in character columns
    public var columns: Int
    /// Initial window height in character rows
    public var rows: Int
    /// Scrollback limit in lines; nil means unlimited
    public var scrollbackLines: Int?
    /// Fixed window title; nil composes the title dynamically
    public var titleOverride: String?
    /// Dynamic components shown after an optional custom title
    public var titleComponents: Set<TerminalTitleComponent>

    // MARK: Shell
    public var shell: ShellCommand
    public var whenShellExits: ShellExitBehavior
    public var askBeforeClosing: AskBeforeClosing
    /// New panes with this profile start persistent sessions
    public var sessionPersistence: SessionPersistence

    // MARK: Keyboard
    public var optionAsMetaKey: Bool
    /// The Option keys that are Meta while `optionAsMetaKey` is true. The
    /// other key types the characters of the keyboard layout.
    public var optionMetaSide: OptionMetaKeySide
    public var backspaceSendsControlH: Bool
    public var hidePointerWhileTyping: Bool
    public var keyBindings: [TerminalKeyBinding]

    // MARK: Advanced
    /// Accept links set by terminal programs with OSC 8.
    public var linkOsc8: Bool
    /// Answer DECRQCRA screen checksum requests. Programs can use these
    /// requests to read the text on the screen, so the default is false.
    public var screenChecksumReports: Bool
    /// Value for the TERM environment variable
    public var termName: String
    /// Value for TERM_PROGRAM when TERM is xterm-ghostty
    public var termProgram: String
    /// Value for TERM_VERSION when TERM is xterm-ghostty
    public var termVersion: String
    /// Set or unset values after Tecolot prepares the child environment.
    public var environmentVariables: [TerminalEnvironmentVariable]
    // Kept for migration and downgrade safety; no runtime readers. Remove in a later release.
    /// How the terminal responds to the bell character
    public var bellStyle: BellStyle
    /// Programs can show desktop notifications (OSC 9, OSC 777)
    public var allowsNotifications: Bool

    public init (id: UUID = UUID (), name: String) {
        let defaults = TerminalProfile.standardValues
        self.id = id
        self.name = name
        self.lightThemeName = TerminalProfile.defaultThemeName(isDark: false)
        self.darkThemeName = TerminalProfile.defaultThemeName(isDark: true)
        self.lightExtendedPalette = defaults.extendedPalette
        self.darkExtendedPalette = defaults.extendedPalette
        self.fontFamily = defaults.fontFamily
        self.fontSize = defaults.fontSize
        self.lineSpacing = defaults.lineSpacing
        self.fontSmoothing = defaults.fontSmoothing
        self.useBrightColorsForBold = defaults.useBrightColorsForBold
        self.cursorStyle = defaults.cursorStyle
        self.backgroundOpacity = defaults.backgroundOpacity
        self.useThemeColorsForWindowChrome = defaults.useThemeColorsForWindowChrome
        self.columns = defaults.columns
        self.rows = defaults.rows
        self.scrollbackLines = defaults.scrollbackLines
        self.titleOverride = defaults.titleOverride
        self.titleComponents = defaults.titleComponents
        self.shell = defaults.shell
        self.whenShellExits = defaults.whenShellExits
        self.askBeforeClosing = defaults.askBeforeClosing
        self.sessionPersistence = defaults.sessionPersistence
        self.optionAsMetaKey = defaults.optionAsMetaKey
        self.optionMetaSide = defaults.optionMetaSide
        self.backspaceSendsControlH = defaults.backspaceSendsControlH
        self.hidePointerWhileTyping = defaults.hidePointerWhileTyping
        self.keyBindings = defaults.keyBindings
        self.linkOsc8 = defaults.linkOsc8
        self.screenChecksumReports = defaults.screenChecksumReports
        self.termName = defaults.termName
        self.termProgram = defaults.termProgram
        self.termVersion = defaults.termVersion
        self.environmentVariables = defaults.environmentVariables
        self.bellStyle = defaults.bellStyle
        self.allowsNotifications = defaults.allowsNotifications
    }

    public static let lineSpacingRange: ClosedRange<Double> = 0.8...2.0

    public static func sanitizedLineSpacing(_ value: Double) -> Double {
        guard value.isFinite else {
            return standardValues.lineSpacing
        }
        return min(max(value, lineSpacingRange.lowerBound), lineSpacingRange.upperBound)
    }

    /// The theme that the "Default" group shows for each mode, and the
    /// theme of each mode in a new profile.
    public static func defaultThemeName(isDark: Bool) -> String {
        isDark ? TerminalTheme.fallback.name : "Apple System Colors Light"
    }

    /// The theme name for the given system appearance
    public func themeName(isDark: Bool) -> String {
        isDark ? darkThemeName : lightThemeName
    }

    /// Sets the theme name for the given system appearance
    public mutating func setThemeName(_ name: String, isDark: Bool) {
        if isDark {
            darkThemeName = name
        } else {
            lightThemeName = name
        }
    }

    /// How palette colors 16-255 are made for the given system appearance
    public func extendedPalette(isDark: Bool) -> ExtendedPaletteMode {
        isDark ? darkExtendedPalette : lightExtendedPalette
    }

    /// Sets how palette colors 16-255 are made for the given system appearance
    public mutating func setExtendedPalette(_ mode: ExtendedPaletteMode, isDark: Bool) {
        if isDark {
            darkExtendedPalette = mode
        } else {
            lightExtendedPalette = mode
        }
    }

    /// The SwiftTerm strategy for palette colors 16-255 in the given
    /// system appearance.
    public func ansi256PaletteStrategy(isDark: Bool) -> Ansi256PaletteStrategy {
        extendedPalette(isDark: isDark).strategy
    }

    /// Replaces each slot that uses `oldName` with the result of
    /// `replacement` for the mode of that slot. Returns true if a slot changed.
    @discardableResult
    public mutating func replaceThemeName(_ oldName: String, with replacement: (_ isDark: Bool) -> String) -> Bool {
        var changed = false
        for isDark in [false, true] where themeName(isDark: isDark) == oldName {
            let newName = replacement(isDark)
            if newName != oldName {
                setThemeName(newName, isDark: isDark)
                changed = true
            }
        }
        return changed
    }

    /// The defaults applied to new profiles and to fields missing from
    /// persisted data written by older versions
    static var standardValues: (
        extendedPalette: ExtendedPaletteMode,
        fontFamily: String?,
        fontSize: Double,
        lineSpacing: Double,
        fontSmoothing: Bool,
        useBrightColorsForBold: Bool,
        cursorStyle: CursorStyle,
        backgroundOpacity: Double,
        useThemeColorsForWindowChrome: Bool,
        columns: Int,
        rows: Int,
        scrollbackLines: Int?,
        titleOverride: String?,
        titleComponents: Set<TerminalTitleComponent>,
        shell: ShellCommand,
        whenShellExits: ShellExitBehavior,
        askBeforeClosing: AskBeforeClosing,
        sessionPersistence: SessionPersistence,
        optionAsMetaKey: Bool,
        optionMetaSide: OptionMetaKeySide,
        backspaceSendsControlH: Bool,
        hidePointerWhileTyping: Bool,
        linkOsc8: Bool,
        screenChecksumReports: Bool,
        termName: String,
        termProgram: String,
        termVersion: String,
        environmentVariables: [TerminalEnvironmentVariable],
        bellStyle: BellStyle,
        allowsNotifications: Bool,
        keyBindings: [TerminalKeyBinding]
    ) {
        (
            // Colors 16-255 are the standard xterm colors, as in other
            // terminals (issue #77).
            extendedPalette: .standard,
            fontFamily: nil,
            fontSize: 12,
            lineSpacing: 1.0,
            fontSmoothing: false,
            useBrightColorsForBold: true,
            cursorStyle: .blinkBlock,
            backgroundOpacity: 1.0,
            useThemeColorsForWindowChrome: true,
            columns: 80,
            rows: 25,
            scrollbackLines: 10_000,
            titleOverride: nil,
            titleComponents: [.activeTitle, .workingDirectory],
            shell: .loginShell,
            whenShellExits: .closeIfExitedCleanly,
            askBeforeClosing: .onlyIfProcessesRunning,
            sessionPersistence: .standard,
            optionAsMetaKey: true,
            optionMetaSide: .both,
            backspaceSendsControlH: false,
            hidePointerWhileTyping: true,
            linkOsc8: true,
            screenChecksumReports: false,
            termName: "xterm-256color",
            termProgram: "ghostty",
            termVersion: "1.3.1",
            environmentVariables: [],
            bellStyle: .sound,
            allowsNotifications: true,
            keyBindings: []
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, name, fontFamily
        case lightThemeName = "themeName", darkThemeName, fontSize, lineSpacing, fontSmoothing
        case lightExtendedPalette, darkExtendedPalette
        case useBrightColorsForBold, cursorStyle, backgroundOpacity
        case useThemeColorsForWindowChrome
        case columns, rows, scrollbackLines, titleOverride, titleComponents
        case shell, whenShellExits, askBeforeClosing, sessionPersistence
        case optionAsMetaKey, optionMetaSide, backspaceSendsControlH, hidePointerWhileTyping, keyBindings
        case linkOsc8, screenChecksumReports, termName, termProgram, termVersion
        case environmentVariables, bellStyle, allowsNotifications
    }

    // Hand-written decoding: every field except id/name falls back to the
    // standard defaults, so profiles written by older versions of the model
    // keep loading as fields are added.
    public init (from decoder: Decoder) throws {
        let c = try decoder.container (keyedBy: CodingKeys.self)
        let defaults = TerminalProfile.standardValues
        self.id = try c.decodeIfPresent (UUID.self, forKey: .id) ?? UUID ()
        self.name = try c.decode (String.self, forKey: .name)
        // A profile from an older version has one theme: use it in both modes.
        if let legacyName = try c.decodeIfPresent (String.self, forKey: .lightThemeName) {
            self.lightThemeName = legacyName
            self.darkThemeName = try c.decodeIfPresent (String.self, forKey: .darkThemeName) ?? legacyName
        } else {
            self.lightThemeName = TerminalProfile.defaultThemeName(isDark: false)
            self.darkThemeName = try c.decodeIfPresent (String.self, forKey: .darkThemeName)
                ?? TerminalProfile.defaultThemeName(isDark: true)
        }
        // An unknown value (from a newer version) falls back to the default.
        self.lightExtendedPalette = (try? c.decodeIfPresent(ExtendedPaletteMode.self, forKey: .lightExtendedPalette))
            .flatMap {
                $0
            } ?? defaults.extendedPalette
        self.darkExtendedPalette = (try? c.decodeIfPresent(ExtendedPaletteMode.self, forKey: .darkExtendedPalette))
            .flatMap {
                $0
            } ?? defaults.extendedPalette
        self.fontFamily = try c.decodeIfPresent (String.self, forKey: .fontFamily) ?? defaults.fontFamily
        self.fontSize = try c.decodeIfPresent (Double.self, forKey: .fontSize) ?? defaults.fontSize
        let decodedLineSpacing = try c.decodeIfPresent (Double.self, forKey: .lineSpacing) ?? defaults.lineSpacing
        self.lineSpacing = TerminalProfile.sanitizedLineSpacing (decodedLineSpacing)
        self.fontSmoothing = try c.decodeIfPresent (Bool.self, forKey: .fontSmoothing) ?? defaults.fontSmoothing
        self.useBrightColorsForBold = try c.decodeIfPresent (Bool.self, forKey: .useBrightColorsForBold) ?? defaults.useBrightColorsForBold
        // CursorStyle is deliberately not Codable in SwiftTerm; persist its tagName
        if let tag = try c.decodeIfPresent (String.self, forKey: .cursorStyle) {
            self.cursorStyle = CursorStyle (tagName: tag) ?? defaults.cursorStyle
        } else {
            self.cursorStyle = defaults.cursorStyle
        }
        self.backgroundOpacity = try c.decodeIfPresent (Double.self, forKey: .backgroundOpacity) ?? defaults.backgroundOpacity
        self.useThemeColorsForWindowChrome = try c.decodeIfPresent(
            Bool.self,
            forKey: .useThemeColorsForWindowChrome
        ) ?? defaults.useThemeColorsForWindowChrome
        self.columns = try c.decodeIfPresent (Int.self, forKey: .columns) ?? defaults.columns
        self.rows = try c.decodeIfPresent (Int.self, forKey: .rows) ?? defaults.rows
        // An explicit null means "unlimited"; only a missing key falls back to the default
        if c.contains (.scrollbackLines) {
            self.scrollbackLines = try c.decode (Int?.self, forKey: .scrollbackLines)
        } else {
            self.scrollbackLines = defaults.scrollbackLines
        }
        self.titleOverride = try c.decodeIfPresent (String.self, forKey: .titleOverride) ?? defaults.titleOverride
        self.titleComponents = try c.decodeIfPresent (Set<TerminalTitleComponent>.self, forKey: .titleComponents) ?? defaults.titleComponents
        self.shell = try c.decodeIfPresent (ShellCommand.self, forKey: .shell) ?? defaults.shell
        self.whenShellExits = try c.decodeIfPresent (ShellExitBehavior.self, forKey: .whenShellExits) ?? defaults.whenShellExits
        self.askBeforeClosing = try c.decodeIfPresent (AskBeforeClosing.self, forKey: .askBeforeClosing) ?? defaults.askBeforeClosing
        // An unknown value (from a newer version) falls back to the default.
        self.sessionPersistence = (try? c.decodeIfPresent (SessionPersistence.self, forKey: .sessionPersistence))
            .flatMap {
                $0
            } ?? defaults.sessionPersistence
        self.optionAsMetaKey = try c.decodeIfPresent (Bool.self, forKey: .optionAsMetaKey) ?? defaults.optionAsMetaKey
        self.optionMetaSide = (try? c.decodeIfPresent (OptionMetaKeySide.self, forKey: .optionMetaSide)) ?? defaults.optionMetaSide
        self.backspaceSendsControlH = try c.decodeIfPresent (Bool.self, forKey: .backspaceSendsControlH) ?? defaults.backspaceSendsControlH
        self.hidePointerWhileTyping = try c.decodeIfPresent(
            Bool.self,
            forKey: .hidePointerWhileTyping
        ) ?? defaults.hidePointerWhileTyping
        self.keyBindings = try c.decodeIfPresent ([TerminalKeyBinding].self, forKey: .keyBindings) ?? defaults.keyBindings
        self.linkOsc8 = try c.decodeIfPresent(Bool.self, forKey: .linkOsc8) ?? defaults.linkOsc8
        self.screenChecksumReports = try c.decodeIfPresent(
            Bool.self,
            forKey: .screenChecksumReports
        ) ?? defaults.screenChecksumReports
        self.termName = try c.decodeIfPresent (String.self, forKey: .termName) ?? defaults.termName
        self.termProgram = try c.decodeIfPresent(String.self, forKey: .termProgram) ?? defaults.termProgram
        self.termVersion = try c.decodeIfPresent(String.self, forKey: .termVersion) ?? defaults.termVersion
        self.environmentVariables = try c.decodeIfPresent ([TerminalEnvironmentVariable].self, forKey: .environmentVariables)
            ?? defaults.environmentVariables
        // BellStyle is deliberately not Codable in SwiftTerm; persist its tagName
        if let tag = try c.decodeIfPresent (String.self, forKey: .bellStyle) {
            self.bellStyle = BellStyle (tagName: tag) ?? defaults.bellStyle
        } else {
            self.bellStyle = defaults.bellStyle
        }
        self.allowsNotifications = try c.decodeIfPresent (Bool.self, forKey: .allowsNotifications)
            ?? defaults.allowsNotifications
    }

    public func encode (to encoder: Encoder) throws {
        var c = encoder.container (keyedBy: CodingKeys.self)
        try c.encode (id, forKey: .id)
        try c.encode (name, forKey: .name)
        try c.encode (lightThemeName, forKey: .lightThemeName)
        try c.encode (darkThemeName, forKey: .darkThemeName)
        try c.encode(lightExtendedPalette, forKey: .lightExtendedPalette)
        try c.encode(darkExtendedPalette, forKey: .darkExtendedPalette)
        try c.encodeIfPresent (fontFamily, forKey: .fontFamily)
        try c.encode (fontSize, forKey: .fontSize)
        try c.encode (lineSpacing, forKey: .lineSpacing)
        try c.encode (fontSmoothing, forKey: .fontSmoothing)
        try c.encode (useBrightColorsForBold, forKey: .useBrightColorsForBold)
        try c.encode (cursorStyle.tagName, forKey: .cursorStyle)
        try c.encode (backgroundOpacity, forKey: .backgroundOpacity)
        try c.encode(useThemeColorsForWindowChrome, forKey: .useThemeColorsForWindowChrome)
        try c.encode (columns, forKey: .columns)
        try c.encode (rows, forKey: .rows)
        // Encoded unconditionally: an explicit null means "unlimited scrollback"
        try c.encode (scrollbackLines, forKey: .scrollbackLines)
        try c.encodeIfPresent (titleOverride, forKey: .titleOverride)
        try c.encode (titleComponents, forKey: .titleComponents)
        try c.encode (shell, forKey: .shell)
        try c.encode (whenShellExits, forKey: .whenShellExits)
        try c.encode (askBeforeClosing, forKey: .askBeforeClosing)
        try c.encode (sessionPersistence, forKey: .sessionPersistence)
        try c.encode (optionAsMetaKey, forKey: .optionAsMetaKey)
        try c.encode (optionMetaSide, forKey: .optionMetaSide)
        try c.encode (backspaceSendsControlH, forKey: .backspaceSendsControlH)
        try c.encode(hidePointerWhileTyping, forKey: .hidePointerWhileTyping)
        try c.encode (keyBindings, forKey: .keyBindings)
        try c.encode(linkOsc8, forKey: .linkOsc8)
        try c.encode(screenChecksumReports, forKey: .screenChecksumReports)
        try c.encode (termName, forKey: .termName)
        try c.encode(termProgram, forKey: .termProgram)
        try c.encode(termVersion, forKey: .termVersion)
        try c.encode (environmentVariables, forKey: .environmentVariables)
        try c.encode (bellStyle.tagName, forKey: .bellStyle)
        try c.encode (allowsNotifications, forKey: .allowsNotifications)
    }
}

/// Versioned on-disk envelope for a profile document
struct ProfileDocument: Codable {
    var version: Int
    var profile: TerminalProfile
}
