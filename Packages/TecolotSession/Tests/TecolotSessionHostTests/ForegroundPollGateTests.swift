import Foundation
import Testing
import TecolotWire
@testable import TecolotSessionHost

struct ForegroundPollGateTests {
    private func observe(_ gate: inout ForegroundPollGate, _ mark: String) {
        gate.observe(osc133: Array(mark.utf8))
    }

    @Test func untrustedGatePermitsEachPoll() {
        var gate = ForegroundPollGate()
        // A shell that sends only prompt marks.
        observe(&gate, "A")
        gate.record(idle: true)
        #expect(gate.shouldProbe())
    }

    @Test func pollsContinueUntilOnlyTheShellIsFound() {
        var gate = ForegroundPollGate()
        observe(&gate, "C")
        gate.record(idle: true)
        #expect(gate.shouldProbe())
        observe(&gate, "A")
        // The prompt runs starship, or a background job is still running.
        gate.record(idle: false)
        #expect(gate.shouldProbe())
        gate.record(idle: true)
        #expect(!gate.shouldProbe())
        observe(&gate, "B")
        #expect(!gate.shouldProbe())
        observe(&gate, "C;cmdline=vim")
        #expect(gate.shouldProbe())
        gate.record(idle: true)
        #expect(gate.shouldProbe())
    }

    @Test func aPollThatIsNotRecordedDoesNotCount() {
        var gate = ForegroundPollGate()
        observe(&gate, "C")
        observe(&gate, "D;0")
        // A cancelled poll: shouldProbe alone does not settle the gate.
        #expect(gate.shouldProbe())
        #expect(gate.shouldProbe())
        gate.record(idle: true)
        #expect(!gate.shouldProbe())
    }

    @Test func nestedShellKeepsThePollsGoing() {
        var gate = ForegroundPollGate()
        observe(&gate, "C")
        // The outer shell runs bash; the inner bash sends only A.
        observe(&gate, "A")
        gate.record(idle: false)
        #expect(gate.shouldProbe())
    }

    @Test func screenSwitchArmsTheGate() {
        var gate = ForegroundPollGate()
        observe(&gate, "C")
        observe(&gate, "A")
        gate.record(idle: true)
        #expect(!gate.shouldProbe())
        // Ctrl-X Ctrl-E starts an editor with no C mark.
        gate.arm()
        #expect(gate.shouldProbe())
    }

    @Test func resetForgetsTheMarks() {
        var gate = ForegroundPollGate()
        observe(&gate, "C")
        observe(&gate, "A")
        gate.record(idle: true)
        gate.reset()
        observe(&gate, "A")
        gate.record(idle: true)
        #expect(gate.shouldProbe())
    }
}

struct SessionInfoPollTests {
    private func probes(_ host: SessionHost) -> Int {
        host.queue.sync {
            host.infoProbes
        }
    }

    private func infoCount(_ client: TestClient) -> Int {
        client.state.withLock {
            $0.events.filter {
                $0.kind == .sessionInfo
            }.count
        }
    }

    private func firstInfo(_ client: TestClient) async throws {
        try await client.wait("session info", timeout: 5) {
            self.infoCount($0) > 0
        }
    }

    @Test func clientCanStopAndRestartThePoll() async throws {
        let host = makeHost(executable: "/bin/sh", arguments: ["-c", "sleep 30"])
        try host.start()
        let client = try TestClient(host: host, capabilities: [.infoReports])
        defer { client.close() }
        try await firstInfo(client)
        client.channel.send(SetInfoReportsMessage(mode: .off))
        try await Task.sleep(for: .milliseconds(300))
        let stopped = probes(host)
        try await Task.sleep(for: .milliseconds(2200))
        #expect(probes(host) == stopped)

        // The information did not change, but a restart sends it again.
        let count = infoCount(client)
        client.channel.send(SetInfoReportsMessage(mode: .live))
        try await client.wait("session info again", timeout: 2) {
            self.infoCount($0) > count
        }
        host.terminate(signal: SIGKILL)
    }

