//
// MessageChannel.swift
// TecolotTransport
//
// A framed, bidirectional message stream over file descriptors (a Unix
// socket, or stdin/stdout for the ssh bridge).
//
// All state lives on `queue`. The handlers run on `queue` as well.
//
// Writes have two priority classes. Interactive messages (frames, events,
// replies) always go before bulk messages (scrollback rows, text, search).
// A producer of bulk data waits for `onDrained` and then sends the next
// chunk, so that bulk data never sits in front of a frame.
//

import Foundation
import TecolotWire
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum MessagePriority: Sendable {
    case interactive
    case bulk
}

public final class MessageChannel: @unchecked Sendable {
    public let queue: DispatchQueue
    /// Marks `queue`, so that a sender that already runs on it can queue
    /// its message at once and in program order.
    private static let queueKey = DispatchSpecificKey<ObjectIdentifier>()

    /// Called for each complete message.
    public var onMessage: ((Envelope) -> Void)?
    /// Called once when the channel closes. The error is nil for a clean end of stream.
    public var onClose: ((Error?) -> Void)?
    /// Called when both write queues become empty.
    public var onDrained: (() -> Void)?

    private let readFD: Int32
    private let writeFD: Int32
    private let ownsDescriptors: Bool
    private let descriptors: DescriptorOwner
    private var decoder: EnvelopeStreamDecoder
    private var readSource: DispatchSourceRead?
    // Exists only while a write waits for the socket to become writable.
    // Dispatch sources must never be released while suspended, so this
    // source is created on demand and cancelled after it fires.
    private var writeSource: DispatchSourceWrite?
    private var interactive = WriteQueue()
    private var bulk = WriteQueue()
    private var current: [UInt8] = []
    private var currentOffset = 0
    private var started = false
    private var flushScheduled = false
    private var closed = false
    private var readBuffer = [UInt8](repeating: 0, count: 64 * 1024)

    /// Bytes queued for writing and not yet written.
    public private(set) var queuedBytes = 0

    public init(readFD: Int32, writeFD: Int32, ownsDescriptors: Bool = true,
                queue: DispatchQueue = DispatchQueue(label: "tecolot.channel"),
                maximumMessageSize: Int = 32 * 1024 * 1024) {
        self.readFD = readFD
        self.writeFD = writeFD
        self.ownsDescriptors = ownsDescriptors
        descriptors = DescriptorOwner(readFD: readFD, writeFD: writeFD)
        self.queue = queue
        decoder = EnvelopeStreamDecoder(maximumMessageSize: maximumMessageSize)
        queue.setSpecific(key: Self.queueKey, value: ObjectIdentifier(queue))
    }

    private var isOnQueue: Bool {
        DispatchQueue.getSpecific(key: Self.queueKey) == ObjectIdentifier(queue)
    }

    deinit {
        readSource?.cancel()
        writeSource?.cancel()
        if !closed && ownsDescriptors { descriptors.close(on: queue) }
    }

    /// A channel over one connected socket.
    public convenience init(socket fd: Int32, queue: DispatchQueue = DispatchQueue(label: "tecolot.channel"),
                            maximumMessageSize: Int = 32 * 1024 * 1024) {
        self.init(readFD: fd, writeFD: fd, queue: queue, maximumMessageSize: maximumMessageSize)
    }

    /// Starts reading. Set the handlers before calling this.
    public func start() {
        queue.async { self.startOnQueue() }
    }

