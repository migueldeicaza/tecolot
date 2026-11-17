//
// LineTable.swift
// TecolotSessionHost
//
// Caches encoded rows by line object. The table keeps a strong reference to
// each line, so that an object address cannot be reused while it is a key,
// and re-encodes a line only when its `generation` or the column count
// changes. Line objects that SwiftTerm recycles bump their generation.
//

import SwiftTerm
import TecolotWire

final class LineTable {
    struct Entry {
        let line: BufferLine
        var generation: UInt64
        var columns: Int
        var marksSignature: Int
        var payload: [UInt8]
        var version: UInt64
        var links: [UInt32]
        var lastUse: UInt64
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var clock: UInt64 = 0
    var maximumEntries = 40_000

    var count: Int { entries.count }

    /// Returns the encoded row for `line`. Hold the terminal lock.
    func row(for line: BufferLine, ringIndex: Int, columns: Int, terminal: Terminal,
             links: LinkTable, encoder: inout LineEncoder) -> Entry {
        clock &+= 1
        let key = ObjectIdentifier(line)
        let marksSignature = Self.marksSignature(terminal.semanticPromptMarks(at: ringIndex))
        if var entry = entries[key], entry.line === line, entry.generation == line.generation,
           entry.columns == columns, entry.marksSignature == marksSignature {
            entry.lastUse = clock
            entries[key] = entry
            return entry
        }
        var used = Set<UInt32>()
        let payload = encoder.encode(line, ringIndex: ringIndex, columns: columns,
                                     terminal: terminal, links: links, usedLinks: &used)
        let entry = Entry(line: line, generation: line.generation, columns: columns,
                          marksSignature: marksSignature, payload: payload,
                          version: WireHash.hash64(payload), links: Array(used), lastUse: clock)
        entries[key] = entry
        return entry
    }

    /// Removes the least recently used entries when the table is too large,
    /// and keeps the three quarters of the limit that were used last.
    ///
    /// Each lookup advances `clock` and stamps one entry, so no two entries
    /// have the same stamp. A selection finds the oldest stamp to keep
    /// without a sort, and the old entries go in place. (Sorting and copying
    /// all the entries took about 10 ms at 40,000 rows, and delayed frames.)
    func trim() {
        guard entries.count > maximumEntries else { return }
        let keep = maximumEntries * 3 / 4
        guard keep > 0 else {
            entries.removeAll()
            return
        }
        var stamps = entries.values.map(\.lastUse)
        let oldestKept = Self.select(stamps.count - keep, in: &stamps)
        let stale = entries.compactMap { $0.value.lastUse < oldestKept ? $0.key : nil }
        for key in stale {
            entries.removeValue(forKey: key)
        }
    }

    /// The `rank`-th smallest value (from 0) of `values`, in linear time on
    /// average (quickselect). Changes the order of `values`.
    static func select(_ rank: Int, in values: inout [UInt64]) -> UInt64 {
        var low = 0
        var high = values.count - 1
        while low < high {
            // The median of three values is the pivot.
            let a = values[low], b = values[low + (high - low) / 2], c = values[high]
            let pivot = max(min(a, b), min(max(a, b), c))
            var i = low
            var j = high
            while i <= j {
                while values[i] < pivot { i += 1 }
                while values[j] > pivot { j -= 1 }
                if i <= j {
                    values.swapAt(i, j)
                    i += 1
                    j -= 1
                }
            }
            if rank <= j {
                high = j
            } else if rank >= i {
                low = i
            } else {
                return values[rank]
            }
        }
        return values[rank]
    }

    func removeAll() {
        entries.removeAll()
    }

    private static func marksSignature(_ marks: [SemanticPromptAnchor]) -> Int {
        guard !marks.isEmpty else { return 0 }
        var hasher = Hasher()
        for mark in marks {
            hasher.combine(mark.position.col)
            hasher.combine(WireMapping.promptKind(mark.kind))
        }
        return hasher.finalize() | 1
    }
}
