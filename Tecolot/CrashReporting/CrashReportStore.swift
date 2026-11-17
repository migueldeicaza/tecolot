//
//  CrashReportStore.swift
//  Tecolot
//
//  The crash reports that macOS wrote for this app. macOS writes each report
//  as `<process>-<date>.ips` in ~/Library/Logs/DiagnosticReports and later
//  moves it to the Retired subfolder. macOS also removes old reports.
//  Tecolot reads these files, and deletes one only when the user asks. The
//  store never sends data.
//
import Darwin
import Foundation
import os

nonisolated struct CrashReport: Identifiable, Hashable, Sendable {
    /// The incident ID from the report header, an uppercase UUID.
    let id: String
    let url: URL
    /// The crash time from the report.
    let createdAt: Date
    let appVersion: String?
    let buildNumber: String?
    /// The exception, for example "EXC_BAD_ACCESS (SIGSEGV)".
    let summary: String?
    let size: Int64

    var displayVersion: String {
        switch (appVersion, buildNumber) {
        case let (version?, build?): return "\(version) (\(build))"
        case let (version?, nil): return version
        default: return "Unknown"
        }
    }

    /// The Sentry event ID: the incident ID as 32 lowercase hexadecimal
    /// characters. The same report always has the same event ID, so Sentry
    /// can find a second submission of it.
    var eventID: String {
        id.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

/// A file with this app's report name that Tecolot cannot read.
nonisolated struct DamagedCrashReport: Identifiable, Hashable, Sendable {
    var id: URL { url }
    let url: URL
    let reason: String
}

nonisolated struct CrashReportListing: Sendable, Equatable {
    /// Valid reports, newest first.
    var reports: [CrashReport] = []
    var damaged: [DamagedCrashReport] = []
    /// False when a folder could not be read. Then a report that is not in
    /// the list can still exist, so callers must not forget its records.
    var isComplete = true
}

nonisolated enum CrashReportStoreError: LocalizedError, Equatable {
    case notACrashReport
    /// A report of this process name that is not a crash, for example a hang.
    case otherKind
    case otherApp
    case tooLarge(Int64)
    case unsafeFile

    var errorDescription: String? {
        switch self {
        case .notACrashReport: return "The file is not a crash report that Tecolot can read."
        case .otherKind: return "The report is not a crash report."
        case .otherApp: return "The report is for a different app."
        case .tooLarge(let size): return "The file is too large (\(size) bytes)."
        case .unsafeFile: return "The item is not a crash report file of this app."
        }
    }
}

/// Reads this app's crash reports. The type has no mutable state. It is safe
/// to use from any thread.
nonisolated struct CrashReportStore: Sendable {
    static let fileExtension = "ips"
    /// A crash report is usually less than 1 MiB. Tecolot does not read a
    /// larger file than this.
    static let maximumReportSize: Int64 = 16 * 1024 * 1024

    /// The folders to read, in order. The first folder is where macOS writes
    /// new reports.
    let directories: [URL]
    let processName: String
    let bundleIdentifier: String

    init(directories: [URL], processName: String, bundleIdentifier: String) {
        self.directories = directories
        self.processName = processName
        self.bundleIdentifier = bundleIdentifier
    }

    /// `~/Library/Logs/DiagnosticReports` and its Retired subfolder.
    static func systemDirectories(fileManager: FileManager = .default) -> [URL] {
        let reports = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/DiagnosticReports", isDirectory: true)
        return [reports, reports.appendingPathComponent("Retired", isDirectory: true)]
    }

    /// The folder that the Settings page shows.
    var primaryDirectory: URL {
        directories[0]
    }

    // MARK: Listing

    /// Lists the reports. A missing folder is an empty list. Any other
    /// failure to read the first folder throws.
    func list() throws -> CrashReportListing {
        var listing = CrashReportListing()
        var seenIDs = Set<String>()
        for (position, directory) in directories.enumerated() {
            let urls: [URL]
            do {
                urls = try candidateFiles(in: directory)
            } catch {
                // The Retired folder is not necessary to list new reports.
                if position == 0 { throw error }
                CrashReporting.logger.error("Could not read \(directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                listing.isComplete = false
                continue
            }
            for url in urls {
                do {
                    guard let report = try listedReport(at: url) else { continue }
                    if seenIDs.insert(report.id).inserted {
                        listing.reports.append(report)
                    }
                } catch {
                    listing.damaged.append(DamagedCrashReport(url: url, reason: error.localizedDescription))
                }
            }
        }
        listing.reports.sort { lhs, rhs in
            lhs.createdAt != rhs.createdAt ? lhs.createdAt > rhs.createdAt : lhs.id > rhs.id
        }
        listing.damaged.sort { $0.url.lastPathComponent < $1.url.lastPathComponent }
        return listing
    }

    /// The `.ips` files whose name starts with the process name. The folder
    /// has reports of all programs, so the name is checked before a file is
    /// opened.
    private func candidateFiles(in directory: URL) throws -> [URL] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: directory.path])
        }
        let prefix = processName + "-"
        return try fileManager.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix("." + Self.fileExtension) }
            .map { directory.appendingPathComponent($0, isDirectory: false) }
    }

    /// The row for one file, from the cache when the file did not change.
    /// Nil for a report of another app or another kind.
    private func listedReport(at url: URL) throws -> CrashReport? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = ListingCache.Key(
            path: url.path,
            bundleIdentifier: bundleIdentifier,
            size: values?.fileSize,
            modified: values?.contentModificationDate
        )
        if values != nil, let cached = ListingCache.shared.entry(for: key) {
            return cached
        }
        let report: CrashReport?
        do {
            report = try readReport(at: url)
        } catch CrashReportStoreError.otherApp, CrashReportStoreError.otherKind {
            report = nil
        }
        if values != nil {
            ListingCache.shared.store(report, for: key)
        }
        return report
    }

    /// Validates one file and reads the fields that the list shows. The body
    /// is parsed only for a crash report of this app.
    func readReport(at url: URL) throws -> CrashReport {
        let (data, size) = try Self.readRegularFile(url)
        let header = try DiagnosticReport.parseHeader(data).header
        guard header.bundleIdentifier == bundleIdentifier else {
            throw CrashReportStoreError.otherApp
        }
        let report = try DiagnosticReport(data: data)
        return CrashReport(
            id: report.header.incidentID,
            url: url,
            createdAt: report.crashDate ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date(timeIntervalSince1970: 0),
            appVersion: report.header.appVersion,
            buildNumber: report.header.buildVersion,
            summary: report.exceptionSummary,
            size: size
        )
    }

    /// Reads and parses the whole report, for a submission.
    func loadReport(_ report: CrashReport) throws -> DiagnosticReport {
        let url = try currentURL(of: report)
        let parsed = try DiagnosticReport(data: Self.readRegularFile(url).data)
        guard parsed.header.bundleIdentifier == bundleIdentifier,
              parsed.header.incidentID == report.id else {
            throw CrashReportStoreError.otherApp
        }
        return parsed
    }

    /// Reads a regular file that is not a symbolic link and not too large.
    /// The checks use the open descriptor, so a FIFO or a link that replaces
    /// the file cannot block or redirect the read.
    static func readRegularFile(_ url: URL) throws -> (data: Data, size: Int64) {
        let (handle, size) = try openRegularFile(url)
        let data = try handle.readToEnd() ?? Data()
        try handle.close()
        return (data, size)
    }

    /// Reads only the header line of a report, with the same checks as
    /// `readRegularFile`. The result ends with the newline.
    static func readHeaderLine(_ url: URL) throws -> Data {
        let (handle, _) = try openRegularFile(url)
        defer { try? handle.close() }
        var data = Data()
        while data.count < maximumHeaderSize {
            guard let chunk = try handle.read(upToCount: 4096), !chunk.isEmpty else { break }
            if let newline = chunk.firstIndex(of: 0x0A) {
                data.append(chunk[chunk.startIndex...newline])
                return data
            }
            data.append(chunk)
        }
        throw CrashReportStoreError.notACrashReport
    }

    /// The header line is about 400 bytes. A longer line is not a report.
    static let maximumHeaderSize = 64 * 1024

    private static func openRegularFile(_ url: URL) throws -> (handle: FileHandle, size: Int64) {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw CrashReportStoreError.unsafeFile }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw CrashReportStoreError.unsafeFile
        }
        let size = Int64(status.st_size)
        guard size <= maximumReportSize else {
            throw CrashReportStoreError.tooLarge(size)
        }
        return (handle, size)
    }

    // MARK: Finding a report

    /// The files of a report in all folders. macOS keeps the file name when
    /// it moves a report to Retired, so a report can have a copy in each
    /// folder, or be in a different folder than when it was listed.
    func files(of report: CrashReport) -> [URL] {
        let name = report.url.lastPathComponent
        return directories.compactMap { directory in
            let url = directory.appendingPathComponent(name, isDirectory: false)
            guard (try? checkOwned(url)) != nil,
                  let data = try? Self.readHeaderLine(url),
                  let header = try? DiagnosticReport.parseHeader(data).header,
                  header.incidentID == report.id,
                  header.bundleIdentifier == bundleIdentifier else {
                return nil
            }
            return url
        }
    }

    /// Where the report is now.
    func currentURL(of report: CrashReport) throws -> URL {
        guard let url = files(of: report).first else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: report.url.path])
        }
        return url
    }

    // MARK: Changes

    /// Deletes all copies of a report.
    func delete(_ report: CrashReport) throws {
        let urls = files(of: report)
        guard !urls.isEmpty else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: report.url.path])
        }
        for url in urls {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Deletes a damaged file. The file must be directly in one of the
    /// report folders and have this app's report name.
    func delete(_ url: URL) throws {
        try checkOwned(url)
        try FileManager.default.removeItem(at: url)
    }

    private func checkOwned(_ url: URL) throws {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard directories.contains(where: { $0.standardizedFileURL == parent }),
              url.lastPathComponent.hasPrefix(processName + "-"),
              url.pathExtension == Self.fileExtension else {
            throw CrashReportStoreError.unsafeFile
        }
    }

    /// Copies the original report byte for byte. The copy goes to a
    /// temporary file next to the destination first, so a failed copy does
    /// not leave a partial file. Call this off the main actor.
    func export(_ report: CrashReport, to destination: URL) throws {
        let fileManager = FileManager.default
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent)-\(UUID().uuidString)")
        try fileManager.copyItem(at: try currentURL(of: report), to: temporary)
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

    /// Creates the directory and its parents. The last component gets 0700.
    static func createPrivateDirectory(_ url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
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

    /// False until Tecolot records the seen reports for the first time.
    var hasBaseline: Bool {
        defaults.object(forKey: Self.key) != nil
    }

    func unseen(in listing: CrashReportListing) -> [CrashReport] {
        let seen = Set(defaults.object(forKey: Self.key) as? [String] ?? [])
        return listing.reports.filter { !seen.contains($0.id) }
    }

    /// Marks the listed reports as seen. A complete listing also forgets
    /// the IDs of deleted reports. A partial listing keeps all known IDs.
    func markSeen(_ listing: CrashReportListing) {
        var ids = Set(listing.reports.map(\.id))
        if !listing.isComplete {
            ids.formUnion(defaults.object(forKey: Self.key) as? [String] ?? [])
        }
        defaults.set(ids.sorted(), forKey: Self.key)
    }
}

/// The listed rows by file, so a list does not parse unchanged reports
/// again. A changed size or modification date reads the file again.
nonisolated final class ListingCache: @unchecked Sendable {
    struct Key: Hashable {
        var path: String
        var bundleIdentifier: String
        var size: Int?
        var modified: Date?
    }

    static let shared = ListingCache()
    private let lock = NSLock()
    /// Nil value: the file is not a crash report of this app.
    private var entries: [Key: CrashReport?] = [:]

    func entry(for key: Key) -> CrashReport?? {
        lock.withLock { entries[key] }
    }

    func store(_ report: CrashReport?, for key: Key) {
        lock.withLock {
            // Keep one entry for each path.
            entries = entries.filter { $0.key.path != key.path }
            entries[key] = .some(report)
        }
    }
}
