//
//  TerminalProfile.swift
//  TerminalProfilesKit
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
        case .closeWindow: return "Close the window"
        case .closeIfExitedCleanly: return "Close if the shell exited cleanly"
        case .keepOpen: return "Don't close the window"
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
        case .always: return "Always"
        case .never: return "Never"
        case .onlyIfProcessesRunning: return "Only if there are running processes"
        }
    }
}

/// A component that can appear in a terminal window title.
///
/// Raw string values are persisted so future versions can add components
/// without changing the profile document format.
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
        case .sendText: return "Send text"
        case .sendEscapeSequence: return "Send escape sequence"
        case .scrollPageUp: return "Scroll one page up"
        case .scrollPageDown: return "Scroll one page down"
        case .scrollLineUp: return "Scroll one line up"
        case .scrollLineDown: return "Scroll one line down"
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

public struct TerminalProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    /// Display name, unique within a store
    public var name: String

    // MARK: Appearance
    /// Name of the TerminalTheme providing the colors
    public var themeName: String
    /// Font family name; nil uses the system monospaced font
    public var fontFamily: String?
    /// Font size in points
    public var fontSize: Double
    /// macOS font smoothing (false approximates "thin strokes")
    public var fontSmoothing: Bool
    /// Render bold text using the bright variant of the ANSI color
    public var useBrightColorsForBold: Bool
    /// Cursor shape and blink
    public var cursorStyle: CursorStyle
    /// Opacity of the default background, 0...1; values below 1 need a
    /// non-opaque host window
    public var backgroundOpacity: Double

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

    // MARK: Keyboard
    public var optionAsMetaKey: Bool
    public var backspaceSendsControlH: Bool
    public var keyBindings: [TerminalKeyBinding]

    // MARK: Advanced
    /// Value for the TERM environment variable
    public var termName: String
    /// How the terminal responds to the bell character
    public var bellStyle: BellStyle

    public init (id: UUID = UUID (), name: String) {
        let defaults = TerminalProfile.standardValues
        self.id = id
        self.name = name
        self.themeName = defaults.themeName
        self.fontFamily = defaults.fontFamily
        self.fontSize = defaults.fontSize
        self.fontSmoothing = defaults.fontSmoothing
        self.useBrightColorsForBold = defaults.useBrightColorsForBold
        self.cursorStyle = defaults.cursorStyle
        self.backgroundOpacity = defaults.backgroundOpacity
        self.columns = defaults.columns
        self.rows = defaults.rows
        self.scrollbackLines = defaults.scrollbackLines
        self.titleOverride = defaults.titleOverride
        self.titleComponents = defaults.titleComponents
        self.shell = defaults.shell
        self.whenShellExits = defaults.whenShellExits
        self.askBeforeClosing = defaults.askBeforeClosing
        self.optionAsMetaKey = defaults.optionAsMetaKey
        self.backspaceSendsControlH = defaults.backspaceSendsControlH
        self.keyBindings = defaults.keyBindings
        self.termName = defaults.termName
        self.bellStyle = defaults.bellStyle
    }

    /// The defaults applied to new profiles and to fields missing from
    /// persisted data written by older versions
    static var standardValues: (themeName: String, fontFamily: String?, fontSize: Double,
                                fontSmoothing: Bool, useBrightColorsForBold: Bool,
                                cursorStyle: CursorStyle, backgroundOpacity: Double,
                                columns: Int, rows: Int, scrollbackLines: Int?,
                                titleOverride: String?, titleComponents: Set<TerminalTitleComponent>, shell: ShellCommand,
                                whenShellExits: ShellExitBehavior, askBeforeClosing: AskBeforeClosing,
                                optionAsMetaKey: Bool, backspaceSendsControlH: Bool, termName: String,
                                bellStyle: BellStyle, keyBindings: [TerminalKeyBinding]) {
        (themeName: TerminalTheme.fallback.name, fontFamily: nil, fontSize: 12,
         fontSmoothing: true, useBrightColorsForBold: true,
         cursorStyle: .blinkBlock, backgroundOpacity: 1.0,
         columns: 80, rows: 25, scrollbackLines: 10_000,
         titleOverride: nil, titleComponents: [.activeTitle, .workingDirectory], shell: .loginShell,
         whenShellExits: .closeIfExitedCleanly, askBeforeClosing: .onlyIfProcessesRunning,
         optionAsMetaKey: true, backspaceSendsControlH: false, termName: "xterm-256color",
         bellStyle: .sound, keyBindings: [])
    }

    enum CodingKeys: String, CodingKey {
        case id, name, themeName, fontFamily, fontSize, fontSmoothing
        case useBrightColorsForBold, cursorStyle, backgroundOpacity
        case columns, rows, scrollbackLines, titleOverride, titleComponents
        case shell, whenShellExits, askBeforeClosing
        case optionAsMetaKey, backspaceSendsControlH, keyBindings, termName, bellStyle
    }

    // Hand-written decoding: every field except id/name falls back to the
    // standard defaults, so profiles written by older versions of the model
    // keep loading as fields are added.
    public init (from decoder: Decoder) throws {
        let c = try decoder.container (keyedBy: CodingKeys.self)
        let defaults = TerminalProfile.standardValues
        self.id = try c.decodeIfPresent (UUID.self, forKey: .id) ?? UUID ()
        self.name = try c.decode (String.self, forKey: .name)
        self.themeName = try c.decodeIfPresent (String.self, forKey: .themeName) ?? defaults.themeName
        self.fontFamily = try c.decodeIfPresent (String.self, forKey: .fontFamily) ?? defaults.fontFamily
        self.fontSize = try c.decodeIfPresent (Double.self, forKey: .fontSize) ?? defaults.fontSize
        self.fontSmoothing = try c.decodeIfPresent (Bool.self, forKey: .fontSmoothing) ?? defaults.fontSmoothing
        self.useBrightColorsForBold = try c.decodeIfPresent (Bool.self, forKey: .useBrightColorsForBold) ?? defaults.useBrightColorsForBold
        // CursorStyle is deliberately not Codable in SwiftTerm; persist its tagName
        if let tag = try c.decodeIfPresent (String.self, forKey: .cursorStyle) {
            self.cursorStyle = CursorStyle (tagName: tag) ?? defaults.cursorStyle
        } else {
            self.cursorStyle = defaults.cursorStyle
        }
        self.backgroundOpacity = try c.decodeIfPresent (Double.self, forKey: .backgroundOpacity) ?? defaults.backgroundOpacity
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
        self.optionAsMetaKey = try c.decodeIfPresent (Bool.self, forKey: .optionAsMetaKey) ?? defaults.optionAsMetaKey
        self.backspaceSendsControlH = try c.decodeIfPresent (Bool.self, forKey: .backspaceSendsControlH) ?? defaults.backspaceSendsControlH
        self.keyBindings = try c.decodeIfPresent ([TerminalKeyBinding].self, forKey: .keyBindings) ?? defaults.keyBindings
        self.termName = try c.decodeIfPresent (String.self, forKey: .termName) ?? defaults.termName
        // BellStyle is deliberately not Codable in SwiftTerm; persist its tagName
        if let tag = try c.decodeIfPresent (String.self, forKey: .bellStyle) {
            self.bellStyle = BellStyle (tagName: tag) ?? defaults.bellStyle
        } else {
            self.bellStyle = defaults.bellStyle
        }
    }

    public func encode (to encoder: Encoder) throws {
        var c = encoder.container (keyedBy: CodingKeys.self)
        try c.encode (id, forKey: .id)
        try c.encode (name, forKey: .name)
        try c.encode (themeName, forKey: .themeName)
        try c.encodeIfPresent (fontFamily, forKey: .fontFamily)
        try c.encode (fontSize, forKey: .fontSize)
        try c.encode (fontSmoothing, forKey: .fontSmoothing)
        try c.encode (useBrightColorsForBold, forKey: .useBrightColorsForBold)
        try c.encode (cursorStyle.tagName, forKey: .cursorStyle)
        try c.encode (backgroundOpacity, forKey: .backgroundOpacity)
        try c.encode (columns, forKey: .columns)
        try c.encode (rows, forKey: .rows)
        // Encoded unconditionally: an explicit null means "unlimited scrollback"
        try c.encode (scrollbackLines, forKey: .scrollbackLines)
        try c.encodeIfPresent (titleOverride, forKey: .titleOverride)
        try c.encode (titleComponents, forKey: .titleComponents)
        try c.encode (shell, forKey: .shell)
        try c.encode (whenShellExits, forKey: .whenShellExits)
        try c.encode (askBeforeClosing, forKey: .askBeforeClosing)
        try c.encode (optionAsMetaKey, forKey: .optionAsMetaKey)
        try c.encode (backspaceSendsControlH, forKey: .backspaceSendsControlH)
        try c.encode (keyBindings, forKey: .keyBindings)
        try c.encode (termName, forKey: .termName)
        try c.encode (bellStyle.tagName, forKey: .bellStyle)
    }
}

/// Versioned on-disk envelope for a profile document
struct ProfileDocument: Codable {
    var version: Int
    var profile: TerminalProfile
}
