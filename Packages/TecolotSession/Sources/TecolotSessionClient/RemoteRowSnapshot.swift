//
// RemoteRowSnapshot.swift
// TecolotSessionClient
//
// A copy of the rows that a remote pane shows, which the app saves when it
// quits (spec-restoration.md section 6.2). At the next launch the pane shows
// these rows until it attaches, so that a host that cannot be reached does
// not give an empty pane. The app deletes the file when the pane attaches.
//
//     "TECOLOT-ROWS 1\n"
//     string sessionID, u64 savedAt (seconds since 1970, bit pattern of a
//     Double), varint columns, varint rows, svarint firstLine,
//     svarint endLine, varint count, then for each row:
//     svarint line, u64 version, blob payload (a row payload, RowCodec)
//
// A file can be changed by another program: the rows are decoded with the
// same checks as the rows that come from a helper.
//

import Foundation
import TecolotWire

public struct RemoteRowSnapshot: Sendable, Equatable {
    /// The version of the file format, in `magic`.
    public static let currentVersion = 1
    public static let magic = Array("TECOLOT-ROWS \(currentVersion)\n".utf8)
    /// The most rows that a file can hold.
    public static let maximumRows = 200_000

    public struct Row: Sendable, Equatable {
        public var line: Int64
        public var version: UInt64
        public var payload: [UInt8]

        public init(line: Int64, version: UInt64, payload: [UInt8]) {
            self.line = line
            self.version = version
            self.payload = payload
        }
    }

    public var sessionID: String
    public var savedAt: Date
    public var columns: Int
    public var rows: Int
    public var firstLine: Int64
    public var endLine: Int64
    /// The saved rows, in line order. Lines that the cache did not hold are missing.
    public var savedRows: [Row]

    public init(sessionID: String, savedAt: Date, columns: Int, rows: Int, firstLine: Int64, endLine: Int64,
                savedRows: [Row]) {
        self.sessionID = sessionID
        self.savedAt = savedAt
        self.columns = columns
        self.rows = rows
        self.firstLine = firstLine
        self.endLine = endLine
        self.savedRows = savedRows
    }

    /// The rows of a capture, before their payloads are built.
    public struct Pending: Sendable {
        public let sessionID: String
        public let columns: Int
        public let rows: Int
        public let firstLine: Int64
        public let endLine: Int64
        let cached: [(line: Int64, row: CachedRow)]

        /// Builds the payloads (off the main thread) and encodes the file.
        public func encode(savedAt: Date) -> Data {
            var encoder = RowEncoder()
            let saved = cached.map { line, row -> Row in
                var header = row.header
                // The images stay on the host; the file has no pixels.
                header.images = []
                encoder.begin(header)
                for cell in row.cells { encoder.append(cell.content, style: cell.style) }
                return Row(line: line, version: row.version, payload: encoder.finish())
            }
            return RemoteRowSnapshot(sessionID: sessionID, savedAt: savedAt, columns: columns, rows: rows,
                                     firstLine: firstLine, endLine: endLine, savedRows: saved).encode()
        }
    }

    /// Copies the screen of `session` and up to `limit` rows above it, under
    /// the session's lock. Nil when the session has no rows.
    public static func capture(_ session: RemoteSession, sessionID: String, limit: Int) -> Pending? {
        session.withState { state, cache in
            guard state.endLine > state.firstLine, cache.count > 0 else { return nil }
            let start = max(state.firstLine, state.endLine - Int64(state.rows) - Int64(max(0, limit)))
            var cached: [(line: Int64, row: CachedRow)] = []
            for line in start ..< state.endLine {
                if let row = cache[line] { cached.append((line, row)) }
            }
            guard !cached.isEmpty else { return nil }
            return Pending(sessionID: sessionID, columns: state.columns, rows: state.rows,
                           firstLine: state.firstLine, endLine: state.endLine, cached: cached)
        }
    }

    public func encode() -> Data {
        var writer = WireWriter(capacity: 4096)
        writer.raw(Self.magic)
        writer.string(sessionID)
        writer.u64(savedAt.timeIntervalSince1970.bitPattern)
        writer.varint(columns)
        writer.varint(rows)
        writer.svarint(firstLine)
        writer.svarint(endLine)
        writer.varint(savedRows.count)
        for row in savedRows {
            writer.svarint(row.line)
            writer.u64(row.version)
            writer.blob(row.payload)
        }
        return Data(writer.bytes)
    }

    /// Decodes and checks a file. Each payload must decode as a row.
    public static func decode(_ data: Data) throws -> RemoteRowSnapshot {
        let bytes = [UInt8](data)
        guard bytes.starts(with: magic) else { throw WireError.invalidValue("not a Tecolot row file") }
        var reader = WireReader(bytes, range: magic.count ..< bytes.count)
        let sessionID = try reader.string(limit: 256)
        let savedAt = Date(timeIntervalSince1970: Double(bitPattern: try reader.u64()))
        let columns = try reader.count(limit: 65_535)
        let rows = try reader.count(limit: 65_535)
        let firstLine = try reader.svarint()
        let endLine = try reader.svarint()
        guard columns > 0, rows > 0, firstLine >= 0, endLine >= firstLine else {
            throw WireError.invalidValue("row file geometry")
        }
        let count = try reader.count(limit: maximumRows)
        var saved: [Row] = []
        saved.reserveCapacity(count)
        var previous = Int64.min
        for _ in 0 ..< count {
            let line = try reader.svarint()
            guard line > previous, line >= firstLine, line < endLine else { throw WireError.invalidValue("row line") }
            previous = line
            let version = try reader.u64()
            let payload = try reader.blob(limit: 4 * 1024 * 1024)
            _ = try RowDecoder.decodeCells(payload)
            saved.append(Row(line: line, version: version, payload: payload))
        }
        return RemoteRowSnapshot(sessionID: sessionID, savedAt: savedAt, columns: columns, rows: rows,
                                 firstLine: firstLine, endLine: endLine, savedRows: saved)
    }
}

extension RemoteSession {
    /// Shows the rows of `snapshot` in a session that is not connected, for
    /// example while the app reconnects after a launch. The first frame of
    /// the helper replaces them.
    public func preload(_ snapshot: RemoteRowSnapshot) {
        queue.async { [self] in
            // Decode the rows before the lock: the renderer needs the lock to draw.
            var prepared = RowCache()
            prepared.select(buffer: .normal, epoch: 0)
            let records = snapshot.savedRows.map {
                WireRowRecord(line: UInt64($0.line), version: $0.version, payload: $0.payload)
            }
            guard (try? prepared.store(records)) != nil else { return }
            let stored = withPreloadLock { state, cache -> Bool in
                guard !state.connected, state.lastFrameSequence == 0 else { return false }
                state.buffer = .normal
                // The file holds only the last rows: the view cannot scroll above them.
                let first = snapshot.savedRows.first?.line ?? snapshot.endLine
                state.firstLine = max(snapshot.firstLine, min(first, snapshot.endLine - Int64(snapshot.rows)))
                state.endLine = snapshot.endLine
                state.columns = snapshot.columns
                state.rows = snapshot.rows
                state.cursor = nil
                state.follow = true
                cache = prepared
                return true
            }
            if stored { onChange?([.rows, .geometry]) }
        }
    }
}
