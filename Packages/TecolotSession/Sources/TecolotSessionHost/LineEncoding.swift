//
// LineEncoding.swift
// TecolotSessionHost
//
// Converts SwiftTerm buffer lines to wire rows. Call these functions with
// `terminal.terminalLock` held.
//

import Foundation
import SwiftTerm
import TecolotWire

enum WireMapping {
    static func color(_ color: Attribute.Color) -> WireColor {
        switch color {
        case .defaultColor: return .default
        case .defaultInvertedColor: return .defaultInverted
        case .ansi256(let code): return .ansi(code)
        case .trueColor(let red, let green, let blue): return .rgb(red, green, blue)
        }
    }

    static func attribute(_ attribute: Attribute) -> WireAttribute {
        WireAttribute(foreground: color(attribute.fg),
                      background: color(attribute.bg),
                      style: attribute.style.rawValue,
                      underlineStyle: attribute.underlineStyle.rawValue,
                      underlineColor: attribute.underlineColor.map(color))
    }

    static func semantic(_ content: SemanticContent) -> UInt8 {
        switch content {
        case .none: return 0
        case .prompt(let kind): return promptKind(kind)
        case .input: return 5
        case .output: return 6
        }
    }

    static func promptKind(_ kind: SemanticPromptKind) -> UInt8 {
        switch kind {
        case .initial: return 1
        case .right: return 2
        case .continuation: return 3
        case .secondary: return 4
        }
    }

    static func cursorStyle(_ style: CursorStyle) -> UInt8 {
        switch style {
        case .blinkBlock: return 0
        case .steadyBlock: return 1
        case .blinkUnderline: return 2
        case .steadyUnderline: return 3
        case .blinkBar: return 4
        case .steadyBar: return 5
        }
    }

    static func cursorStyle(_ index: UInt8) -> CursorStyle {
        switch index {
        case 1: return .steadyBlock
        case 2: return .blinkUnderline
        case 3: return .steadyUnderline
        case 4: return .blinkBar
        case 5: return .steadyBar
        default: return .blinkBlock
        }
    }

    static func cursorBlinks(_ style: CursorStyle) -> Bool {
        switch style {
        case .blinkBlock, .blinkUnderline, .blinkBar: return true
        case .steadyBlock, .steadyUnderline, .steadyBar: return false
        }
    }

    static func bidi(_ state: BidiPresentationState) -> UInt8? {
        guard state != .default else { return nil }
        var value: UInt8 = 0
        if state.supportMode == .explicit { value |= 1 }
        if state.autodetectDirection { value |= 2 }
        if state.fallbackDirection == .rightToLeft { value |= 4 }
        if state.boxMirroring { value |= 8 }
        return value
    }

    static func rgb(_ color: Color) -> WireRGB {
        WireRGB(red: color.red, green: color.green, blue: color.blue)
    }

    static func color(_ rgb: WireRGB) -> Color {
        Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

/// Assigns stable identifiers to OSC 8 hyperlink payloads.
final class LinkTable {
    private var ids: [String: UInt32] = [:]
    private(set) var values: [UInt32: String] = [:]
    private var next: UInt32 = 1

    func id(for payload: String) -> UInt32 {
        if let id = ids[payload] { return id }
        let id = next
        next &+= 1
        ids[payload] = id
        values[id] = payload
        return id
    }

    func value(for id: UInt32) -> String? { values[id] }
}

/// Encodes one buffer line. Hold the terminal lock while calling `encode`.
struct LineEncoder {
    private var encoder = RowEncoder()

    mutating func encode(_ line: BufferLine, ringIndex: Int, columns: Int,
                         terminal: Terminal, links: LinkTable,
                         usedLinks: inout Set<UInt32>) -> [UInt8] {
        var marks: [WireSemanticMark] = []
        for anchor in terminal.semanticPromptMarks(at: ringIndex) {
            marks.append(WireSemanticMark(kind: WireMapping.promptKind(anchor.kind),
                                          column: max(0, anchor.position.col)))
        }
        // Inline image slices (Sixel, iTerm2); the raster image ID is the wire ID.
        let images = terminal.rasterImageSlices(atRow: ringIndex).map {
            WireRowImage(imageID: UInt64($0.image.id), column: $0.column, width: Float($0.width),
                         height: Float($0.height), sourceY: Float($0.sourceY), sourceHeight: Float($0.sourceHeight))
        }
        encoder.begin(WireRowHeader(columns: columns, isWrapped: line.isWrapped,
                                    bidi: WireMapping.bidi(line.bidiState), marks: marks, images: images))
        var rightToLeft = false
        let count = min(line.count, columns)
        var lastAttribute: Attribute?
        var lastWireAttribute = WireAttribute.plain
        var lastPayload: String?
        var lastLink: UInt32 = 0
        for column in 0 ..< count {
            let cell = line[column]
            let attribute = cell.attribute
            if attribute != lastAttribute {
                lastAttribute = attribute
                lastWireAttribute = WireMapping.attribute(attribute)
            }
            var link: UInt32 = 0
            if cell.hasPayload, let payload = cell.getPayload() as? String {
                if payload == lastPayload {
                    link = lastLink
                } else {
                    link = links.id(for: payload)
                    lastPayload = payload
                    lastLink = link
                }
                usedLinks.insert(link)
            }
            let style = WireCellStyle(attribute: lastWireAttribute, link: link,
                                      semantic: WireMapping.semantic(cell.semanticContent),
                                      isProtected: cell.isProtected)
            let content = Self.content(of: cell)
            if !rightToLeft, case .grapheme(let text, _) = content,
               text.unicodeScalars.contains(where: { WireMapping.isRightToLeftTrigger($0.value) }) {
                rightToLeft = true
                encoder.markRightToLeft()
            }
            encoder.append(content, style: style)
        }
        return encoder.finish()
    }

    /// True when the line has characters that can start right-to-left text.
    func mayNeedBidi(_ line: BufferLine, columns: Int) -> Bool {
        for column in 0 ..< min(line.count, columns) {
            let cell = line[column]
            guard cell.width > 0 else { continue }
            if cell.getCharacter().unicodeScalars.contains(where: { WireMapping.isRightToLeftTrigger($0.value) }) {
                return true
            }
        }
        return false
    }

    static func content(of cell: CharData) -> WireCellContent {
        let width = cell.width
        if width == 0 { return .spacer }
        let text = cell.getText()
        if cell.isSimpleRune {
            let scalars = text.unicodeScalars
            if scalars.count == 1, let scalar = scalars.first {
                if scalar.value == 0 { return .null }
                if width == 1, scalar.value >= 0x20, scalar.value <= 0x7e {
                    return .ascii(UInt8(scalar.value))
                }
            }
        }
        return .grapheme(text, width: UInt8(clamping: Int(width)))
    }
}
