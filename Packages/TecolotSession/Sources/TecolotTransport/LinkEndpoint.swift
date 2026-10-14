//
// LinkEndpoint.swift
// TecolotTransport
//
// Multiplexes local byte streams over a link. State and callbacks use `queue`.
//

import Foundation
import TecolotWire
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Counters for the data streams. Control messages are not counted.
public struct LinkCounters: Sendable {
    public let bytesSent: [UInt64: UInt64]
    public let bytesReceived: [UInt64: UInt64]
    public let maxUnacknowledgedBytesObserved: UInt64
    public let unacknowledgedBytes: UInt64
}

public final class LinkEndpoint: @unchecked Sendable {
    public static let defaultReceiveWindow: UInt64 = 1024 * 1024
    public static let defaultChannelWindow: UInt64 = 64 * 1024
    public let queue: DispatchQueue
    private static let queueKey = DispatchSpecificKey<ObjectIdentifier>()
    private let readFD: Int32
    private let writeFD: Int32
    private let descriptors: DescriptorOwner
    private let receiveWindow: UInt64
    private var peerReceiveWindow: UInt64
    private let marker: [UInt8]?
    private let startMarker: [UInt8]
    private var markerBytes: [UInt8] = []
    private var markerDiscarded = 0
    private var markerFound: Bool
    private var decoder = LinkFrameStreamDecoder()
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var ackTimer: DispatchSourceTimer?
    private var channels: [UInt64: LinkDataChannel] = [:]
    private var usedChannels = Set<UInt64>()
    private var channelOrder: [UInt64] = []
    private var nextTurn = 0
    private var urgent = WriteQueue()
    private var control = WriteQueue()
    private var current: [UInt8] = []
    private var currentOffset = 0
    private var currentChannel: UInt64?
    private var currentPayloadCount = 0
    private var started = false
    private var closed = false
    private var flushScheduled = false
    private var sent: UInt64 = 0
    private var acknowledged: UInt64 = 0
    private var received: UInt64 = 0
    private var lastAck: UInt64 = 0
    private var maximumUnacknowledged: UInt64 = 0
    private var sentByChannel: [UInt64: UInt64] = [:]
    private var receivedByChannel: [UInt64: UInt64] = [:]
    private var receivedTime = ProcessInfo.processInfo.systemUptime
    private var sentTime = ProcessInfo.processInfo.systemUptime
    private var controlHandler: (@Sendable (Envelope) -> Void)?
    private var closeHandler: (@Sendable (Error?) -> Void)?
    private var pings: [UInt64: (TimeInterval, @Sendable (Result<TimeInterval, Error>) -> Void)] = [:]

    public init(readFD: Int32, writeFD: Int32, expectedNonce: String? = nil,
                startNonce: String? = nil,
                receiveWindow: UInt64 = LinkEndpoint.defaultReceiveWindow,
                peerReceiveWindow: UInt64 = LinkEndpoint.defaultReceiveWindow,
                queue: DispatchQueue = DispatchQueue(label: "tecolot.link")) {
        UnixSocket.setCloseOnExec(readFD)
        UnixSocket.setCloseOnExec(writeFD)
        self.readFD = readFD
        self.writeFD = writeFD
        descriptors = DescriptorOwner(readFD: readFD, writeFD: writeFD)
        self.receiveWindow = max(1, receiveWindow)
        self.peerReceiveWindow = max(1, peerReceiveWindow)
        self.queue = queue
        marker = expectedNonce.map { Array("TECOLOT-BRIDGE \(LinkProtocol.version) \($0)\n".utf8) }
        markerFound = expectedNonce == nil
        startMarker = startNonce.map { Array("TECOLOT-BRIDGE \(LinkProtocol.version) \($0)\n".utf8) } ?? []
        queue.setSpecific(key: Self.queueKey, value: ObjectIdentifier(queue))
    }

    private var isOnQueue: Bool {
        DispatchQueue.getSpecific(key: Self.queueKey) == ObjectIdentifier(queue)
    }

