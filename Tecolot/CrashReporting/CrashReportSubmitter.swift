//
//  CrashReportSubmitter.swift
//  Tecolot
//
//  Sends one saved crash report to Tecolot's Sentry project when the user
//  clicks Submit and confirms. This is the only network code for crash
//  reports. The SDK in SentryNativeBreakpad has no transport and no DSN.
//
import Foundation
import Observation
import os

/// The parts of a Sentry DSN that the envelope endpoint needs.
nonisolated struct SentryDSN: Equatable, Sendable {
    let publicKey: String
    let host: String
    let projectID: String
    let envelopeURL: URL

    /// Parses `https://<public key>@<host>/<project id>`. Returns nil for
    /// an empty or malformed value, for example in Debug builds.
    init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme == "https",
              let key = components.user, !key.isEmpty,
              components.password == nil,
              let host = components.host, !host.isEmpty else {
            return nil
        }
        let projectID = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !projectID.isEmpty, projectID.allSatisfy(\.isNumber) else { return nil }

        var endpoint = URLComponents()
        endpoint.scheme = "https"
        endpoint.host = host
        endpoint.port = components.port
        endpoint.path = "/api/\(projectID)/envelope/"
        guard let url = endpoint.url else { return nil }

        self.publicKey = key
        self.host = host
        self.projectID = projectID
        self.envelopeURL = url
    }

    /// The DSN from the app's Info.plist. Only Release builds have one.
    static func fromBundle(_ bundle: Bundle = .main) -> SentryDSN? {
        guard let value = bundle.object(forInfoDictionaryKey: "TecolotCrashReportDSN") as? String else {
            return nil
        }
        return SentryDSN(value)
    }
}

nonisolated enum CrashReportSubmissionError: LocalizedError, Equatable {
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .rateLimited(let retryAfter?):
            // Clamp again, so no value can trap in the Int conversion.
            let range = CrashReportSubmitter.retryAfterRange
            let seconds = retryAfter.isFinite ? min(max(retryAfter, range.lowerBound), range.upperBound) : range.upperBound
            let minutes = Int((seconds / 60).rounded(.up))
            return "Sentry is not accepting reports now. Try again in \(minutes) minute\(minutes == 1 ? "" : "s")."
        case .rateLimited(nil):
            return "Sentry is not accepting reports now. Try again later."
        case .server(let status):
            return "Sentry rejected the report (HTTP \(status))."
        case .invalidResponse:
            return "Sentry sent a response that Tecolot cannot read."
        }
    }
}

/// Sends one envelope in one request. It never retries by itself.
nonisolated struct CrashReportSubmitter: Sendable {
    /// Sends the request with the file as its body.
    typealias Transport = @Sendable (URLRequest, URL) async throws -> (Data, URLResponse)

    let dsn: SentryDSN
    let clientVersion: String
    private let transport: Transport

    init(dsn: SentryDSN, clientVersion: String, transport: Transport? = nil) {
        self.dsn = dsn
        self.clientVersion = clientVersion
        self.transport = transport ?? Self.ephemeralTransport
    }

    /// `Retry-After` values are clamped to this range.
    static let retryAfterRange: ClosedRange<TimeInterval> = 1...(24 * 60 * 60)

    /// The request for one envelope. The body is the saved file, unchanged.
    func makeRequest() -> URLRequest {
        var request = URLRequest(url: dsn.envelopeURL)
        request.httpMethod = "POST"
        request.setValue("application/x-sentry-envelope", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Sentry sentry_version=7, sentry_key=\(dsn.publicKey), sentry_client=tecolot/\(clientVersion)",
            forHTTPHeaderField: "X-Sentry-Auth"
        )
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 120
        return request
    }

    /// Sends the saved file unchanged and returns the event ID that Sentry
    /// accepted. The file is streamed, not read into memory.
    func submit(file: URL) async throws -> String {
        let (data, response) = try await transport(makeRequest(), file)
        guard let http = response as? HTTPURLResponse else {
            throw CrashReportSubmissionError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300:
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? String, !id.isEmpty else {
                throw CrashReportSubmissionError.invalidResponse
            }
            return id
        case 429:
            throw CrashReportSubmissionError.rateLimited(
                retryAfter: Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After"))
            )
        default:
            throw CrashReportSubmissionError.server(status: http.statusCode)
        }
    }

    /// Reads `Retry-After` in seconds. Returns nil for a missing, negative,
    /// or non-finite value, and clamps large values. An HTTP date is not read.
    static func retryAfter(_ value: String?) -> TimeInterval? {
        guard let value,
              let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)),
              seconds.isFinite, seconds >= 0 else {
            return nil
        }
        return min(max(seconds, retryAfterRange.lowerBound), retryAfterRange.upperBound)
    }

    private static let ephemeralTransport: Transport = { request, file in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        return try await session.upload(for: request, fromFile: file)
    }
}

