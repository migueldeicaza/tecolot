//
//  SystemAppearance.swift
//  Tecolot
//
//  Tells whether the system is in Dark Mode. A profile has one theme for
//  Light Mode and one for Dark Mode; terminals use the one that agrees with
//  this value.
//
import AppKit
import Combine

@MainActor
final class SystemAppearance: ObservableObject {
    @Published private(set) var isDark: Bool
    private var observation: NSKeyValueObservation?
    /// The app keeps one instance for its full life, so the observers are
    /// not removed.
    private var themeChangeObserver: NSObjectProtocol?

    init() {
        // Use the application appearance, not a window appearance: "Match
        // window chrome to theme" sets the window appearance from the theme,
        // and that would make a loop.
        let application = NSApplication.shared
        isDark = Self.systemIsDark(application)
        observation = application.observe(\.effectiveAppearance, options: [.new]) { [weak self] application, _ in
            MainActor.assumeIsolated {
                self?.update(from: application)
            }
        }
        // When the application appearance is set (see systemIsDark), a
        // change of the system setting does not change it. This
        // notification tells about the system change.
        themeChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.update(from: NSApplication.shared)
            }
        }
    }

    /// For tests and previews.
    init(isDark: Bool) {
        self.isDark = isDark
    }

    private func update(from application: NSApplication) {
        let isDark = Self.systemIsDark(application)
        if self.isDark != isDark {
            self.isDark = isDark
        }
    }

    /// The system setting. SwiftUI `preferredColorScheme` can set the
    /// application appearance from a terminal theme; then the effective
    /// application appearance follows the theme and not the system, so
    /// read the system setting instead.
    private static func systemIsDark(_ application: NSApplication) -> Bool {
        guard application.appearance != nil else {
            return isDark(application.effectiveAppearance)
        }
        // macOS writes "Dark" here in Dark Mode, also when the mode
        // changes automatically, and removes the value in Light Mode.
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let style = CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication)
        return (style as? String) == "Dark"
    }

    nonisolated static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
