import Foundation
import Testing
import TecolotWire
@testable import TecolotTransport

/// Collects messages from a channel and lets a test wait for them.
final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var envelopes: [Envelope] = []
    private var closed = false

    func add(_ envelope: Envelope) { lock.withLock { envelopes.append(envelope) } }
    func markClosed() { lock.withLock { closed = true } }
    var isClosed: Bool { lock.withLock { closed } }
    var all: [Envelope] { lock.withLock { envelopes } }

    func wait(for count: Int, timeout: TimeInterval = 5) async throws -> [Envelope] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = all
            if current.count >= count { return current }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        Issue.record("timed out waiting for \(count) messages, got \(all.count)")
        return all
    }

    func waitClosed(timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isClosed { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        Issue.record("timed out waiting for close")
    }
}

func makePair() throws -> (MessageChannel, Inbox, MessageChannel, Inbox) {
    var fds: [Int32] = [0, 0]
    #if canImport(Darwin)
    let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
    #else
    let result = socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds)
    #endif
    guard result == 0 else { throw TransportError("socketpair") }
    func make(_ fd: Int32) -> (MessageChannel, Inbox) {
        let channel = MessageChannel(socket: fd)
        let inbox = Inbox()
        channel.onMessage = { inbox.add($0) }
        channel.onClose = { _ in inbox.markClosed() }
        channel.start()
        return (channel, inbox)
    }
    let (a, inboxA) = make(fds[0])
    let (b, inboxB) = make(fds[1])
    return (a, inboxA, b, inboxB)
}

struct MessageChannelTests {
    @Test func messagesFlowBothWays() async throws {
        let (a, inboxA, b, inboxB) = try makePair()
        a.send(TextMessage(text: "to b"))
        b.send(TextMessage(text: "to a"), requestID: 5)
        let atB = try await inboxB.wait(for: 1)
        let atA = try await inboxA.wait(for: 1)
        #expect(try atB[0].decode(TextMessage.self).text == "to b")
        #expect(try atA[0].decode(TextMessage.self).text == "to a")
        #expect(atA[0].requestID == 5)
        a.close()
        try await inboxB.waitClosed()
        b.close()
    }

    @Test func largeMessagesArriveIntact() async throws {
        let (a, _, b, inboxB) = try makePair()
        let payload = (0 ..< 3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        a.send(InputMessage(bytes: payload))
        a.send(PingMessage(nonce: 1))
        let received = try await inboxB.wait(for: 2, timeout: 10)
        #expect(try received[0].decode(InputMessage.self).bytes == payload)
        #expect(received[1].kind == .ping)
        a.close()
        b.close()
    }

    @Test func interactiveMessagesGoBeforeQueuedBulk() async throws {
        let (a, _, b, inboxB) = try makePair()
        // Queue everything in one turn of the channel queue, before any flush.
        let gate = DispatchSemaphore(value: 0)
        a.queue.async { gate.wait() }
        for index in 0 ..< 5 {
            a.send(PingMessage(nonce: UInt64(index)), priority: .bulk)
        }
        a.send(TextMessage(text: "urgent"), priority: .interactive)
        gate.signal()
        let received = try await inboxB.wait(for: 6)
        // The channel writes as soon as it can, so the first bulk message may
        // already be on the wire; the interactive one must beat the rest.
        let position = try #require(received.firstIndex { $0.kind == .text })
        #expect(position <= 1)
        a.close()
        b.close()
    }

    @Test func drainedFiresWhenQueuesEmpty() async throws {
        let (a, _, b, _) = try makePair()
        let drained = Inbox()
        a.queue.sync {
            a.onDrained = { drained.markClosed() }
        }
        a.send(PingMessage(nonce: 3), priority: .bulk)
        try await drained.waitClosed()
        a.close()
        b.close()
    }

    @Test func malformedInputClosesTheChannel() async throws {
        var fds: [Int32] = [0, 0]
        #if canImport(Darwin)
        _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        #else
        _ = socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds)
        #endif
        let channel = MessageChannel(socket: fds[0], maximumMessageSize: 1024)
        let inbox = Inbox()
        channel.onClose = { _ in inbox.markClosed() }
        channel.start()
        // A length prefix far above the maximum.
        var bytes: [UInt8] = [0xff, 0xff, 0xff, 0x7f, 1, 0]
        _ = write(fds[1], &bytes, bytes.count)
        try await inbox.waitClosed()
        close(fds[1])
    }

