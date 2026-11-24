import Foundation
import Testing
import TecolotWire
@testable import TecolotSessionHost

struct ForegroundPollGateTests {
    @Test func initialProbeSettlesWhenQuiet() {
        let base = ContinuousClock.now
        var gate = ForegroundPollGate(settleWindow: .milliseconds(500))
        #expect(gate.schedule == .immediate)
        #expect(gate.shouldProbe)

        let token = gate.beginProbe(at: base)
        gate.record(token)
        #expect(gate.schedule == .idle)
        #expect(!gate.shouldProbe)
    }

    @Test func activityArmsAndSettlesOnceQuietForSettleWindow() {
        let base = ContinuousClock.now
        var gate = ForegroundPollGate(settleWindow: .milliseconds(500))
        gate.record(gate.beginProbe(at: base))
        #expect(gate.schedule == .idle)

        gate.noteActivity(at: base + .seconds(1))
        #expect(gate.schedule == .active)

        // Probe runs 1s after activity (>= 500ms settle window): settles in one probe.
        let token = gate.beginProbe(at: base + .seconds(2))
        gate.record(token)
        #expect(gate.schedule == .idle)
    }

    @Test func recentActivityBeforeProbeRequiresSettleProbe() {
        let base = ContinuousClock.now
        var gate = ForegroundPollGate(settleWindow: .milliseconds(500))
        gate.record(gate.beginProbe(at: base))

        // Typing starts at t=1.0s, Enter echoes at t=1.99s, armed timer fires at t=2.0s.
        gate.noteActivity(at: base + .seconds(1))
        gate.noteActivity(at: base + .milliseconds(1990))
        let early = gate.beginProbe(at: base + .seconds(2))
        gate.record(early)
        // Elapsed since last activity is only 10ms (< 500ms): keep one follow-up probe.
        #expect(gate.schedule == .active)

        // Follow-up probe at t=3.0s sees 1.01s of quiet and settles.
        let settle = gate.beginProbe(at: base + .seconds(3))
        gate.record(settle)
        #expect(gate.schedule == .idle)
    }

    @Test func activityDuringInFlightProbePreventsSettling() {
        let base = ContinuousClock.now
        var gate = ForegroundPollGate(settleWindow: .milliseconds(500))
        gate.record(gate.beginProbe(at: base))

        gate.noteActivity(at: base + .seconds(1))
        let inFlight = gate.beginProbe(at: base + .seconds(2))
        // New output arrives before the async probe records its result.
        gate.noteActivity(at: base + .milliseconds(2050))
        gate.record(inFlight)
        #expect(gate.schedule == .active)

        let next = gate.beginProbe(at: base + .seconds(3))
        gate.record(next)
        #expect(gate.schedule == .idle)
    }

    @Test func cancelledProbeDoesNotSettleTheGate() {
        let base = ContinuousClock.now
        var gate = ForegroundPollGate(settleWindow: .milliseconds(500))
        gate.noteActivity(at: base)
        _ = gate.beginProbe(at: base + .seconds(1))
        #expect(gate.schedule == .immediate)
        gate.record(gate.beginProbe(at: base + .seconds(1)))
        #expect(gate.schedule == .idle)
    }

    @Test func backgroundChildrenUseFallbackUntilCleared() {
        let base = ContinuousClock.now
        var gate = ForegroundPollGate(settleWindow: .milliseconds(500))
        gate.noteActivity(at: base)
        gate.record(gate.beginProbe(at: base + .seconds(1)), hasBackgroundChildren: true)
        #expect(gate.schedule == .backgroundChildren)
        #expect(gate.shouldProbe)

        // New output upgrades from slow fallback back to active rate.
        gate.noteActivity(at: base + .seconds(2))
        #expect(gate.schedule == .active)
        gate.record(gate.beginProbe(at: base + .seconds(3)), hasBackgroundChildren: true)
        #expect(gate.schedule == .backgroundChildren)

        // Once the background child exits, the gate goes completely idle.
        gate.record(gate.beginProbe(at: base + .seconds(8)), hasBackgroundChildren: false)
        #expect(gate.schedule == .idle)
    }

