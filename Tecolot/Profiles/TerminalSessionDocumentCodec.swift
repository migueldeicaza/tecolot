import Foundation

public struct TerminalSessionDocumentValue: Equatable, Sendable {
    public var profileID: UUID?
    public var themeOverride: String?
    public var content: String?

    public init(profileID: UUID? = nil, themeOverride: String? = nil, content: String? = nil) {
        self.profileID = profileID
        self.themeOverride = themeOverride
        self.content = content
    }
}

private struct TerminalSessionDocumentV1: Codable {
    var version: Int
    var profileID: UUID?
    var themeOverride: String?
    var content: String?
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
            guard let content = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            return TerminalSessionDocumentValue(content: content)
        case 1:
            let document = try JSONDecoder().decode(TerminalSessionDocumentV1.self, from: data)
            return TerminalSessionDocumentValue(
                profileID: document.profileID,
                themeOverride: document.themeOverride,
                content: document.content
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
            themeOverride: value.themeOverride,
            content: value.content
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
