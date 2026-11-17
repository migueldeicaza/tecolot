import Dispatch
import Foundation
import Synchronization
import Testing
import TecolotSessionClient
import TecolotSessionDirectory
import TecolotTransport
import TecolotWire
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private func linkSockets() throws -> [Int32] {
    var fds: [Int32] = [-1, -1]
    #if canImport(Darwin)
    let type = SOCK_STREAM
    #else
    let type = Int32(SOCK_STREAM.rawValue)
    #endif
    guard socketpair(AF_UNIX, type, 0, &fds) == 0 else { throw TransportError("socketpair") }
    return fds
}

/// Answers Hello. Gives other requests to `received` instead of an answer, when it is set.
private func testBridge(_ fd: Int32, received: (@Sendable (Envelope) -> Void)? = nil) -> LinkEndpoint {
    let endpoint = LinkEndpoint(readFD: fd, writeFD: fd, startNonce: "")
    endpoint.onControl = { [weak endpoint] envelope in
        if envelope.kind == .linkHello {
            endpoint?.sendControl(HelperInfoMessage(build: "test", os: "test", arch: "test", machineID: "test",
                                                    hostName: "test", runtimeDirectory: "/tmp", home: "/tmp",
                                                    shell: "/bin/sh", receiveWindow: 1024 * 1024), requestID: envelope.requestID)
        } else if let received {
            received(envelope)
        } else if envelope.kind == .listSessions {
            endpoint?.sendControl(SessionListMessage(json: Array("[]".utf8)), requestID: envelope.requestID)
        } else {
            endpoint?.sendControl(ErrorMessage(code: .unavailable, failedKind: envelope.kind,
                                                message: "test request failed"), requestID: envelope.requestID)
        }
    }
    endpoint.start()
    return endpoint
}

struct LinkClientTests {
    @Test func explicitLivenessPingReceivesPong() async throws {
        let fds = try linkSockets()
        let peer = testBridge(fds[1])
        defer { peer.close() }
        let client = LinkClient(readFD: fds[0], writeFD: fds[0], build: "test", clientName: "test")
        defer { client.close() }
        let result = Mutex<Result<TimeInterval, Error>?>(nil)
        client.start()
        client.checkLiveness(timeout: 0.1) { value in result.withLock { $0 = value } }
        try await eventually("explicit pong") { result.withLock { $0 != nil } }
        #expect(try result.withLock { $0! }.get() >= 0)
        #expect(!peer.isClosed)
    }

    @Test func explicitLivenessTimeoutClosesSilentLink() async throws {
        let fds = try linkSockets()
        defer { close(fds[1]) }
        let client = LinkClient(readFD: fds[0], writeFD: fds[0], build: "test", clientName: "test")
        defer { client.close() }
        let closed = Mutex(false)
        let result = Mutex<Result<TimeInterval, Error>?>(nil)
        client.onClose = { _ in closed.withLock { $0 = true } }
        client.start()
        client.checkLiveness(timeout: 0.02) { value in result.withLock { $0 = value } }
        try await eventually("liveness timeout") { result.withLock { $0 != nil } && closed.withLock { $0 } }
        #expect(throws: LinkClientError.self) { try result.withLock { $0! }.get() }
    }

    @Test func bytesAfterLivenessPingKeepLinkAlive() async throws {
        let fds = try linkSockets()
        defer { close(fds[1]) }
        let client = LinkClient(readFD: fds[0], writeFD: fds[0], build: "test", clientName: "test")
        defer { client.close() }
        let result = Mutex<Result<TimeInterval, Error>?>(nil)
        let closed = Mutex(false)
        client.onClose = { _ in closed.withLock { $0 = true } }
        client.start()
        client.checkLiveness(timeout: 0.1) { value in result.withLock { $0 = value } }
        // A partial frame proves that bytes can arrive before a complete Pong.
        try await Task.sleep(for: .milliseconds(20))
        var byte: UInt8 = 0
        #expect(write(fds[1], &byte, 1) == 1)
        try await eventually("received bytes") { result.withLock { $0 != nil } }
        #expect(try result.withLock { $0! }.get() >= 0)
        #expect(!closed.withLock { $0 })
    }

