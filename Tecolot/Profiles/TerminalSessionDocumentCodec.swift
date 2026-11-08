import Foundation

/// A `.terminalSession` file: a profile and a theme. RestoreStore keeps the
/// text of the window's panes; a new save does not add text to the file.
public struct TerminalSessionDocumentValue: Equatable, Sendable {
    public var profileID: UUID?
    public var themeOverride: String?
    /// The terminal text of a file from an older version: the `content` key,
    /// or the whole file before the versioned format. The pane that opens
    /// the file shows it, and a save keeps it, so that the text is not lost.
    public var legacyContent: String?

    public init(profileID: UUID? = nil, themeOverride: String? = nil, legacyContent: String? = nil) {
        self.profileID = profileID
        self.themeOverride = themeOverride
        self.legacyContent = legacyContent
    }
}

private struct TerminalSessionDocumentV1: Codable {
    var version: Int
    var profileID: UUID?
    var themeOverride: String?
    /// Written only to keep the text of an older file.
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
            // Terminal text only, from before the versioned format.
            guard let content = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            return TerminalSessionDocumentValue(legacyContent: content.isEmpty ? nil : content)
        case 1:
            let document = try JSONDecoder().decode(TerminalSessionDocumentV1.self, from: data)
            return TerminalSessionDocumentValue(
                profileID: document.profileID,
                themeOverride: document.themeOverride,
                legacyContent: document.content?.isEmpty == false ? document.content : nil
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
            content: value.legacyContent
        ))
    }

    /// The text that the pane shows for `content`: its last `limit` lines,
    /// with tabs expanded to spaces (8-column stops) and the other control
    /// characters (other than line ends) replaced, as the file is not
    /// trusted. The result only has text and line ends, which is what
    /// `ScrollbackFile.validate` accepts for persistent panes.
    public static func replayText(for content: String, limit: Int) -> String? {
        guard limit > 0 else { return nil }
        // "\r\n" is one Character: split on the scalars.
        var lines = content.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        guard !lines.isEmpty else { return nil }
        let printable = lines.suffix(limit).map { line in
            var output = String.UnicodeScalarView()
            var column = 0
            for scalar in line {
                switch scalar {
                case "\r":
                    continue
                case "\t":
                    let spaces = tabWidth - column % tabWidth
                    output.append(contentsOf: repeatElement(" ", count: spaces))
                    column += spaces
                case _ where scalar.value < 0x20 || (0x7F ... 0x9F).contains(scalar.value):
                    output.append("\u{FFFD}")
                    column += 1
                default:
                    output.append(scalar)
                    // Combining marks take no column; this does not
                    // measure wide characters.
                    if scalar.properties.generalCategory != .nonspacingMark
                        && scalar.properties.generalCategory != .enclosingMark {
                        column += 1
                    }
                }
            }
            return String(output)
        }
        return printable.joined(separator: "\n") + "\n"
    }

    private static let tabWidth = 8

    private static func sourceVersion(in data: Data) throws -> Int {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              dictionary.keys.contains("version") else {
            return 0
        }
        return try PersistenceVersionProbe.requiredVersion(in: data)
    }
}
