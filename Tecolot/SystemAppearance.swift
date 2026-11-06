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

    init() {
        // Use the application appearance, not a window appearance: "Match
        // window chrome to theme" sets the window appearance from the theme,
        // and that would make a loop.
        let application = NSApplication.shared
        isDark = Self.isDark(application.effectiveAppearance)
        observation = application.observe(\.effectiveAppearance, options: [.new]) { [weak self] application, _ in
            MainActor.assumeIsolated {
                let isDark = Self.isDark(application.effectiveAppearance)
                if self?.isDark != isDark {
                    self?.isDark = isDark
                }
            }
        }
    }

    /// For tests and previews.
    init(isDark: Bool) {
        self.isDark = isDark
    }

    nonisolated static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
