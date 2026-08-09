import Combine
import CoreFoundation
import Foundation

public enum PersistenceDomain: String, Codable, CaseIterable, Sendable {
    case profiles
    case profileStore
    case userThemes
    case themeFavorites
    case windowGroups
    case preferences
    case terminalDocument
    case legacyApplicationSupport

    public var displayName: String {
        switch self {
        case .profiles: return "Profiles"
        case .profileStore: return "Default Profile"
        case .userThemes: return "User Themes"
        case .themeFavorites: return "Theme Favorites"
        case .windowGroups: return "Window Groups"
        case .preferences: return "Preferences"
        case .terminalDocument: return "Terminal Documents"
        case .legacyApplicationSupport: return "Legacy Application Data"
        }
    }
}

public enum PersistenceIssueKind: String, Codable, Sendable {
    case unreadable
    case invalidFormat
    case validationFailed
    case unsupportedVersion
    case backupFailed
    case migrationFailed
    case writeFailed
}

public struct PersistenceIssue: Identifiable, Equatable, Sendable {
    public var id: String { "\(domain.rawValue):\(sourceURL.standardizedFileURL.path)" }
    public let domain: PersistenceDomain
    public let sourceURL: URL
    public let kind: PersistenceIssueKind
    public let message: String
    public let foundVersion: Int?
    public let supportedVersion: Int?
    public let backupURL: URL?

    public init(
        domain: PersistenceDomain,
        sourceURL: URL,
        kind: PersistenceIssueKind,
        message: String,
        foundVersion: Int? = nil,
        supportedVersion: Int? = nil,
        backupURL: URL? = nil
    ) {
        self.domain = domain
        self.sourceURL = sourceURL
        self.kind = kind
        self.message = message
        self.foundVersion = foundVersion
        self.supportedVersion = supportedVersion
        self.backupURL = backupURL
    }
}

@MainActor
public final class PersistenceIssueCenter: ObservableObject {
    @Published public private(set) var issues: [PersistenceIssue] = []

    public init() {}

    public func report(_ issue: PersistenceIssue) {
        issues.removeAll { $0.id == issue.id }
        issues.append(issue)
        issues.sort {
            if $0.domain.displayName == $1.domain.displayName {
                return $0.sourceURL.lastPathComponent < $1.sourceURL.lastPathComponent
            }
            return $0.domain.displayName < $1.domain.displayName
        }
    }

    public func resolve(domain: PersistenceDomain, sourceURL: URL) {
        let id = "\(domain.rawValue):\(sourceURL.standardizedFileURL.path)"
        issues.removeAll { $0.id == id }
    }

    public func replaceIssues(in domain: PersistenceDomain, with newIssues: [PersistenceIssue]) {
        issues.removeAll { $0.domain == domain }
        for issue in newIssues {
            report(issue)
        }
    }
}

public enum PersistenceRewritePolicy: Sendable {
    case eagerWithBackup
    case inMemoryOnly
}

public enum PersistenceMutationError: LocalizedError, Equatable {
    case recoveryRequired(PersistenceDomain)

    public var errorDescription: String? {
        switch self {
        case let .recoveryRequired(domain):
            return "\(domain.displayName) is read-only until its data recovery issue is resolved."
        }
    }
}

public protocol VersionedDocumentMigrator {
    associatedtype Value

    var currentVersion: Int { get }
    func sourceVersion(in data: Data) throws -> Int
    func decode(_ data: Data, from sourceVersion: Int) throws -> Value
    func validate(_ value: Value) throws
    func encodeCurrent(_ value: Value) throws -> Data
}

public struct PersistenceLoadResult<Value> {
    public let value: Value?
    public let sourceVersion: Int?
    public let migrated: Bool
    public let missing: Bool
    public let issue: PersistenceIssue?

    public init(
        value: Value?,
        sourceVersion: Int?,
        migrated: Bool,
        missing: Bool,
        issue: PersistenceIssue?
    ) {
        self.value = value
        self.sourceVersion = sourceVersion
        self.migrated = migrated
        self.missing = missing
        self.issue = issue
    }
}

public enum VersionedPersistenceError: LocalizedError, Equatable {
    case missingVersion
    case unsupportedVersion(found: Int, supported: Int)
    case invalidDocument(String)

    public var errorDescription: String? {
        switch self {
        case .missingVersion:
            return "The document does not contain a schema version."
        case let .unsupportedVersion(found, supported):
            return "This document uses schema version \(found). This version of Tecolot supports up to version \(supported)."
        case let .invalidDocument(message):
            return message
        }
    }
}

public enum PersistenceVersionProbe {
    public static func optionalVersion(in data: Data) throws -> Int? {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else { return nil }
        guard let rawVersion = dictionary["version"] else { return nil }
        guard let version = rawVersion as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID() else {
            throw VersionedPersistenceError.invalidDocument("The schema version is not an integer.")
        }
        let value = version.intValue
        guard version.doubleValue == Double(value) else {
            throw VersionedPersistenceError.invalidDocument("The schema version is not an integer.")
        }
        return value
    }

    public static func requiredVersion(in data: Data) throws -> Int {
        guard let version = try optionalVersion(in: data) else {
            throw VersionedPersistenceError.missingVersion
        }
        return version
    }
}

