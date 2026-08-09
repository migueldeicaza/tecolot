//
//  AppearancePreferences.swift
//  Tecolot
//

import AppKit
import Foundation

enum InterfaceAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> InterfaceAppearance {
        guard let value = defaults.string(forKey: AppearancePreferences.interfaceAppearanceKey) else {
            return .system
        }
        return InterfaceAppearance(rawValue: value) ?? .system
    }

    @MainActor
    func apply() {
        switch self {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

enum MacTitlebarStyle: String, CaseIterable, Identifiable {
    case native
    case blended
    case liquidGlass = "liquid-glass"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .native: "Native"
        case .blended: "Blended"
        case .liquidGlass: "Liquid Glass"
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> MacTitlebarStyle {
        guard let value = defaults.string(forKey: AppearancePreferences.macosTitlebarStyleKey) else {
            return .native
        }
        return MacTitlebarStyle(rawValue: value) ?? .native
    }

    func resolved(for version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> MacTitlebarStyle {
        guard self == .liquidGlass, version.majorVersion < 26 else { return self }
        return .blended
    }
}

enum AppearancePreferences {
    static let interfaceAppearanceKey = "interfaceAppearance"
    static let macosTitlebarStyleKey = "macosTitlebarStyle"
    static let liquidGlassOpacityKey = "liquidGlassOpacity"

    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            interfaceAppearanceKey: InterfaceAppearance.system.rawValue,
            macosTitlebarStyleKey: MacTitlebarStyle.native.rawValue,
            liquidGlassOpacityKey: 0.7,
        ])
    }

    static func liquidGlassOpacity(in defaults: UserDefaults = .standard) -> Double {
        min(max(defaults.double(forKey: liquidGlassOpacityKey), 0), 1)
    }
}