    private func startOnQueue() {
        guard !started, !closed else { return }
        started = true
        UnixSocket.setNonBlocking(readFD)
        if writeFD != readFD { UnixSocket.setNonBlocking(writeFD) }
        UnixSocket.setNoSignalOnBrokenPipe(writeFD)

        let read = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: queue)
        read.setEventHandler { [weak self] in self?.readAvailable() }
        descriptors.track(read)
        readSource = read
        read.resume()
        if hasPendingWrites { flush() }
    }

    /// Encodes and queues `message`. Safe to call from any thread.
    public func send<M: WireMessage>(_ message: M, priority: MessagePriority = .interactive,
                                     flags: EnvelopeFlags = [], requestID: UInt64? = nil) {
        sendEncoded(EnvelopeCodec.encode(message, flags: flags, requestID: requestID), priority: priority)
    }

    /// Queues bytes that already hold one or more complete envelopes.
    public func sendEncoded(_ bytes: [UInt8], priority: MessagePriority = .interactive) {
        if isOnQueue {
            enqueue(bytes, priority: priority)
        } else {
            queue.async { self.enqueue(bytes, priority: priority) }
        }
    }

    /// Writes the queued messages now instead of on a later turn of the
    /// queue. For replies that the peer waits for, such as frame
    /// acknowledgements. Call only on `queue`.
    public func flushPending() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard started, writeSource == nil, hasPendingWrites else { return }
        flush()
    }

    /// Queues bytes; call only on `queue`.
    public func enqueue(_ bytes: [UInt8], priority: MessagePriority) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !closed, !bytes.isEmpty else { return }
        switch priority {
        case .interactive: interactive.append(bytes)
        case .bulk: bulk.append(bytes)
        }
        queuedBytes += bytes.count
        scheduleFlush()
    }

    /// Flushes on a later turn of the queue, so that messages queued in one
    /// burst are written in priority order and with fewer system calls.
    private func scheduleFlush() {
        guard started, !flushScheduled, writeSource == nil else { return }
        flushScheduled = true
        queue.async {
            self.flushScheduled = false
            self.flush()
        }
    }

    /// Closes the channel. Pending writes are dropped.
    public func close() {
        queue.async { self.finish(nil) }
    }

    /// Closes the channel after the queued writes are flushed.
    public func closeWhenDrained() {
        queue.async { [weak self] in
            guard let self else { return }
            if hasPendingWrites {
                let previous = onDrained
                onDrained = { [weak self] in
                    previous?()
                    self?.finish(nil)
                }
            } else {
                finish(nil)
            }
        }
    }

    public var isClosed: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return closed
    }

    private var hasPendingWrites: Bool {
        currentOffset < current.count || !interactive.isEmpty || !bulk.isEmpty
    }

    private func readAvailable() {
        guard !closed else { return }
        while true {
            let count = readBuffer.withUnsafeMutableBytes { buffer in
                posixRead(readFD, buffer.baseAddress, buffer.count)
            }
            if count > 0 {
                decoder.append(readBuffer[0 ..< count])
                do {
                    while let envelope = try decoder.next() {
                        onMessage?(envelope)
                        if closed { return }
                    }
                } catch {
                    finish(error)
                    return
                }
                if count < readBuffer.count { return }
            } else if count == 0 {
                finish(nil)
                return
            } else {
                switch errno {
                case EINTR: continue
                case EAGAIN, EWOULDBLOCK: return
                default:
                    finish(TransportError("read"))
                    return
                }
            }
        }
    }

    private func flush() {
        guard !closed else { return }
        while true {
            if currentOffset >= current.count {
                if let next = interactive.popFirst() ?? bulk.popFirst() {
                    current = next
                    currentOffset = 0
                } else {
                    current = []
                    currentOffset = 0
                    onDrained?()
                    return
                }
            }
            let written = current.withUnsafeBytes { buffer in
                posixWrite(writeFD, buffer.baseAddress! + currentOffset, buffer.count - currentOffset)
            }
            if written > 0 {
                currentOffset += written
                queuedBytes -= written
            } else if written < 0 {
                switch errno {
                case EINTR: continue
                case EAGAIN, EWOULDBLOCK:
                    waitForWritable()
                    return
                default:
                    finish(TransportError("write"))
                    return
                }
            }
        }
    }

    private func waitForWritable() {
        guard writeSource == nil else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: writeFD, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            writeSource?.cancel()
            writeSource = nil
            flush()
        }
        descriptors.track(source)
        writeSource = source
        source.resume()
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        readSource?.cancel()
        writeSource?.cancel()
        readSource = nil
        writeSource = nil
        interactive = WriteQueue()
        bulk = WriteQueue()
        current = []
        queuedBytes = 0
        if ownsDescriptors { descriptors.close(on: queue) }
        let handler = onClose
        onMessage = nil
        onDrained = nil
        onClose = nil
        handler?(error)
    }
}

/// A FIFO of byte arrays with amortized O(1) removal at the front.
struct WriteQueue {
    private var items: [[UInt8]] = []
    private var head = 0

    var isEmpty: Bool { head >= items.count }

    mutating func append(_ bytes: [UInt8]) {
        items.append(bytes)
    }

    mutating func popFirst() -> [UInt8]? {
        guard head < items.count else { return nil }
        let item = items[head]
        items[head] = []
        head += 1
        if head > 64 && head * 2 > items.count {
            items.removeSubrange(0 ..< head)
            head = 0
        }
        return item
    }
}

/// Accepts connections on a listening Unix socket. Connections from other
/// users are refused.
public final class SocketListener: @unchecked Sendable {
    public let path: String
    public let queue: DispatchQueue
    private let fd: Int32
    private var source: DispatchSourceRead?
    private let onConnection: (Int32) -> Void

    public init(path: String, queue: DispatchQueue, onConnection: @escaping (Int32) -> Void) throws {
        self.path = path
        self.queue = queue
        self.onConnection = onConnection
        fd = try UnixSocket.listen(path: path)
    }

    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptPending() }
            source.setCancelHandler { [fd] in posixClose(fd) }
            self.source = source
            source.resume()
        }
    }

    private func acceptPending() {
        while let connection = try? UnixSocket.accept(fd) {
            guard UnixSocket.peerUID(connection) == getuid() else {
                posixClose(connection)
                continue
            }
            onConnection(connection)
        }
    }

    /// Stops listening and removes the socket file.
    public func stop() {
        queue.async {
            self.source?.cancel()
            self.source = nil
            unlink(self.path)
        }
    }
}