    private func synchronized<T>(_ body: () -> T) -> T {
        isOnQueue ? body() : queue.sync(execute: body)
    }

    private func perform(_ body: @escaping @Sendable () -> Void) {
        if isOnQueue { body() } else { queue.async(execute: body) }
    }

    public var onControl: (@Sendable (Envelope) -> Void)? {
        get { synchronized { controlHandler } }
        set { synchronized { controlHandler = newValue } }
    }

    public var onClose: (@Sendable (Error?) -> Void)? {
        get { synchronized { closeHandler } }
        set { synchronized { closeHandler = newValue } }
    }

    /// Monotonic time of the last byte read from the link.
    public var lastByteReceived: TimeInterval { synchronized { receivedTime } }
    public var lastByteSent: TimeInterval { synchronized { sentTime } }
    public var isClosed: Bool { synchronized { closed } }
    public var counters: LinkCounters {
        synchronized {
            LinkCounters(bytesSent: sentByChannel, bytesReceived: receivedByChannel,
                         maxUnacknowledgedBytesObserved: maximumUnacknowledged,
                         unacknowledgedBytes: sent - acknowledged)
        }
    }
    public var maxUnacknowledgedBytesObserved: UInt64 { counters.maxUnacknowledgedBytesObserved }

    deinit {
        readSource?.cancel()
        writeSource?.cancel()
        ackTimer?.cancel()
        for channel in channels.values { channel.cancel(queue: queue) }
        descriptors.close(on: queue)
    }

    /// Starts reading. Set the callbacks first.
    public func start() { perform { self.startOnQueue() } }

