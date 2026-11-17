import Foundation
import Testing
import TecolotWire
@testable import TecolotTransport
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private final class LinkEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var closeCount = 0
    private var closeError: Error?
    private var elapsed: TimeInterval?
    func close(_ error: Error?) { lock.withLock { closeCount += 1; closeError = error } }
    func ping(_ result: Result<TimeInterval, Error>) { lock.withLock { elapsed = try? result.get() } }
    var closed: Bool { lock.withLock { closeCount > 0 } }
    var closures: Int { lock.withLock { closeCount } }
    var error: Error? { lock.withLock { closeError } }
    var roundTrip: TimeInterval? { lock.withLock { elapsed } }
}

private func linkSocketPair() throws -> (Int32, Int32) {
    var fds: [Int32] = [-1, -1]
    #if canImport(Darwin)
    let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
    #elseif canImport(Glibc)
    let result = socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds)
    #endif
    guard result == 0 else { throw TransportError("socketpair") }
    for fd in fds {
        UnixSocket.setNonBlocking(fd)
        UnixSocket.setNoSignalOnBrokenPipe(fd)
        UnixSocket.setCloseOnExec(fd)
    }
    return (fds[0], fds[1])
}

private func waitLink(_ condition: () -> Bool, timeout: TimeInterval = 5) async throws {
    let end = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= end { throw TransportError("test timeout", code: ETIMEDOUT) }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

private func writeLinkBytes(_ fd: Int32, _ bytes: [UInt8], timeout: TimeInterval = 20) async throws {
    var offset = 0
    let end = Date().addingTimeInterval(timeout)
    while offset < bytes.count {
        try Task.checkCancellation()
        let count = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, min(64 * 1024, $0.count - offset)) }
        if count > 0 { offset += count }
        else if count < 0 && errno == EINTR { continue }
        else if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK { throw TransportError("test write") }
        else {
            if Date() >= end { throw TransportError("write timeout", code: ETIMEDOUT) }
            try await Task.sleep(nanoseconds: 100_000)
        }
    }
}

private func readLinkBytes(_ fd: Int32, count expected: Int, timeout: TimeInterval = 20) async throws -> [UInt8] {
    var result: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    let end = Date().addingTimeInterval(timeout)
    while result.count < expected {
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, min($0.count, expected - result.count)) }
        if count > 0 { result.append(contentsOf: buffer.prefix(count)) }
        else if count == 0 { throw TransportError("unexpected test EOF", code: ECONNRESET) }
        else if errno == EINTR { continue }
        else if errno != EAGAIN && errno != EWOULDBLOCK { throw TransportError("test read") }
        else {
            if Date() >= end { throw TransportError("read timeout", code: ETIMEDOUT) }
            try await Task.sleep(nanoseconds: 100_000)
        }
    }
    return result
}

private func waitLinkEOF(_ fd: Int32) async throws {
    try await waitLink {
        var byte: UInt8 = 0
        let count = read(fd, &byte, 1)
        return count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
    }
}

private func endpointPair(window: UInt64 = 32 * 1024) throws -> (LinkEndpoint, LinkEndpoint) {
    let (a, b) = try linkSocketPair()
    return (LinkEndpoint(readFD: a, writeFD: a, receiveWindow: window, peerReceiveWindow: window),
            LinkEndpoint(readFD: b, writeFD: b, receiveWindow: window, peerReceiveWindow: window))
}

private func channelPair(_ a: LinkEndpoint, _ b: LinkEndpoint, channel: UInt64,
                         window: UInt64 = 32 * 1024) throws -> (Int32, Int32) {
    let (left, boundA) = try linkSocketPair()
    let (right, boundB) = try linkSocketPair()
    a.bindChannel(channel, descriptor: boundA, receiveWindow: window, sendWindow: window)
    b.bindChannel(channel, descriptor: boundB, receiveWindow: window, sendWindow: window)
    return (left, right)
}

