import Foundation
import SwiftTerm
import Testing
@testable import TecolotSessionHost

struct LineTableTests {
    final class Quiet: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    /// A trim keeps the three quarters of the limit that were used last.
    @Test func trimKeepsTheRowsUsedLast() {
        let delegate = Quiet()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 5, scrollback: 500))
        terminal.feed(text: (0 ..< 300).map { "line \($0)" }.joined(separator: "\r\n"))
        let table = LineTable()
        table.maximumEntries = 100
        let links = LinkTable()
        var encoder = LineEncoder()
        var encoded: [(index: Int, version: UInt64)] = []
        terminal.terminalLock.withLock {
            for index in 0 ..< 150 {
                guard let line = terminal.bufferLine(atRow: index) else { continue }
                let entry = table.row(for: line, ringIndex: index, columns: 20, terminal: terminal,
                                      links: links, encoder: &encoder)
                encoded.append((index, entry.version))
            }
        }
        #expect(table.count == 150)
        table.trim()
        #expect(table.count == 75)
        // The rows used last stay: asking for them again does not encode them.
        terminal.terminalLock.withLock {
            for (index, _) in encoded.suffix(75) {
                guard let line = terminal.bufferLine(atRow: index) else { continue }
                _ = table.row(for: line, ringIndex: index, columns: 20, terminal: terminal,
                              links: links, encoder: &encoder)
            }
        }
        #expect(table.count == 75)
    }

    /// Clients ask for the same rows on every frame. A trim still keeps the
    /// three quarters of the limit, not only the rows of the last frames.
    @Test func trimKeepsEnoughRowsWhenTheSameRowsRepeat() {
        let delegate = Quiet()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 5, scrollback: 500))
        terminal.feed(text: (0 ..< 300).map { "line \($0)" }.joined(separator: "\r\n"))
        let table = LineTable()
        table.maximumEntries = 100
        let links = LinkTable()
        var encoder = LineEncoder()
        func use(_ rows: Range<Int>) {
            terminal.terminalLock.withLock {
                for index in rows {
                    guard let line = terminal.bufferLine(atRow: index) else { continue }
                    _ = table.row(for: line, ringIndex: index, columns: 20, terminal: terminal,
                                  links: links, encoder: &encoder)
                }
            }
        }
        use(0 ..< 150)
        // A hundred frames of the same ten rows.
        for _ in 0 ..< 100 { use(140 ..< 150) }
        table.trim()
        #expect(table.count == 75)
        // Rows 75 to 149 were used last: they are still in the table.
        use(75 ..< 150)
        #expect(table.count == 75)
    }

    @Test func selectFindsTheValueOfEachRank() {
        var generator = SystemRandomNumberGenerator()
        for count in [1, 2, 3, 10, 101, 1000] {
            let values = (0 ..< count).map { _ in UInt64.random(in: 0 ..< 50, using: &generator) }
            let sorted = values.sorted()
            for rank in Set([0, count / 2, count - 1]) {
                var copy = values
                #expect(LineTable.select(rank, in: &copy) == sorted[rank], "rank \(rank) of \(count)")
            }
        }
    }
}

/// Prints how long a trim of a full table takes (set TECOLOT_TRIM_TIMING=1).
@Test(.enabled(if: ProcessInfo.processInfo.environment["TECOLOT_TRIM_TIMING"] == "1"))
func trimTiming() {
    let delegate = LineTableTests.Quiet()
    let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 80, rows: 24, scrollback: 60_000))
    terminal.feed(text: (0 ..< 56_000).map { "line \($0) with some text" }.joined(separator: "\r\n"))
    let table = LineTable()
    let links = LinkTable()
    var encoder = LineEncoder()
    terminal.terminalLock.withLock {
        for index in 0 ..< 40_100 {
            guard let line = terminal.bufferLine(atRow: index) else { continue }
            _ = table.row(for: line, ringIndex: index, columns: 80, terminal: terminal, links: links, encoder: &encoder)
        }
    }
    let start = DispatchTime.now().uptimeNanoseconds
    table.trim()
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    print("trim of \(40_100) rows to \(table.count): \(Double(elapsed) / 1e6) ms")
}