    @Test func backgroundModePollsSlowly() async throws {
        let host = makeHost(executable: "/bin/sh", arguments: ["-c", "sleep 30"])
        try host.start()
        let client = try TestClient(host: host, capabilities: [.infoReports])
        defer { client.close() }
        try await firstInfo(client)
        client.channel.send(SetInfoReportsMessage(mode: .background))
        try await Task.sleep(for: .milliseconds(300))
        let start = probes(host)
        try await Task.sleep(for: .milliseconds(3000))
        // Live mode would poll three times; background mode at most once.
        #expect(probes(host) - start <= 1)
        host.terminate(signal: SIGKILL)
    }

    @Test func detachedSessionPollsAgain() async throws {
        let host = makeHost(executable: "/bin/sh", arguments: ["-c", "sleep 30"])
        try host.start()
        let client = try TestClient(host: host, capabilities: [.infoReports])
        try await firstInfo(client)
        client.channel.send(SetInfoReportsMessage(mode: .off))
        try await Task.sleep(for: .milliseconds(300))
        let stopped = probes(host)
        client.channel.send(DetachMessage())
        // The detached timer polls at once, then every five seconds.
        try await Task.sleep(for: .milliseconds(700))
        #expect(probes(host) > stopped)
        client.close()
        host.terminate(signal: SIGKILL)
    }

    @Test func clientThatTurnsReportsOnGetsCurrentInformation() async throws {
        let host = makeHost(executable: "/bin/sh", arguments: ["-c", "sleep 30"])
        try host.start()
        let live = try TestClient(host: host, capabilities: [.infoReports])
        defer { live.close() }
        try await firstInfo(live)
        let other = try TestClient(host: host, capabilities: [.infoReports])
        defer { other.close() }
        try await firstInfo(other)
        other.channel.send(SetInfoReportsMessage(mode: .off))
        try await Task.sleep(for: .milliseconds(300))
        let count = infoCount(other)
        // The other client keeps the timer running, so it does not restart.
        other.channel.send(SetInfoReportsMessage(mode: .live))
        try await other.wait("current information", timeout: 2) {
            self.infoCount($0) > count
        }
        host.terminate(signal: SIGKILL)
    }

    @Test func promptMarksSkipPollsOnlyWhenTheShellIsIdle() async throws {
        let host = makeHost(executable: "/bin/sh", arguments: ["-c", "sleep 30"])
        try host.start()
        let client = try TestClient(host: host)
        defer { client.close() }
        try await firstInfo(client)
        host.inject("\u{1b}]133;C\u{7}")
        host.inject("\u{1b}]133;A\u{7}")
        // One poll finds only the shell (sh runs sleep with exec), then none.
        try await Task.sleep(for: .milliseconds(1600))
        let atPrompt = probes(host)
        try await Task.sleep(for: .milliseconds(2200))
        #expect(probes(host) == atPrompt)

        host.inject("\u{1b}]133;C\u{7}")
        try await Task.sleep(for: .milliseconds(2200))
        #expect(probes(host) > atPrompt)
        host.terminate(signal: SIGKILL)
    }

    @Test func promptWithAChildKeepsPolling() async throws {
        let host = makeHost(executable: "/bin/sh", arguments: ["-c", "sleep 30 & wait"])
        try host.start()
        let client = try TestClient(host: host)
        defer { client.close() }
        try await firstInfo(client)
        host.inject("\u{1b}]133;C\u{7}")
        host.inject("\u{1b}]133;A\u{7}")
        try await Task.sleep(for: .milliseconds(1600))
        let atPrompt = probes(host)
        try await Task.sleep(for: .milliseconds(2200))
        #expect(probes(host) > atPrompt)
        host.terminate(signal: SIGKILL)
    }
}
