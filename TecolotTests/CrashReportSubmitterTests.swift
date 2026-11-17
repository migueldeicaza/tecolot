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
        return CrashReportSubmitter(dsn: dsn, clientVersion: "1.2") { request, file in
            capture.append(request, try Data(contentsOf: file))
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

    private func file(_ data: Data) throws -> URL {
        let directory = fixture.directory("Upload")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("report.tecolotcrash")
        try data.write(to: url)
        return url
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

    @Test func sendsOneRequestWithUnchangedBody() async throws {
        let capture = Capture()
        let submitter = try Self.submitter(status: 200, body: #"{"id":"abc123"}"#, capture: capture)
        let envelope = Data((0..<2048).map { UInt8($0 % 251) })

        let id = try await submitter.submit(file: try file(envelope))

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
            try await submitter.submit(file: try self.file(Data("x".utf8)))
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
            try await failing.submit(file: try self.file(Data("x".utf8)))
        }
        let unreadable = try Self.submitter(status: 200, body: "not json", capture: capture)
        await #expect(throws: CrashReportSubmissionError.invalidResponse) {
            try await unreadable.submit(file: try self.file(Data("x".utf8)))
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

    @Test func listingIgnoresSubmissionLog() throws {
        let directory = fixture.directory()
        try CrashReportSubmissionLog(directory: directory)
            .record(CrashReportSubmission(sentryEventID: "s", date: Date()), for: "r")
        let listing = try CrashReportStore(directory: directory).list()
        #expect(listing.reports.isEmpty)
        #expect(listing.damaged.isEmpty)
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
        let directory = fixture.directory()
        let center = CrashReportSubmissionCenter(directory: directory, submitter: submitter)
        let report = CrashReport(
            id: "0123456789abcdef0123456789abcdef",
            url: try file(Data("envelope".utf8)),
            createdAt: Date(),
            savedAt: Date(),
            appVersion: "1.2",
            buildNumber: "3",
            size: 8
        )

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
        #expect(center.completedEventID == "sentry1")
        #expect(center.isSubmitted(report.id))
        #expect(CrashReportSubmissionLog(directory: directory).load()[report.id]?.sentryEventID == "sentry1")

        // A new center, as at the next launch, reads the record.
        let next = CrashReportSubmissionCenter(directory: directory, submitter: submitter)
        await next.refresh(keeping: [report.id])
        next.submit(report)
        #expect(next.inFlight.isEmpty)
        #expect(capture.requests.count == 1)
    }
}

/// Breakpad's task exception port must not reach terminal processes.
struct ChildExceptionPortTests {
    @Test func forkedChildHasNoInheritedExceptionPort() throws {
        ChildExceptionPorts.installResetInForkedChildren()
        let task = mach_task_self_
        let mask = ChildExceptionPorts.breakpadMask
        let capacity = 32

        // Save the current ports, to restore them after the test.
        let savedMasks = UnsafeMutablePointer<exception_mask_t>.allocate(capacity: capacity)
        let savedPorts = UnsafeMutablePointer<mach_port_t>.allocate(capacity: capacity)
        let savedBehaviors = UnsafeMutablePointer<exception_behavior_t>.allocate(capacity: capacity)
        let savedFlavors = UnsafeMutablePointer<thread_state_flavor_t>.allocate(capacity: capacity)
        defer {
            savedMasks.deallocate()
            savedPorts.deallocate()
            savedBehaviors.deallocate()
            savedFlavors.deallocate()
        }
        var savedCount = mach_msg_type_number_t(capacity)
        #expect(task_get_exception_ports(task, mask, savedMasks, &savedCount, savedPorts, savedBehaviors, savedFlavors) == KERN_SUCCESS)

        // Install a port, as Breakpad does.
        var port = mach_port_t(MACH_PORT_NULL)
        #expect(mach_port_allocate(task, MACH_PORT_RIGHT_RECEIVE, &port) == KERN_SUCCESS)
        #expect(mach_port_insert_right(task, port, port, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND)) == KERN_SUCCESS)
        #expect(task_set_exception_ports(
            task, mask, port, exception_behavior_t(EXCEPTION_DEFAULT), thread_state_flavor_t(THREAD_STATE_NONE)
        ) == KERN_SUCCESS)
        defer {
            _ = task_set_exception_ports(
                task, mask, mach_port_t(MACH_PORT_NULL),
                exception_behavior_t(EXCEPTION_DEFAULT), thread_state_flavor_t(THREAD_STATE_NONE)
            )
            for index in 0..<Int(savedCount) {
                _ = task_set_exception_ports(
                    task, savedMasks[index], savedPorts[index], savedBehaviors[index], savedFlavors[index]
                )
            }
            _ = mach_port_mod_refs(task, port, MACH_PORT_RIGHT_RECEIVE, -1)
            _ = mach_port_deallocate(task, port)
        }

        // The child reads its ports into buffers that exist before the fork.
        let masks = UnsafeMutablePointer<exception_mask_t>.allocate(capacity: capacity)
        let ports = UnsafeMutablePointer<mach_port_t>.allocate(capacity: capacity)
        let behaviors = UnsafeMutablePointer<exception_behavior_t>.allocate(capacity: capacity)
        let flavors = UnsafeMutablePointer<thread_state_flavor_t>.allocate(capacity: capacity)
        let count = UnsafeMutablePointer<mach_msg_type_number_t>.allocate(capacity: 1)
        defer {
            masks.deallocate()
            ports.deallocate()
            behaviors.deallocate()
            flavors.deallocate()
            count.deallocate()
        }

        // The parent sees the port, so the check in the child is meaningful.
        count.pointee = mach_msg_type_number_t(capacity)
        _ = task_get_exception_ports(task, mask, masks, count, ports, behaviors, flavors)
        #expect((0..<Int(count.pointee)).contains { ports[$0] != mach_port_t(MACH_PORT_NULL) })

        var master: Int32 = 0
        let pid = forkpty(&master, nil, nil, nil)
        #expect(pid >= 0)
        if pid == 0 {
            count.pointee = mach_msg_type_number_t(capacity)
            var status: Int32 = 0
            if task_get_exception_ports(mach_task_self_, mask, masks, count, ports, behaviors, flavors) != KERN_SUCCESS {
                status = 2
            }
            var index = 0
            while index < Int(count.pointee) {
                if ports[index] != mach_port_t(MACH_PORT_NULL) {
                    status = 1
                }
                index += 1
            }
            _exit(status)
        }
        close(master)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        // WIFEXITED and WEXITSTATUS are C macros.
        #expect(status & 0x7f == 0)
        #expect((status >> 8) & 0xff == 0)
    }
}