    @Test func closeAndReleaseEndThePeerConnection() async throws {
        let (a, _, b, inboxB) = try makePair()
        a.close()
        try await inboxB.waitClosed()
        b.close()
        var (c, _, d, inboxD): (MessageChannel?, Inbox, MessageChannel, Inbox) = try makePair()
        _ = c
        c = nil
        try await inboxD.waitClosed()
        d.close()
    }

    @Test func descriptorOwnerClosesAfterCancelHandlers() async throws {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        defer { close(fds[1]) }
        UnixSocket.setNoSignalOnBrokenPipe(fds[1])
        let queue = DispatchQueue(label: "descriptor-owner-test")
        let owner = DescriptorOwner(readFD: fds[0], writeFD: fds[0])
        let source = DispatchSource.makeReadSource(fileDescriptor: fds[0], queue: queue)
        owner.track(source)
        source.resume()
        let gate = DispatchSemaphore(value: 0)
        // The cancel handler cannot run until the gate opens.
        queue.async { gate.wait() }
        source.cancel()
        owner.close(on: queue)
        // A write to the pipe works only while its read end is open.
        var byte: UInt8 = 1
        #expect(write(fds[1], &byte, 1) == 1)
        gate.signal()
        let deadline = Date().addingTimeInterval(5)
        var closed = false
        while !closed && Date() < deadline {
            closed = write(fds[1], &byte, 1) < 0 && errno == EPIPE
            if !closed { try await Task.sleep(nanoseconds: 2_000_000) }
        }
        #expect(closed)
    }
}

struct SocketTests {
    @Test func listenerAcceptsSameUserConnections() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tt-\(UInt32.random(in: 0 ... .max))", isDirectory: true)
        try RuntimeDirectory.prepare(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path
        let accepted = Inbox()
        let queue = DispatchQueue(label: "listener")
        let channels = NSLock()
        nonisolated(unsafe) var serverChannels: [MessageChannel] = []
        let listener = try SocketListener(path: path, queue: queue) { fd in
            let channel = MessageChannel(socket: fd)
            channel.onMessage = { envelope in
                accepted.add(envelope)
                channel.send(PongMessage(nonce: 9))
            }
            channels.withLock { serverChannels.append(channel) }
            channel.start()
        }
        listener.start()

        let fd = try UnixSocket.connect(path: path)
        #expect(UnixSocket.peerUID(fd) == getuid())
        let client = MessageChannel(socket: fd)
        let replies = Inbox()
        client.onMessage = { replies.add($0) }
        client.start()
        client.send(PingMessage(nonce: 9))
        _ = try await accepted.wait(for: 1)
        let pong = try await replies.wait(for: 1)
        #expect(pong[0].kind == .pong)
        client.close()
        listener.stop()
    }

    @Test func runtimeDirectoryIsPrivate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rd-\(UInt32.random(in: 0 ... .max))", isDirectory: true)
        mkdir(directory.path, 0o755)
        defer { try? FileManager.default.removeItem(at: directory) }
        try RuntimeDirectory.prepare(directory)
        var status = stat()
        stat(directory.path, &status)
        #expect(status.st_mode & 0o777 == 0o700)
    }

    @Test func runtimeDirectoryRejectsSymlinks() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("rl-\(UInt32.random(in: 0 ... .max))", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: base)
        #expect(throws: TransportError.self) { try RuntimeDirectory.prepare(link) }
    }

    @Test func longSocketPathsAreRejected() {
        let path = "/tmp/" + String(repeating: "x", count: 200)
        #expect(throws: TransportError.self) { _ = try UnixSocket.listen(path: path) }
    }

    /// Writing to a peer that went away must close the channel, not raise
    /// SIGPIPE (which would end the app). Socket pairs get no SO_NOSIGPIPE.
    @Test func writingToAClosedPeerClosesWithoutSignal() async throws {
        var fds: [Int32] = [0, 0]
        #if canImport(Darwin)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw TransportError("socketpair") }
        #else
        guard socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds) == 0 else { throw TransportError("socketpair") }
        #endif
        close(fds[1])
        let channel = MessageChannel(socket: fds[0])
        let inbox = Inbox()
        channel.onClose = { _ in inbox.markClosed() }
        channel.start()
        channel.send(TextMessage(text: "nobody listens"))
        channel.queue.sync { channel.flushPending() }
        try await inbox.waitClosed()
    }
}
