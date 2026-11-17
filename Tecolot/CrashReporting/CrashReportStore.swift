//
//  CrashReportStore.swift
//  Tecolot
//
//  Completed crash reports on this Mac. Each report is an intact Sentry
//  envelope in `<event id>.tecolotcrash`. The store never sends data.
//
import Darwin
import Foundation
import os
import SentryNativeBreakpad

/// Directories for one bundle identifier.
nonisolated struct CrashReportLocations: Sendable, Equatable {
    /// Completed reports: `~/Library/Application Support/<id>/CrashReports`.
    let reportsDirectory: URL
    /// SDK working database: `~/Library/Application Support/<id>/CrashReporter`.
    /// It holds the pending crash envelope until the next launch, so it must
    /// not be in Caches, where the system can remove it.
    let databaseDirectory: URL

    init(reportsDirectory: URL, databaseDirectory: URL) {
        self.reportsDirectory = reportsDirectory
        self.databaseDirectory = databaseDirectory
    }

    init(bundleIdentifier: String, fileManager: FileManager = .default) {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
        reportsDirectory = applicationSupport.appendingPathComponent("CrashReports", isDirectory: true)
        databaseDirectory = applicationSupport.appendingPathComponent("CrashReporter", isDirectory: true)
    }
}

nonisolated struct CrashReport: Identifiable, Hashable, Sendable {
    /// The event ID, 32 lowercase hexadecimal characters.
    let id: String
    let url: URL
    /// The crash time from the event, or the file creation date. The list
    /// shows this date.
    let createdAt: Date
    /// When Tecolot saved the report. The retention rule uses this date, so
    /// a report is not removed before the user can see it.
    let savedAt: Date
    let appVersion: String?
    let buildNumber: String?
    let size: Int64

    var displayVersion: String {
        switch (appVersion, buildNumber) {
        case let (version?, build?): return "\(version) (\(build))"
        case let (version?, nil): return version
        default: return "Unknown"
        }
    }
}

/// A file in the report directory that is not a valid report.
nonisolated struct DamagedCrashReport: Identifiable, Hashable, Sendable {
    var id: URL { url }
    let url: URL
    let reason: String
}

nonisolated struct CrashReportListing: Sendable, Equatable {
    /// Valid reports, newest first.
    var reports: [CrashReport] = []
    var damaged: [DamagedCrashReport] = []

    var totalSize: Int64 {
        reports.reduce(0) { $0 + $1.size }
    }
}

nonisolated struct CrashReportRetentionPolicy: Sendable, Equatable {
    var maximumCount = 20
    var maximumTotalSize: Int64 = 100 * 1024 * 1024
    var maximumAge: TimeInterval = 30 * 24 * 60 * 60

    static let standard = CrashReportRetentionPolicy()
}

nonisolated enum CrashReportStoreError: LocalizedError, Equatable {
    case notACrashEvent
    case eventIDMismatch
    case tooLarge(Int64)
    case unsafeFile

    var errorDescription: String? {
        switch self {
        case .notACrashEvent: return "The file is not a crash event envelope."
        case .eventIDMismatch: return "The file name does not match the event ID."
        case .tooLarge(let size): return "The file is too large (\(size) bytes)."
        case .unsafeFile: return "The item is not a regular file."
        }
    }
}

