//
//  RemoteFrameSource.swift
//  Tecolot
//
//  Turns the rows that a RemoteSession caches (wire cells) into SwiftTerm
//  lines for TerminalRenderView. Only rows whose content changed are
//  converted again, and only when the view draws a frame.
//

import Foundation
import SwiftTerm
import TecolotSessionClient
import TecolotWire

final class RemoteFrameSource: TerminalExternalFrameSource {
    var session: RemoteSession {
        didSet {
            converted.removeAll()
            paletteCache = nil
        }
    }
    /// The selection to draw, in absolute line numbers.
    var selection: TerminalExternalSelection?
    /// The 16 theme colors and the default colors, for the 256-color palette.
    var theme: (ansi: [Color], foreground: Color, background: Color)? {
        didSet { paletteCache = nil }
    }

    private var store = TerminalRowStore()
    private var converted: [Int64: (stamp: UInt64, line: BufferLine)] = [:]
    private var attributes: [WireAttribute: Attribute] = [:]
    private var paletteCache: (overrides: [UInt8: WireRGB], palette: [Color])?

    init(session: RemoteSession) {
        self.session = session
    }

    func withFrame(_ body: (TerminalExternalFrame, TerminalRowStore, (Int) -> BufferLine?) -> Void) {
        session.withState { state, cache in
            if store.isNearCapacity {
                store = TerminalRowStore()
                converted.removeAll()
                attributes.removeAll()
            }
            let top = state.displayTop
            let rows = state.rows
            // Keep conversions near the viewport only.
            if converted.count > rows * 4 {
                let low = top - Int64(rows)
                let high = top + Int64(rows * 2)
                converted = converted.filter { $0.key >= low && $0.key < high }
            }
            let cursor = state.cursor
            let frame = TerminalExternalFrame(
                columns: state.columns, rows: rows, topLine: Int(top),
                cursorLine: Int(cursor?.line ?? 0), cursorColumn: cursor?.column ?? 0,
                cursorVisible: cursor?.visible ?? false,
                cursorStyle: PersistentSessions.cursorStyle(cursor?.style ?? 0),
                isAlternateBuffer: state.buffer == .alternate,
                palette: palette(overrides: state.colors?.paletteOverrides ?? [:]),
                selection: selection)
            body(frame, store) { number in
                self.line(Int64(number), cache: cache)
            }
        }
    }

    private func line(_ number: Int64, cache: RowCache) -> BufferLine? {
        guard let row = cache[number] else { return nil }
        if let existing = converted[number], existing.stamp == row.stamp {
            return existing.line
        }
        let columns = max(1, row.header.columns)
        let line: BufferLine
        if let existing = converted[number]?.line, existing.count == columns {
            line = existing
            store.clear(line)
        } else {
            line = store.makeLine(columns: columns)
        }
        for (column, cell) in row.cells.enumerated() where column < columns {
            let attribute = attribute(for: cell.style.attribute)
            switch cell.content {
            case .null:
                if attribute != Attribute.empty {
                    store.setCell(line, column: column, text: nil, width: 1, attribute: attribute)
                }
            case .ascii(let byte):
                store.setCell(line, column: column, text: String(UnicodeScalar(byte)), width: 1,
                              attribute: attribute, isProtected: cell.style.isProtected)
            case .grapheme(let text, let width):
                store.setCell(line, column: column, text: text, width: Int(width),
                              attribute: attribute, isProtected: cell.style.isProtected)
            case .spacer:
                store.setCell(line, column: column, text: nil, width: 0, attribute: attribute)
            }
        }
        store.setLineState(line, isWrapped: row.header.isWrapped,
                           renderMode: Self.renderMode(row.header.renderMode))
        converted[number] = (row.stamp, line)
        return line
    }

    private func attribute(for wire: WireAttribute) -> Attribute {
        if let cached = attributes[wire] { return cached }
        let value = Attribute(foreground: Self.color(wire.foreground), background: Self.color(wire.background),
                              style: CharacterStyle(rawValue: wire.style),
                              underlineStyle: UnderlineStyle(rawValue: wire.underlineStyle) ?? .none,
                              underlineColor: wire.underlineColor.map(Self.color))
        if attributes.count > 4096 { attributes.removeAll() }
        attributes[wire] = value
        return value
    }

    private func palette(overrides: [UInt8: WireRGB]) -> [Color] {
        if let paletteCache, paletteCache.overrides == overrides { return paletteCache.palette }
        var palette = TerminalExternalFrame.makePalette(ansiColors: theme?.ansi, foreground: theme?.foreground,
                                                        background: theme?.background)
        for (index, color) in overrides where Int(index) < palette.count {
            palette[Int(index)] = Color(red: color.red, green: color.green, blue: color.blue)
        }
        paletteCache = (overrides, palette)
        return palette
    }

    static func color(_ wire: WireColor) -> Attribute.Color {
        switch wire {
        case .default: return .defaultColor
        case .defaultInverted: return .defaultInvertedColor
        case .ansi(let code): return .ansi256(code: code)
        case .rgb(let red, let green, let blue): return .trueColor(red: red, green: green, blue: blue)
        }
    }

    static func renderMode(_ value: UInt8) -> BufferLine.RenderLineMode {
        switch value {
        case 1: return .doubleWidth
        case 2: return .doubledTop
        case 3: return .doubledDown
        default: return .single
        }
    }
}
