import Foundation
import Testing
@testable import Tecolot

/// Temporary folders that a test suite removes when it ends.
final class CrashReportTestFixture {
    let root: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrashReportTests-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func directory(_ name: String = "CrashReports") -> URL {
        root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// Preferences in memory. A UserDefaults suite would leave a .plist in
    /// ~/Library/Preferences.
    func defaults() -> MemoryCrashReportPreferences {
        MemoryCrashReportPreferences()
    }
}

final class MemoryCrashReportPreferences: CrashReportPreferences {
    private var values: [String: Any] = [:]

    func object(forKey defaultName: String) -> Any? {
        values[defaultName]
    }

    func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
    }
}

final class CrashReportStoreTests {
    private let fixture = CrashReportTestFixture()

    private func makeDirectory() throws -> URL {
        fixture.directory()
    }

    private static func eventID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// A Sentry envelope with an event item and a minidump attachment.
    private static func envelope(
        eventID: String,
        timestamp: String = "2026-11-15T22:47:20.773331Z",
        includeEvent: Bool = true,
        attachmentSize: Int = 64
    ) -> Data {
        let dashed = [8, 4, 4, 4, 12].reduce(into: (parts: [String](), rest: Substring(eventID))) { state, count in
            state.parts.append(String(state.rest.prefix(count)))
            state.rest = state.rest.dropFirst(count)
        }.parts.joined(separator: "-")
        let event = """
        {"event_id":"\(dashed)","timestamp":"\(timestamp)","level":"fatal","release":"com.tirania.Tecolot@1.2+34","tags":{"app_version":"1.2","build_number":"34"}}
        """
        var data = Data("{\"event_id\":\"\(dashed)\"}\n".utf8)
        if includeEvent {
            data.append(Data("{\"type\":\"event\",\"length\":\(event.utf8.count)}\n".utf8))
            data.append(Data(event.utf8))
            data.append(0x0A)
        }
        data.append(Data("{\"type\":\"attachment\",\"length\":\(attachmentSize),\"attachment_type\":\"event.minidump\"}\n".utf8))
        data.append(Data(repeating: 0x4D, count: attachmentSize))
        return data
    }

