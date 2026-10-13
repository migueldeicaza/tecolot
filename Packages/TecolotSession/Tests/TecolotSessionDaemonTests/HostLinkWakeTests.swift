#if canImport(Darwin)
import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing
import TecolotSessionClient
import TecolotSessionDirectory
import TecolotTransport

private enum HostWakeError: Error { case timeout(String) }

private func wakeWait(_ name: String, _ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw HostWakeError.timeout(name)
}

private final class WakeQueueProbe: @unchecked Sendable {
    let key = DispatchSpecificKey<Bool>()
    init(_ queue: DispatchQueue) { queue.setSpecific(key: key, value: true) }
    var isOnQueue: Bool { DispatchQueue.getSpecific(key: key) == true }
}

private func connectedWakeLink(_ fixture: HostFaultFixture) async throws -> HostLink {
    var configuration = fixture.configuration
    configuration.backoffSchedule = [2]
    let link = HostLink(destination: "fault-host", configuration: configuration,
                        askpassServer: fixture.server)
    fixture.track(link)
    let probe = WakeQueueProbe(link.queue)
    link.onStateChange = { _ in #expect(probe.isOnQueue) }
    link.confirmInstall = { _, _, reply in
        #expect(probe.isOnQueue)
        reply(true)
    }
    let result = Mutex<Result<[SessionRecord], Error>?>(nil)
    link.retain()
    link.listSessions { value in
        #expect(probe.isOnQueue)
        result.withLock { $0 = value }
    }
    try await faultWait("initial wake-test connection") { result.withLock { $0 != nil } }
    #expect(try result.withLock { $0! }.get().isEmpty)
    return link
}

struct HostLinkWakeTests {
    @Test func idleWakeDoesNotStartSSH() async throws {
        let fixture = try HostFaultFixture()
        defer { fixture.cleanup() }
        let link = HostLink(destination: "fault-host", configuration: fixture.configuration,
                            askpassServer: fixture.server)
        fixture.track(link)
        let states = Mutex<[String]>([])
        let probe = WakeQueueProbe(link.queue)
        link.onStateChange = { state in
            #expect(probe.isOnQueue)
            states.withLock { $0.append(String(describing: state)) }
        }

        link.checkLiveness()
        link.queue.sync {}
        try await Task.sleep(for: .milliseconds(100))

        if case .idle = link.state {} else { Issue.record("An idle wake started a connection") }
        #expect(states.withLock { $0.isEmpty })
        #expect(fixture.log.isEmpty)
        #expect(fixture.masterPIDs.isEmpty)
        #expect(link.masterProcessIdentifier == nil)
        #expect(link.bridgeProcessIdentifier == nil)
    }

    @Test func bridgeWakeKeepsMasterAndCancelsScheduledRetry() async throws {
        let fixture = try HostFaultFixture()
        defer { fixture.cleanup() }
        let link = try await connectedWakeLink(fixture)
        let masterPID = try #require(link.masterProcessIdentifier)
        let bridgePID = try #require(link.bridgeProcessIdentifier)
        let generation = link.connectionGeneration
        let resolves = fixture.log.filter { $0 == "resolve" }.count

        #expect(kill(bridgePID, SIGTERM) == 0)
        try await faultWait("bridge retry scheduled") {
            if case .reconnecting(attempt: 1, nextRetry: _) = link.state { return true }
            return false
        }
        guard case .reconnecting(_, let nextRetry) = link.state else {
            Issue.record("The bridge drop did not schedule a retry")
            return
        }
        link.checkLiveness()
        try await wakeWait("bridge retry after wake") { link.connectionGeneration == generation + 1 }

        #expect(Date() < nextRetry)
        #expect(link.masterProcessIdentifier == masterPID)
        #expect(kill(masterPID, 0) == 0)
        #expect(link.bridgeProcessIdentifier != bridgePID)
        #expect(fixture.log.filter { $0 == "master" }.count == 1)
        #expect(fixture.log.filter { $0 == "resolve" }.count == resolves)
        let callsAfterWake = fixture.log
        let remaining = nextRetry.timeIntervalSinceNow + 0.2
        if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
        link.queue.sync {}
        #expect(link.connectionGeneration == generation + 1)
        #expect(fixture.log == callsAfterWake)
        #expect(link.masterProcessIdentifier == masterPID)
    }

    @Test func failedWakeRetryKeepsAttemptCount() async throws {
        let fixture = try HostFaultFixture()
        defer { fixture.cleanup() }
        let link = try await connectedWakeLink(fixture)
        let bridgePID = try #require(link.bridgeProcessIdentifier)
        let generation = link.connectionGeneration
        #expect(kill(bridgePID, SIGTERM) == 0)
        try await faultWait("first bridge retry scheduled") {
            if case .reconnecting(attempt: 1, nextRetry: _) = link.state { return true }
            return false
        }
        try Data().write(to: fixture.stateDirectory.appendingPathComponent("fail-next-bridge"))

        link.checkLiveness()
        try await wakeWait("second retry attempt") {
            if case .reconnecting(attempt: 2, nextRetry: _) = link.state { return true }
            return false
        }
        #expect(link.connectionGeneration == generation)
        #expect(fixture.log.filter { $0 == "master" }.count == 1)
    }

    @Test func masterWakeStartsLoginBeforeScheduledRetry() async throws {
        let fixture = try HostFaultFixture()
        defer { fixture.cleanup() }
        let link = try await connectedWakeLink(fixture)
        let masterPID = try #require(link.masterProcessIdentifier)
        let generation = link.connectionGeneration
        let controlPath = try SSHCommandLine.controlSocketPath(runtimeDirectory: fixture.appRuntime,
                                                               configuration: fixture.resolved)
        unlink(controlPath)
        #expect(kill(masterPID, SIGTERM) == 0)
        try await faultWait("master retry scheduled") {
            if case .reconnecting(attempt: 1, nextRetry: _) = link.state { return true }
            return false
        }
        guard case .reconnecting(_, let nextRetry) = link.state else {
            Issue.record("The master drop did not schedule a retry")
            return
        }

        link.checkLiveness()
        try await wakeWait("master retry after wake") { link.connectionGeneration == generation + 1 }
        #expect(Date() < nextRetry)
        #expect(link.masterProcessIdentifier != masterPID)
        #expect(fixture.log.filter { $0 == "master" }.count == 2)
    }
}
#endif
