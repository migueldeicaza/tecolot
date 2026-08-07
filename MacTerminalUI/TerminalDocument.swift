//
//  TerminalDocument.swift
//  MacTerminalUI
//
//  Created by Miguel de Icaza on 8/5/25.
//

import SwiftUI
import UniformTypeIdentifiers

struct TerminalDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.terminalSession] }
    
    var content: String
    
    init(content: String = "") {
        self.content = content
    }
    
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let string = String(data: data, encoding: .utf8)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        content = string
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = content.data(using: .utf8)!
        return .init(regularFileWithContents: data)
    }
}

extension UTType {
    static var terminalSession: UTType {
        UTType(importedAs: "com.example.terminal-session")
    }
}