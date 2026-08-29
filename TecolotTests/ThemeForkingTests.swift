//
//  ThemeForkingTests.swift
//  TecolotTests
//
//  Tests theme fork lineage, duplicate names, and persistence compatibility.
//
import Foundation
import Testing
@testable import Tecolot

@MainActor
final class ThemeForkingTests {
    private func makeStore() throws -> (ThemeStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-forking-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (ThemeStore(directory: directory), directory)
    }

    @Test func forkNameDeduplicatesCaseInsensitively() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = store.theme(named: "Dracula")

        #expect(store.forkName(basedOn: base.name) == "Dracula (Custom)")

        var first = base
        first.name = "dracula (custom)"
        first.isBuiltIn = false
        try store.saveUserTheme(first)
        #expect(store.forkName(basedOn: base.name) == "Dracula (Custom) 2")

        var second = base
        second.name = "DRACULA (CUSTOM) 2"
        second.isBuiltIn = false
        try store.saveUserTheme(second)
        #expect(store.forkName(basedOn: base.name) == "Dracula (Custom) 3")
    }

    @Test func copyNameDeduplicates() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var custom = store.theme(named: "Dracula")
        custom.name = "Night"
        custom.isBuiltIn = false
        try store.saveUserTheme(custom)

        #expect(store.copyName(basedOn: custom.name) == "Night copy")

        var firstCopy = custom
        firstCopy.name = "NIGHT COPY"
        try store.saveUserTheme(firstCopy)
        #expect(store.copyName(basedOn: custom.name) == "Night copy 2")

        var secondCopy = custom
        secondCopy.name = "Night copy 2"
        try store.saveUserTheme(secondCopy)
        #expect(store.copyName(basedOn: custom.name) == "Night copy 3")
    }

    @Test func forkSetsAndPersistsLineage() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = store.theme(named: "Dracula")
        let fork = store.fork(of: source)

        #expect(fork.name == "Dracula (Custom)")
        #expect(fork.baseThemeName == source.name)
        #expect(!fork.isBuiltIn)

        try store.saveUserTheme(fork)
        let reloaded = ThemeStore(directory: directory)
        #expect(reloaded.theme(named: fork.name).baseThemeName == source.name)

        let file = directory.appendingPathComponent("\(fork.id).json")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        let savedTheme = try #require(object["theme"] as? [String: Any])
        #expect(savedTheme["baseThemeName"] as? String == source.name)
    }

    @Test func duplicateUsesSourceKindAndPreservesLineage() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let builtIn = store.theme(named: "Dracula")

        let builtInCopy = store.duplicate(of: builtIn)
        #expect(builtInCopy.name == "Dracula (Custom)")
        #expect(builtInCopy.baseThemeName == builtIn.name)
        #expect(!builtInCopy.isBuiltIn)

        var custom = builtIn
        custom.name = "Night"
        custom.baseThemeName = builtIn.name
        custom.isBuiltIn = false
        try store.saveUserTheme(custom)

        let customCopy = store.duplicate(of: custom)
        #expect(customCopy.name == "Night copy")
        #expect(customCopy.baseThemeName == builtIn.name)
        #expect(!customCopy.isBuiltIn)
    }

    @Test func missingLineageKeyDecodesAsNil() throws {
        var theme = TerminalTheme.fallback
        theme.baseThemeName = "Original"
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(theme)) as? [String: Any]
        )
        object.removeValue(forKey: "baseThemeName")
        let data = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(TerminalTheme.self, from: data)
        #expect(decoded.baseThemeName == nil)
    }
}