    private func startOnQueue() {
        guard !started, !closed else { return }
        started = true
        receivedTime = ProcessInfo.processInfo.systemUptime
        sentTime = receivedTime
        UnixSocket.setCloseOnExec(readFD)
        UnixSocket.setCloseOnExec(writeFD)
        UnixSocket.setNonBlocking(readFD)
        UnixSocket.setNonBlocking(writeFD)
        UnixSocket.setNoSignalOnBrokenPipe(writeFD)
        let source = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: queue)
        descriptors.track(source)
        source.setEventHandler { [weak self] in self?.readLink() }
        readSource = source
        source.resume()
        current = startMarker
        scheduleFlush()
        updateChannelReads()
    }

    /// Queues one control message. Safe from any thread.
    public func sendControl<M: WireMessage>(_ message: M, flags: EnvelopeFlags = [],
                                           requestID: UInt64? = nil) {
        let bytes = EnvelopeCodec.encode(message, flags: flags, requestID: requestID)
        perform { self.enqueueControl(bytes, urgent: M.kind == .ping || M.kind == .pong) }
    }

    private func enqueueControl(_ bytes: [UInt8], urgent highPriority: Bool = false) {
        guard !closed else { return }
        do {
            let frame = try LinkFrameCodec.encode(LinkFrame(channel: 0, payload: bytes))
            if highPriority { urgent.append(frame) } else { control.append(frame) }
            scheduleFlush()
        } catch { finish(error) }
    }

    /// Takes ownership of a local descriptor. Zero send credit defers reads.
    public func bindChannel(_ channel: UInt64, descriptor: Int32,
                            receiveWindow: UInt64 = LinkEndpoint.defaultChannelWindow,
                            sendWindow: UInt64 = 0) {
        UnixSocket.setCloseOnExec(descriptor)
        perform {
            guard !self.closed else { posixClose(descriptor); return }
            guard channel > 0, !self.usedChannels.contains(channel), receiveWindow > 0 else {
                posixClose(descriptor)
                self.finish(WireError.invalidValue("channel or receive window"))
                return
            }
            self.usedChannels.insert(channel)
            let local = LinkDataChannel(descriptor: descriptor, receiveWindow: receiveWindow,
                                        sendWindow: sendWindow)
            UnixSocket.setCloseOnExec(descriptor)
            UnixSocket.setNonBlocking(descriptor)
            UnixSocket.setNoSignalOnBrokenPipe(descriptor)
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: self.queue)
            local.owner.track(source)
            source.setEventHandler { [weak endpoint = self] in endpoint?.readChannel(channel) }
            local.readSource = source
            // Start suspended. updateChannelReads balances the first resume.
            local.readSuspended = true
            self.channels[channel] = local
            self.channelOrder.append(channel)
            self.updateChannelReads()
        }
    }

    /// Sets the initial credit after ChannelOpened.
    public func setChannelSendWindow(_ channel: UInt64, receiveWindow: UInt64) {
        perform {
            guard let local = self.channels[channel], !self.closed else { return }
            guard receiveWindow > 0 else {
                self.finish(WireError.invalidValue("channel send window")); return
            }
            local.sendCredit = receiveWindow
            self.updateChannelReads()
            self.scheduleFlush()
        }
    }

    public func setPeerReceiveWindow(_ window: UInt64) {
        perform {
            guard window > 0, window >= self.sent - self.acknowledged else {
                self.finish(WireError.invalidValue("link receive window")); return
            }
            self.peerReceiveWindow = window
            self.updateChannelReads()
            self.scheduleFlush()
        }
    }

    /// Closes a local channel after its pending output is sent.
    public func closeChannel(_ channel: UInt64) {
        perform {
            guard let local = self.channels[channel] else { return }
            local.localEnded = true
            self.updateChannelReads()
            self.completeChannelIfNeeded(channel)
            self.scheduleFlush()
        }
    }

    /// Drops a channel without sending CloseChannel after an open fails.
    public func discardChannel(_ channel: UInt64) { perform { self.removeChannel(channel) } }

    public func ping(nonce: UInt64,
                     completion: @escaping @Sendable (Result<TimeInterval, Error>) -> Void) {
        perform {
            guard !self.closed else { completion(.failure(TransportError("link closed", code: ENOTCONN))); return }
            guard self.pings[nonce] == nil else {
                completion(.failure(WireError.invalidValue("duplicate ping nonce"))); return
            }
            self.pings[nonce] = (ProcessInfo.processInfo.systemUptime, completion)
            self.sendControl(PingMessage(nonce: nonce))
        }
    }

    /// Drops pending output and closes all descriptors. Safe from any thread.
    public func close(error: Error? = nil) { perform { self.finish(error) } }

    private func readLink() {
        guard !closed else { return }
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        // Yield to channel writes and callbacks during a continuous stream.
        for _ in 0 ..< 16 {
            let count = bytes.withUnsafeMutableBytes { posixRead(readFD, $0.baseAddress, $0.count) }
            if count > 0 {
                receivedTime = ProcessInfo.processInfo.systemUptime
                do {
                    try feedLink(Array(bytes.prefix(count)))
                    if closed { return }
                } catch { finish(error); return }
            } else if count == 0 {
                finish(markerFound && decoder.pendingByteCount == 0 ? nil : WireError.truncated)
                return
            } else {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                finish(TransportError("read link")); return
            }
        }
    }

    private func feedLink(_ bytes: [UInt8]) throws {
        if !markerFound, let marker {
            markerBytes.append(contentsOf: bytes)
            // A marker must occupy a complete line. Retain only the last partial line.
            while let newline = markerBytes.firstIndex(of: 10) {
                let line = Array(markerBytes.prefix(newline + 1))
                markerBytes.removeFirst(newline + 1)
                if line == marker {
                    markerFound = true
                    decoder.append(markerBytes)
                    markerBytes.removeAll()
                    break
                }
                markerDiscarded += line.count
                guard markerDiscarded <= 64 * 1024 else { throw WireError.invalidValue("bridge marker missing") }
            }
            guard markerDiscarded + markerBytes.count <= 64 * 1024 || markerFound else {
                throw WireError.invalidValue("bridge marker missing")
            }
            if !markerFound { return }
        } else { decoder.append(bytes) }
        while let frame = try decoder.next() {
            if frame.channel == 0 {
                var envelopes = EnvelopeStreamDecoder()
                envelopes.append(frame.payload)
                guard let envelope = try envelopes.next(), envelopes.pendingByteCount == 0,
                      try envelopes.next() == nil else {
                    throw WireError.invalidValue("control envelope")
                }
                try handleControl(envelope)
            } else {
                guard let local = channels[frame.channel] else {
                    guard usedChannels.contains(frame.channel) else {
                        throw WireError.invalidValue("unknown channel")
                    }
                    recordReceived(frame)
                    continue
                }
                guard UInt64(frame.payload.count) <= local.receiveCredit else {
                    throw WireError.invalidValue("channel receive window exceeded")
                }
                // Credit includes received bytes until grants return to the peer.
                local.receiveCredit -= UInt64(frame.payload.count)
                if local.incomingOffset > 0 {
                    local.incoming.removeFirst(local.incomingOffset)
                    local.incomingOffset = 0
                }
                local.incoming.append(contentsOf: frame.payload)
                recordReceived(frame)
                writeChannel(frame.channel)
            }
            if closed { return }
        }
    }

    private func recordReceived(_ frame: LinkFrame) {
        received += UInt64(frame.payload.count)
        receivedByChannel[frame.channel, default: 0] += UInt64(frame.payload.count)
        if received - lastAck >= max(1, receiveWindow / 4) { sendAck() }
        else if ackTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(20))
            timer.setEventHandler { [weak self] in self?.sendAck() }
            ackTimer = timer
            timer.resume()
        }
    }

    private func sendAck() {
        ackTimer?.cancel()
        ackTimer = nil
        guard received > lastAck, !closed else { return }
        lastAck = received
        sendControl(LinkAckMessage(received: received))
    }

    private func handleControl(_ envelope: Envelope) throws {
        switch envelope.kind {
        case .ping:
            sendControl(PongMessage(nonce: try envelope.decode(PingMessage.self).nonce), requestID: envelope.requestID)
        case .pong:
            let nonce = try envelope.decode(PongMessage.self).nonce
            if let (time, completion) = pings.removeValue(forKey: nonce) {
                completion(.success(ProcessInfo.processInfo.systemUptime - time))
            }
        case .linkAck:
            let count = try envelope.decode(LinkAckMessage.self).received
            guard count >= acknowledged, count <= sent else { throw WireError.invalidValue("link acknowledgement") }
            acknowledged = count
            updateChannelReads()
            scheduleFlush()
        case .channelWindow:
            let message = try envelope.decode(ChannelWindowMessage.self)
            guard message.increment > 0 else { throw WireError.invalidValue("empty channel grant") }
            guard let local = channels[message.channel] else {
                if usedChannels.contains(message.channel) { return }
                throw WireError.invalidValue("unknown channel grant")
            }
            let (credit, overflow) = local.sendCredit.addingReportingOverflow(message.increment)
            guard !overflow else { throw WireError.invalidValue("channel credit overflow") }
            local.sendCredit = credit
            updateChannelReads()
            scheduleFlush()
        case .closeChannel:
            let channel = try envelope.decode(CloseChannelMessage.self).channel
            guard let local = channels[channel] else {
                if usedChannels.contains(channel) { return }
                throw WireError.invalidValue("unknown channel close")
            }
            local.remoteEnded = true
            local.outgoing.removeAll()
            updateChannelReads()
            writeChannel(channel)
            completeChannelIfNeeded(channel)
        default: controlHandler?(envelope)
        }
    }

    private func readChannel(_ channel: UInt64) {
        guard let local = channels[channel], canRead(local), !closed else { return }
        let available = min(UInt64(16 * 1024 - local.outgoing.count),
                            min(local.sendCredit - UInt64(local.outgoing.count), peerReceiveWindow - (sent - acknowledged)))
        var bytes = [UInt8](repeating: 0, count: Int(available))
        let count = bytes.withUnsafeMutableBytes { posixRead(local.descriptor, $0.baseAddress, $0.count) }
        if count > 0 { local.outgoing.append(contentsOf: bytes.prefix(count)) }
        else if count == 0 { local.localEnded = true }
        else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { local.localEnded = true }
        updateChannelReads()
        completeChannelIfNeeded(channel)
        scheduleFlush()
    }

    private func canRead(_ local: LinkDataChannel) -> Bool {
        started && !closed && !local.localEnded && !local.remoteEnded && local.outgoing.count < 16 * 1024
            && local.sendCredit > UInt64(local.outgoing.count) && sent - acknowledged < peerReceiveWindow
    }

    private func updateChannelReads() {
        for local in channels.values {
            let enabled = canRead(local)
            if enabled && local.readSuspended { local.readSuspended = false; local.readSource?.resume() }
            else if !enabled && !local.readSuspended { local.readSuspended = true; local.readSource?.suspend() }
        }
    }

    private func writeChannel(_ channel: UInt64) {
        guard let local = channels[channel], !closed else { return }
        while local.incomingOffset < local.incoming.count {
            let count = local.incoming.withUnsafeBytes {
                posixWrite(local.descriptor, $0.baseAddress! + local.incomingOffset, $0.count - local.incomingOffset)
            }
            if count > 0 {
                local.incomingOffset += count
                local.pendingGrant += UInt64(count)
            } else if count < 0 && errno == EINTR { continue }
            else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                if local.writeSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: local.descriptor, queue: queue)
                    local.owner.track(source)
                    source.setEventHandler { [weak self] in
                        guard let self, let local = self.channels[channel] else { return }
                        local.writeSource?.cancel()
                        local.writeSource = nil
                        self.writeChannel(channel)
                    }
                    local.writeSource = source
                    source.resume()
                }
                grantChannel(channel)
                return
            } else {
                local.localEnded = true
                local.incoming.removeAll()
                local.incomingOffset = 0
                updateChannelReads()
                completeChannelIfNeeded(channel)
                scheduleFlush()
                return
            }
        }
        local.incoming.removeAll(keepingCapacity: true)
        local.incomingOffset = 0
        grantChannel(channel)
        completeChannelIfNeeded(channel)
    }

    private func grantChannel(_ channel: UInt64) {
        guard let local = channels[channel], local.pendingGrant > 0, !local.remoteEnded,
              local.pendingGrant >= max(1, local.receiveWindow / 4)
                || local.incomingOffset == local.incoming.count else { return }
        let grant = local.pendingGrant
        local.pendingGrant = 0
        local.receiveCredit += grant
        sendControl(ChannelWindowMessage(channel: channel, increment: grant))
    }

    private func completeChannelIfNeeded(_ channel: UInt64) {
        guard let local = channels[channel] else { return }
        if local.remoteEnded && local.incomingOffset == local.incoming.count {
            removeChannel(channel)
        } else if local.localEnded && local.outgoing.isEmpty && currentChannel != channel {
            sendControl(CloseChannelMessage(channel: channel))
            removeChannel(channel)
        }
    }

    private func removeChannel(_ channel: UInt64) {
        guard let local = channels.removeValue(forKey: channel) else { return }
        local.cancel(queue: queue)
        channelOrder.removeAll { $0 == channel }
        if nextTurn >= channelOrder.count { nextTurn = 0 }
    }

    private func scheduleFlush() {
        guard started, !closed, !flushScheduled, writeSource == nil else { return }
        flushScheduled = true
        queue.async { self.flushScheduled = false; self.flush() }
    }

    private func nextFrame() throws -> [UInt8]? {
        currentChannel = nil
        currentPayloadCount = 0
        if let bytes = urgent.popFirst() ?? control.popFirst() { return bytes }
        guard sent - acknowledged < peerReceiveWindow else { return nil }
        for _ in 0 ..< channelOrder.count {
            if nextTurn >= channelOrder.count { nextTurn = 0 }
            let channel = channelOrder[nextTurn]
            nextTurn += 1
            guard let local = channels[channel], !local.outgoing.isEmpty, local.sendCredit > 0 else { continue }
            let count = min(local.outgoing.count, Int(min(UInt64(16 * 1024),
                                min(local.sendCredit, peerReceiveWindow - (sent - acknowledged)))))
            guard count > 0 else { continue }
            let payload = Array(local.outgoing.prefix(count))
            local.outgoing.removeFirst(count)
            local.sendCredit -= UInt64(count)
            sent += UInt64(count)
            maximumUnacknowledged = max(maximumUnacknowledged, sent - acknowledged)
            currentChannel = channel
            currentPayloadCount = count
            updateChannelReads()
            return try LinkFrameCodec.encode(LinkFrame(channel: channel, payload: payload))
        }
        return nil
    }

    private func flush() {
        guard started, !closed, writeSource == nil else { return }
        for _ in 0 ..< 64 {
            if currentOffset == current.count {
                if let channel = currentChannel {
                    sentByChannel[channel, default: 0] += UInt64(currentPayloadCount)
                    currentChannel = nil
                    completeChannelIfNeeded(channel)
                }
                do {
                    guard let next = try nextFrame() else {
                        current = []; currentOffset = 0
                        updateChannelReads()
                        return
                    }
                    current = next; currentOffset = 0
                } catch { finish(error); return }
            }
            let count = current.withUnsafeBytes {
                posixWrite(writeFD, $0.baseAddress! + currentOffset, $0.count - currentOffset)
            }
            if count > 0 {
                currentOffset += count
                sentTime = ProcessInfo.processInfo.systemUptime
            } else if count < 0 && errno == EINTR { continue }
            else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                let source = DispatchSource.makeWriteSource(fileDescriptor: writeFD, queue: queue)
                descriptors.track(source)
                source.setEventHandler { [weak self] in
                    guard let self else { return }
                    self.writeSource?.cancel(); self.writeSource = nil
                    self.flush()
                }
                writeSource = source
                source.resume()
                return
            } else { finish(TransportError("write link")); return }
        }
        scheduleFlush()
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        readSource?.cancel(); readSource = nil
        writeSource?.cancel(); writeSource = nil
        ackTimer?.cancel(); ackTimer = nil
        for local in channels.values { local.cancel(queue: queue) }
        channels.removeAll()
        channelOrder.removeAll()
        descriptors.close(on: queue)
        current = []; urgent = WriteQueue(); control = WriteQueue()
        let pending = pings.values
        pings.removeAll()
        for (_, completion) in pending {
            completion(.failure(error ?? TransportError("link closed", code: ENOTCONN)))
        }
        let handler = closeHandler
        closeHandler = nil; controlHandler = nil
        handler?(error)
    }
}

private final class LinkDataChannel {
    let descriptor: Int32
    let owner: DescriptorOwner
    let receiveWindow: UInt64
    var receiveCredit: UInt64
    var sendCredit: UInt64
    var outgoing: [UInt8] = []
    var incoming: [UInt8] = []
    var incomingOffset = 0
    var pendingGrant: UInt64 = 0
    var localEnded = false
    var remoteEnded = false
    var readSource: DispatchSourceRead?
    var readSuspended = true
    var writeSource: DispatchSourceWrite?
    init(descriptor: Int32, receiveWindow: UInt64, sendWindow: UInt64) {
        self.descriptor = descriptor
        self.receiveWindow = receiveWindow
        receiveCredit = receiveWindow
        sendCredit = sendWindow
        owner = DescriptorOwner(readFD: descriptor, writeFD: descriptor)
    }
    func cancel(queue: DispatchQueue) {
        if readSuspended { readSource?.resume(); readSuspended = false }
        readSource?.cancel(); readSource = nil
        writeSource?.cancel(); writeSource = nil
        owner.close(on: queue)
    }
}
