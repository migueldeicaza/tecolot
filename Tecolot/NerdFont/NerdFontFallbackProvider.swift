//
// NerdFontFallbackProvider.swift
//
// Tecolot's implementation of SwiftTerm's glyph-fallback hook: registers the
// bundled Symbols Nerd Font once and serves it, with a placement policy, for
// the Nerd Font codepoints the selected terminal font cannot draw.
//

import CoreText
import Foundation
import SwiftTerm
import os

final class NerdFontFallbackProvider: TerminalGlyphFallbackProvider, @unchecked Sendable {
    static let shared = NerdFontFallbackProvider()

    /// The bundled font's PostScript name (Nerd Fonts 3.4.0).
    static let postScriptName = "SymbolsNF"

    /// The metadata is static for the life of the process, so the generation
    /// never changes; the provider's object identity covers instance changes.
    let generation: UInt64 = 1

    private let registered: Bool
    private let fontsBySize = OSAllocatedUnfairLock<[CGFloat: CTFont]>(initialState: [:])

    /// Policies are shared values: the placement classes carry no per-size
    /// state, so two constants cover the whole table.
    private static let iconPolicy = TerminalGlyphPlacementPolicy(placement: .icon,
                                                                 maximumCellWidth: 2)
    private static let stretchPolicy = TerminalGlyphPlacementPolicy(placement: .stretch,
                                                                    maximumCellWidth: 1)

    private init () {
        registered = Self.registerBundledFont()
    }

    private static func registerBundledFont () -> Bool {
        guard let url = Bundle.main.url(forResource: "SymbolsNerdFont-Regular",
                                        withExtension: "ttf",
                                        subdirectory: "NerdFontResources")
                ?? Bundle(for: NerdFontFallbackProvider.self)
                    .url(forResource: "SymbolsNerdFont-Regular", withExtension: "ttf",
                         subdirectory: "NerdFontResources") else {
            Logger().error("NerdFont: bundled SymbolsNerdFont-Regular.ttf not found")
            return false
        }
        var registrationError: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &registrationError) {
            return true
        }
        if let error = registrationError?.takeRetainedValue() {
            let code = CFErrorGetCode(error)
            // An already-registered or duplicate-name font serves our purpose.
            if code == CTFontManagerError.alreadyRegistered.rawValue
                || code == CTFontManagerError.duplicatedName.rawValue {
                return true
            }
            Logger().error("NerdFont: font registration failed: \(error)")
        }
        return false
    }

    // MARK: TerminalGlyphFallbackProvider

    func placementPolicy (for scalar: Unicode.Scalar) -> TerminalGlyphPlacementPolicy? {
        switch NerdFontGlyphMetadata.policyClass(for: scalar.value) {
        case .icon: return Self.iconPolicy
        case .stretch: return Self.stretchPolicy
        case nil: return nil
        }
    }

    func fallbackFont (forPointSize size: CGFloat) -> CTFont? {
        guard registered else { return nil }
        return fontsBySize.withLock { fonts in
            if let cached = fonts[size] {
                return cached
            }
            let font = CTFontCreateWithName(Self.postScriptName as CFString, size, nil)
            // CTFontCreateWithName substitutes a system face for unknown
            // names; reject a substitute rather than render wrong glyphs.
            guard CTFontCopyPostScriptName(font) as String == Self.postScriptName else {
                Logger().error("NerdFont: \(Self.postScriptName) resolved to a substitute font")
                return nil
            }
            fonts[size] = font
            return font
        }
    }
}
