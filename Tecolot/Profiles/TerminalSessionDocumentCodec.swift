import Foundation

/// A `.terminalSession` file: a profile and a theme. The terminal text is
/// not in the file; RestoreStore keeps the text of the window's panes.
public struct TerminalSessionDocumentValue: Equatable, Sendable {
    public var profileID: UUID?
    public var themeOverride: String?

    public init(profileID: UUID? = nil, themeOverride: String? = nil) {
        self.profileID = profileID
        self.themeOverride = themeOverride
    }
}

/// Older files can also have a `content` key with terminal text. The
/// decoder ignores it, and the next save removes it.
private struct TerminalSessionDocumentV1: Codable {
    var version: Int
    var profileID: UUID?
    var themeOverride: String?
}

public enum TerminalSessionDocumentCodec {
    public static let currentVersion = 1

    public static func decode(_ data: Data) throws -> TerminalSessionDocumentValue {
        let version = try sourceVersion(in: data)
        guard version <= currentVersion else {
            throw VersionedPersistenceError.unsupportedVersion(
                found: version,
                supported: currentVersion
            )
        }

        switch version {
        case 0:
            // Terminal text only, from before the versioned format.
            guard String(data: data, encoding: .utf8) != nil else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            return TerminalSessionDocumentValue()
        case 1:
            let document = try JSONDecoder().decode(TerminalSessionDocumentV1.self, from: data)
            return TerminalSessionDocumentValue(
                profileID: document.profileID,
                themeOverride: document.themeOverride
            )
        default:
            throw VersionedPersistenceError.invalidDocument("Unsupported terminal-document schema.")
        }
    }

    public static func encode(_ value: TerminalSessionDocumentValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(TerminalSessionDocumentV1(
            version: currentVersion,
            profileID: value.profileID,
            themeOverride: value.themeOverride
        ))
    }

    private static func sourceVersion(in data: Data) throws -> Int {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              dictionary.keys.contains("version") else {
            return 0
        }
        return try PersistenceVersionProbe.requiredVersion(in: data)
    }
}
