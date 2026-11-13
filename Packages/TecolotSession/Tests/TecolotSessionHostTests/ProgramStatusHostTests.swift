import Foundation
import SwiftTerm
import Testing
import TecolotWire
@testable import TecolotSessionHost

struct ProgramStatusHostTests {
    @Test func hidingFramesDoesNotReplayVisibleOutputAsUnseenActivity() async throws {
        let host = makeHost()
        let client = try TestClient(host: host, capabilities: [.programStatus, .statusOnly])
        defer { client.close() }
        try await client.wait("initial status") {
            $0.latestProgramStatus != nil
        }
        host.inject("already visible")
        try await client.waitForScreen(containing: "already visible")
        let count = client.programStatusCount
        client.channel.send(SetFrameRateMessage(0))
        // More than one activity interval: a stale-feed snapshot would arrive here.
        try await Task.sleep(for: .milliseconds(350))
        #expect(client.programStatusCount == count)
        host.inject("new hidden output")
        try await client.wait("new hidden activity") {
            $0.programStatusCount > count
        }
        #expect(client.latestProgramStatus?.outputSerial ?? 0 > 0)
    }

    @Test func attachAtZeroEstablishesAnOutputBaselineOnce() async throws {
        let host = makeHost()
        host.inject("before attach")
        let client = try TestClient(host: host, frameRate: 0, capabilities: [.programStatus, .statusOnly])
        defer { client.close() }
        try await client.wait("baseline") {
            $0.latestProgramStatus != nil
        }
        let count = client.programStatusCount
        let baseline = client.latestProgramStatus?.outputSerial
        try await Task.sleep(for: .milliseconds(350))
        #expect(client.programStatusCount == count)
        host.inject("after attach")
        try await client.wait("new serial") {
            $0.latestProgramStatus?.outputSerial != baseline
        }
        #expect(client.frameCount == 0)
    }

