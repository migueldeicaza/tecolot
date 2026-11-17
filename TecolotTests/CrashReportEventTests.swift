import Foundation
import Testing
@testable import Tecolot

struct CrashReportEventTests {
    private static let eventID = "c00b20dd0f094d1b9cdb9609ff5e3c40"

    private static func report(_ text: String = CrashReportSamples.ips()) throws -> DiagnosticReport {
        try DiagnosticReport(data: Data(text.utf8))
    }

    private static func event() throws -> [String: Any] {
        CrashReportEvent.event(for: try report(), eventID: eventID)
    }

    @Test func rejectsReportsThatAreNotCrashes() {
        #expect(throws: CrashReportStoreError.otherKind) {
            try DiagnosticReport(data: Data(CrashReportSamples.ips(bugType: "288").utf8))
        }
        #expect(throws: CrashReportStoreError.notACrashReport) {
            try DiagnosticReport(data: Data("{}".utf8))
        }
        #expect(throws: CrashReportStoreError.notACrashReport) {
            try DiagnosticReport(data: Data("{\"incident_id\":\"not a uuid\",\"bug_type\":\"309\"}\n{}".utf8))
        }
    }

    @Test func eventHasTheReleaseAndContexts() throws {
        let event = try Self.event()
        #expect(event["event_id"] as? String == Self.eventID)
        #expect(event["release"] as? String == "com.tirania.Tecolot@1.2+34")
        #expect(event["dist"] as? String == "34")
        #expect(event["level"] as? String == "fatal")
        let tags = try #require(event["tags"] as? [String: String])
        #expect(tags["macos_version"] == "27.0.1")
        #expect(tags["arch"] == "arm64")
        let contexts = try #require(event["contexts"] as? [String: Any])
        let os = try #require(contexts["os"] as? [String: Any])
        #expect(os["build"] as? String == "26A434")
        let device = try #require(contexts["device"] as? [String: Any])
        #expect(device["model"] as? String == "Mac15,14")
    }

    @Test func exceptionHasTheCrashedThreadAndMessages() throws {
        let event = try Self.event()
        let exception = try #require(((event["exception"] as? [String: Any])?["values"] as? [[String: Any]])?.first)
        #expect(exception["type"] as? String == "EXC_BAD_ACCESS")
        #expect(exception["value"] as? String
            == "SIGSEGV: KERN_INVALID_ADDRESS at 0x0000000000000010 — Fatal error: Index out of range")
        #expect(exception["thread_id"] as? Int == 1)
        let meta = try #require((exception["mechanism"] as? [String: Any])?["meta"] as? [String: Any])
        let mach = try #require(meta["mach_exception"] as? [String: Any])
        #expect(mach["exception"] as? Int == 1)
        #expect(mach["subcode"] as? UInt64 == 16)
        #expect((meta["signal"] as? [String: Any])?["number"] as? Int64 == 11)
        let frames = try #require((exception["stacktrace"] as? [String: Any])?["frames"] as? [[String: Any]])
        #expect(frames.count == 2)
    }

    @Test func framesAreOldestFirstWithAbsoluteAddresses() throws {
        let event = try Self.event()
        let threads = try #require((event["threads"] as? [String: Any])?["values"] as? [[String: Any]])
        #expect(threads.count == 2)
        #expect(threads[0]["name"] as? String == "com.apple.main-thread")
        #expect(threads[1]["crashed"] as? Bool == true)
        let stacktrace = try #require(threads[1]["stacktrace"] as? [String: Any])
        #expect(stacktrace["instruction_addr_adjustment"] as? String == "all_but_first")
        let frames = try #require(stacktrace["frames"] as? [[String: Any]])
        // The inline frame is not sent. The crashing frame is last.
        #expect(frames.map { $0["function"] as? String } == ["main", "crash()"])
        #expect(frames[0]["instruction_addr"] as? String == CrashReportEvent.hex(4_296_998_912 + 512))
        #expect(frames[1]["instruction_addr"] as? String == CrashReportEvent.hex(4_326_850_560 + 4096))
        #expect(frames[1]["symbol_addr"] as? String == CrashReportEvent.hex(4_326_850_560 + 4096 - 16))
        // Both images are in the app bundle.
        #expect(frames.allSatisfy { $0["in_app"] as? Bool == true })
        let mainThreadFrames = try #require((threads[0]["stacktrace"] as? [String: Any])?["frames"] as? [[String: Any]])
        #expect(mainThreadFrames.first?["in_app"] as? Bool == false)
    }

    @Test func debugImagesAreOnlyTheUsedImages() throws {
        let event = try Self.event()
        let images = try #require((event["debug_meta"] as? [String: Any])?["images"] as? [[String: Any]])
        #expect(images.map { $0["code_file"] as? String } == [
            "/Users/USER/*/Tecolot.app/Contents/MacOS/Tecolot",
            "/Users/USER/*/Tecolot.app/Contents/Frameworks/SwiftTerm.framework/SwiftTerm",
            "/usr/lib/system/libsystem_kernel.dylib"
        ])
        #expect(images[0]["debug_id"] as? String == "ae22159d-0a95-3f8c-8737-f533cf93799d")
        #expect(images[0]["type"] as? String == "macho")
        #expect(images[0]["image_size"] as? UInt64 == 16384)
    }

    @Test func eventHasNoRegistersOrIdentifiers() throws {
        let envelope = try CrashReportEvent.envelope(
            for: try Self.report(), eventID: Self.eventID, clientVersion: "1.2"
        )
        let text = try #require(String(data: envelope, encoding: .utf8))
        for forbidden in [
            "threadState", "4242", "18446744073709551569", "crashReporterKey", "E9800B4C",
            "B0DDA00D", "instructionByteStream", "wANf1g", "vmSummary", "Writable regions"
        ] {
            #expect(!text.contains(forbidden), "The envelope contains \(forbidden)")
        }
    }

    @Test func envelopeHasOneEventItemWithTheRightLength() throws {
        let envelope = try CrashReportEvent.envelope(
            for: try Self.report(), eventID: Self.eventID, clientVersion: "1.2"
        )
        let lines = envelope.split(separator: 0x0A, omittingEmptySubsequences: false)
        #expect(lines.count == 4)
        #expect(lines[3].isEmpty)
        let header = try #require(try JSONSerialization.jsonObject(with: Data(lines[0])) as? [String: Any])
        #expect(header["event_id"] as? String == Self.eventID)
        let item = try #require(try JSONSerialization.jsonObject(with: Data(lines[1])) as? [String: Any])
        #expect(item["type"] as? String == "event")
        #expect(item["length"] as? Int == lines[2].count)
        let event = try #require(try JSONSerialization.jsonObject(with: Data(lines[2])) as? [String: Any])
        #expect(event["event_id"] as? String == Self.eventID)
    }

    @Test func redactsTheHomeFolder() {
        let home = NSHomeDirectory()
        #expect(CrashReportEvent.redactHome(home + "/Applications/Tecolot.app") == "~/Applications/Tecolot.app")
        #expect(CrashReportEvent.redactHome("/Applications/Tecolot.app") == "/Applications/Tecolot.app")
    }

    @Test func readsUnsignedValuesAboveInt64Max() throws {
        let text = CrashReportSamples.ips().replacingOccurrences(
            of: "\"rawCodes\":[1,16]", with: "\"rawCodes\":[1,18446744073709551600]"
        )
        let report = try Self.report(text)
        #expect(report.exception?.rawCodes == [1, 18_446_744_073_709_551_600])
        #expect(DiagnosticReport.unsigned(NSNumber(value: UInt64.max)) == UInt64.max)
        #expect(DiagnosticReport.unsigned(NSNumber(value: -1)) == nil)
        #expect(DiagnosticReport.unsigned(NSNumber(value: true)) == nil)
    }

    @Test func redactsTheHomeFolderInAllText() throws {
        let home = NSHomeDirectory()
        let text = CrashReportSamples.ips()
            .replacingOccurrences(of: "Fatal error: Index out of range", with: "Cannot open \(home)/notes.txt")
            .replacingOccurrences(of: "\"name\":\"worker\"", with: "\"name\":\"\(home)/thread\"")
        let envelope = try CrashReportEvent.envelope(for: try Self.report(text), eventID: Self.eventID, clientVersion: "1.2")
        let body = try #require(String(data: envelope, encoding: .utf8))
        #expect(!body.contains(home + "/"))
        #expect(body.contains("Cannot open ~/notes.txt"))
        #expect(body.contains("~/thread"))
    }

    @Test func redactsOnlyWholePathComponents() {
        #expect(CrashReportEvent.redactHome("/Users/ann/a and /Users/anna/b", home: "/Users/ann") == "~/a and /Users/anna/b")
        #expect(CrashReportEvent.redactHome("at /Users/ann.", home: "/Users/ann") == "at /Users/ann.")
        #expect(CrashReportEvent.redactHome("in /Users/ann: no", home: "/Users/ann") == "in ~: no")
    }

    @Test func exceptionBacktraceAdjustsAllFrames() throws {
        let text = CrashReportSamples.ips().replacingOccurrences(
            of: "\"vmSummary\"",
            with: "\"lastExceptionBacktrace\" : [{\"imageOffset\":100,\"symbol\":\"objc_exception_throw\",\"imageIndex\":3}],\n  \"vmSummary\""
        )
        let event = CrashReportEvent.event(for: try Self.report(text), eventID: Self.eventID)
        let exception = try #require(((event["exception"] as? [String: Any])?["values"] as? [[String: Any]])?.first)
        let stacktrace = try #require(exception["stacktrace"] as? [String: Any])
        #expect(stacktrace["instruction_addr_adjustment"] as? String == "all")
        #expect((stacktrace["frames"] as? [[String: Any]])?.first?["function"] as? String == "objc_exception_throw")
    }
}