public enum PersistenceBackups {
    public static func backupURL(
        for sourceURL: URL,
        domain: PersistenceDomain,
        sourceVersion: Int,
        root: URL
    ) -> URL {
        root
            .appendingPathComponent(domain.rawValue, isDirectory: true)
            .appendingPathComponent("\(sourceURL.lastPathComponent).v\(sourceVersion).backup")
    }

    @discardableResult
    public static func createIfNeeded(
        for sourceURL: URL,
        domain: PersistenceDomain,
        sourceVersion: Int,
        root: URL
    ) throws -> URL {
        let destination = backupURL(
            for: sourceURL,
            domain: domain,
            sourceVersion: sourceVersion,
            root: root
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    @discardableResult
    public static func writeSnapshotIfNeeded(
        _ data: Data,
        sourceName: String,
        domain: PersistenceDomain,
        sourceVersion: Int,
        root: URL
    ) throws -> URL {
        let sourceURL = root.appendingPathComponent(sourceName)
        let destination = backupURL(
            for: sourceURL,
            domain: domain,
            sourceVersion: sourceVersion,
            root: root
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
        return destination
    }

    public static func restore(_ backupURL: URL, to sourceURL: URL) throws {
        let data = try Data(contentsOf: backupURL)
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: sourceURL, options: .atomic)
    }
}

public enum VersionedFileLoader {
    public static func load<M: VersionedDocumentMigrator>(
        from sourceURL: URL,
        domain: PersistenceDomain,
        backupRoot: URL,
        migrator: M,
        rewritePolicy: PersistenceRewritePolicy = .eagerWithBackup
    ) -> PersistenceLoadResult<M.Value> {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return PersistenceLoadResult(
                value: nil,
                sourceVersion: nil,
                migrated: false,
                missing: true,
                issue: nil
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: sourceURL)
        } catch {
            return failure(
                domain: domain,
                sourceURL: sourceURL,
                kind: .unreadable,
                message: error.localizedDescription,
                supportedVersion: migrator.currentVersion
            )
        }

        let sourceVersion: Int
        do {
            sourceVersion = try migrator.sourceVersion(in: data)
        } catch {
            return failure(
                domain: domain,
                sourceURL: sourceURL,
                kind: .invalidFormat,
                message: error.localizedDescription,
                supportedVersion: migrator.currentVersion
            )
        }

        guard sourceVersion <= migrator.currentVersion else {
            let error = VersionedPersistenceError.unsupportedVersion(
                found: sourceVersion,
                supported: migrator.currentVersion
            )
            return failure(
                domain: domain,
                sourceURL: sourceURL,
                kind: .unsupportedVersion,
                message: error.localizedDescription,
                foundVersion: sourceVersion,
                supportedVersion: migrator.currentVersion
            )
        }

        let value: M.Value
        do {
            value = try migrator.decode(data, from: sourceVersion)
        } catch {
            return failure(
                domain: domain,
                sourceURL: sourceURL,
                kind: .invalidFormat,
                message: error.localizedDescription,
                foundVersion: sourceVersion,
                supportedVersion: migrator.currentVersion
            )
        }

        do {
            try migrator.validate(value)
        } catch {
            return failure(
                domain: domain,
                sourceURL: sourceURL,
                kind: .validationFailed,
                message: error.localizedDescription,
                foundVersion: sourceVersion,
                supportedVersion: migrator.currentVersion
            )
        }

        let mustRewrite = sourceVersion < migrator.currentVersion
            && rewritePolicy == .eagerWithBackup
        guard mustRewrite else {
            return PersistenceLoadResult(
                value: value,
                sourceVersion: sourceVersion,
                migrated: false,
                missing: false,
                issue: nil
            )
        }

        let backupURL: URL
        do {
            backupURL = try PersistenceBackups.createIfNeeded(
                for: sourceURL,
                domain: domain,
                sourceVersion: sourceVersion,
                root: backupRoot
            )
        } catch {
            return failure(
                domain: domain,
                sourceURL: sourceURL,
                kind: .backupFailed,
                message: error.localizedDescription,
                foundVersion: sourceVersion,
                supportedVersion: migrator.currentVersion
            )
        }

        do {
            let currentData = try migrator.encodeCurrent(value)
            try currentData.write(to: sourceURL, options: .atomic)
        } catch {
            return failure(
                domain: domain,
                sourceURL: sourceURL,
                kind: .migrationFailed,
                message: error.localizedDescription,
                foundVersion: sourceVersion,
                supportedVersion: migrator.currentVersion,
                backupURL: backupURL
            )
        }

        return PersistenceLoadResult(
            value: value,
            sourceVersion: sourceVersion,
            migrated: true,
            missing: false,
            issue: nil
        )
    }

    private static func failure<Value>(
        domain: PersistenceDomain,
        sourceURL: URL,
        kind: PersistenceIssueKind,
        message: String,
        foundVersion: Int? = nil,
        supportedVersion: Int? = nil,
        backupURL: URL? = nil
    ) -> PersistenceLoadResult<Value> {
        PersistenceLoadResult(
            value: nil,
            sourceVersion: foundVersion,
            migrated: false,
            missing: false,
            issue: PersistenceIssue(
                domain: domain,
                sourceURL: sourceURL,
                kind: kind,
                message: message,
                foundVersion: foundVersion,
                supportedVersion: supportedVersion,
                backupURL: backupURL
            )
        )
    }
}
