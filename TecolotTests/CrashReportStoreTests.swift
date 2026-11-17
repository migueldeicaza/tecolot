import Darwin
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

    func directory(_ name: String = "DiagnosticReports") -> URL {
        root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// A store with a report folder and its Retired subfolder.
    func store(bundleIdentifier: String = CrashReportSamples.bundleIdentifier) throws -> CrashReportStore {
        let primary = directory()
        let retired = primary.appendingPathComponent("Retired", isDirectory: true)
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        return CrashReportStore(directories: [primary, retired], processName: "Tecolot", bundleIdentifier: bundleIdentifier)
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

/// Crash reports in the macOS `.ips` format, version 2, with only the
/// fields that Tecolot reads and a few that it must not send.
enum CrashReportSamples {
    static let bundleIdentifier = "com.tirania.Tecolot"

    static func ips(
        incident: String = UUID().uuidString,
        bundleIdentifier: String = CrashReportSamples.bundleIdentifier,
        bugType: String = "309",
        captureTime: String = "2026-11-15 22:28:05.9862 -0500",
        version: String = "1.2",
        build: String = "34"
    ) -> String {
        let header = """
        {"app_name":"Tecolot","timestamp":"2026-11-15 22:28:24.00 -0500","app_version":"\(version)","slice_uuid":"ae22159d-0a95-3f8c-8737-f533cf93799d","build_version":"\(build)","platform":1,"bundleID":"\(bundleIdentifier)","bug_type":"\(bugType)","os_version":"macOS 27.0.1 (26A434)","name":"Tecolot","incident_id":"\(incident)"}
        """
        let body = """
        {
          "captureTime" : "\(captureTime)",
          "modelCode" : "Mac15,14",
          "cpuType" : "ARM-64",
          "osVersion" : {"train":"macOS 27.0.1","build":"26A434","releaseType":"User"},
          "incident" : "\(incident)",
          "crashReporterKey" : "E9800B4C-388F-97E5-6F8A-1C5FFBB0A5E2",
          "storeInfo" : {"deviceIdentifierForVendor":"B0DDA00D-D7D6-5512-A6B1-4D63A9FF88D4"},
          "procPath" : "/Users/USER/*/Tecolot.app/Contents/MacOS/Tecolot",
          "instructionByteStream" : {"atPC":"wANf1g=="},
          "exception" : {"codes":"0x0000000000000001, 0x0000000000000010","rawCodes":[1,16],"type":"EXC_BAD_ACCESS","signal":"SIGSEGV","subtype":"KERN_INVALID_ADDRESS at 0x0000000000000010"},
          "termination" : {"flags":0,"code":11,"namespace":"SIGNAL","indicator":"Segmentation fault: 11"},
          "asi" : {"libswiftCore.dylib":["Fatal error: Index out of range"]},
          "faultingThread" : 1,
          "threads" : [
            {"id":100,"queue":"com.apple.main-thread","threadState":{"x":[{"value":4242}],"pc":{"value":6710152224}},
             "frames":[{"imageOffset":3104,"symbol":"mach_msg2_trap","symbolLocation":8,"imageIndex":2}]},
            {"triggered":true,"id":101,"name":"worker","threadState":{"x":[{"value":18446744073709551569}]},
             "frames":[
               {"imageOffset":4096,"symbol":"inlined()","symbolLocation":0,"imageIndex":1,"inline":true},
               {"imageOffset":4096,"symbol":"crash()","symbolLocation":16,"imageIndex":1},
               {"imageOffset":512,"symbol":"main","symbolLocation":4,"imageIndex":0}
             ]}
          ],
          "usedImages" : [
            {"source":"P","arch":"arm64","base":4296998912,"size":16384,"uuid":"AE22159D-0A95-3F8C-8737-F533CF93799D","path":"/Users/USER/*/Tecolot.app/Contents/MacOS/Tecolot","name":"Tecolot"},
            {"source":"P","arch":"arm64","base":4326850560,"size":12599296,"uuid":"cecb5b6c-7624-352a-9c19-52b9e158b4d9","path":"/Users/USER/*/Tecolot.app/Contents/Frameworks/SwiftTerm.framework/SwiftTerm","name":"SwiftTerm"},
            {"source":"P","arch":"arm64e","base":6710149120,"size":250000,"uuid":"11111111-2222-3333-4444-555555555555","path":"/usr/lib/system/libsystem_kernel.dylib","name":"libsystem_kernel.dylib"},
            {"source":"P","arch":"arm64e","base":6734983168,"size":19649160,"uuid":"4317f7c6-73d2-3be9-b010-f318f1198a1b","path":"/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation","name":"Foundation"},
            {"size":0,"source":"A","base":0}
          ],
          "vmSummary" : "Writable regions: Total=204.1M",
          "bug_type" : "\(bugType)"
        }
        """
        return header + "\n" + body
    }

    @discardableResult
    static func write(_ text: String, named name: String, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }
}

final class CrashReportStoreTests {
    private let fixture = CrashReportTestFixture()

    @Test func missingFoldersAreAnEmptyList() throws {
        let missing = fixture.directory()
        let store = CrashReportStore(directories: [missing], processName: "Tecolot", bundleIdentifier: "x")
        #expect(try store.list() == CrashReportListing())
    }

    @Test func readsTheFieldsThatTheListShows() throws {
        let store = try fixture.store()
        let incident = "C00B20DD-0F09-4D1B-9CDB-9609FF5E3C40"
        try CrashReportSamples.write(
            CrashReportSamples.ips(incident: incident),
            named: "Tecolot-2026-11-15-222824.ips",
            in: store.primaryDirectory
        )

        let report = try #require(try store.list().reports.first)
        #expect(report.id == incident)
        #expect(report.eventID == "c00b20dd0f094d1b9cdb9609ff5e3c40")
        #expect(report.displayVersion == "1.2 (34)")
        #expect(report.summary == "EXC_BAD_ACCESS (SIGSEGV)")
        // 2026-11-15 22:28:05.9862 -0500
        #expect(abs(report.createdAt.timeIntervalSince1970 - 1_794_799_685.9862) < 0.001)
    }

    @Test func listsOnlyThisAppsCrashesFromBothFolders() throws {
        let store = try fixture.store()
        let primary = store.primaryDirectory
        let retired = store.directories[1]
        try CrashReportSamples.write(
            CrashReportSamples.ips(captureTime: "2026-11-15 10:00:00.00 -0500"),
            named: "Tecolot-2026-11-15-100000.ips", in: primary
        )
        try CrashReportSamples.write(
            CrashReportSamples.ips(captureTime: "2026-11-01 10:00:00.00 -0500"),
            named: "Tecolot-2026-11-01-100000.ips", in: retired
        )
        // The Debug build, a hang report, another program, and a file that
        // is not a report.
        try CrashReportSamples.write(
            CrashReportSamples.ips(bundleIdentifier: "com.tirania.Tecolot.debug"),
            named: "Tecolot-2026-11-14-100000.ips", in: primary
        )
        try CrashReportSamples.write(
            CrashReportSamples.ips(bugType: "288"),
            named: "Tecolot-2026-11-13-100000.ips", in: primary
        )
        try CrashReportSamples.write(CrashReportSamples.ips(), named: "bash-2026-11-15-100000.ips", in: primary)
        try CrashReportSamples.write("not json", named: "Tecolot-2026-11-12-100000.ips", in: primary)
        try CrashReportSamples.write(CrashReportSamples.ips(), named: "Tecolot-2026-11-15-100000.txt", in: primary)

        let listing = try store.list()
        #expect(listing.reports.map(\.url.lastPathComponent) == [
            "Tecolot-2026-11-15-100000.ips",
            "Tecolot-2026-11-01-100000.ips"
        ])
        #expect(listing.damaged.map(\.url.lastPathComponent) == ["Tecolot-2026-11-12-100000.ips"])
    }

    @Test func listsAReportInBothFoldersOnce() throws {
        let store = try fixture.store()
        let text = CrashReportSamples.ips()
        try CrashReportSamples.write(text, named: "Tecolot-2026-11-15-100000.ips", in: store.primaryDirectory)
        try CrashReportSamples.write(text, named: "Tecolot-2026-11-15-100000.ips", in: store.directories[1])
        let listing = try store.list()
        #expect(listing.reports.count == 1)
        #expect(listing.reports.first?.url.deletingLastPathComponent().lastPathComponent == "DiagnosticReports")
    }

    @Test func deletesOnlyThisAppsReports() throws {
        let store = try fixture.store()
        let report = try CrashReportSamples.write(
            CrashReportSamples.ips(), named: "Tecolot-2026-11-15-100000.ips", in: store.primaryDirectory
        )
        let other = try CrashReportSamples.write(
            CrashReportSamples.ips(), named: "bash-2026-11-15-100000.ips", in: store.primaryDirectory
        )
        let outside = try CrashReportSamples.write(
            CrashReportSamples.ips(), named: "Tecolot-2026-11-15-100000.ips", in: fixture.directory("Elsewhere")
        )

        #expect(throws: CrashReportStoreError.unsafeFile) { try store.delete(other) }
        #expect(throws: CrashReportStoreError.unsafeFile) { try store.delete(outside) }
        try store.delete(report)
        #expect(!FileManager.default.fileExists(atPath: report.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func exportCopiesTheReportUnchanged() throws {
        let store = try fixture.store()
        let text = CrashReportSamples.ips()
        try CrashReportSamples.write(text, named: "Tecolot-2026-11-15-100000.ips", in: store.primaryDirectory)
        let report = try #require(try store.list().reports.first)
        let destinationDirectory = fixture.directory("Export")
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destination = destinationDirectory.appendingPathComponent("copy.ips")

        try store.export(report, to: destination)
        // A second export replaces the first.
        try store.export(report, to: destination)
        #expect(try Data(contentsOf: destination) == Data(text.utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destinationDirectory.path) == ["copy.ips"])
    }

    @Test func loadReportChecksTheIncident() throws {
        let store = try fixture.store()
        let url = try CrashReportSamples.write(
            CrashReportSamples.ips(), named: "Tecolot-2026-11-15-100000.ips", in: store.primaryDirectory
        )
        let report = try #require(try store.list().reports.first)
        #expect(try store.loadReport(report).threads.count == 2)

        // The file changed after the list was read.
        try Data(CrashReportSamples.ips().utf8).write(to: url)
        // The report is gone: no file has its incident ID.
        #expect(throws: CocoaError.self) { try store.loadReport(report) }
    }

    @Test func seenStateTracksReports() throws {
        let store = try fixture.store()
        try CrashReportSamples.write(CrashReportSamples.ips(), named: "Tecolot-a.ips", in: store.primaryDirectory)
        let defaults = fixture.defaults()
        let seen = CrashReportSeenState(defaults: defaults)
        let first = try store.list()

        #expect(!seen.hasBaseline)
        #expect(seen.unseen(in: first).count == 1)
        seen.markSeen(first)
        #expect(seen.hasBaseline)
        #expect(seen.unseen(in: first).isEmpty)

        try CrashReportSamples.write(CrashReportSamples.ips(), named: "Tecolot-b.ips", in: store.primaryDirectory)
        #expect(seen.unseen(in: try store.list()).count == 1)
    }

    @Test func deleteRemovesTheCopyInBothFolders() throws {
        let store = try fixture.store()
        let text = CrashReportSamples.ips()
        let primary = try CrashReportSamples.write(text, named: "Tecolot-2026-11-15-100000.ips", in: store.primaryDirectory)
        let retired = try CrashReportSamples.write(text, named: "Tecolot-2026-11-15-100000.ips", in: store.directories[1])
        let report = try #require(try store.list().reports.first)

        try store.delete(report)
        #expect(!FileManager.default.fileExists(atPath: primary.path))
        #expect(!FileManager.default.fileExists(atPath: retired.path))
        #expect(try store.list().reports.isEmpty)
    }

    @Test func findsAReportThatMacOSMovedToRetired() throws {
        let store = try fixture.store()
        let primary = try CrashReportSamples.write(
            CrashReportSamples.ips(), named: "Tecolot-2026-11-15-100000.ips", in: store.primaryDirectory
        )
        let report = try #require(try store.list().reports.first)
        let retired = store.directories[1].appendingPathComponent(primary.lastPathComponent)
        try FileManager.default.moveItem(at: primary, to: retired)

        #expect(try store.currentURL(of: report).standardizedFileURL == retired.standardizedFileURL)
        #expect(try store.loadReport(report).header.incidentID == report.id)
    }

    @Test func aFolderThatCannotBeReadGivesAPartialListing() throws {
        let store = try fixture.store()
        try CrashReportSamples.write(CrashReportSamples.ips(), named: "Tecolot-a.ips", in: store.primaryDirectory)
        try CrashReportSamples.write(CrashReportSamples.ips(), named: "Tecolot-b.ips", in: store.directories[1])
        let defaults = fixture.defaults()
        let seen = CrashReportSeenState(defaults: defaults)
        seen.markSeen(try store.list())
        #expect((defaults.object(forKey: CrashReportSeenState.key) as? [String])?.count == 2)

        let retired = store.directories[1]
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: retired.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: retired.path) }
        let partial = try store.list()
        #expect(!partial.isComplete)
        #expect(partial.reports.count == 1)

        // The seen ID of the report in Retired stays.
        seen.markSeen(partial)
        #expect((defaults.object(forKey: CrashReportSeenState.key) as? [String])?.count == 2)
    }

    @Test func doesNotReadAFIFO() throws {
        let store = try fixture.store()
        let url = try CrashReportSamples.write(
            CrashReportSamples.ips(), named: "Tecolot-2026-11-15-100000.ips", in: store.primaryDirectory
        )
        let report = try #require(try store.list().reports.first)
        try FileManager.default.removeItem(at: url)
        #expect(mkfifo(url.path, 0o600) == 0)

        // A FIFO with no writer would block a plain read.
        #expect(throws: (any Error).self) { try store.loadReport(report) }
        #expect(throws: CrashReportStoreError.unsafeFile) { try CrashReportStore.readRegularFile(url) }
        #expect(throws: CrashReportStoreError.unsafeFile) { try CrashReportStore.readHeaderLine(url) }
    }

    @Test func readsOnlyTheHeaderLine() throws {
        let directory = fixture.directory()
        let incident = UUID().uuidString
        let text = CrashReportSamples.ips(incident: incident)
        let url = try CrashReportSamples.write(text, named: "Tecolot-2026-11-15-100000.ips", in: directory)
        let line = try CrashReportStore.readHeaderLine(url)
        let expected = text.prefix { $0 != "\n" } + "\n"
        #expect(line == Data(expected.utf8))
        #expect(try DiagnosticReport.parseHeader(line).header.incidentID == incident)

        // A first line longer than the limit is not a report.
        let long = try CrashReportSamples.write(
            String(repeating: "x", count: CrashReportStore.maximumHeaderSize + 10),
            named: "Tecolot-long.ips", in: directory
        )
        #expect(throws: CrashReportStoreError.notACrashReport) { try CrashReportStore.readHeaderLine(long) }
    }

    @Test func doesNotFollowASymbolicLink() throws {
        let store = try fixture.store()
        let target = try CrashReportSamples.write(CrashReportSamples.ips(), named: "target.ips", in: fixture.directory("Other"))
        let link = store.primaryDirectory.appendingPathComponent("Tecolot-2026-11-15-100000.ips")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let listing = try store.list()
        #expect(listing.reports.isEmpty)
        #expect(listing.damaged.count == 1)
    }

    @Test func listingSeesAChangedFile() throws {
        let store = try fixture.store()
        let url = try CrashReportSamples.write(
            CrashReportSamples.ips(version: "1.2"), named: "Tecolot-2026-11-15-100000.ips", in: store.primaryDirectory
        )
        #expect(try store.list().reports.first?.appVersion == "1.2")
        try Data(CrashReportSamples.ips(version: "1.30").utf8).write(to: url)
        #expect(try store.list().reports.first?.appVersion == "1.30")
    }
}
