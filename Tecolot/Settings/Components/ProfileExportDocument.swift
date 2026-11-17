import SwiftUI
import UniformTypeIdentifiers

/// FileDocument wrapper so fileExporter can save a profile
struct ProfileExportDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.json]
    }

    var profile: TerminalProfile

    var filename: String {
        profile.name
    }

    init(profile: TerminalProfile) {
        self.profile = profile
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct Envelope: Codable {
            var version: Int
            var profile: TerminalProfile
        }
        let data = try encoder.encode(Envelope(version: 1, profile: profile))
        return FileWrapper(regularFileWithContents: data)
    }
}