    @Test func immediateRequestDuringInFlightProbeIsNotCleared() {
        let base = ContinuousClock.now
        var gate = ForegroundPollGate(settleWindow: .milliseconds(500))
        let first = gate.beginProbe(at: base)
        gate.requestImmediateProbe()
        gate.record(first)
        #expect(gate.schedule == .immediate)

        let second = gate.beginProbe(at: base + .milliseconds(10))
        gate.record(second)
        #expect(gate.schedule == .idle)
    }

    @Test func resetRequestsImmediateProbeAndClearsBackgroundChildren() {
        let base = ContinuousClock.now
        var gate = ForegroundPollGate(settleWindow: .milliseconds(500))
        gate.record(gate.beginProbe(at: base), hasBackgroundChildren: true)
        #expect(gate.schedule == .backgroundChildren)

        gate.reset()
        #expect(gate.schedule == .immediate)
        gate.record(gate.beginProbe(at: base + .seconds(1)))
        #expect(gate.schedule == .idle)
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

    private func lastInfo(_ client: TestClient) -> SessionInfoMessage? {
        client.state.withLock { state in
            guard let envelope = state.events.last(where: { $0.kind == .sessionInfo }) else {
                return nil
            }
            return try? envelope.decode(SessionInfoMessage.self)
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
        defer { host.terminate(signal: SIGKILL) }
        let client = try TestClient(host: host, capabilities: [.infoReports])
        defer { client.close() }
        try await firstInfo(client)
        client.channel.send(SetInfoReportsMessage(mode: .off))
        try await Task.sleep(for: .milliseconds(300))
        let stopped = probes(host)
        host.inject("output while off\r\n")
        try await Task.sleep(for: .milliseconds(1600))
        #expect(probes(host) == stopped)

        // Turning reports back on delivers info immediately and re-probes.
        let count = infoCount(client)
        client.channel.send(SetInfoReportsMessage(mode: .live))
        try await client.wait("session info again", timeout: 2) {
            self.infoCount($0) > count
        }
        #expect(probes(host) > stopped)
    }

    @Test func backgroundModePollsSlowlyDuringOutput() async throws {
        let host = makeHost(executable: "/bin/sh", arguments: ["-c", "sleep 30"])
        try host.start()
        defer { host.terminate(signal: SIGKILL) }
        let client = try TestClient(host: host, capabilities: [.infoReports])
        defer { client.close() }
        try await firstInfo(client)
        // Let the initial launch settle before switching to background mode.
        try await Task.sleep(for: .milliseconds(1600))
        client.channel.send(SetInfoReportsMessage(mode: .background))
        try await Task.sleep(for: .milliseconds(300))
        let start = probes(host)
        // Drive continuous output for 3 seconds: live mode would poll ~3 times,
        // background mode (5s) polls 0 times (at most 1).
        for _ in 0..<10 {
            host.inject(".")
            try await Task.sleep(for: .milliseconds(300))
        }
        #expect(probes(host) - start <= 1)
    }

    @Test func detachedSessionPollsAgain() async throws {
        let host = makeHost(executable: "/bin/sh", arguments: ["-c", "sleep 30"])
        try host.start()
        defer { host.terminate(signal: SIGKILL) }
        let client = try TestClient(host: host, capabilities: [.infoReports])
        defer { client.close() }
        try await firstInfo(client)
        client.channel.send(SetInfoReportsMessage(mode: .off))
        try await Task.sleep(for: .milliseconds(300))
        let stopped = probes(host)
        client.channel.send(DetachMessage())
        // Re-enabling on detach probes immediately.
        try await Task.sleep(for: .milliseconds(700))
        #expect(probes(host) > stopped)
    }

    @Test func clientThatTurnsReportsOnGetsCurrentInformation() async throws {
        let host = makeHost(executable: "/bin/sh", arguments: ["-c", "sleep 30"])
        try host.start()
        defer { host.terminate(signal: SIGKILL) }
        let live = try TestClient(host: host, capabilities: [.infoReports])
        defer { live.close() }
        try await firstInfo(live)
        let other = try TestClient(host: host, capabilities: [.infoReports])
        defer { other.close() }
        try await firstInfo(other)
        other.channel.send(SetInfoReportsMessage(mode: .off))
        try await Task.sleep(for: .milliseconds(300))
        let count = infoCount(other)
        // The other client keeps reporting enabled, so this sends cached info.
        other.channel.send(SetInfoReportsMessage(mode: .live))
        try await other.wait("current information", timeout: 2) {
            self.infoCount($0) > count
        }
    }

    @Test func quietProcessStopsPollingAndOutputRearmsIt() async throws {
        // No OSC 133 marks: a quiet process still stops polling after settling.
        let host = makeHost(executable: "/bin/sh", arguments: ["-c", "sleep 30"])
        try host.start()
        defer { host.terminate(signal: SIGKILL) }
        let client = try TestClient(host: host)
        defer { client.close() }
        try await firstInfo(client)
        // Allow the initial settle probe (~1s after start) to complete.
        try await Task.sleep(for: .milliseconds(1600))
        let settled = probes(host)
        try await Task.sleep(for: .milliseconds(2200))
        #expect(probes(host) == settled)

        // Output re-arms the probe for the live delay, then settles again.
        host.inject("hello\r\n")
        try await Task.sleep(for: .milliseconds(1600))
        let afterOutput = probes(host)
        #expect(afterOutput > settled)
        try await Task.sleep(for: .milliseconds(2200))
        #expect(probes(host) == afterOutput)
    }

    @Test func inputRearmsQuietSessionWithoutOutput() async throws {
        // Disable PTY echo so the sent byte produces no PTY output.
        let host = makeHost(executable: "/bin/sh", arguments: ["-c", "stty -echo && exec sleep 30"])
        try host.start()
        defer { host.terminate(signal: SIGKILL) }
        let client = try TestClient(host: host)
        defer { client.close() }
        try await firstInfo(client)
        try await Task.sleep(for: .milliseconds(1600))
        let settled = probes(host)
        let feedBefore = host.feedSequence.load(ordering: .acquiring)

        // Even with no PTY output, user input re-arms polling.
        client.channel.send(InputMessage(bytes: [0x00]))
        try await Task.sleep(for: .milliseconds(1600))
        #expect(host.feedSequence.load(ordering: .acquiring) == feedBefore)
        let afterInput = probes(host)
        #expect(afterInput > settled)
        try await Task.sleep(for: .milliseconds(2200))
        #expect(probes(host) == afterInput)
    }

    @Test func backgroundChildUsesFallbackAndStopsWhenChildExits() async throws {
        // `read` is a shell builtin, so once `sleep 2` exits silently in the
        // background, the foreground shell has no children and produces no output.
        let host = makeHost(executable: "/bin/sh", arguments: ["-c", "sleep 2 & while read line; do :; done"])
        host.queue.sync {
            host.infoFallbackSeconds = 1
        }
        try host.start()
        defer { host.terminate(signal: SIGKILL) }
        let client = try TestClient(host: host)
        defer { client.close() }
        try await firstInfo(client)
        try await client.wait("background child detected", timeout: 3) {
            self.lastInfo($0)?.hasChildren == true
        }
        // Fallback detects the silent background exit and clears hasChildren.
        try await client.wait("background child exited", timeout: 5) {
            self.lastInfo($0)?.hasChildren == false
        }
        let afterExit = probes(host)
        try await Task.sleep(for: .milliseconds(2200))
        #expect(probes(host) == afterExit)
    }
}
