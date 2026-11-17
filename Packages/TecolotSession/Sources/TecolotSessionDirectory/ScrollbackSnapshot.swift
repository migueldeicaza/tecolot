//
// ScrollbackSnapshot.swift
// TecolotSessionDirectory
//
// The scrollback file of a restored pane. The app writes it for local panes,
// and the helper for persistent sessions.
//
// A file is one JSON header line and the text:
//
//     {"columns":120,"format":"tecolot-scrollback","paneID":"…",…}\n
//     text\n
//     text\n
//
// The text has one logical line per line: rows that wrap are joined, so that
// the text wraps again at the width of the new pane. Colors and styles are
// SGR sequences that this file makes from the cell attributes. It never
// copies the bytes that a program sent, and a reader rejects every sequence
// other than SGR: a replay cannot change the title, the modes, the clipboard
// or the working directory.
//

import Foundation
import TecolotWire

/// One row of a terminal buffer, as copied for a save.
public struct ScrollbackRow: Hashable, Sendable {
    /// True when this row continues the row before it.
    public var isWrapped: Bool
    public var cells: [WireCell]

    public init(isWrapped: Bool, cells: [WireCell]) {
        self.isWrapped = isWrapped
        self.cells = cells
    }
}

public struct ScrollbackHeader: Codable, Hashable, Sendable {
    public static let formatName = "tecolot-scrollback"
    public static let currentVersion = 1

    public var format = ScrollbackHeader.formatName
    public var version = ScrollbackHeader.currentVersion
    public var paneID: String
    public var savedAt: Date
    /// The column count of the pane at the save.
    public var columns: Int
    /// The count of rows in the file, before the rows were joined.
    public var rows: Int
    /// The full-screen program that showed the alternate screen at the save.
    public var alternateScreenProgram: String?

    public init(paneID: String, savedAt: Date, columns: Int, rows: Int, alternateScreenProgram: String? = nil) {
        self.paneID = paneID
        self.savedAt = savedAt
        self.columns = columns
        self.rows = rows
        self.alternateScreenProgram = alternateScreenProgram
    }
}

public enum ScrollbackFileError: Error, CustomStringConvertible, Sendable {
    case noHeader
    case badHeader(String)
    case unsupportedVersion(Int)
    case unsafeText(offset: Int)

    public var description: String {
        switch self {
        case .noHeader: return "the scrollback file has no header"
        case .badHeader(let reason): return "the scrollback header is not valid: \(reason)"
        case .unsupportedVersion(let version): return "scrollback format version \(version) is not supported"
        case .unsafeText(let offset): return "the scrollback text has a control sequence other than SGR at byte \(offset)"
        }
    }
}

public enum ScrollbackFile {
    // MARK: Rows

    /// Removes the rows that a replay must not show: the blank rows at the
    /// bottom of the screen, and the logical line from `cursorRow` down
    /// (the shell's prompt; the new shell shows its own). Keeps at most
    /// `limit` rows, the last ones.
    public static func prepare(_ rows: [ScrollbackRow], cursorRow: Int?, limit: Int) -> [ScrollbackRow] {
        guard limit > 0 else { return [] }
        var rows = rows
        if let cursorRow, cursorRow >= 0, cursorRow < rows.count {
            var start = cursorRow
            while start > 0 && rows[start].isWrapped { start -= 1 }
            // Drop the prompt only when nothing below it has text.
            if !rows[(cursorRow + 1)...].contains(where: { !isBlank($0) }) {
                rows.removeSubrange(start...)
            }
        }
        while let last = rows.last, isBlank(last) { rows.removeLast() }
        if rows.count > limit { rows.removeFirst(rows.count - limit) }
        // A continuation row without its start begins a line.
        if !rows.isEmpty { rows[0].isWrapped = false }
        return rows
    }

    static func isBlank(_ row: ScrollbackRow) -> Bool {
        row.cells.allSatisfy(isBlank)
    }

    static func isBlank(_ cell: WireCell) -> Bool {
        let attribute = cell.style.attribute
        let paints = attribute.background != .default && attribute.background != .defaultInverted
            || attribute.style & inverseBit != 0
        switch cell.content {
        case .null, .spacer: return !paints
        case .ascii(let byte): return byte == 0x20 && !paints
        case .grapheme: return false
        }
    }

    // MARK: Encoding

