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
    /// The terminal text of a file from an older version. A save keeps it.
    var legacyContent: String?

    init(profileID: UUID? = nil, themeOverride: String? = nil, legacyContent: String? = nil) {
        self.profileID = profileID
        self.themeOverride = themeOverride
        self.legacyContent = legacyContent
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let value = try TerminalSessionDocumentCodec.decode(data)
        profileID = value.profileID
        themeOverride = value.themeOverride
        legacyContent = value.legacyContent
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try TerminalSessionDocumentCodec.encode(TerminalSessionDocumentValue(
            profileID: profileID,
            themeOverride: themeOverride,
            legacyContent: legacyContent
        ))
        return .init(regularFileWithContents: data)
    }
}

extension UTType {
    static var terminalSession: UTType {
        UTType(exportedAs: "com.tirania.tecolot.terminal-session")
    }
}