    @Test func keepaliveMeasuresRoundTrip() async throws {
        let fds = try linkSockets()
        let peer = testBridge(fds[1])
        defer { peer.close() }
        let client = LinkClient(readFD: fds[0], writeFD: fds[0], build: "test", clientName: "test")
        client.keepaliveInterval = 0.02
        client.receiveTimeout = 0.3
        client.start()
        defer { client.close() }
        try await eventually("keepalive round trip") { client.roundTripTime != nil }
        #expect(client.roundTripTime! >= 0)
        // Pongs keep the client alive past the receive timeout.
        try await Task.sleep(for: .milliseconds(350))
        #expect(!peer.isClosed)
    }

    @Test func receiveTimeoutFailsWaitingRequestsAndClosesSockets() async throws {
        let fds = try linkSockets()
        defer { close(fds[1]) }
        let client = LinkClient(readFD: fds[0], writeFD: fds[0], build: "test", clientName: "test")
        client.receiveTimeout = 0.05
        client.keepaliveInterval = 0.02
        let closeCount = Mutex(0)
        let closeError = Mutex<LinkClientError?>(nil)
        let listFailed = Mutex(false)
        let openFailed = Mutex(false)
        client.onClose = { error in
            closeCount.withLock { $0 += 1 }
            closeError.withLock { $0 = error as? LinkClientError }
        }
        client.listSessions { result in
            if case .failure = result { listFailed.withLock { $0 = true } }
        }
        let fd = client.openChannel(sessionID: "123abc") { result in
            if case .failure = result { openFailed.withLock { $0 = true } }
        }
        let session = RemoteSession(socket: fd, clientName: "test", build: "test")
        let sessionClosed = Mutex(false)
        session.onEvent = { event in
            if case .closed = event { sessionClosed.withLock { $0 = true } }
        }
        session.start(size: WireGridSize(columns: 20, rows: 5), focused: true)
        client.start()
        try await eventually("timeout callbacks") {
            closeCount.withLock { $0 } == 1 && listFailed.withLock { $0 } && openFailed.withLock { $0 }
                && sessionClosed.withLock { $0 }
        }
        if case .timedOut? = closeError.withLock({ $0 }) {} else { Issue.record("timeout error was not reported") }
        client.close()
        client.close()
        try await Task.sleep(for: .milliseconds(20))
        #expect(closeCount.withLock { $0 } == 1)
        session.close()
    }

    @Test func failedOpenClosesTheReturnedConnection() async throws {
        let fds = try linkSockets()
        let peer = testBridge(fds[1])
        defer { peer.close() }
        let client = LinkClient(readFD: fds[0], writeFD: fds[0], build: "test", clientName: "test")
        defer { client.close() }
        let failed = Mutex(false)
        let fd = client.openChannel(sessionID: "123abc") { result in
            if case .failure(let error) = result, let linkError = error as? LinkClientError, case .remote(let wireError) = linkError {
                failed.withLock { $0 = wireError.failedKind == .openChannel }
            }
        }
        let session = RemoteSession(socket: fd, clientName: "test", build: "test")
        defer { session.close() }
        let closed = Mutex(false)
        session.onEvent = { event in if case .closed = event { closed.withLock { $0 = true } } }
        session.start(size: WireGridSize(columns: 20, rows: 5), focused: true)
        client.start()
        try await eventually("open error and socket close") { failed.withLock { $0 } && closed.withLock { $0 } }
        let listed = Mutex(false)
        client.listSessions { result in
            if case .success(let records) = result { listed.withLock { $0 = records.isEmpty } }
        }
        try await eventually("list works after rejected open") { listed.withLock { $0 } }
        #expect(!peer.isClosed)
    }

    @Test(arguments: [true, false])
    func releasedClientFailsSentRequests(closeFirst: Bool) async throws {
        let fds = try linkSockets()
        let sent = Mutex(false)
        let peer = testBridge(fds[1]) { envelope in
            if envelope.kind == .listSessions { sent.withLock { $0 = true } }
        }
        defer { peer.close() }
        var client: LinkClient? = LinkClient(readFD: fds[0], writeFD: fds[0], build: "test", clientName: "test")
        let result = Mutex<Result<[SessionRecord], Error>?>(nil)
        client?.listSessions { value in result.withLock { $0 = value } }
        client?.start()
        try await eventually("list request sent") { sent.withLock { $0 } }
        // The owner of the link drops it while the request waits for its answer.
        if closeFirst { client?.close() }
        client = nil
        try await eventually("released request fails") { result.withLock { $0 != nil } }
        #expect(throws: LinkClientError.self) { try result.withLock { $0! }.get() }
    }
}
