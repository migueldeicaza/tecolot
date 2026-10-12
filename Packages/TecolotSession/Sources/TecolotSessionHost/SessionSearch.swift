//
// SessionSearch.swift
// TecolotSessionHost
//
// Find in the helper, over the whole scrollback. The index holds logical
// lines (wrapped rows joined) with a map from each UTF-16 unit back to its
// row and column, so that a match can become a selection in absolute line
// numbers. The helper reuses the index while the output does not change.
//

import Foundation
import SwiftTerm
import TecolotWire

struct SearchIndex {
    struct CellReference {
        /// The row inside the logical line (0 is the first row).
        var rowOffset: UInt16
        var column: UInt16
    }

    struct Line {
        var firstLine: Int64
        var text: String
        var cells: [CellReference]
    }

    private(set) var lines: [Line] = []
    private var open: Line?
    var feed: UInt64 = .max
    var epoch: UInt64 = .max
    var buffer: WireBuffer = .normal
    var columns = 0

    mutating func reset(feed: UInt64, epoch: UInt64, buffer: WireBuffer, columns: Int) {
        lines.removeAll(keepingCapacity: true)
        open = nil
        self.feed = feed
        self.epoch = epoch
        self.buffer = buffer
        self.columns = columns
    }

    /// Adds the rows of `ringIndices`, in order. Hold the terminal lock.
    mutating func append(terminal: Terminal, ringIndices: Range<Int>, lineNumber: (Int) -> Int64) {
        for ring in ringIndices {
            guard let row = terminal.bufferLine(atRow: ring) else { continue }
            let number = lineNumber(ring)
            if !row.isWrapped || open == nil || (open.map { number - $0.firstLine >= Int64(UInt16.max) } ?? true) {
                finishLine()
                open = Line(firstLine: number, text: "", cells: [])
            }
            guard var line = open else { continue }
            let rowOffset = UInt16(clamping: number - line.firstLine)
            let used = min(row.getTrimmedLength(), row.count, columns)
            var column = 0
            while column < used {
                let cell = row[column]
                if cell.width == 0 {
                    column += 1
                    continue
                }
                var text = cell.getText()
                if text == "\u{0}" { text = " " }
                let reference = CellReference(rowOffset: rowOffset, column: UInt16(clamping: column))
                for _ in text.utf16 { line.cells.append(reference) }
                line.text += text
                column += 1
            }
            open = line
        }
    }

    mutating func finish() {
        finishLine()
    }

    private mutating func finishLine() {
        if let open { lines.append(open) }
        open = nil
    }

    /// Finds the next match after (or before) the start position, wrapping
    /// around once.
    func search(_ request: SearchMessage) -> SearchResultMessage {
        guard !request.query.isEmpty else { return SearchResultMessage(found: false) }
        var pattern = request.options.contains(.regularExpression)
            ? request.query : NSRegularExpression.escapedPattern(for: request.query)
        if request.options.contains(.wholeWord) { pattern = "\\b(?:\(pattern))\\b" }
        let expression: NSRegularExpression
        do {
            expression = try NSRegularExpression(
                pattern: pattern,
                options: request.options.contains(.caseSensitive) ? [] : [.caseInsensitive])
        } catch {
            return SearchResultMessage(found: false, problem: "Invalid regular expression")
        }
        guard !lines.isEmpty else { return SearchResultMessage(found: false) }

        let start = (line: Int64(clamping: request.startLine), column: request.startColumn)
        let backward = request.options.contains(.backward)
        // The logical line that holds the start position.
        var startIndex = lines.count - 1
        var low = 0
        var high = lines.count - 1
        while low <= high {
            let middle = (low + high) / 2
            if lines[middle].firstLine <= start.line {
                startIndex = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        if lines[0].firstLine > start.line { startIndex = 0 }

        func position(_ line: Line, _ offset: Int) -> (line: Int64, column: Int) {
            let reference = line.cells[min(max(0, offset), line.cells.count - 1)]
            return (line.firstLine + Int64(reference.rowOffset), Int(reference.column))
        }
        func isBefore(_ a: (line: Int64, column: Int), _ b: (line: Int64, column: Int)) -> Bool {
            a.line < b.line || (a.line == b.line && a.column < b.column)
        }
        func matches(in line: Line) -> [NSRange] {
            let text = line.text as NSString
            return expression.matches(in: line.text, range: NSRange(location: 0, length: text.length))
                .map(\.range).filter { $0.length > 0 }
        }
        func result(_ line: Line, _ range: NSRange) -> SearchResultMessage {
            let first = position(line, range.location)
            let last = position(line, range.location + range.length - 1)
            return SearchResultMessage(found: true, line: UInt64(max(0, first.line)), column: first.column,
                                       endLine: UInt64(max(0, last.line)), endColumn: last.column)
        }

        let count = lines.count
        for step in 0 ... count {
            let index = backward
                ? ((startIndex - step) % count + count) % count
                : (startIndex + step) % count
            let line = lines[index]
            let found = matches(in: line)
            let ordered = backward ? Array(found.reversed()) : found
            for range in ordered {
                let first = position(line, range.location)
                if step == 0 {
                    // On the first pass the match must be past the start.
                    if backward ? !isBefore(first, start) : !isBefore(start, first) { continue }
                } else if step == count {
                    // After wrapping around, only matches up to the start remain
                    // (a single match at the start is found again).
                    if backward ? isBefore(first, start) : isBefore(start, first) { continue }
                }
                return result(line, range)
            }
        }
        return SearchResultMessage(found: false)
    }
}