struct LinkEndpointTests {
    @Test func disconnectedSocketWritesDoNotRaiseSIGPIPE() throws {
        var fds: [Int32] = [-1, -1]
        #if canImport(Darwin)
        let status = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        #elseif canImport(Glibc)
        let status = socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds)
        #endif
        guard status == 0 else { throw TransportError("socketpair") }
        close(fds[1])
        defer { close(fds[0]) }
        // No descriptor option was set before the peer closed. This write
        // must use MSG_NOSIGNAL: Darwin now refuses to change the option.
        var byte: UInt8 = 42
        let count = posixWrite(fds[0], &byte, 1)
        #expect(count == -1)
        #expect(errno == EPIPE)
    }

    @Test func brokenPipeWritesDoNotRaiseSIGPIPE() throws {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw TransportError("pipe") }
        close(fds[0])
        defer { close(fds[1]) }
        UnixSocket.setNoSignalOnBrokenPipe(fds[1])
        var byte: UInt8 = 42
        let count = posixWrite(fds[1], &byte, 1)
        #expect(count == -1)
        #expect(errno == EPIPE)
    }

    @Test func eightMegabytesAreIntactAndWindowIsBounded() async throws {
        let (a, b) = try endpointPair()
        let (left, right) = try channelPair(a, b, channel: 1)
        defer { a.close(); b.close(); close(left); close(right) }
        a.start(); b.start()
        var state: UInt64 = 0x5f3a6c91
        let payload = (0 ..< 8 * 1024 * 1024).map { _ -> UInt8 in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: state >> 32)
        }
        async let send: Void = writeLinkBytes(left, payload)
        let output = try await readLinkBytes(right, count: payload.count)
        try await send
        #expect(output == payload)
        let reply = Array("both directions".utf8)
        try await writeLinkBytes(right, reply)
        #expect(try await readLinkBytes(left, count: reply.count) == reply)
        #expect(a.counters.maxUnacknowledgedBytesObserved <= 32 * 1024)
        #expect(a.counters.maxUnacknowledgedBytesObserved > 0)
        #expect(a.counters.bytesSent[1] == UInt64(payload.count))
        #expect(b.counters.bytesReceived[1] == UInt64(payload.count))
    }

    @Test func blockedChannelDoesNotStopAnotherChannel() async throws {
        let (a, b) = try endpointPair()
        let (flood, boundA) = try linkSocketPair()
        let (unread, boundB) = try linkSocketPair()
        var size: Int32 = 4096
        _ = setsockopt(boundB, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        a.bindChannel(1, descriptor: boundA, receiveWindow: 32 * 1024, sendWindow: 32 * 1024)
        b.bindChannel(1, descriptor: boundB, receiveWindow: 32 * 1024, sendWindow: 32 * 1024)
        let (left, right) = try channelPair(a, b, channel: 2)
        defer { a.close(); b.close(); close(flood); close(unread); close(left); close(right) }
        a.start(); b.start()
        // The group waits for the writer to stop before any descriptor is closed.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                do { try await writeLinkBytes(flood, [UInt8](repeating: 0x5a, count: 8 * 1024 * 1024)) }
                catch is CancellationError { }
            }
            defer { group.cancelAll() }
            try await waitLink { (b.counters.bytesReceived[1] ?? 0) >= 32 * 1024 }
            let text = Array("channel two remains usable".utf8)
            try await writeLinkBytes(left, text)
            #expect(try await readLinkBytes(right, count: text.count, timeout: 2) == text)
            let events = LinkEvents()
            a.ping(nonce: 42) { events.ping($0) }
            try await waitLink { events.roundTrip != nil }
            #expect(a.maxUnacknowledgedBytesObserved <= 32 * 1024)
        }
    }

    @Test func smallWindowAndDelayedAcknowledgementMakeProgress() async throws {
        let (a, b) = try endpointPair(window: 127)
        let (left, right) = try channelPair(a, b, channel: 1, window: 71)
        defer { a.close(); b.close(); close(left); close(right) }
        a.start(); b.start()
        let payload = [UInt8](repeating: 0xef, count: 3000)
        async let send: Void = writeLinkBytes(left, payload)
        #expect(try await readLinkBytes(right, count: payload.count) == payload)
        try await send
        #expect(a.maxUnacknowledgedBytesObserved <= 127)
        try await waitLink { a.counters.unacknowledgedBytes == 0 }
        // One byte is below the quarter-window ACK threshold. Its timer must free credit.
        try await writeLinkBytes(left, [42])
        #expect(try await readLinkBytes(right, count: 1) == [42])
        try await waitLink({ a.counters.unacknowledgedBytes == 0 }, timeout: 0.5)
        try await writeLinkBytes(left, [UInt8](repeating: 7, count: 127))
        #expect(try await readLinkBytes(right, count: 127) == [UInt8](repeating: 7, count: 127))
    }

    @Test func closeDrainsDataAndPropagatesEOF() async throws {
        let (a, b) = try endpointPair()
        let (left, right) = try channelPair(a, b, channel: 1)
        defer { a.close(); b.close(); close(right) }
        a.start(); b.start()
        let payload = Array("bytes before EOF".utf8)
        try await writeLinkBytes(left, payload)
        close(left)
        #expect(try await readLinkBytes(right, count: payload.count) == payload)
        try await waitLinkEOF(right)
    }

    @Test func linkCloseClosesAllLocalChannelsExactlyOnce() async throws {
        let (a, b) = try endpointPair()
        let (left, right) = try channelPair(a, b, channel: 1)
        let (otherLeft, otherRight) = try channelPair(a, b, channel: 2)
        defer { close(left); close(right); close(otherLeft); close(otherRight) }
        let eventsA = LinkEvents(), eventsB = LinkEvents()
        a.onClose = { eventsA.close($0) }; b.onClose = { eventsB.close($0) }
        a.start(); b.start()
        a.close(); a.close()
        try await waitLink { eventsA.closed && eventsB.closed }
        for fd in [left, right, otherLeft, otherRight] { try await waitLinkEOF(fd) }
        #expect(eventsA.closures == 1)
        #expect(eventsB.closures == 1)
        b.close()
    }

    @Test func markerSkipsStartupLinesAndPingReportsRoundTrip() async throws {
        let (aFD, bFD) = try linkSocketPair()
        try await writeLinkBytes(bFD, Array("startup output\nTECOLOT-BRIDGE 1 wrong\n".utf8))
        let a = LinkEndpoint(readFD: aFD, writeFD: aFD, expectedNonce: "1234")
        let b = LinkEndpoint(readFD: bFD, writeFD: bFD, startNonce: "1234")
        defer { a.close(); b.close() }
        let inbox = Inbox(), events = LinkEvents()
        a.onControl = { inbox.add($0) }
        a.start(); b.start()
        b.sendControl(TextMessage(text: "ready"), requestID: 9)
        let messages = try await inbox.wait(for: 1)
        #expect(try messages[0].decode(TextMessage.self).text == "ready")
        a.ping(nonce: 19) { events.ping($0) }
        try await waitLink { events.roundTrip != nil }
        #expect(try #require(events.roundTrip) >= 0)
        #expect(a.lastByteReceived <= ProcessInfo.processInfo.systemUptime)
    }

    @Test func markerLimitAndMalformedFramesCloseWithErrors() async throws {
        let (fd, raw) = try linkSocketPair()
        let endpoint = LinkEndpoint(readFD: fd, writeFD: fd, expectedNonce: "missing")
        let events = LinkEvents()
        endpoint.onClose = { events.close($0) }
        endpoint.start()
        defer { endpoint.close(); close(raw) }
        try await writeLinkBytes(raw, [UInt8](repeating: 65, count: 64 * 1024 + 1))
        try await waitLink { events.closed }
        #expect(events.error != nil)

        let (fd2, raw2) = try linkSocketPair()
        let invalid = LinkEndpoint(readFD: fd2, writeFD: fd2)
        let invalidEvents = LinkEvents()
        invalid.onClose = { invalidEvents.close($0) }
        invalid.start()
        defer { invalid.close(); close(raw2) }
        try await writeLinkBytes(raw2, [0xff, 0xff, 0xff, 0x7f])
        try await waitLink { invalidEvents.closed }
        #expect(invalidEvents.error != nil)
    }

    @Test func channelsWaitForOpenAndSuspendedSourcesCanBeReleased() async throws {
        let (a, b) = try endpointPair()
        let (left, boundA) = try linkSocketPair()
        let (right, boundB) = try linkSocketPair()
        a.bindChannel(1, descriptor: boundA, sendWindow: 0)
        b.bindChannel(1, descriptor: boundB, sendWindow: 65536)
        defer { a.close(); b.close(); close(left); close(right) }
        a.start(); b.start()
        try await writeLinkBytes(left, [1, 2, 3])
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(a.counters.bytesSent[1] == nil)
        a.setChannelSendWindow(1, receiveWindow: 65536)
        #expect(try await readLinkBytes(right, count: 3) == [1, 2, 3])

        let (linkFD, linkPeer) = try linkSocketPair()
        let (local, bound) = try linkSocketPair()
        defer { close(linkPeer); close(local) }
        var released: LinkEndpoint? = LinkEndpoint(readFD: linkFD, writeFD: linkFD)
        released!.bindChannel(1, descriptor: bound)
        released!.queue.sync {}
        released = nil
        try await waitLinkEOF(local)
        try await waitLinkEOF(linkPeer)
    }

    @Test func pingHasPriorityOverOtherControlMessages() async throws {
        let (fd, raw) = try linkSocketPair()
        let endpoint = LinkEndpoint(readFD: fd, writeFD: fd)
        defer { endpoint.close(); close(raw) }
        endpoint.sendControl(TextMessage(text: "first"))
        endpoint.sendControl(TextMessage(text: "second"))
        endpoint.sendControl(PingMessage(nonce: 7))
        endpoint.start()
        let encodedPing = try LinkFrameCodec.encode(LinkFrame(channel: 0, payload: EnvelopeCodec.encode(PingMessage(nonce: 7))))
        let actual = try await readLinkBytes(raw, count: encodedPing.count)
        #expect(actual == encodedPing)
    }
}
