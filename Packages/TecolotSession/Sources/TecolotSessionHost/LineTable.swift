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

    /// Removes the least recently used entries when the table is too large.
    func trim() {
        guard entries.count > maximumEntries else { return }
        let keep = maximumEntries * 3 / 4
        let sorted = entries.sorted { $0.value.lastUse > $1.value.lastUse }
        entries = Dictionary(uniqueKeysWithValues: sorted.prefix(keep).map { ($0.key, $0.value) })
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
