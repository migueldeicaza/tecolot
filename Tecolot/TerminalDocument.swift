//
//  TerminalDocument.swift
//  Tecolot
//
//  Created by Miguel de Icaza on 8/5/25.
//

import SwiftUI
import UniformTypeIdentifiers

struct TerminalDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.terminalSession] }

    var profileID: UUID?
    var themeOverride: String?
    var content: String?

    init(profileID: UUID? = nil, themeOverride: String? = nil, content: String? = "") {
        self.profileID = profileID
        self.themeOverride = themeOverride
        self.content = content
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let string = String(data: data, encoding: .utf8)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }

        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.version == 1 {
            profileID = envelope.profileID
            themeOverride = envelope.themeOverride
            content = envelope.content
        } else {
            // Files created by earlier versions were plain terminal text.
            profileID = nil
            themeOverride = nil
            content = string
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let envelope = Envelope(version: 1,
                                profileID: profileID,
                                themeOverride: themeOverride,
                                content: content)
        let data = try JSONEncoder().encode(envelope)
        return .init(regularFileWithContents: data)
    }

    private struct Envelope: Codable {
        var version: Int
        var profileID: UUID?
        var themeOverride: String?
        var content: String?
    }
}

extension UTType {
    static var terminalSession: UTType {
        UTType(exportedAs: "com.tirania.tecolot.terminal-session")
    }
}
