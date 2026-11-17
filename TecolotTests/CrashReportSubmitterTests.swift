import Darwin
import Foundation
import Testing
@testable import Tecolot

final class CrashReportSubmitterTests {
    private static let dsnString = "https://8785d54390ea6a6a3d37b6f3d4228346@o201469.ingest.us.sentry.io/4512438257713152"
    private let fixture = CrashReportTestFixture()

    nonisolated private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [(URLRequest, Data)] = []

        var requests: [(URLRequest, Data)] {
            lock.withLock { _requests }
        }

        func append(_ request: URLRequest, _ body: Data) {
            lock.withLock { _requests.append((request, body)) }
        }
    }

    private static func submitter(
        status: Int,
        body: String = "{}",
        headers: [String: String] = [:],
        delay: Duration = .zero,
        capture: Capture
    ) throws -> CrashReportSubmitter {
        let dsn = try #require(SentryDSN(dsnString))
        return CrashReportSubmitter(dsn: dsn, clientVersion: "1.2") { request, sent in
            capture.append(request, sent)
            if delay > .zero {
                try await Task.sleep(for: delay)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            return (Data(body.utf8), response)
        }
    }

    @Test func parsesDSN() throws {
        let dsn = try #require(SentryDSN(Self.dsnString))
        #expect(dsn.publicKey == "8785d54390ea6a6a3d37b6f3d4228346")
        #expect(dsn.host == "o201469.ingest.us.sentry.io")
        #expect(dsn.projectID == "4512438257713152")
        #expect(dsn.envelopeURL.absoluteString == "https://o201469.ingest.us.sentry.io/api/4512438257713152/envelope/")
    }

    @Test func rejectsMissingOrMalformedDSN() {
        #expect(SentryDSN("") == nil)
        #expect(SentryDSN("$(TECOLOT_CRASH_REPORT_DSN)") == nil)
        #expect(SentryDSN("http://key@sentry.io/1") == nil)
        #expect(SentryDSN("https://sentry.io/1") == nil)
        #expect(SentryDSN("https://key@sentry.io/") == nil)
        #expect(SentryDSN("https://key:secret@sentry.io/1") == nil)
    }

    @Test func sendsOneRequestWithTheEnvelope() async throws {
        let capture = Capture()
        let submitter = try Self.submitter(status: 200, body: #"{"id":"abc123"}"#, capture: capture)
        let envelope = Data((0..<2048).map { UInt8($0 % 251) })

        let id = try await submitter.submit(envelope: envelope)

        #expect(id == "abc123")
        #expect(capture.requests.count == 1)
        let (request, body) = try #require(capture.requests.first)
        #expect(body == envelope)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://o201469.ingest.us.sentry.io/api/4512438257713152/envelope/")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-sentry-envelope")
        #expect(request.value(forHTTPHeaderField: "X-Sentry-Auth")
            == "Sentry sentry_version=7, sentry_key=8785d54390ea6a6a3d37b6f3d4228346, sentry_client=tecolot/1.2")
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test func reportsRateLimitWithoutRetrying() async throws {
        let capture = Capture()
        let submitter = try Self.submitter(status: 429, headers: ["Retry-After": "120"], capture: capture)
        await #expect(throws: CrashReportSubmissionError.rateLimited(retryAfter: 120)) {
            try await submitter.submit(envelope: Data("x".utf8))
        }
        #expect(capture.requests.count == 1)
        #expect(CrashReportSubmissionError.rateLimited(retryAfter: 120).errorDescription?.contains("2 minutes") == true)
    }

    @Test(arguments: ["inf", "nan", "1e300", "-5", "abc", "", "Wed, 21 Oct 2026 07:28:00 GMT"])
    func retryAfterNeverTraps(value: String) {
        let seconds = CrashReportSubmitter.retryAfter(value)
        if let seconds {
            #expect(CrashReportSubmitter.retryAfterRange.contains(seconds))
        }
        // The message must not trap for any value.
        _ = CrashReportSubmissionError.rateLimited(retryAfter: seconds).errorDescription
        _ = CrashReportSubmissionError.rateLimited(retryAfter: .infinity).errorDescription
        _ = CrashReportSubmissionError.rateLimited(retryAfter: .nan).errorDescription
    }

    @Test func clampsLargeRetryAfter() {
        #expect(CrashReportSubmitter.retryAfter("1e300") == CrashReportSubmitter.retryAfterRange.upperBound)
        #expect(CrashReportSubmitter.retryAfter("inf") == nil)
        #expect(CrashReportSubmitter.retryAfter("30") == 30)
    }

    @Test func reportsServerErrorsAndBadResponses() async throws {
        let capture = Capture()
        let failing = try Self.submitter(status: 413, capture: capture)
        await #expect(throws: CrashReportSubmissionError.server(status: 413)) {
            try await failing.submit(envelope: Data("x".utf8))
        }
        let unreadable = try Self.submitter(status: 200, body: "not json", capture: capture)
        await #expect(throws: CrashReportSubmissionError.invalidResponse) {
            try await unreadable.submit(envelope: Data("x".utf8))
        }
    }

    @Test func submissionLogRecordsAndPrunes() throws {
        let log = CrashReportSubmissionLog(directory: fixture.directory())
        #expect(log.load().isEmpty)

        let date = Date(timeIntervalSince1970: 1_800_000_000)
        try log.record(CrashReportSubmission(sentryEventID: "s1", date: date), for: "report1")
        try log.record(CrashReportSubmission(sentryEventID: "s2", date: date), for: "report2")
        #expect(log.load()["report1"] == CrashReportSubmission(sentryEventID: "s1", date: date))

        let mode = try FileManager.default.attributesOfItem(atPath: log.url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        try log.prune(keeping: ["report2"])
        #expect(Set(log.load().keys) == ["report2"])
    }

    @Test func concurrentRecordsAndPrunesKeepEveryRecord() async throws {
        let log = CrashReportSubmissionLog(directory: fixture.directory())
        let ids = (0..<40).map { "report\($0)" }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask {
                    try log.record(CrashReportSubmission(sentryEventID: id, date: Date()), for: id)
                }
                group.addTask {
                    try log.prune(keeping: Set(ids))
                }
            }
            try await group.waitForAll()
        }
        #expect(Set(log.load().keys) == Set(ids))
    }

    @MainActor
    @Test func centerSendsAReportOnlyOnce() async throws {
        let capture = Capture()
        let submitter = try Self.submitter(
            status: 200,
            body: #"{"id":"sentry1"}"#,
            delay: .milliseconds(100),
            capture: capture
        )
        let directory = fixture.directory("State")
        let store = try fixture.store()
        try CrashReportSamples.write(
            CrashReportSamples.ips(), named: "Tecolot-2026-11-15-100000.ips", in: store.primaryDirectory
        )
        let report = try #require(try store.list().reports.first)
        let center = CrashReportSubmissionCenter(directory: directory, store: store, submitter: submitter)

        // A second click while the first request runs, as after leaving and
        // reopening the Settings page, sends nothing.
        center.submit(report)
        center.submit(report)
        #expect(center.inFlight == [report.id])
        while !center.inFlight.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        center.submit(report)

        #expect(capture.requests.count == 1)
        // The body is the converted event, not the macOS file.
        let body = try #require(capture.requests.first.flatMap { String(data: $0.1, encoding: .utf8) })
        #expect(body.contains(report.eventID))
        #expect(!body.contains("threadState"))
        #expect(center.completedEventID == "sentry1")
        #expect(center.isSubmitted(report.id))
        #expect(CrashReportSubmissionLog(directory: directory).load()[report.id]?.sentryEventID == "sentry1")

        // A new center, as at the next launch, reads the record.
        let next = CrashReportSubmissionCenter(directory: directory, store: store, submitter: submitter)
        await next.refresh(keeping: [report.id])
        next.submit(report)
        #expect(next.inFlight.isEmpty)
        #expect(capture.requests.count == 1)
    }

    @MainActor
    @Test func aRecordFailureIsNotASendFailure() async throws {
        let capture = Capture()
        let submitter = try Self.submitter(status: 200, body: #"{"id":"sentry2"}"#, capture: capture)
        // A file where the record folder must be, so the record write fails.
        let blocked = fixture.directory("State")
        try FileManager.default.createDirectory(at: blocked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: blocked)
        let store = try fixture.store()
        try CrashReportSamples.write(
            CrashReportSamples.ips(), named: "Tecolot-2026-11-15-100000.ips", in: store.primaryDirectory
        )
        let report = try #require(try store.list().reports.first)
        let center = CrashReportSubmissionCenter(directory: blocked, store: store, submitter: submitter)

        center.submit(report)
        while center.inFlight.contains(report.id) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(center.completedEventID == "sentry2")
        #expect(center.errorMessage == nil)
        #expect(center.completionWarning != nil)
        #expect(center.isSubmitted(report.id))
    }

    @MainActor
    @Test func aPartialListingKeepsSubmissionRecords() async throws {
        let directory = fixture.directory("State")
        let log = CrashReportSubmissionLog(directory: directory)
        try log.record(CrashReportSubmission(sentryEventID: "s", date: Date()), for: "retired-report")
        let center = CrashReportSubmissionCenter(directory: directory, store: try fixture.store(), submitter: nil)

        await center.refresh(keeping: [], prune: false)
        #expect(center.isSubmitted("retired-report"))
        await center.refresh(keeping: [])
        #expect(!center.isSubmitted("retired-report"))
    }
}