/// A report that the user submitted.
nonisolated struct CrashReportSubmission: Codable, Equatable, Sendable {
    /// The event ID that Sentry returned.
    let sentryEventID: String
    let date: Date
}

/// Records submissions in `Submissions.json` next to the reports, keyed by
/// the report's event ID. A process-wide lock serializes each
/// read-modify-write, so `record` and `prune` cannot lose each other's
/// changes.
nonisolated struct CrashReportSubmissionLog: Sendable {
    static let fileName = "Submissions.json"
    private static let lock = NSLock()
    let directory: URL

    var url: URL {
        directory.appendingPathComponent(Self.fileName)
    }

    func load() -> [String: CrashReportSubmission] {
        Self.lock.withLock { unlockedLoad() }
    }

    private func unlockedLoad() -> [String: CrashReportSubmission] {
        guard let data = try? Data(contentsOf: url),
              let records = try? Self.decoder.decode([String: CrashReportSubmission].self, from: data) else {
            return [:]
        }
        return records
    }

    func record(_ submission: CrashReportSubmission, for reportID: String) throws {
        try Self.lock.withLock {
            var records = unlockedLoad()
            records[reportID] = submission
            try write(records)
        }
    }

    /// Removes records whose report is gone, for example after a delete or
    /// the retention rule.
    func prune(keeping reportIDs: Set<String>) throws {
        try Self.lock.withLock {
            let records = unlockedLoad()
            let kept = records.filter { reportIDs.contains($0.key) }
            guard kept.count != records.count else { return }
            try write(kept)
        }
    }

    private func write(_ records: [String: CrashReportSubmission]) throws {
        try CrashReportStore.createPrivateDirectory(directory)
        let data = try Self.encoder.encode(records)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Owns submissions for the whole app. A submission continues and stays
/// visible when the user leaves the Settings page, so the page cannot offer
/// Submit again while a request runs.
@Observable
@MainActor
final class CrashReportSubmissionCenter {
    static let shared = CrashReportSubmissionCenter(
        directory: CrashReporting.locations.reportsDirectory,
        submitter: CrashReporting.submitter
    )

    /// Nil when the build has no DSN, as in Debug builds.
    let submitter: CrashReportSubmitter?
    /// Submissions by report ID. This includes a submission that Sentry
    /// accepted but that could not be written to disk.
    private(set) var submissions: [String: CrashReportSubmission] = [:]
    /// Reports that are being sent now.
    private(set) var inFlight: Set<String> = []
    /// Sentry's event ID after a successful submission, for the alert.
    var completedEventID: String?
    var errorMessage: String?

    private let log: CrashReportSubmissionLog

    init(directory: URL, submitter: CrashReportSubmitter?) {
        self.submitter = submitter
        self.log = CrashReportSubmissionLog(directory: directory)
    }

    var canSubmit: Bool {
        submitter != nil
    }

    func isSubmitted(_ reportID: String) -> Bool {
        submissions[reportID] != nil
    }

    /// Reads the records and forgets those of reports that are gone.
    func refresh(keeping reportIDs: Set<String>) async {
        let log = self.log
        let loaded = await Task.detached(priority: .utility) {
            do {
                try log.prune(keeping: reportIDs)
            } catch {
                CrashReporting.logger.error("Could not update the crash report submission record: \(error.localizedDescription, privacy: .public)")
            }
            return log.load()
        }.value
        // Keep in-memory records that could not be written, so the same
        // report is not offered again in this session.
        var merged = loaded
        for (id, submission) in submissions where reportIDs.contains(id) && merged[id] == nil {
            merged[id] = submission
        }
        submissions = merged
    }

    /// Sends one report after the user confirmed. Never call this without a
    /// click and a confirmation. Does nothing when the report is sent or
    /// being sent.
    func submit(_ report: CrashReport) {
        guard let submitter,
              !inFlight.contains(report.id),
              submissions[report.id] == nil else {
            return
        }
        inFlight.insert(report.id)
        let log = self.log
        Task {
            defer { inFlight.remove(report.id) }
            let sentryID: String
            do {
                sentryID = try await submitter.submit(file: report.url)
            } catch {
                CrashReporting.logger.error("Could not submit a crash report: \(error.localizedDescription, privacy: .public)")
                errorMessage = error.localizedDescription
                return
            }

            let submission = CrashReportSubmission(sentryEventID: sentryID, date: Date())
            submissions[report.id] = submission
            completedEventID = sentryID
            do {
                try await Task.detached(priority: .utility) {
                    try log.record(submission, for: report.id)
                }.value
            } catch {
                CrashReporting.logger.error("Could not record a crash report submission: \(error.localizedDescription, privacy: .public)")
                errorMessage = "Sentry received the report (ID \(sentryID)), but Tecolot could not record this on disk: \(error.localizedDescription) Tecolot will not offer to send it again until it quits."
            }
        }
    }
}