/// Reads and writes completed crash reports. The type has no mutable state.
/// It is safe to use from any thread.
nonisolated struct CrashReportStore: Sendable {
    static let fileExtension = "tecolotcrash"
    /// Tecolot does not save or read a single envelope larger than this. It
    /// is larger than the total limit, so the retention rule can keep a
    /// newest report that alone exceeds the total limit.
    static let maximumReportSize: Int64 = 512 * 1024 * 1024
    /// The event item is JSON. A larger event item is not parsed.
    static let maximumEventSize = 8 * 1024 * 1024
    private static let temporaryPrefix = ".partial-"
    private static let staleTemporaryAge: TimeInterval = 60 * 60

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    // MARK: Saving

    /// Saves an envelope as `<event id>.tecolotcrash`. The write goes to a
    /// temporary file first and then moves into place. Returns false when a
    /// report with this event ID exists.
    @discardableResult
    func save(envelope data: Data, eventID rawEventID: String) throws -> Bool {
        guard let eventID = SentryEnvelope.normalizedEventID(rawEventID) else {
            throw CrashReportStoreError.notACrashEvent
        }
        let envelope = try SentryEnvelope(data: data)
        guard envelope.containsEvent, envelope.eventID == eventID else {
            throw CrashReportStoreError.notACrashEvent
        }
        guard Int64(data.count) <= Self.maximumReportSize else {
            throw CrashReportStoreError.tooLarge(Int64(data.count))
        }

        try Self.createPrivateDirectory(directory)
        let destination = reportURL(for: eventID)
        if FileManager.default.fileExists(atPath: destination.path) {
            return false
        }

        let temporary = directory.appendingPathComponent(
            "\(Self.temporaryPrefix)\(eventID)-\(UUID().uuidString)"
        )
        try Self.writePrivateFile(data, to: temporary)
        // RENAME_EXCL keeps an existing report. A second launch that sees the
        // same event cannot replace or duplicate it.
        if renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            if code == EEXIST {
                return false
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return true
    }

    func reportURL(for eventID: String) -> URL {
        directory.appendingPathComponent(eventID).appendingPathExtension(Self.fileExtension)
    }

    // MARK: Listing

    /// Lists the reports. A missing directory is an empty list. Any other
    /// failure to read the directory throws.
    func list() throws -> CrashReportListing {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            return CrashReportListing()
        }
        guard isDirectory.boolValue else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: directory.path])
        }
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .creationDateKey],
            options: []
        )

        var listing = CrashReportListing()
        for url in urls where url.pathExtension == Self.fileExtension
            && !url.lastPathComponent.hasPrefix(".") {
            do {
                listing.reports.append(try readReport(at: url))
            } catch {
                listing.damaged.append(DamagedCrashReport(url: url, reason: error.localizedDescription))
            }
        }
        listing.reports.sort { lhs, rhs in
            lhs.createdAt != rhs.createdAt ? lhs.createdAt > rhs.createdAt : lhs.id > rhs.id
        }
        listing.damaged.sort { $0.url.lastPathComponent < $1.url.lastPathComponent }
        return listing
    }

    /// Validates one file and reads the fields that the list shows. Only the
    /// envelope headers and the event item are parsed. The minidump is not.
    func readReport(at url: URL) throws -> CrashReport {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .creationDateKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CrashReportStoreError.unsafeFile
        }
        let size = Int64(values.fileSize ?? 0)
        guard size <= Self.maximumReportSize else {
            throw CrashReportStoreError.tooLarge(size)
        }
        // A mapped file is read only where the parser looks. The parser skips
        // the minidump, so a large report is not read into memory.
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let envelope = try SentryEnvelope(data: data)
        guard envelope.containsEvent, let eventID = envelope.eventID else {
            throw CrashReportStoreError.notACrashEvent
        }
        guard url.deletingPathExtension().lastPathComponent == eventID else {
            throw CrashReportStoreError.eventIDMismatch
        }

        let savedAt = values.creationDate ?? Date(timeIntervalSince1970: 0)
        var createdAt = savedAt
        var appVersion: String?
        var buildNumber: String?
        if let item = envelope.items.first(where: { $0.type == "event" }),
           item.payloadRange.count <= Self.maximumEventSize,
           let event = try? JSONSerialization.jsonObject(with: data.subdata(in: item.payloadRange)) as? [String: Any] {
            if let timestamp = event["timestamp"] as? String,
               let date = Self.parseTimestamp(timestamp) {
                createdAt = date
            } else if let seconds = event["timestamp"] as? Double {
                createdAt = Date(timeIntervalSince1970: seconds)
            }
            let tags = event["tags"] as? [String: Any]
            appVersion = tags?[CrashReportTag.appVersion] as? String
            buildNumber = tags?[CrashReportTag.buildNumber] as? String
            if appVersion == nil {
                appVersion = event["release"] as? String
            }
        }
        return CrashReport(
            id: eventID,
            url: url,
            createdAt: createdAt,
            savedAt: savedAt,
            appVersion: appVersion,
            buildNumber: buildNumber,
            size: size
        )
    }

    private static func parseTimestamp(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) {
            return date
        }
        return ISO8601DateFormatter().date(from: string)
    }

    // MARK: Changes

    func delete(_ url: URL) throws {
        guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else {
            throw CrashReportStoreError.unsafeFile
        }
        try FileManager.default.removeItem(at: url)
    }

    /// Copies the original envelope byte for byte. The copy goes to a
    /// temporary file next to the destination first, so a failed copy does
    /// not leave a partial file. Call this off the main actor.
    func export(_ report: CrashReport, to destination: URL) throws {
        let fileManager = FileManager.default
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent)-\(UUID().uuidString)")
        try fileManager.copyItem(at: report.url, to: temporary)
        do {
            if fileManager.fileExists(atPath: destination.path) {
                // The save panel asked the user to replace this file.
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    /// Applies the retention rule and removes stale partial files. Returns
    /// the URLs that it removed. Call this during a normal launch only.
    @discardableResult
    func applyRetention(
        _ policy: CrashReportRetentionPolicy = .standard,
        now: Date = Date()
    ) throws -> [URL] {
        removeStaleTemporaryFiles(now: now)
        let listing = try list()
        var removed: [URL] = []
        var keptCount = 0
        var keptSize: Int64 = 0
        // Newest saved first. The crash time is not used: a report of an old
        // crash must not be removed in the launch that saves it.
        let bySaveTime = listing.reports.sorted { $0.savedAt > $1.savedAt }
        for report in bySaveTime {
            let isTooOld = now.timeIntervalSince(report.savedAt) > policy.maximumAge
            let exceedsCount = keptCount >= policy.maximumCount
            // The newest kept report stays even when it alone is too large.
            let exceedsSize = keptCount > 0 && keptSize + report.size > policy.maximumTotalSize
            if isTooOld || exceedsCount || exceedsSize {
                do {
                    try FileManager.default.removeItem(at: report.url)
                    removed.append(report.url)
                } catch {
                    CrashReporting.logger.error("Could not remove an old crash report: \(error.localizedDescription, privacy: .public)")
                }
            } else {
                keptCount += 1
                keptSize += report.size
            }
        }
        return removed
    }

    private func removeStaleTemporaryFiles(now: Date) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ) else { return }
        for url in urls where url.lastPathComponent.hasPrefix(Self.temporaryPrefix) {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) > Self.staleTemporaryAge {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: File permissions

    /// Creates the directory and its parents. The last component gets 0700.
    static func createPrivateDirectory(_ url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func writePrivateFile(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}

/// The fields that Tecolot adds to a crash event. Do not add others without
/// a change to the crash reporting spec.
nonisolated enum CrashReportTag {
    static let appVersion = "app_version"
    static let buildNumber = "build_number"
    static let bundleIdentifier = "bundle_id"
    static let architecture = "arch"
    static let macOSVersion = "macos_version"
    static let renderer = "renderer"
}

/// The preference calls that crash reporting uses. `UserDefaults` conforms.
/// Tests use an in-memory store, so they write no preference files.
nonisolated protocol CrashReportPreferences: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: CrashReportPreferences {}

/// Remembers which reports the user has seen, in Settings or in the notice.
nonisolated struct CrashReportSeenState {
    static let key = "CrashReportsSeenIDs"
    let defaults: any CrashReportPreferences

    func unseen(in listing: CrashReportListing) -> [CrashReport] {
        let seen = Set(defaults.object(forKey: Self.key) as? [String] ?? [])
        return listing.reports.filter { !seen.contains($0.id) }
    }

    /// Marks the listed reports as seen and forgets IDs of deleted reports.
    func markSeen(_ listing: CrashReportListing) {
        defaults.set(listing.reports.map(\.id).sorted(), forKey: Self.key)
    }
}