    @Test func repeatedProgressDoesNotBumpStatusVersion() {
        let host = makeHost()
        host.progressReport(source: host.terminal, report: .init(state: .set, progress: 20))
        let version = host.events.withLock {
            $0.programStatusVersion
        }
        host.progressReport(source: host.terminal, report: .init(state: .set, progress: 20))
        #expect(host.events.withLock {
            $0.programStatusVersion
        } == version)
        host.progressReport(source: host.terminal, report: .init(state: .set, progress: 21))
        #expect(host.events.withLock {
            $0.programStatusVersion
        } == version + 1)
    }

    @Test func progressOnlyChangesCoalesceButStateChangesAreImmediate() async throws {
        let host = makeHost()
        let client = try TestClient(host: host, frameRate: 0, capabilities: [.programStatus, .statusOnly])
        defer { client.close() }
        host.inject("\u{1b}]7501;state=working:progress=1\u{7}")
        try await client.wait("working") {
            $0.latestProgramStatus?.records.first?.progress == 1
        }
        let count = client.programStatusCount
        for value in 2...80 {
            host.inject("\u{1b}]7501;state=working:progress=\(value)\u{7}")
        }
        host.inject("\u{1b}]7501;state=blocked:kind=permission\u{7}")
        try await client.wait("urgent blocked bypasses progress throttle") {
            $0.latestProgramStatus?.records.first?.state == .blocked
        }
        #expect(client.programStatusCount <= count + 2, "Native snapshots: \(client.state.withLock { $0.events.filter { $0.kind == .programStatus }.compactMap { try? $0.decode(ProgramStatusMessage.self) } })")
        host.inject("\u{1b}]9;4;1;10\u{7}")
        try await client.wait("fallback working") {
            $0.latestProgramStatus?.progress?.progress == 10
        }
        let fallbackCount = client.programStatusCount
        for value in 11...90 {
            host.inject("\u{1b}]9;4;1;\(value)\u{7}")
        }
        host.inject("\u{1b}]9;4;2\u{7}")
        try await client.wait("fallback error bypasses throttle") {
            $0.latestProgramStatus?.progress?.state == 2
        }
        #expect(client.programStatusCount <= fallbackCount + 2)
    }

    @Test func statusOnlyAttachHasNoFramesAndResumes() async throws {
        let host = makeHost()
        let client = try TestClient(host: host, frameRate: 0, capabilities: [.programStatus, .statusOnly])
        defer { client.close() }
        host.inject("hidden output\u{1b}]7501;state=blocked:kind=permission\u{7}")
        try await client.wait("blocked status without frames") {
            $0.latestProgramStatus?.records.first?.state == .blocked
        }
        #expect(client.frameCount == 0)
        host.inject("\u{1b}]9;4;1;40\u{7}\u{1b}]777;notify;Title;Body\u{7}")
        try await client.wait("notification without frames") {
            $0.state.withLock {
                $0.events.contains {
                    $0.kind == .notification
                }
            }
        }
        #expect(client.frameCount == 0)
        client.channel.send(SetFrameRateMessage(60))
        try await client.waitForScreen(containing: "hidden output")
        #expect(client.frameCount > 0)
    }

    @Test func fallbackErrorSurvivesPromptAndExitUntilSeenKeypress() async throws {
        let host = makeHost()
        let client = try TestClient(host: host, frameRate: 0, capabilities: [.programStatus, .statusOnly])
        defer { client.close() }
        host.inject("\u{1b}]9;4;2\u{7}")
        try await client.wait("fallback error") {
            $0.latestProgramStatus?.progress?.state == 2
        }
        let time = try #require(client.latestProgramStatus?.progressReportTime)
        host.inject("\u{1b}]133;A\u{7}output")
        host.processTerminated(host.process, exitCode: 0)
        try await client.wait("exit event") {
            $0.state.withLock {
                $0.events.contains {
                    $0.kind == .processExited
                }
            }
        }
        #expect(client.latestProgramStatus?.progress?.state == 2)
        #expect(client.latestProgramStatus?.progressReportTime == time)
        client.channel.send(ClearProgramStatusMessage(records: [WireProgramStatus(state: .error, reportTime: time)]))
        try await client.wait("seen fallback cleared") {
            $0.latestProgramStatus?.progress == nil
        }
    }

    @Test func lateAttachGetsStableTimesAndOldClientsGetNoNewMessages() async throws {
        let host = makeHost()
        host.inject("\u{1b}]7501;state=done:id=build\u{7}")
        let first = try TestClient(host: host, capabilities: [.programStatus])
        defer { first.close() }
        try await first.wait("first snapshot") {
            $0.latestProgramStatus?.records.count == 1
        }
        let second = try TestClient(host: host, capabilities: [.programStatus])
        let old = try TestClient(host: host)
        defer { second.close()
            old.close()
        }
        try await second.wait("second snapshot") {
            $0.latestProgramStatus?.records.count == 1
        }
        try await old.wait("old client frame") {
            $0.frameCount > 0
        }
        #expect(first.latestProgramStatus?.records == second.latestProgramStatus?.records)
        #expect(old.latestProgramStatus == nil)
        let records = try #require(second.latestProgramStatus?.records)
        second.channel.send(ClearProgramStatusMessage(records: records))
        try await second.wait("seen completion removed") {
            $0.latestProgramStatus?.records.isEmpty == true
        }
    }

    @Test func promptAndExitDropIdleWorkingAndBlockedButKeepCompletions() async throws {
        let host = makeHost()
        let client = try TestClient(host: host, capabilities: [.programStatus])
        defer { client.close() }
        for state in ProgramStatusState.allCases {
            host.inject("\u{1b}]7501;state=\(state.rawValue):id=\(state.rawValue)\u{7}")
        }
        try await client.wait("all records") {
            $0.latestProgramStatus?.records.count == 5
        }
        host.inject("\u{1b}]133;A\u{7}")
        try await client.wait("prompt cleanup") {
            $0.latestProgramStatus?.records.count == 2
        }
        #expect(Set(client.latestProgramStatus?.records.map(\.state) ?? []) == [.done, .error])
        for state in [ProgramStatusState.idle, .working, .blocked] {
            host.inject("\u{1b}]7501;state=\(state.rawValue):id=\(state.rawValue)\u{7}")
        }
        try await client.wait("new active records") {
            $0.latestProgramStatus?.records.count == 5
        }
        host.processTerminated(host.process, exitCode: 0)
        try await client.wait("exit cleanup") {
            $0.latestProgramStatus?.records.count == 2
        }
        #expect(Set(client.latestProgramStatus?.records.map(\.state) ?? []) == [.done, .error])
        let tracker = ProgramStatusTracker()
        let terminal = Terminal(delegate: LineTableTests.Quiet())
        terminal.feed(text: "\u{1b}]7501;state=idle\u{7}")
        tracker.receive(terminal.programStatusRecords)
        tracker.dropTransient()
        #expect(tracker.snapshot.records.isEmpty)
        terminal.feed(text: "\u{1b}]7501;state=done\u{7}")
        tracker.receive(terminal.programStatusRecords)
        tracker.dropTransient()
        #expect(tracker.snapshot.records.first?.state == .done)
    }

    @Test func validatedReportCannotRearmWorkingAfterProcessExit() {
        let tracker = ProgramStatusTracker()
        let terminal = Terminal(delegate: LineTableTests.Quiet())
        terminal.feed(text: "\u{1b}]7501;state=working:id=work\u{7}\u{1b}]7501;state=done:id=done\u{7}")
        let records = terminal.programStatusRecords
        tracker.receive(records)
        // An OSC observer can validate first, then race with the exit callback.
        tracker.processExited()
        tracker.receive(records, isReport: false)
        tracker.rearmReport(id: "work", touchReport: false)
        #expect(tracker.snapshot.records.map(\.state) == [.done])
    }

    @Test func risResetsFallbackButScreenSwitchAndSoftResetDoNot() {
        let tracker = ProgramStatusTracker(), terminal = Terminal(delegate: LineTableTests.Quiet())
        tracker.initializeBuffer(terminal)
        terminal.feed(text: "\u{1b}]7501;state=working\u{7}")
        tracker.receive(terminal.programStatusRecords)
        terminal.feed(text: "\u{1b}[?1049h")
        tracker.bufferActivated(terminal)
        terminal.feed(text: "\u{1b}[?1049l")
        #expect(!tracker.bufferActivated(terminal))
        terminal.feed(text: "\u{1b}[!p")
        #expect(tracker.snapshot.uses7501)
        terminal.feed(text: "\u{1b}c")
        #expect(tracker.bufferActivated(terminal))
        #expect(tracker.snapshot.records.isEmpty && !tracker.snapshot.uses7501 && tracker.snapshot.resetSerial == 1)
        terminal.feed(text: "\u{1b}]7501;state=idle:app=claude-code\u{7}\u{1b}]7501;state=done:id=child\u{7}")
        tracker.receive(terminal.programStatusRecords)
        #expect(tracker.snapshot.records.last?.app == "claude-code")
        tracker.dropTransient()
        #expect(tracker.snapshot.records.last?.app == nil)
    }

    /// A view may not receive a normal-buffer callback before its first RIS.
    private final class LazyResetDelegate: TerminalDelegate {
        let tracker = ProgramStatusTracker()
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
        func bufferActivated(source: Terminal) {
            tracker.bufferActivated(source)
        }
    }

    @Test(arguments: [false, true])
    func lazyBufferDiscoveryRecognizesRISOnce(startAlternate: Bool) {
        let delegate = LazyResetDelegate()
        let terminal = Terminal(delegate: delegate)
        if startAlternate {
            terminal.feed(text: "\u{1b}[?1049h\u{1b}[?1049l")
            #expect(delegate.tracker.snapshot.resetSerial == 0)
        }
        delegate.tracker.progress(WireProgress(state: 1, progress: 20))
        terminal.feed(text: "\u{1b}c")
        #expect(delegate.tracker.snapshot.resetSerial == 1)
        #expect(delegate.tracker.snapshot.progress == nil)
        delegate.tracker.progress(WireProgress(state: 1, progress: 30))
        terminal.feed(text: "\u{1b}[?1049h\u{1b}[?1049l")
        #expect(delegate.tracker.snapshot.resetSerial == 1)
        #expect(delegate.tracker.snapshot.progress?.progress == 30)
        terminal.feed(text: "\u{1b}c")
        #expect(delegate.tracker.snapshot.resetSerial == 2)
    }

    @Test func swiftTermLimitsAndLRUAtThePin() {
        let terminal = Terminal(delegate: LineTableTests.Quiet())
        func report(_ payload: String) {
            terminal.feed(text: "\u{1b}]7501;" + payload + "\u{7}")
        }
        for invalid in [
            "state=paused",
            "state=working:msg=Cg==",
            "state=working:msg=____",
            "state=working:id=a//b",
            "state=working:id=" + String(repeating: "a", count: 33),
            "state=working:id=a/b/c/d/e/f/g/h/i",
            "state=working:msg=" + String(repeating: "A", count: 2733),
            "state=working:title=" + String(repeating: "A", count: 257),
            "state=working:app=" + String(repeating: "a", count: 33),
            "state=working:" + String(repeating: "a", count: 17) + "=x",
            "state=working:msg=YQ=",
            "state=working:" + String(repeating: "x", count: 5000)
        ] {
            report(invalid)
            #expect(terminal.programStatusRecords.isEmpty, "\(invalid.prefix(80))")
        }
        for index in 0..<256 {
            report("state=done:id=r\(index)")
        }
        report("state=done:id=r0")
        for index in 256..<300 {
            report("state=done:id=r\(index)")
        }
        #expect(terminal.programStatusRecords.count == 256)
        #expect(terminal.programStatus(id: "r0") != nil && terminal.programStatus(id: "r1") == nil)
    }
}

private extension TestClient {
    var programStatusCount: Int {
        state.withLock {
            $0.events.filter {
                $0.kind == .programStatus
            }.count
        }
    }
    var latestProgramStatus: ProgramStatusMessage? {
        state.withLock { state in
            state.events.last(where: {
                $0.kind == .programStatus
            }).flatMap {
                try? $0.decode(ProgramStatusMessage.self)
            }
        }
    }
}
