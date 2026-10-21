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

    init(profileID: UUID? = nil, themeOverride: String? = nil) {
        self.profileID = profileID
        self.themeOverride = themeOverride
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let value = try TerminalSessionDocumentCodec.decode(data)
        profileID = value.profileID
        themeOverride = value.themeOverride
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try TerminalSessionDocumentCodec.encode(TerminalSessionDocumentValue(
            profileID: profileID,
            themeOverride: themeOverride
        ))
        return .init(regularFileWithContents: data)
    }
}

extension UTType {
    static var terminalSession: UTType {
        UTType(exportedAs: "com.tirania.tecolot.terminal-session")
    }
}