    /// The file: the header line and the text of `rows`.
    public static func encode(_ rows: [ScrollbackRow], header: ScrollbackHeader) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var header = header
        header.rows = rows.count
        var data = try encoder.encode(header)
        data.append(0x0A)
        data.append(contentsOf: Array(text(rows).utf8))
        return data
    }

    /// The text of `rows`: one logical line per line, with SGR sequences.
    public static func text(_ rows: [ScrollbackRow]) -> String {
        var lines: [[WireCell]] = []
        for row in rows {
            if row.isWrapped, !lines.isEmpty {
                lines[lines.count - 1].append(contentsOf: row.cells)
            } else {
                lines.append(row.cells)
            }
        }
        var output = ""
        for var cells in lines {
            while let last = cells.last, isBlank(last) { cells.removeLast() }
            var current = WireAttribute.plain
            for cell in cells {
                let attribute = cell.style.attribute
                if attribute != current {
                    output += sgr(attribute)
                    current = attribute
                }
                switch cell.content {
                case .null: output.append(" ")
                case .ascii(let byte): output.append(Character(UnicodeScalar(byte)))
                case .grapheme(let text, _): output += printable(text)
                case .spacer: break
                }
            }
            if current != .plain { output += "\u{1B}[0m" }
            output.append("\n")
        }
        return output
    }

    static let inverseBit: UInt8 = 8

    /// The SGR sequence that sets `attribute` from the default state.
    public static func sgr(_ attribute: WireAttribute) -> String {
        var parameters = ["0"]
        let style = attribute.style
        if style & 1 != 0 { parameters.append("1") }
        if style & 32 != 0 { parameters.append("2") }
        if style & 64 != 0 { parameters.append("3") }
        if attribute.underlineStyle > 1 {
            parameters.append("4:\(attribute.underlineStyle)")
        } else if style & 2 != 0 || attribute.underlineStyle == 1 {
            parameters.append("4")
        }
        if style & 4 != 0 { parameters.append("5") }
        if style & inverseBit != 0 { parameters.append("7") }
        if style & 16 != 0 { parameters.append("8") }
        if style & 128 != 0 { parameters.append("9") }
        parameters += color(attribute.foreground, base: 30, bright: 90, extended: 38)
        parameters += color(attribute.background, base: 40, bright: 100, extended: 48)
        if let underline = attribute.underlineColor {
            parameters += color(underline, base: nil, bright: nil, extended: 58)
        }
        return "\u{1B}[" + parameters.joined(separator: ";") + "m"
    }

    static func color(_ color: WireColor, base: Int?, bright: Int?, extended: Int) -> [String] {
        switch color {
        case .default, .defaultInverted:
            return []
        case .ansi(let code):
            if let base, code < 8 { return ["\(base + Int(code))"] }
            if let bright, code < 16 { return ["\(bright + Int(code) - 8)"] }
            return ["\(extended)", "5", "\(code)"]
        case .rgb(let red, let green, let blue):
            return ["\(extended)", "2", "\(red)", "\(green)", "\(blue)"]
        }
    }

    /// Replaces control characters in cell text; a cell never has them, but
    /// the reader must accept everything that the writer makes.
    static func printable(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isControl) else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.map { isControl($0) ? "\u{FFFD}" : $0 }))
    }

    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F ... 0x9F).contains(scalar.value)
    }

    // MARK: Decoding

    /// Reads a file. Throws when the header is not valid, or when the text
    /// has anything other than printable text, line ends and SGR sequences.
    public static func decode(_ data: Data) throws -> (header: ScrollbackHeader, text: String) {
        guard let end = data.firstIndex(of: 0x0A) else { throw ScrollbackFileError.noHeader }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let header: ScrollbackHeader
        do {
            header = try decoder.decode(ScrollbackHeader.self, from: data[data.startIndex ..< end])
        } catch {
            throw ScrollbackFileError.badHeader("\(error)")
        }
        guard header.format == ScrollbackHeader.formatName else { throw ScrollbackFileError.badHeader("format") }
        guard header.version == ScrollbackHeader.currentVersion else {
            throw ScrollbackFileError.unsupportedVersion(header.version)
        }
        let body = data[data.index(after: end)...]
        let text = String(decoding: body, as: UTF8.self)
        try validate(text)
        return (header, text)
    }

    /// Throws unless `text` has only printable text, line ends and SGR
    /// sequences (ESC [ digits, ';' and ':' m).
    public static func validate(_ text: String) throws {
        let scalars = Array(text.unicodeScalars)
        var index = 0
        var offset = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\u{1B}" {
                var next = index + 1
                guard next < scalars.count, scalars[next] == "[" else { throw ScrollbackFileError.unsafeText(offset: offset) }
                next += 1
                // Digits, ';' and ':'.
                while next < scalars.count, (0x30 ... 0x3B).contains(scalars[next].value) {
                    next += 1
                }
                guard next < scalars.count, scalars[next] == "m", next - index <= 128 else {
                    throw ScrollbackFileError.unsafeText(offset: offset)
                }
                offset += next - index + 1
                index = next + 1
                continue
            }
            if scalar == "\n" || !isControl(scalar) {
                index += 1
                offset += 1
                continue
            }
            throw ScrollbackFileError.unsafeText(offset: offset)
        }
    }

    /// The bytes to feed to a terminal: `text` with CR LF line ends.
    public static func terminalBytes(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "\r\n")
    }
}

/// The line that a replay adds under the restored text.
public enum RestoreSeparator {
    public enum Reason: String, Codable, Sendable {
        case appQuit
        case macRestarted
        case hostRestarted
        case sessionEnded

        public var text: String {
            switch self {
            case .appQuit: return "Tecolot quit"
            case .macRestarted: return "the Mac restarted"
            case .hostRestarted: return "the host restarted"
            case .sessionEnded: return "the session ended"
            }
        }
    }

    /// For example "── Restored · Oct 17 14:02 · the Mac restarted ──", in a dim
    /// color, with a line end.
    public static func line(savedAt: Date?, reason: Reason, directoryNotFound: Bool = false,
                            program: String? = nil) -> String {
        var parts = ["Restored"]
        if let savedAt { parts.append(dateText(savedAt)) }
        parts.append(reason.text)
        if directoryNotFound { parts.append("the directory was not found") }
        if let program, !program.isEmpty { parts.append("\(ScrollbackFile.printable(program)) was running") }
        return "\u{1B}[0;2m── " + parts.joined(separator: " · ") + " ──\u{1B}[0m\n"
    }

    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("MMMdHHmm")
        return formatter.string(from: date)
    }
}
