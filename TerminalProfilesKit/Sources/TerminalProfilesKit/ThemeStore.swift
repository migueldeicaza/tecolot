//
//  ThemeStore.swift
//  TerminalProfilesKit
//
//  Loads the bundled curated themes and manages user themes (customized
//  copies) plus favorites. Bundled themes are immutable; editing one saves
//  a user theme under a new name.
//
import Foundation

@MainActor
public final class ThemeStore: ObservableObject {
    /// All themes, bundled and user, sorted by name
    @Published public private(set) var themes: [TerminalTheme] = []
    /// Names of favorite themes
    @Published public private(set) var favorites: Set<String> = []

    private let userThemesDirectory: URL
    private let favoritesFile: URL

    /// - Parameter directory: overrides the user-themes location (for tests);
    ///   nil uses Application Support/<bundle id>/Themes
    public init (directory: URL? = nil) {
        let base = directory ?? ThemeStore.defaultDirectory ()
        self.userThemesDirectory = base
        self.favoritesFile = base.appendingPathComponent ("favorites.json")
        reload ()
    }

    nonisolated static func defaultDirectory () -> URL {
        let appSupport = FileManager.default.urls (for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleId = Bundle.main.bundleIdentifier ?? "TerminalProfilesKit"
        return appSupport.appendingPathComponent (bundleId).appendingPathComponent ("Themes")
    }

    /// Reloads bundled and user themes from disk
    public func reload () {
        var loaded: [String: TerminalTheme] = [:]
        for var theme in ThemeStore.loadBundledThemes () {
            theme.isBuiltIn = true
            loaded [theme.name] = theme
        }
        // User themes shadow bundled ones with the same name
        for theme in ThemeStore.loadThemes (in: userThemesDirectory) {
            loaded [theme.name] = theme
        }
        if loaded.isEmpty {
            loaded [TerminalTheme.fallback.name] = TerminalTheme.fallback
        }
        themes = loaded.values.sorted { $0.name.localizedCaseInsensitiveCompare ($1.name) == .orderedAscending }
        favorites = ThemeStore.loadFavorites (from: favoritesFile)
    }

    /// Finds a theme by name; falls back to `TerminalTheme.fallback` so a
    /// caller always gets something usable
    public func theme (named name: String) -> TerminalTheme {
        themes.first { $0.name == name } ?? TerminalTheme.fallback
    }

    /// Themes matching a search string (empty returns everything)
    public func themes (matching query: String) -> [TerminalTheme] {
        guard !query.isEmpty else {
            return themes
        }
        return themes.filter { $0.name.localizedCaseInsensitiveContains (query) }
    }

    public func isFavorite (_ name: String) -> Bool {
        favorites.contains (name)
    }

    public func toggleFavorite (_ name: String) {
        if favorites.contains (name) {
            favorites.remove (name)
        } else {
            favorites.insert (name)
        }
        try? persistFavorites ()
    }

    /// Saves a theme into the user themes directory (creating or replacing);
    /// the name must not collide with a bundled theme
    public func saveUserTheme (_ theme: TerminalTheme) throws {
        guard theme.isValid else {
            throw ProfilesError.invalidTheme
        }
        var copy = theme
        copy.isBuiltIn = false
        try FileManager.default.createDirectory (at: userThemesDirectory, withIntermediateDirectories: true)
        let url = userThemesDirectory.appendingPathComponent ("\(copy.id).json")
        let encoder = JSONEncoder ()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode (copy).write (to: url, options: .atomic)
        reload ()
    }

    /// Deletes a user theme; bundled themes cannot be deleted
    public func deleteUserTheme (named name: String) throws {
        guard let theme = themes.first (where: { $0.name == name }), !theme.isBuiltIn else {
            throw ProfilesError.themeIsBuiltIn
        }
        let url = userThemesDirectory.appendingPathComponent ("\(theme.id).json")
        try FileManager.default.removeItem (at: url)
        favorites.remove (name)
        try? persistFavorites ()
        reload ()
    }

    /// Imports either a Tecolot JSON theme or an iTerm2 .itermcolors file.
    /// Imported themes are always saved as user themes.
    @discardableResult
    public func importTheme (from url: URL) throws -> TerminalTheme {
        let data = try Data (contentsOf: url)
        var imported: TerminalTheme

        if let decoded = try? JSONDecoder ().decode (TerminalTheme.self, from: data), decoded.isValid {
            imported = decoded
        } else if let iTermTheme = ThemeStore.iTermTheme (from: data, name: url.deletingPathExtension ().lastPathComponent) {
            imported = iTermTheme
        } else {
            throw ProfilesError.invalidTheme
        }

        imported.name = uniqueThemeName (basedOn: imported.name)
        imported.isBuiltIn = false
        try saveUserTheme (imported)
        return imported
    }

    // MARK: - Loading helpers

    nonisolated static func loadBundledThemes () -> [TerminalTheme] {
        guard let resourceURL = Bundle.module.url (forResource: "Themes", withExtension: nil) else {
            return []
        }
        return loadThemes (in: resourceURL)
    }

    nonisolated static func loadThemes (in directory: URL) -> [TerminalTheme] {
        guard let files = try? FileManager.default.contentsOfDirectory (at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = JSONDecoder ()
        var result: [TerminalTheme] = []
        for file in files where file.pathExtension == "json" && file.lastPathComponent != "favorites.json" {
            if let data = try? Data (contentsOf: file),
               let theme = try? decoder.decode (TerminalTheme.self, from: data),
               theme.isValid {
                result.append (theme)
            }
        }
        return result
    }

    nonisolated static func loadFavorites (from url: URL) -> Set<String> {
        guard let data = try? Data (contentsOf: url),
              let names = try? JSONDecoder ().decode ([String].self, from: data) else {
            return []
        }
        return Set (names)
    }

    private func uniqueThemeName (basedOn base: String) -> String {
        guard themes.contains (where: {
            $0.name.localizedCaseInsensitiveCompare (base) == .orderedSame
        }) else {
            return base
        }
        var number = 2
        var candidate = "\(base) \(number)"
        while themes.contains (where: {
            $0.name.localizedCaseInsensitiveCompare (candidate) == .orderedSame
        }) {
            number += 1
            candidate = "\(base) \(number)"
        }
        return candidate
    }

    nonisolated private static func iTermTheme (from data: Data, name: String) -> TerminalTheme? {
        guard let propertyList = try? PropertyListSerialization.propertyList (
            from: data,
            options: [],
            format: nil
        ), let dictionary = propertyList as? [String: Any] else {
            return nil
        }

        let ansi = (0..<16).compactMap { color (named: "Ansi \($0) Color", in: dictionary) }
        guard ansi.count == 16,
              let foreground = color (named: "Foreground Color", in: dictionary),
              let background = color (named: "Background Color", in: dictionary) else {
            return nil
        }

        return TerminalTheme (
            name: name,
            ansi: ansi,
            foreground: foreground,
            background: background,
            cursor: color (named: "Cursor Color", in: dictionary),
            cursorText: color (named: "Cursor Text Color", in: dictionary),
            selectionBackground: color (named: "Selection Color", in: dictionary),
            selectionText: color (named: "Selected Text Color", in: dictionary)
        )
    }

    nonisolated private static func color (named name: String, in dictionary: [String: Any]) -> ProfileColor? {
        guard let components = dictionary [name] as? [String: Any],
              let red = (components ["Red Component"] as? NSNumber)?.doubleValue,
              let green = (components ["Green Component"] as? NSNumber)?.doubleValue,
              let blue = (components ["Blue Component"] as? NSNumber)?.doubleValue,
              red.isFinite, green.isFinite, blue.isFinite else {
            return nil
        }

        func channel (_ value: Double) -> UInt16 {
            UInt16 ((min (max (value, 0), 1) * 65535).rounded ())
        }
        return ProfileColor (red: channel (red), green: channel (green), blue: channel (blue))
    }

    private func persistFavorites () throws {
        try FileManager.default.createDirectory (at: userThemesDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder ().encode (favorites.sorted ())
        try data.write (to: favoritesFile, options: .atomic)
    }
}

public enum ProfilesError: Error, Equatable {
    case invalidTheme
    case themeIsBuiltIn
    case duplicateName
    case cannotDeleteLastProfile
    case profileNotFound
}
