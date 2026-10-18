//
// ScrollbackCapture.swift
// TecolotSessionHost
//
// Converts a SwiftTerm content snapshot to the rows of a scrollback file.
// The helper uses it for persistent sessions and the app for local panes,
// so that both write the same format. The file format is in
// TecolotSessionDirectory/ScrollbackSnapshot.swift.
//

import Foundation
import SwiftTerm
import TecolotSessionDirectory
import TecolotWire

public enum ScrollbackCapture {
    /// The rows to save: at most `limit`, without the shell's prompt row.
    public static func rows(_ snapshot: TerminalContentSnapshot, limit: Int) -> [ScrollbackRow] {
        ScrollbackFile.prepare(scrollbackRows(snapshot), cursorRow: cursorIndex(snapshot), limit: limit)
    }

    /// The scrollback file of `rows`, which `rows(_:limit:)` made from `snapshot`.
    public static func encode(_ rows: [ScrollbackRow], of snapshot: TerminalContentSnapshot, paneID: String,
                              savedAt: Date, alternateScreenProgram: String?) -> Data? {
        let header = ScrollbackHeader(paneID: paneID, savedAt: savedAt, columns: snapshot.inputState.dimensions.cols,
                                      rows: rows.count, alternateScreenProgram: alternateScreenProgram)
        return try? ScrollbackFile.encode(rows, header: header)
    }

    /// The name of the foreground process of a PTY.
    public static func foregroundProgram(ptyDescriptor: Int32) -> String? {
        ProcessInspector.foreground(ptyDescriptor: ptyDescriptor)?.name
    }

    /// The index of the cursor row in `snapshot.rows`, while the normal
    /// buffer is active: the row of the shell's prompt.
    static func cursorIndex(_ snapshot: TerminalContentSnapshot) -> Int? {
        guard !snapshot.inputState.isAlternateBuffer else { return nil }
        let index = snapshot.cursorRow - snapshot.capturedRange.lowerBound
        return snapshot.rows.indices.contains(index) ? index : nil
    }

    static func scrollbackRows(_ snapshot: TerminalContentSnapshot) -> [ScrollbackRow] {
        snapshot.rows.map { row in
            ScrollbackRow(isWrapped: row.isWrapped, cells: row.cells.map { cell in
                let style = WireCellStyle(attribute: WireMapping.attribute(cell.attribute))
                if cell.width == 0 { return WireCell(.spacer, style: style) }
                if cell.text.isEmpty || cell.text == "\u{0}" { return WireCell(.null, style: style) }
                if cell.width == 1, cell.text.utf8.count == 1, let byte = cell.text.utf8.first, (0x20 ... 0x7E).contains(byte) {
                    return WireCell(.ascii(byte), style: style)
                }
                return WireCell(.grapheme(cell.text, width: UInt8(clamping: cell.width)), style: style)
            })
        }
    }
}