    @Test func saveWritesPrivateFileAndSkipsDuplicates() throws {
        let directory = try makeDirectory()
        let store = CrashReportStore(directory: directory)
        let id = Self.eventID()
        let data = Self.envelope(eventID: id)

        #expect(try store.save(envelope: data, eventID: id))
        #expect(try store.save(envelope: data, eventID: id) == false)

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files == ["\(id).tecolotcrash"])
        let fileMode = try FileManager.default.attributesOfItem(atPath: store.reportURL(for: id).path)[.posixPermissions] as? Int
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        #expect(fileMode == 0o600)
        #expect(directoryMode == 0o700)
        #expect(try Data(contentsOf: store.reportURL(for: id)) == data)
    }

    @Test func saveRejectsEnvelopeWithoutEvent() throws {
        let store = CrashReportStore(directory: try makeDirectory())
        let id = Self.eventID()
        #expect(throws: CrashReportStoreError.self) {
            try store.save(envelope: Self.envelope(eventID: id, includeEvent: false), eventID: id)
        }
    }

    @Test func listReadsFieldsAndReportsDamagedFiles() throws {
        let directory = try makeDirectory()
        let store = CrashReportStore(directory: directory)
        let id = Self.eventID()
        try store.save(envelope: Self.envelope(eventID: id), eventID: id)

        // A cut-off file must not appear as a valid report.
        let truncatedID = Self.eventID()
        let full = Self.envelope(eventID: truncatedID, attachmentSize: 400)
        try full.prefix(full.count - 100).write(to: store.reportURL(for: truncatedID))

        // A file name that does not match its event ID is damaged.
        let otherID = Self.eventID()
        try Self.envelope(eventID: otherID).write(to: store.reportURL(for: Self.eventID()))

        // Partial writes and other files are ignored.
        try Data("x".utf8).write(to: directory.appendingPathComponent(".partial-\(otherID)-1"))
        try Data("x".utf8).write(to: directory.appendingPathComponent("notes.txt"))

        let listing = try store.list()
        #expect(listing.reports.map(\.id) == [id])
        #expect(listing.damaged.count == 2)
        let report = try #require(listing.reports.first)
        #expect(report.appVersion == "1.2")
        #expect(report.buildNumber == "34")
        #expect(report.displayVersion == "1.2 (34)")
        let expectedDate = ISO8601DateFormatter().date(from: "2026-11-15T22:47:20Z")!
        #expect(abs(report.createdAt.timeIntervalSince(expectedDate) - 0.773331) < 0.01)
    }

    @Test func missingDirectoryIsEmptyAndFileInPlaceOfDirectoryIsAnError() throws {
        let directory = try makeDirectory()
        #expect(try CrashReportStore(directory: directory).list() == CrashReportListing())

        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: directory)
        #expect(throws: (any Error).self) {
            try CrashReportStore(directory: directory).list()
        }
    }

    @Test func exportCopiesOriginalBytes() throws {
        let directory = try makeDirectory()
        let store = CrashReportStore(directory: directory)
        let id = Self.eventID()
        let data = Self.envelope(eventID: id, attachmentSize: 4096)
        try store.save(envelope: data, eventID: id)
        let report = try #require(try store.list().reports.first)

        let destination = directory.deletingLastPathComponent().appendingPathComponent("export.tecolotcrash")
        try store.export(report, to: destination)
        #expect(try Data(contentsOf: destination) == data)
    }

    @Test func deleteRemovesOnlyFilesInStore() throws {
        let directory = try makeDirectory()
        let store = CrashReportStore(directory: directory)
        let id = Self.eventID()
        try store.save(envelope: Self.envelope(eventID: id), eventID: id)

        let outside = directory.deletingLastPathComponent().appendingPathComponent("outside.tecolotcrash")
        try Data("x".utf8).write(to: outside)
        #expect(throws: CrashReportStoreError.self) {
            try store.delete(outside)
        }
        try store.delete(store.reportURL(for: id))
        #expect(try store.list().reports.isEmpty)
    }

    /// Saves a report and sets the file creation date, which is the time
    /// that the retention rule uses.
    private func saveReport(
        in store: CrashReportStore,
        crashTime: Date,
        savedAt: Date,
        attachmentSize: Int = 64
    ) throws -> String {
        let id = Self.eventID()
        let timestamp = ISO8601DateFormatter().string(from: crashTime)
        try store.save(envelope: Self.envelope(eventID: id, timestamp: timestamp, attachmentSize: attachmentSize), eventID: id)
        try FileManager.default.setAttributes([.creationDate: savedAt], ofItemAtPath: store.reportURL(for: id).path)
        return id
    }

    @Test func retentionKeepsNewestByCountAndSaveTime() throws {
        let store = CrashReportStore(directory: try makeDirectory())
        let now = ISO8601DateFormatter().date(from: "2026-11-15T12:00:00Z")!

        var idsByAgeInDays: [Int: String] = [:]
        for days in [0, 1, 2, 3, 40] {
            let date = now.addingTimeInterval(-Double(days) * 86_400)
            idsByAgeInDays[days] = try saveReport(in: store, crashTime: date, savedAt: date)
        }

        var policy = CrashReportRetentionPolicy.standard
        policy.maximumCount = 3
        try store.applyRetention(policy, now: now)
        // Count limit keeps days 0...2. The 40 day report is too old anyway.
        #expect(Set(try store.list().reports.map(\.id)) == Set([0, 1, 2].compactMap { idsByAgeInDays[$0] }))
    }

    @Test func retentionUsesSaveTimeNotCrashTime() throws {
        let store = CrashReportStore(directory: try makeDirectory())
        let now = ISO8601DateFormatter().date(from: "2026-11-15T12:00:00Z")!

        // A crash from 45 days ago, saved now, stays until the user can see it.
        let oldCrash = try saveReport(in: store, crashTime: now.addingTimeInterval(-45 * 86_400), savedAt: now)
        let oldSave = try saveReport(in: store, crashTime: now, savedAt: now.addingTimeInterval(-31 * 86_400))

        try store.applyRetention(.standard, now: now)
        let ids = try store.list().reports.map(\.id)
        #expect(ids == [oldCrash])
        #expect(!ids.contains(oldSave))
    }

    @Test func retentionKeepsNewestReportEvenWhenTooLarge() throws {
        let store = CrashReportStore(directory: try makeDirectory())
        let now = ISO8601DateFormatter().date(from: "2026-11-15T12:00:00Z")!

        let newest = try saveReport(in: store, crashTime: now, savedAt: now, attachmentSize: 2_000)
        _ = try saveReport(in: store, crashTime: now, savedAt: now.addingTimeInterval(-60), attachmentSize: 10)

        var policy = CrashReportRetentionPolicy.standard
        policy.maximumTotalSize = 1_000
        try store.applyRetention(policy, now: now)
        #expect(try store.list().reports.map(\.id) == [newest])
    }

    @Test func singleReportLimitIsLargerThanTotalLimit() {
        // Otherwise a report larger than the total limit could not be saved,
        // and the rule "keep the newest report" could not apply.
        #expect(CrashReportStore.maximumReportSize > CrashReportRetentionPolicy.standard.maximumTotalSize)
    }

    @Test func exportReplacesAnExistingFile() throws {
        let directory = try makeDirectory()
        let store = CrashReportStore(directory: directory)
        let id = Self.eventID()
        let data = Self.envelope(eventID: id, attachmentSize: 128)
        try store.save(envelope: data, eventID: id)
        let report = try #require(try store.list().reports.first)

        let destination = directory.deletingLastPathComponent().appendingPathComponent("export.tecolotcrash")
        try Data("old".utf8).write(to: destination)
        try store.export(report, to: destination)
        #expect(try Data(contentsOf: destination) == data)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(".") }
        #expect(leftovers.isEmpty)
    }

    @Test func seenStateTracksListedReports() throws {
        let directory = try makeDirectory()
        let store = CrashReportStore(directory: directory)
        let defaults = fixture.defaults()
        let seen = CrashReportSeenState(defaults: defaults)

        let first = Self.eventID()
        try store.save(envelope: Self.envelope(eventID: first), eventID: first)
        #expect(seen.unseen(in: try store.list()).map(\.id) == [first])

        seen.markSeen(try store.list())
        #expect(seen.unseen(in: try store.list()).isEmpty)

        let second = Self.eventID()
        try store.save(envelope: Self.envelope(eventID: second), eventID: second)
        #expect(seen.unseen(in: try store.list()).map(\.id) == [second])
    }

    @Test func metadataHasOnlyTheSpecifiedFields() throws {
        let defaults = fixture.defaults()
        defaults.set(false, forKey: "useMetalRenderer")
        let metadata = CrashReportMetadata.current(defaults: defaults)
        #expect(Set(metadata.tags.keys) == [
            CrashReportTag.appVersion,
            CrashReportTag.buildNumber,
            CrashReportTag.bundleIdentifier,
            CrashReportTag.architecture,
            CrashReportTag.macOSVersion,
            CrashReportTag.renderer
        ])
        #expect(metadata.tags[CrashReportTag.renderer] == "coregraphics")
        #expect(metadata.release.contains("@"))
    }

    @Test func locationsUseBundleIdentifierAndApplicationSupport() {
        let locations = CrashReportLocations(bundleIdentifier: "com.example.Test")
        #expect(locations.reportsDirectory.path.hasSuffix("Library/Application Support/com.example.Test/CrashReports"))
        // The pending crash envelope must not be in Caches.
        #expect(locations.databaseDirectory.path.hasSuffix("Library/Application Support/com.example.Test/CrashReporter"))
    }
}
