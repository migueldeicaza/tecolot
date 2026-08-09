//
//  TerminalDocument.swift
//  Tecolot
//
//  Created by Miguel de Icaza on 8/5/25.
//

import SwiftUI
import TerminalProfilesKit
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
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let value = try TerminalSessionDocumentCodec.decode(data)
        profileID = value.profileID
        themeOverride = value.themeOverride
        content = value.content
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try TerminalSessionDocumentCodec.encode(TerminalSessionDocumentValue(
            profileID: profileID,
            themeOverride: themeOverride,
            content: content
        ))
        return .init(regularFileWithContents: data)
    }
}

extension UTType {
    static var terminalSession: UTType {
        UTType(exportedAs: "com.tirania.tecolot.terminal-session")
    }
}
