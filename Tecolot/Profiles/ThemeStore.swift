import Combine
import Foundation

private struct ThemeDocumentV1: Codable {
    var version: Int
    var theme: TerminalTheme
}

private struct FavoritesDocumentV1: Codable {
    var version: Int
    var names: [String]
}

private struct UserThemeMigrator: VersionedDocumentMigrator {
    let currentVersion = 1

    func sourceVersion(in data: Data) throws -> Int {
        try PersistenceVersionProbe.optionalVersion(in: data) ?? 0
    }

    func decode(_ data: Data, from sourceVersion: Int) throws -> TerminalTheme {
        switch sourceVersion {
        case 0:
            return try JSONDecoder().decode(TerminalTheme.self, from: data)
        case 1:
            return try JSONDecoder().decode(ThemeDocumentV1.self, from: data).theme
        default:
            throw VersionedPersistenceError.invalidDocument("Unsupported theme schema.")
        }
    }

    func validate(_ theme: TerminalTheme) throws {
        guard theme.isValid,
              !theme.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VersionedPersistenceError.invalidDocument("The theme contains invalid values.")
        }
    }

    func encodeCurrent(_ theme: TerminalTheme) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(ThemeDocumentV1(version: currentVersion, theme: theme))
    }
}

private struct FavoritesMigrator: VersionedDocumentMigrator {
    let currentVersion = 1

    func sourceVersion(in data: Data) throws -> Int {
        try PersistenceVersionProbe.optionalVersion(in: data) ?? 0
    }

    func decode(_ data: Data, from sourceVersion: Int) throws -> Set<String> {
        switch sourceVersion {
        case 0:
            return Set(try JSONDecoder().decode([String].self, from: data))
        case 1:
            return Set(try JSONDecoder().decode(FavoritesDocumentV1.self, from: data).names)
        default:
            throw VersionedPersistenceError.invalidDocument("Unsupported favorites schema.")
        }
    }

    func validate(_ value: Set<String>) throws {}

    func encodeCurrent(_ value: Set<String>) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(FavoritesDocumentV1(version: currentVersion, names: value.sorted()))
    }
}

@MainActor
public final class ThemeStore: ObservableObject {
    @Published public private(set) var themes: [TerminalTheme] = []
    @Published public private(set) var favorites: Set<String> = []

    private let userThemesDirectory: URL
    private let favoritesFile: URL
    private let backupDirectory: URL
    private let issueCenter: PersistenceIssueCenter?
    private var userThemeFiles: [String: URL] = [:]
    private var favoritesAreReadOnly = false

    public init(
        directory: URL? = nil,
        issueCenter: PersistenceIssueCenter? = nil,
        backupDirectory: URL? = nil
    ) {
        let base = directory ?? ThemeStore.defaultDirectory()
        userThemesDirectory = base
        favoritesFile = base.appendingPathComponent("favorites.json")
        self.backupDirectory = backupDirectory ?? base.appendingPathComponent("Backups")
        self.issueCenter = issueCenter
        reload()
    }

