//
// LineNumbering.swift
// TecolotSessionHost
//
// SwiftTerm has no stable line numbering: `totalLinesTrimmed` resets on
// ED 3, Buffer.clear and RIS, and resize, clearScrollback and reflow trim or
// rewrite lines without notice. The helper gives every line an absolute
// number instead:
//
//     line = base + totalLinesTrimmed + ringIndex
//
// When the helper detects a discontinuity, `base` jumps forward so that the
// new first line comes after the old last line. A number is never reused, so
// a client cache can never confuse old and new content.
//
// Detection (all O(1), under the terminal lock):
// - the Buffer object changed (RIS, alternate screen activation);
// - totalLinesTrimmed or the end of the range went down;
// - a sentinel line deep in scrollback moved or changed;
// - the helper itself requested the change (column resize, clear, reset).
//
// Visible rows are always revalidated by content hash, so a missed
// detection costs bandwidth, never correctness.
//

import SwiftTerm

struct BufferNumbering {
    struct Sentinel {
        let line: BufferLine
        let generation: UInt64
        let number: Int64
    }

    private(set) var base: Int64 = 0
    private(set) var epoch: UInt64 = 0
    private var identity: ObjectIdentifier?
    private var lastTrimmed = 0
    private var lastEnd: Int64 = 0
    private var sentinels: [Sentinel] = []

    /// Absolute line number of a ring index.
    func line(ringIndex: Int, trimmed: Int) -> Int64 {
        base + Int64(trimmed) + Int64(ringIndex)
    }

    /// Ring index of an absolute line number (may be out of range).
    func ringIndex(line: Int64, trimmed: Int) -> Int64 {
        line - base - Int64(trimmed)
    }

    /// Updates the numbering for the current buffer state. Returns true when
    /// the epoch changed. Call with the terminal lock held.
    @discardableResult
    mutating func update(terminal: Terminal, buffer: Buffer, lineCount: Int, scrollbackRows: Int,
                         force: Bool) -> Bool {
        let trimmed = buffer.totalLinesTrimmed
        let bufferIdentity = ObjectIdentifier(buffer)
        var broken = force
        if let identity, identity != bufferIdentity { broken = true }
        if trimmed < lastTrimmed { broken = true }
        let end = base + Int64(trimmed) + Int64(lineCount)
        if identity != nil && end < lastEnd { broken = true }
        if !broken {
            for sentinel in sentinels {
                let ring = sentinel.number - base - Int64(trimmed)
                if ring < 0 { continue }
                guard ring < Int64(lineCount),
                      let line = terminal.bufferLine(atRow: Int(ring)),
                      line === sentinel.line,
                      line.generation == sentinel.generation else {
                    broken = true
                    break
                }
            }
        }

        var changed = false
        if broken && identity != nil {
            // The new first line follows the old last line.
            base = lastEnd - Int64(trimmed)
            epoch &+= 1
            sentinels.removeAll()
            changed = true
        }
        identity = bufferIdentity
        lastTrimmed = trimmed
        lastEnd = base + Int64(trimmed) + Int64(lineCount)

        // Drop sentinels that trimming removed; keep up to three in scrollback.
        sentinels.removeAll { $0.number - base - Int64(trimmed) < 0 }
        if scrollbackRows > 0 && sentinels.count < 3 {
            for ring in [0, scrollbackRows / 2, scrollbackRows - 1] {
                let lineNumber = base + Int64(trimmed) + Int64(ring)
                guard !sentinels.contains(where: { $0.number == lineNumber }),
                      let line = terminal.bufferLine(atRow: ring) else { continue }
                sentinels.append(Sentinel(line: line, generation: line.generation, number: lineNumber))
                if sentinels.count >= 3 { break }
            }
        }
        return changed
    }
}
