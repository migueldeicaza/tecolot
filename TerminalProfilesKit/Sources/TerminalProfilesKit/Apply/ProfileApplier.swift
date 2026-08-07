//
//  ProfileApplier.swift
//  TerminalProfilesKit
//
//  Bridges the profile/theme models onto a live SwiftTerm TerminalView.
//  Three phases:
//    1. terminalOptions(for:)  - creation-time TerminalOptions
//    2. apply(theme:)/apply(profile:) - live application, safe to repeat
//    3. launchParameters(for:) - what to feed startProcess
//
import Foundation
import SwiftTerm

#if os(macOS)
import AppKit
public typealias ProfileNativeFont = NSFont
#elseif os(iOS) || os(visionOS)
import UIKit
public typealias ProfileNativeFont = UIFont
#endif

/// Everything a host needs to launch the shell described by a profile
public struct LaunchParameters: Sendable {
    public var executable: String
    public var args: [String]
    public var execName: String?
    public var environment: [String]
    public var currentDirectory: String?
}

public enum ProfileApplier {
    // MARK: Phase 1: creation

    /// Terminal options for creating a TerminalView with this profile
    public static func terminalOptions (for profile: TerminalProfile) -> TerminalOptions {
        var options = TerminalOptions.default
        options.cols = profile.columns
        options.rows = profile.rows
        options.cursorStyle = profile.cursorStyle
        options.termName = profile.termName
        if let lines = profile.scrollbackLines {
            options.scrollback = lines
        }
        // "unlimited" (nil) is applied after creation via changeScrollback(nil)
        // in the live-apply phase; the creation default stays in place here
        return options
    }

    // MARK: Phase 2: live application

    #if os(macOS) || os(iOS) || os(visionOS)
    /// Applies just the colors of a theme to a running terminal view;
    /// this is the hot path used while previewing themes in a picker
    @MainActor
    public static func apply (theme: TerminalTheme, opacity: Double = 1.0, to view: TerminalView) {
        guard theme.isValid else {
            return
        }
        view.installColors (theme.ansi.map { $0.terminalColor })

        let background = nativeColor (theme.background, alpha: opacity)
        let foreground = nativeColor (theme.foreground)
        view.nativeBackgroundColor = background
        view.nativeForegroundColor = foreground

        if let cursor = theme.cursor {
            view.caretColor = nativeColor (cursor)
        }
        if let cursorText = theme.cursorText {
            view.caretTextColor = nativeColor (cursorText)
        }
        if let selection = theme.selectionBackground {
            view.selectedTextBackgroundColor = nativeColor (selection)
        }
        if let selectionText = theme.selectionText {
            view.selectedTextForegroundColor = nativeColor (selectionText)
        }
    }

    /// Applies everything in a profile that can change on a live terminal:
    /// theme colors, font, cursor, scrollback and keyboard behavior.
    /// termName, initial cols/rows and the shell settings cannot change on
    /// a running session.
    @MainActor
    public static func apply (profile: TerminalProfile, themeStore: ThemeStore,
                              sessionThemeOverride: String? = nil, to view: TerminalView) {
        let themeName = sessionThemeOverride ?? profile.themeName
        apply (theme: themeStore.theme (named: themeName), opacity: profile.backgroundOpacity, to: view)

        view.font = font (for: profile)
        #if os(macOS)
        view.fontSmoothing = profile.fontSmoothing
        #endif
        view.useBrightColors = profile.useBrightColorsForBold
        view.optionAsMetaKey = profile.optionAsMetaKey
        view.backspaceSendsControlH = profile.backspaceSendsControlH
        view.getTerminal ().setCursorStyle (profile.cursorStyle)
        view.changeScrollback (profile.scrollbackLines)
        view.bellStyle = profile.bellStyle
    }

    /// The native font described by the profile, falling back to the
    /// system monospaced font
    public static func font (for profile: TerminalProfile) -> ProfileNativeFont {
        let size = CGFloat (profile.fontSize)
        if let family = profile.fontFamily,
           let custom = ProfileNativeFont (name: family, size: size) {
            return custom
        }
        #if os(macOS)
        return NSFont.monospacedSystemFont (ofSize: size, weight: .regular)
        #else
        return UIFont.monospacedSystemFont (ofSize: size, weight: .regular)
        #endif
    }

    #if os(macOS)
    static func nativeColor (_ color: ProfileColor, alpha: Double = 1.0) -> NSColor {
        let base = color.terminalColor.nsColor
        return alpha < 1.0 ? base.withAlphaComponent (CGFloat (alpha)) : base
    }
    #else
    static func nativeColor (_ color: ProfileColor, alpha: Double = 1.0) -> UIColor {
        let base = color.terminalColor.uiColor
        return alpha < 1.0 ? base.withAlphaComponent (CGFloat (alpha)) : base
    }
    #endif
    #endif

    // MARK: Phase 3: launch

    /// Resolves the shell command, environment (including TERM) and working
    /// directory to launch a session with this profile
    public static func launchParameters (for profile: TerminalProfile,
                                         initialDirectory: String? = nil) -> LaunchParameters {
        let environment = Terminal.getEnvironmentVariables (termName: profile.termName, trueColor: true)
        let directory = initialDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path

        switch profile.shell {
        case .loginShell:
            let shell = LoginShell.current
            return LaunchParameters (executable: shell, args: [],
                                     execName: LoginShell.loginArgZero (for: shell),
                                     environment: environment,
                                     currentDirectory: directory)
        case .command(let commandLine, let runInShell):
            if runInShell {
                let shell = LoginShell.current
                return LaunchParameters (executable: shell, args: ["-lc", commandLine],
                                         execName: nil,
                                         environment: environment,
                                         currentDirectory: directory)
            }
            var parts = commandLine.split (separator: " ").map (String.init)
            let executable = parts.isEmpty ? LoginShell.current : parts.removeFirst ()
            return LaunchParameters (executable: executable, args: parts,
                                     execName: nil,
                                     environment: environment,
                                     currentDirectory: directory)
        }
    }
}