    nonisolated static func defaultDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "com.tirania.Tecolot"
        return appSupport.appendingPathComponent(bundleID).appendingPathComponent("Themes")
    }

    public func reload() {
        var loaded: [String: TerminalTheme] = [:]
        for var theme in ThemeStore.loadBundledThemes() {
            theme.isBuiltIn = true
            loaded[theme.name] = theme
        }

        let userResult = loadUserThemes()
        userThemeFiles = [:]
        for (theme, sourceURL) in userResult.values {
            loaded[theme.name] = theme
            userThemeFiles[theme.name] = sourceURL
        }
        if loaded.isEmpty {
            loaded[TerminalTheme.fallback.name] = TerminalTheme.fallback
        }
        themes = loaded.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        issueCenter?.replaceIssues(in: .userThemes, with: userResult.issues)

        let favoritesResult = VersionedFileLoader.load(
            from: favoritesFile,
            domain: .themeFavorites,
            backupRoot: backupDirectory,
            migrator: FavoritesMigrator()
        )
        favoritesAreReadOnly = favoritesResult.issue != nil
        favorites = favoritesResult.value ?? []
        issueCenter?.replaceIssues(
            in: .themeFavorites,
            with: favoritesResult.issue.map { [$0] } ?? []
        )
    }

    public func theme(named name: String) -> TerminalTheme {
        themes.first { $0.name == name } ?? TerminalTheme.fallback
    }

    public func themes(matching query: String) -> [TerminalTheme] {
        guard !query.isEmpty else { return themes }
        return themes.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    public func forkName(basedOn base: String) -> String {
        deduplicatedName("\(base) (Custom)")
    }

    public func copyName(basedOn base: String) -> String {
        deduplicatedName("\(base) copy")
    }

    public func fork(of theme: TerminalTheme) -> TerminalTheme {
        var fork = theme
        fork.name = forkName(basedOn: theme.name)
        fork.isBuiltIn = false
        fork.baseThemeName = theme.name
        return fork
    }

    public func duplicate(of theme: TerminalTheme) -> TerminalTheme {
        var copy = theme
        copy.isBuiltIn = false
        if theme.isBuiltIn {
            copy.name = forkName(basedOn: theme.name)
            copy.baseThemeName = theme.name
        } else {
            copy.name = copyName(basedOn: theme.name)
        }
        return copy
    }

    public func isFavorite(_ name: String) -> Bool {
        favorites.contains(name)
    }

    public func toggleFavorite(_ name: String) throws {
        try ensureFavoritesAreWritable()
        let oldFavorites = favorites
        if favorites.contains(name) {
            favorites.remove(name)
        } else {
            favorites.insert(name)
        }
        do {
            try persistFavorites()
            issueCenter?.resolve(domain: .themeFavorites, sourceURL: favoritesFile)
        } catch {
            favorites = oldFavorites
            reportWriteFailure(error, domain: .themeFavorites, sourceURL: favoritesFile)
            throw error
        }
    }

    public func saveUserTheme(
        _ theme: TerminalTheme,
        replacing existingUserThemeName: String? = nil
    ) throws {
        try UserThemeMigrator().validate(theme)
        var copy = theme
        copy.isBuiltIn = false
        let isRename = existingUserThemeName.map {
            $0.localizedCaseInsensitiveCompare(copy.name) != .orderedSame
        } ?? false
        if isRename {
            // A corrupt favorites document can contain the old theme name even
            // when the fallback set is empty. Do not rename until recovery.
            try ensureFavoritesAreWritable()
        }

        let sourceURL = existingUserThemeName.flatMap { userThemeFiles[$0] }
        let originalSourceData: Data?
        if isRename, let sourceURL {
            do {
                originalSourceData = try Data(contentsOf: sourceURL)
            } catch {
                reportWriteFailure(error, domain: .userThemes, sourceURL: sourceURL)
                throw error
            }
        } else {
            originalSourceData = nil
        }

        try FileManager.default.createDirectory(at: userThemesDirectory, withIntermediateDirectories: true)
        let url = userThemesDirectory.appendingPathComponent("\(copy.id).json")
        do {
            let data = try UserThemeMigrator().encodeCurrent(copy)
            try data.write(to: url, options: .atomic)
            issueCenter?.resolve(domain: .userThemes, sourceURL: url)
        } catch {
            reportWriteFailure(error, domain: .userThemes, sourceURL: url)
            throw error
        }

        let sourceIsDestination = sourceURL?.standardizedFileURL == url.standardizedFileURL
        if isRename, let sourceURL, !sourceIsDestination {
            do {
                try FileManager.default.removeItem(at: sourceURL)
                issueCenter?.resolve(domain: .userThemes, sourceURL: sourceURL)
            } catch {
                try? FileManager.default.removeItem(at: url)
                reload()
                reportWriteFailure(error, domain: .userThemes, sourceURL: sourceURL)
                throw error
            }
        }

        if isRename,
           let existingUserThemeName,
           favorites.contains(existingUserThemeName) {
            let oldFavorites = favorites
            favorites.remove(existingUserThemeName)
            favorites.insert(copy.name)
            do {
                try persistFavorites()
                issueCenter?.resolve(domain: .themeFavorites, sourceURL: favoritesFile)
            } catch {
                favorites = oldFavorites
                rollbackRename(
                    sourceURL: sourceURL,
                    destinationURL: url,
                    originalSourceData: originalSourceData
                )
                reload()
                reportWriteFailure(error, domain: .themeFavorites, sourceURL: favoritesFile)
                throw error
            }
        }
        reload()
    }

    public func deleteUserTheme(named name: String) throws {
        // The failed document can contain this theme even when the fallback set
        // is empty, so every deletion must wait for favorites recovery.
        try ensureFavoritesAreWritable()
        guard let theme = themes.first(where: { $0.name == name }), !theme.isBuiltIn else {
            throw ProfilesError.themeIsBuiltIn
        }
        let url = userThemeFiles[name]
            ?? userThemesDirectory.appendingPathComponent("\(theme.id).json")
        do {
            try FileManager.default.removeItem(at: url)
            issueCenter?.resolve(domain: .userThemes, sourceURL: url)
        } catch {
            reportWriteFailure(error, domain: .userThemes, sourceURL: url)
            throw error
        }

        if favorites.remove(name) != nil {
            do {
                try persistFavorites()
            } catch {
                // The theme file is already gone. Reload both published
                // collections from disk before reporting the favorites write.
                reload()
                reportWriteFailure(
                    error,
                    domain: .themeFavorites,
                    sourceURL: favoritesFile
                )
                throw error
            }
        }
        reload()
    }

    @discardableResult
    public func importTheme(from url: URL) throws -> TerminalTheme {
        let data = try Data(contentsOf: url)
        var imported: TerminalTheme

        if (try? JSONSerialization.jsonObject(with: data)) != nil {
            let migrator = UserThemeMigrator()
            let version = try migrator.sourceVersion(in: data)
            guard version <= migrator.currentVersion else {
                throw VersionedPersistenceError.unsupportedVersion(
                    found: version,
                    supported: migrator.currentVersion
                )
            }
            imported = try migrator.decode(data, from: version)
            try migrator.validate(imported)
        } else if let iTermTheme = ThemeStore.iTermTheme(
            from: data,
            name: url.deletingPathExtension().lastPathComponent
        ) {
            imported = iTermTheme
        } else {
            throw ProfilesError.invalidTheme
        }

        imported.name = uniqueThemeName(basedOn: imported.name)
        imported.isBuiltIn = false
        try saveUserTheme(imported)
        return imported
    }

    nonisolated static func loadBundledThemes() -> [TerminalTheme] {
        guard let resourceURL = Bundle.main.url(forResource: "Themes", withExtension: nil) else {
            return []
        }
        return loadRawThemes(in: resourceURL)
    }

    nonisolated static func loadThemes(in directory: URL) -> [TerminalTheme] {
        loadRawThemes(in: directory)
    }

    nonisolated private static func loadRawThemes(in directory: URL) -> [TerminalTheme] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return files.compactMap { file in
            guard file.pathExtension == "json",
                  file.lastPathComponent != "favorites.json",
                  let data = try? Data(contentsOf: file),
                  let theme = try? JSONDecoder().decode(TerminalTheme.self, from: data),
                  theme.isValid else {
                return nil
            }
            return theme
        }
    }

    nonisolated static func loadFavorites(from url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let migrator = FavoritesMigrator()
        guard let version = try? migrator.sourceVersion(in: data),
              version <= migrator.currentVersion,
              let value = try? migrator.decode(data, from: version) else {
            return []
        }
        return value
    }

    private func loadUserThemes() -> (values: [(TerminalTheme, URL)], issues: [PersistenceIssue]) {
        guard FileManager.default.fileExists(atPath: userThemesDirectory.path) else {
            return ([], [])
        }
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: userThemesDirectory,
                includingPropertiesForKeys: nil
            )
        } catch {
            return ([], [PersistenceIssue(
                domain: .userThemes,
                sourceURL: userThemesDirectory,
                kind: .unreadable,
                message: error.localizedDescription,
                supportedVersion: 1
            )])
        }
        var values: [(TerminalTheme, URL)] = []
        var issues: [PersistenceIssue] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where file.pathExtension == "json" && file.lastPathComponent != "favorites.json" {
            let result = VersionedFileLoader.load(
                from: file,
                domain: .userThemes,
                backupRoot: backupDirectory,
                migrator: UserThemeMigrator()
            )
            if let value = result.value { values.append((value, file)) }
            if let issue = result.issue { issues.append(issue) }
        }
        return (values, issues)
    }

    private func uniqueThemeName(basedOn base: String) -> String {
        guard themes.allSatisfy({ $0.name.localizedCaseInsensitiveCompare(base) != .orderedSame }) else {
            var number = 2
            var candidate = "\(base) \(number)"
            while themes.contains(where: {
                $0.name.localizedCaseInsensitiveCompare(candidate) == .orderedSame
            }) {
                number += 1
                candidate = "\(base) \(number)"
            }
            return candidate
        }
        return base
    }

    private func deduplicatedName(_ base: String) -> String {
        var candidate = base
        var number = 2
        while themes.contains(where: {
            $0.name.localizedCaseInsensitiveCompare(candidate) == .orderedSame
        }) {
            candidate = "\(base) \(number)"
            number += 1
        }
        return candidate
    }

    nonisolated private static func iTermTheme(from data: Data, name: String) -> TerminalTheme? {
        guard let propertyList = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ), let dictionary = propertyList as? [String: Any] else {
            return nil
        }

        let ansi = (0..<16).compactMap { color(named: "Ansi \($0) Color", in: dictionary) }
        guard ansi.count == 16,
              let foreground = color(named: "Foreground Color", in: dictionary),
              let background = color(named: "Background Color", in: dictionary) else {
            return nil
        }
        return TerminalTheme(
            name: name,
            ansi: ansi,
            foreground: foreground,
            background: background,
            cursor: color(named: "Cursor Color", in: dictionary),
            cursorText: color(named: "Cursor Text Color", in: dictionary),
            selectionBackground: color(named: "Selection Color", in: dictionary),
            selectionText: color(named: "Selected Text Color", in: dictionary)
        )
    }

    nonisolated private static func color(
        named name: String,
        in dictionary: [String: Any]
    ) -> ProfileColor? {
        guard let components = dictionary[name] as? [String: Any],
              let red = (components["Red Component"] as? NSNumber)?.doubleValue,
              let green = (components["Green Component"] as? NSNumber)?.doubleValue,
              let blue = (components["Blue Component"] as? NSNumber)?.doubleValue,
              red.isFinite, green.isFinite, blue.isFinite else {
            return nil
        }

        func channel(_ value: Double) -> UInt16 {
            UInt16((min(max(value, 0), 1) * 65535).rounded())
        }
        return ProfileColor(red: channel(red), green: channel(green), blue: channel(blue))
    }

    private func persistFavorites() throws {
        try FileManager.default.createDirectory(at: userThemesDirectory, withIntermediateDirectories: true)
        let data = try FavoritesMigrator().encodeCurrent(favorites)
        try data.write(to: favoritesFile, options: .atomic)
    }

    private func ensureFavoritesAreWritable() throws {
        guard !favoritesAreReadOnly else {
            throw PersistenceMutationError.recoveryRequired(.themeFavorites)
        }
    }

    private func rollbackRename(
        sourceURL: URL?,
        destinationURL: URL,
        originalSourceData: Data?
    ) {
        guard let sourceURL, let originalSourceData else { return }
        if sourceURL.standardizedFileURL == destinationURL.standardizedFileURL {
            try? originalSourceData.write(to: sourceURL, options: .atomic)
        } else {
            try? originalSourceData.write(to: sourceURL, options: .atomic)
            try? FileManager.default.removeItem(at: destinationURL)
        }
    }

    private func reportWriteFailure(_ error: Error, domain: PersistenceDomain, sourceURL: URL) {
        issueCenter?.report(PersistenceIssue(
            domain: domain,
            sourceURL: sourceURL,
            kind: .writeFailed,
            message: error.localizedDescription,
            supportedVersion: 1
        ))
    }
}

public enum ProfilesError: Error, Equatable {
    case invalidTheme
    case themeIsBuiltIn
    case invalidName
    case duplicateName
    case cannotDeleteLastProfile
    case profileNotFound
}

extension ProfilesError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidTheme: return "The theme file is not valid."
        case .themeIsBuiltIn: return "A built-in theme cannot be changed."
        case .invalidName: return "Enter a profile name."
        case .duplicateName: return "A profile with this name already exists."
        case .cannotDeleteLastProfile: return "The last profile cannot be deleted."
        case .profileNotFound: return "The profile no longer exists."
        }
    }
}
