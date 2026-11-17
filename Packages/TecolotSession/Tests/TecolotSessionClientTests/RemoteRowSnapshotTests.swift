import Foundation
import Testing
import TecolotSessionClient
import TecolotWire

struct RemoteRowSnapshotTests {
    private func payload(_ text: String, columns: Int = 20, wrapped: Bool = false) -> [UInt8] {
        var encoder = RowEncoder()
        encoder.begin(WireRowHeader(columns: columns, isWrapped: wrapped))
        for byte in text.utf8 { encoder.append(.ascii(byte), style: .plain) }
        return encoder.finish()
    }

    private func screen(_ session: RemoteSession) -> [String] {
        session.withState { state, cache in
            (state.firstLine ..< state.endLine).compactMap { line in
                guard let row = cache[line] else { return nil }
                return cache.text(from: (line, 0), to: (line, row.cells.count - 1))?
                    .trimmingCharacters(in: .whitespaces)
            }
        }
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// The app saves the rows at quit and shows them at the next launch,
    /// before the pane attaches.
    @Test func rowsRoundTripThroughTheFileIntoASession() async throws {
        let saved = RemoteRowSnapshot(sessionID: "abc123", savedAt: Date(timeIntervalSince1970: 1_000), columns: 20,
                                      rows: 3, firstLine: 10, endLine: 14,
                                      savedRows: [.init(line: 11, version: 7, payload: payload("first")),
                                                  .init(line: 12, version: 8, payload: payload("second")),
                                                  .init(line: 13, version: 9, payload: payload("third"))])
        let decoded = try RemoteRowSnapshot.decode(saved.encode())
        #expect(decoded == saved)

        let session = RemoteSession(socket: -1, clientName: "test", build: "test")
        session.preload(decoded)
        try await waitFor { session.state.endLine == 14 }
        #expect(screen(session) == ["first", "second", "third"])
        #expect(!session.state.connected)

        // A quit before the pane attaches saves the same rows again.
        let pending = try #require(RemoteRowSnapshot.capture(session, sessionID: "abc123", limit: 1))
        let again = try RemoteRowSnapshot.decode(pending.encode(savedAt: saved.savedAt))
        #expect(again.savedRows.map(\.line) == [11, 12, 13])
        #expect(again.savedRows.map(\.version) == [7, 8, 9])
        // The first line is the first saved row: line 10 is not in the file.
        #expect(again.firstLine == 11 && again.endLine == 14 && again.columns == 20)
    }

    /// The file holds only the last rows of a long session. The view cannot
    /// scroll above them, and it does not ask the helper for rows.
    @Test func preloadedViewScrollsOnlyTheSavedRows() async throws {
        let rows = (45 ..< 50).map { RemoteRowSnapshot.Row(line: Int64($0), version: 1, payload: payload("row \($0)")) }
        let session = RemoteSession(socket: -1, clientName: "test", build: "test")
        session.preload(RemoteRowSnapshot(sessionID: "a1", savedAt: Date(), columns: 20, rows: 3, firstLine: 0,
                                          endLine: 50, savedRows: rows))
        try await waitFor { session.state.endLine == 50 }
        #expect(session.state.firstLine == 45)
        #expect(session.scroll(toTop: 0) == 45)
        #expect(screen(session).first == "row 45")
    }

    @Test func limitKeepsTheScreenAndTheLastRowsAbove() async throws {
        let rows = (0 ..< 10).map { RemoteRowSnapshot.Row(line: Int64($0), version: UInt64($0), payload: payload("row \($0)")) }
        let session = RemoteSession(socket: -1, clientName: "test", build: "test")
        session.preload(RemoteRowSnapshot(sessionID: "a1", savedAt: Date(), columns: 20, rows: 3, firstLine: 0,
                                          endLine: 10, savedRows: rows))
        try await waitFor { session.state.endLine == 10 }
        let pending = try #require(RemoteRowSnapshot.capture(session, sessionID: "a1", limit: 2))
        let snapshot = try RemoteRowSnapshot.decode(pending.encode(savedAt: Date()))
        #expect(snapshot.savedRows.map(\.line) == [5, 6, 7, 8, 9])
    }

    @Test func emptySessionHasNoSnapshot() {
        let session = RemoteSession(socket: -1, clientName: "test", build: "test")
        #expect(RemoteRowSnapshot.capture(session, sessionID: "a1", limit: 100) == nil)
    }

    @Test func damagedFilesAreRejected() {
        let good = RemoteRowSnapshot(sessionID: "a1", savedAt: Date(), columns: 20, rows: 2, firstLine: 0, endLine: 2,
                                     savedRows: [.init(line: 0, version: 1, payload: payload("x")),
                                                 .init(line: 1, version: 2, payload: payload("y"))])
        let data = good.encode()
        #expect(throws: (any Error).self) { try RemoteRowSnapshot.decode(Data("not a row file".utf8)) }
        #expect(throws: (any Error).self) { try RemoteRowSnapshot.decode(data.prefix(data.count - 2)) }
        // Rows out of order, or outside the lines of the file.
        var unordered = good
        unordered.savedRows.reverse()
        #expect(throws: (any Error).self) { try RemoteRowSnapshot.decode(unordered.encode()) }
        var outside = good
        outside.savedRows[1].line = 5
        #expect(throws: (any Error).self) { try RemoteRowSnapshot.decode(outside.encode()) }
        // A payload that is not a row.
        var bad = good
        bad.savedRows[0].payload = [0xff, 0xff, 0xff, 0xff, 0xff]
        #expect(throws: (any Error).self) { try RemoteRowSnapshot.decode(bad.encode()) }
    }
}
