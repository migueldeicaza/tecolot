//
//  NerdFontTests.swift
//  TecolotTests
//
//  Validates the bundled Symbols Nerd Font, the provider contract, and the
//  generated codepoint metadata against the committed TTF.
//

import CoreText
import Foundation
import Testing
@testable import Tecolot

struct NerdFontTests {
    /// A CTFont created straight from the committed TTF, bypassing
    /// registration, so metadata validation cannot pass via some other
    /// installed Nerd Font.
    private func fontFromBundledFile() throws -> CTFont {
        let url = try #require(
            Bundle(for: NerdFontFallbackProvider.self)
                .url(forResource: "SymbolsNerdFont-Regular", withExtension: "ttf",
                     subdirectory: "NerdFontResources")
            ?? Bundle.main.url(forResource: "SymbolsNerdFont-Regular", withExtension: "ttf",
                               subdirectory: "NerdFontResources"))
        let descriptors = try #require(
            CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])
        return CTFontCreateWithFontDescriptor(try #require(descriptors.first), 12, nil)
    }

    private func hasGlyph(_ font: CTFont, _ scalar: UInt32) -> Bool {
        guard let unicode = Unicode.Scalar(scalar) else { return false }
        var units = Array(String(unicode).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        return CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count)
    }

    @Test func providerRegistersAndServesAStableFont() throws {
        let provider = NerdFontFallbackProvider.shared
        let font = try #require(provider.fallbackFont(forPointSize: 13))
        #expect(CTFontCopyPostScriptName(font) as String == NerdFontFallbackProvider.postScriptName)
        // The contract requires the identical instance per size.
        #expect(provider.fallbackFont(forPointSize: 13).map { $0 === font } == true)
        // A known Nerd Font icon resolves in the served font.
        var units: [UniChar] = [0xEA61]
        var glyphs: [CGGlyph] = [0]
        #expect(CTFontGetGlyphsForCharacters(font, &units, &glyphs, 1))
    }

    @Test func candidacyIsExactSetMembership() {
        let provider = NerdFontFallbackProvider.shared
        #expect(provider.placementPolicy(for: "\u{EA61}") != nil)
        // Powerline block fills its cell exactly.
        #expect(provider.placementPolicy(for: "\u{E0B1}")?.placement == .stretch)
        // An unrelated private-use scalar is not claimed.
        #expect(provider.placementPolicy(for: "\u{F8FF}") == nil)
        // Non-PUA symbols the release defines are claimed.
        #expect(provider.placementPolicy(for: "\u{2665}") != nil)
    }

    /// Spec generator validation: every codepoint the metadata claims must
    /// have a glyph in the committed TTF, and versions must match.
    @Test func generatedMetadataMatchesTheBundledFont() throws {
        let font = try fontFromBundledFile()
        let version = try #require(CTFontCopyName(font, kCTFontVersionNameKey) as String?)
        #expect(version.contains("Nerd Fonts \(NerdFontGlyphMetadata.version)"))

        var missing: [UInt32] = []
        for entry in NerdFontGlyphMetadata.entries {
            #expect(entry.lower <= entry.upper)
            for code in entry.lower...entry.upper where !hasGlyph(font, code) {
                missing.append(code)
            }
        }
        #expect(missing.isEmpty, "codepoints without glyphs: \(missing.prefix(10).map { String($0, radix: 16) })")
    }

    @Test func metadataRangesAreSortedAndDisjoint() {
        let entries = NerdFontGlyphMetadata.entries
        for i in 1..<entries.count {
            #expect(entries[i - 1].upper < entries[i].lower)
        }
        // Binary search agrees with a straight scan on the boundaries.
        #expect(NerdFontGlyphMetadata.policyClass(for: 0x23FB) == .icon)
        #expect(NerdFontGlyphMetadata.policyClass(for: 0xE0B0) == .stretch)
        #expect(NerdFontGlyphMetadata.policyClass(for: 0x41) == nil)
        #expect(NerdFontGlyphMetadata.policyClass(for: 0x10FFFF) == nil)
    }
}
