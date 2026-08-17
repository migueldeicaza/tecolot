//
// NerdFontMetadataGen — deterministic generator for Tecolot's Nerd Font
// codepoint metadata.
//
// Inputs (pinned in this tool's `inputs/` directory and the app bundle):
//   - inputs/glyphnames.json           the Nerd Fonts release glyph list
//   - Tecolot/NerdFont/NerdFontResources/SymbolsNerdFont-Regular.ttf
//
// Output:
//   - Tecolot/NerdFont/NerdFontGlyphMetadata.generated.swift
//
// The generator fails, with a clear message, when: the metadata and font
// versions differ; a codepoint appears twice with conflicting placement
// classes (upstream alias names that agree are collapsed); or a metadata
// codepoint has no glyph in the TTF. Output is sorted and formatted
// deterministically: regenerating from pinned inputs produces no diff.
//
// Placement classes follow the coarse Ghostty groupings: the Powerline
// blocks stretch to fill their cell exactly; everything else fits as a
// default icon limited to two cells. Refine per-glyph metrics here when
// finer data is imported.
//

import CoreText
import Foundation

func fail (_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

// MARK: Locate inputs relative to the repository root

let toolURL = URL(fileURLWithPath: #filePath)     // .../tools/NerdFontMetadataGen/Sources/main.swift
let toolRoot = toolURL.deletingLastPathComponent().deletingLastPathComponent()
let repoRoot = toolRoot.deletingLastPathComponent().deletingLastPathComponent()
let glyphNamesURL = toolRoot.appendingPathComponent("inputs/glyphnames.json")
let fontURL = repoRoot.appendingPathComponent("Tecolot/NerdFont/NerdFontResources/SymbolsNerdFont-Regular.ttf")
let outputURL = repoRoot.appendingPathComponent("Tecolot/NerdFont/NerdFontGlyphMetadata.generated.swift")

// MARK: Parse glyphnames.json

guard let glyphData = try? Data(contentsOf: glyphNamesURL),
      let root = try? JSONSerialization.jsonObject(with: glyphData) as? [String: Any] else {
    fail("cannot read \(glyphNamesURL.path)")
}
guard let metadata = root["METADATA"] as? [String: Any],
      let metadataVersion = metadata["version"] as? String else {
    fail("glyphnames.json has no METADATA.version")
}

enum PolicyClass: String, Comparable {
    case icon
    case stretch

    static func < (lhs: PolicyClass, rhs: PolicyClass) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The Powerline blocks fill their cell exactly on both axes, matching the
/// font-patcher's "xy" scale rules for these ranges; E0B0/E0B2/E0B4/E0B6 are
/// normally intercepted by SwiftTerm's own PowerlineRenderer before the
/// fallback ever runs.
func policyClass (for code: UInt32) -> PolicyClass {
    switch code {
    case 0xE0A0...0xE0A3, 0xE0B0...0xE0D7:
        return .stretch
    default:
        return .icon
    }
}

var classByCode: [UInt32: PolicyClass] = [:]
for (name, value) in root where name != "METADATA" {
    guard let entry = value as? [String: Any],
          let codeString = entry["code"] as? String,
          let code = UInt32(codeString, radix: 16) else {
        fail("malformed entry for \(name)")
    }
    let cls = policyClass(for: code)
    if let existing = classByCode[code], existing != cls {
        fail(String(format: "duplicate codepoint U+%04X with conflicting classes", code))
    }
    classByCode[code] = cls
}
guard !classByCode.isEmpty else { fail("no codepoints parsed") }

// MARK: Validate against the pinned TTF

guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL)
        as? [CTFontDescriptor],
      let descriptor = descriptors.first else {
    fail("cannot read font at \(fontURL.path)")
}
let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
guard let versionName = CTFontCopyName(font, kCTFontVersionNameKey) as String? else {
    fail("font has no version name entry")
}
guard versionName.contains("Nerd Fonts \(metadataVersion)") else {
    fail("version mismatch: metadata \(metadataVersion), font \"\(versionName)\"")
}

var missing: [UInt32] = []
for code in classByCode.keys {
    guard let scalar = Unicode.Scalar(code) else {
        fail(String(format: "invalid scalar U+%04X", code))
    }
    var units = Array(String(scalar).utf16)
    var glyphs = [CGGlyph](repeating: 0, count: units.count)
    if !CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count) {
        missing.append(code)
    }
}
if !missing.isEmpty {
    let sample = missing.sorted().prefix(10)
        .map { String(format: "U+%04X", $0) }.joined(separator: ", ")
    fail("\(missing.count) metadata codepoints have no glyph in the TTF: \(sample)…")
}

// MARK: Merge into ranges and emit

struct Run { var lower: UInt32; var upper: UInt32; let cls: PolicyClass }
var runs: [Run] = []
for code in classByCode.keys.sorted() {
    let cls = classByCode[code]!
    if var last = runs.last, last.upper + 1 == code, last.cls == cls {
        last.upper = code
        runs[runs.count - 1] = last
    } else {
        runs.append(Run(lower: code, upper: code, cls: cls))
    }
}

var out = """
//
// NerdFontGlyphMetadata.generated.swift
//
// Generated by tools/NerdFontMetadataGen — DO NOT EDIT.
// Source: Nerd Fonts \(metadataVersion) glyphnames.json + SymbolsNerdFont-Regular.ttf.
// Regenerate with: swift run --package-path tools/NerdFontMetadataGen
//

import Foundation

enum NerdFontGlyphMetadata {
    static let version = "\(metadataVersion)"

    enum PolicyClass: UInt8 {
        /// Default icon: preserve aspect ratio, fit and center in the cell.
        case icon
        /// Powerline-style: fill the cell exactly on both axes.
        case stretch
    }

    struct Entry {
        let lower: UInt32
        let upper: UInt32
        let policy: PolicyClass
    }

    /// Sorted, non-overlapping codepoint ranges of every glyph the pinned
    /// symbols font supplies (\(classByCode.count) codepoints).
    static let entries: [Entry] = [

"""
for run in runs {
    out += String(format: "        Entry(lower: 0x%04X, upper: 0x%04X, policy: .%@),\n",
                  run.lower, run.upper, run.cls.rawValue)
}
out += """
    ]

    /// The placement class for `scalar`, or nil when the scalar is not a
    /// Nerd Font candidate. Exact-set membership: unrelated private-use
    /// scalars stay untouched.
    static func policyClass (for scalar: UInt32) -> PolicyClass? {
        var low = 0
        var high = entries.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let entry = entries[mid]
            if scalar < entry.lower {
                high = mid - 1
            } else if scalar > entry.upper {
                low = mid + 1
            } else {
                return entry.policy
            }
        }
        return nil
    }
}

"""

do {
    try out.write(to: outputURL, atomically: true, encoding: .utf8)
} catch {
    fail("cannot write \(outputURL.path): \(error)")
}
print("wrote \(outputURL.path): \(classByCode.count) codepoints in \(runs.count) ranges")
