//
// RowCache.swift
// TecolotSessionClient
//
// The rows that a client holds for one buffer. Line numbers come from the
// helper and are never reused, so a cached row is either current or older
// than the helper's first line; it is never wrong for its number.
//

import Synchronization
import TecolotWire

public struct CachedRow: Sendable {
    public let version: UInt64
    public let header: WireRowHeader
    public let cells: [WireCell]
    /// A counter that increases on every store, for consumers that convert
    /// rows. It is unique in the process: a cache that replaces another
    /// cache (a preload, then the first frame) never repeats a stamp.
    public let stamp: UInt64
}

public struct RowCache: Sendable {
    public private(set) var rows: [Int64: CachedRow] = [:]
    public private(set) var buffer: WireBuffer = .normal
    public private(set) var epoch: UInt64 = 0
    /// The most rows kept outside the pinned window.
    public var capacity = 20_000
    private static let stamps = Atomic<UInt64>(0)

    public init() {}

    public var count: Int { rows.count }

    public subscript(line: Int64) -> CachedRow? { rows[line] }

    /// Switches to another buffer. Rows of the other buffer are dropped; the
    /// alternate screen has no scrollback worth keeping, and the normal
    /// buffer's rows come back from the helper by version.
    public mutating func select(buffer: WireBuffer, epoch: UInt64) {
        if buffer != self.buffer {
            rows.removeAll(keepingCapacity: true)
        }
        self.buffer = buffer
        self.epoch = epoch
    }

    /// Decodes and stores rows. Returns the lines that changed.
    @discardableResult
    public mutating func store(_ records: [WireRowRecord]) throws -> [Int64] {
        var changed: [Int64] = []
        changed.reserveCapacity(records.count)
        for record in records {
            let line = Int64(clamping: record.line)
            if rows[line]?.version == record.version { continue }
            let (header, cells) = try RowDecoder.decodeCells(record.payload)
            let stamp = Self.stamps.wrappingAdd(1, ordering: .relaxed).newValue
            rows[line] = CachedRow(version: record.version, header: header, cells: cells, stamp: stamp)
            changed.append(line)
        }
        return changed
    }

    /// Drops lines below `first` (trimmed or renumbered by the helper).
    public mutating func dropLines(before first: Int64) {
        guard rows.keys.contains(where: { $0 < first }) else { return }
        rows = rows.filter { $0.key >= first }
    }

    /// Keeps at most `capacity` rows; rows inside `pinned` are always kept.
    public mutating func evict(keeping pinned: Range<Int64>) {
        guard rows.count > capacity + (pinned.upperBound > pinned.lowerBound ? Int(pinned.count) : 0) else { return }
        let center = (pinned.lowerBound + pinned.upperBound) / 2
        let ordered = rows.keys.filter { !pinned.contains($0) }
            .sorted { abs($0 - center) < abs($1 - center) }
        for line in ordered.dropFirst(capacity) {
            rows[line] = nil
        }
    }

    /// The versions held for `lines`, to send with viewport and fetch requests.
    public func knownVersions(in lines: Range<Int64>) -> [WireKnownVersion] {
        var result: [WireKnownVersion] = []
        for line in lines {
            if let row = rows[line], line >= 0 {
                result.append(WireKnownVersion(line: UInt64(line), version: row.version))
            }
        }
        return result
    }

    /// The lines in `range` that are not cached.
    public func missing(in range: Range<Int64>) -> [Range<Int64>] {
        var result: [Range<Int64>] = []
        var start: Int64?
        for line in range {
            if rows[line] == nil {
                if start == nil { start = line }
            } else if let open = start {
                result.append(open ..< line)
                start = nil
            }
        }
        if let open = start { result.append(open ..< range.upperBound) }
        return result
    }

    /// The text of cached rows, joining wrapped rows without a newline.
    /// Returns nil when a row in the range is not cached.
    public func text(from start: (line: Int64, column: Int), to end: (line: Int64, column: Int)) -> String? {
        guard start.line <= end.line else { return "" }
        var result = ""
        for line in start.line ... end.line {
            guard let row = rows[line] else { return nil }
            let from = line == start.line ? start.column : 0
            let to = line == end.line ? end.column : row.cells.count - 1
            var piece = ""
            if from <= to {
                for index in max(0, from) ... min(to, row.cells.count - 1) {
                    switch row.cells[index].content {
                    case .null: piece.append(" ")
                    case .ascii(let byte): piece.append(Character(UnicodeScalar(byte)))
                    case .grapheme(let text, _): piece.append(text)
                    case .spacer: break
                    }
                }
            }
            if line != end.line {
                // Trailing blanks are not part of a hard line end.
                let next = rows[line + 1]
                if next?.header.isWrapped == true {
                    result += piece
                } else {
                    while piece.last == " " { piece.removeLast() }
                    result += piece + "\n"
                }
            } else {
                result += piece
            }
        }
        return result
    }
}
