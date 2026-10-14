// LinkClient.swift
// TecolotSessionClient

import Dispatch
import Foundation
import Synchronization
import TecolotSessionDirectory
import TecolotTransport
import TecolotWire
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum LinkClientError: Error, CustomStringConvertible, Sendable {
    case closed
    case timedOut
    case invalidReply
    case remote(ErrorMessage)

    public var description: String {
        switch self {
        case .closed: return "the bridge link is closed"
        case .timedOut: return "the bridge did not answer in time"
        case .invalidReply: return "the bridge sent an invalid reply"
        case .remote(let error): return error.message
        }
    }
}

/// The client of one bridge link. Callbacks run on `queue`.
public final class LinkClient: @unchecked Sendable {
    public let queue: DispatchQueue
    private let endpoint: LinkEndpoint
    private let build: String
    private let clientName: String
    private let settings = Mutex(Settings())
    private let receiveWindow: UInt64 = 1024 * 1024
    private let channelWindow: UInt64 = 64 * 1024
    private var timer: DispatchSourceTimer?
    private var started = false
    private var ready = false
    private var closed = false
    private var nextRequest: UInt64 = 1
    private var nextChannel: UInt64 = 1
    private var pending: [UInt64: @Sendable (Result<Envelope, Error>) -> Void] = [:]
    private var waitingForReady: [@Sendable () -> Void] = []
    private var lastPing: TimeInterval = 0
    private var nextPingNonce: UInt64 = 1

    private struct Settings: Sendable {
        var onReady: (@Sendable (HelperInfoMessage) -> Void)?
        var onClose: (@Sendable (Error?) -> Void)?
        var keepaliveInterval: TimeInterval = 10
        var receiveTimeout: TimeInterval = 30
        var roundTripTime: TimeInterval?
    }

    public var onReady: (@Sendable (HelperInfoMessage) -> Void)? {
        get { settings.withLock { $0.onReady } }
        set { settings.withLock { $0.onReady = newValue } }
    }
    public var onClose: (@Sendable (Error?) -> Void)? {
        get { settings.withLock { $0.onClose } }
        set { settings.withLock { $0.onClose = newValue } }
    }
    /// Seconds without a send before a keepalive ping.
    public var keepaliveInterval: TimeInterval {
        get { settings.withLock { $0.keepaliveInterval } }
        set { settings.withLock { $0.keepaliveInterval = max(0.01, newValue) } }
    }
    /// Seconds without a received byte before closing the link.
    public var receiveTimeout: TimeInterval {
        get { settings.withLock { $0.receiveTimeout } }
        set { settings.withLock { $0.receiveTimeout = max(0.01, newValue) } }
    }
    public var roundTripTime: TimeInterval? { settings.withLock { $0.roundTripTime } }

    /// Takes ownership of both descriptors.
    public init(readFD: Int32, writeFD: Int32, expectedNonce: String? = nil,
                build: String, clientName: String) {
        endpoint = LinkEndpoint(readFD: readFD, writeFD: writeFD, expectedNonce: expectedNonce ?? "")
        queue = endpoint.queue
        self.build = build
        self.clientName = clientName
        endpoint.onControl = { [weak self] envelope in self?.handle(envelope) }
        endpoint.onClose = { [weak self] error in self?.finish(error) }
    }

    deinit {
        timer?.cancel()
        endpoint.close()
        // The endpoint cannot report its close to a released client.
        let requests = Array(pending.values)
        if !requests.isEmpty {
            queue.async { for completion in requests { completion(.failure(LinkClientError.closed)) } }
        }
    }

    public func start() {
        queue.async { [self] in
            guard !started, !closed else { return }
            started = true
            endpoint.start()
            request(LinkHelloMessage(build: build, clientName: clientName, receiveWindow: receiveWindow)) { [weak self] result in
                guard let self else { return }
                do {
                    let envelope = try result.get()
                    guard envelope.kind == .helperInfo else { throw LinkClientError.invalidReply }
                    let info = try envelope.decode(HelperInfoMessage.self)
                    guard info.version >= LinkProtocol.minimumVersion, info.version <= LinkProtocol.version,
                          info.receiveWindow > 0 else { throw LinkClientError.invalidReply }
                    endpoint.setPeerReceiveWindow(info.receiveWindow)
                    ready = true
                    settings.withLock { $0.onReady }?(info)
                    let actions = waitingForReady
                    waitingForReady.removeAll()
                    for action in actions { action() }
                } catch { endpoint.close(error: error) }
            }
            // Check a few times per interval: often enough for the timeout,
            // and at most once a second when the link is idle.
            let (interval, timeout) = settings.withLock { ($0.keepaliveInterval, $0.receiveTimeout) }
            let period = max(0.01, min(1, min(interval, timeout) / 4))
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + period, repeating: period, leeway: .milliseconds(10))
            timer.setEventHandler { [weak self] in self?.checkKeepalive() }
            self.timer = timer
            timer.resume()
        }
    }

    /// Keeps the client until the close fails its requests, also when the
    /// caller releases the client at once.
    public func close() { queue.async { [self] in endpoint.close() } }

    public func listSessions(_ completion: @escaping @Sendable (Result<[SessionRecord], Error>) -> Void) {
        whenReady { [self] in
            request(ListSessionsMessage()) { result in
                completion(Result {
                    let envelope = try result.get()
                    guard envelope.kind == .sessionList else { throw LinkClientError.invalidReply }
                    return try Self.recordDecoder().decode([SessionRecord].self,
                                                          from: Data(envelope.decode(SessionListMessage.self).json))
                })
            }
        }
    }

    public func createSession(_ launch: RemoteSessionLaunch,
                              completion: @escaping @Sendable (Result<SessionRecord, Error>) -> Void) {
        whenReady { [self] in
            do {
                let json = Array(try JSONEncoder().encode(launch))
                request(CreateSessionMessage(json: json)) { result in
                    completion(Result {
                        let envelope = try result.get()
                        guard envelope.kind == .sessionCreated else { throw LinkClientError.invalidReply }
                        return try Self.recordDecoder().decode(SessionRecord.self,
                                                              from: Data(envelope.decode(SessionCreatedMessage.self).json))
                    })
                }
            } catch { completion(.failure(error)) }
        }
    }

    public func terminateSession(id: String, signal: Int32,
                                 completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        whenReady { [self] in
            request(TerminateSessionMessage(id: id, signal: signal)) { result in
                completion(Result {
                    let envelope = try result.get()
                    guard envelope.kind == .directoryDone else { throw LinkClientError.invalidReply }
                    _ = try envelope.decode(DirectoryDoneMessage.self)
                })
            }
        }
    }

    /// Returns the caller's socket immediately. Returns -1 if socket creation fails.
    public func openChannel(sessionID: String,
                            completion: @escaping @Sendable (Result<Void, Error>) -> Void) -> Int32 {
        var descriptors: [Int32] = [-1, -1]
        #if canImport(Darwin)
        let socketType = SOCK_STREAM
        #else
        let socketType = Int32(SOCK_STREAM.rawValue)
        #endif
        guard socketpair(AF_UNIX, socketType, 0, &descriptors) == 0 else {
            let error = TransportError("socketpair")
            queue.async { completion(.failure(error)) }
            return -1
        }
        for fd in descriptors {
            UnixSocket.setCloseOnExec(fd)
            UnixSocket.setNoSignalOnBrokenPipe(fd)
        }
        let callerFD = descriptors[0]
        openChannel(sessionID: sessionID, boundDescriptor: descriptors[1], completion: completion)
        return callerFD
    }

    /// Takes ownership of the descriptor that the caller created.
    public func openChannel(sessionID: String, boundDescriptor: Int32,
                            completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        UnixSocket.setCloseOnExec(boundDescriptor)
        UnixSocket.setNoSignalOnBrokenPipe(boundDescriptor)
        queue.async { [self] in
            guard !closed else {
                Self.closeDescriptor(boundDescriptor)
                completion(.failure(LinkClientError.closed))
                return
            }
            let channel = nextChannel
            nextChannel += 1
            endpoint.bindChannel(channel, descriptor: boundDescriptor, receiveWindow: channelWindow, sendWindow: 0)
            whenReady { [self] in
                request(OpenChannelMessage(channel: channel, sessionID: sessionID, receiveWindow: channelWindow)) { [self] result in
                    do {
                        let envelope = try result.get()
                        guard envelope.kind == .channelOpened else { throw LinkClientError.invalidReply }
                        let opened = try envelope.decode(ChannelOpenedMessage.self)
                        guard opened.channel == channel, opened.receiveWindow > 0 else { throw LinkClientError.invalidReply }
                        endpoint.setChannelSendWindow(channel, receiveWindow: opened.receiveWindow)
                        completion(.success(()))
                    } catch {
                        endpoint.discardChannel(channel)
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    /// Checks the link at once. A timeout closes the link.
    public func checkLiveness(timeout: TimeInterval = 3,
                              completion: @escaping @Sendable (Result<TimeInterval, Error>) -> Void) {
        queue.async { [self] in
            let nonce = nextPingNonce
            nextPingNonce += 1
            let result = Mutex(false)
            let received = endpoint.lastByteReceived
            endpoint.ping(nonce: nonce) { value in
                let first = result.withLock { done in
                    if done { return false }; done = true; return true
                }
                if first { completion(value) }
            }
            queue.asyncAfter(deadline: .now() + timeout) { [self] in
                let first = result.withLock { done in
                    if done { return false }; done = true; return true
                }
                if first {
                    if endpoint.lastByteReceived > received { completion(.success(0)) }
                    else {
                        completion(.failure(LinkClientError.timedOut))
                        endpoint.close(error: LinkClientError.timedOut)
                    }
                }
            }
        }
    }

    private func whenReady(_ action: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            // The request method reports a closed link to its completion.
            if ready || closed { action() } else { waitingForReady.append(action) }
        }
    }

    private func request<M: WireMessage>(_ message: M,
                                         completion: @escaping @Sendable (Result<Envelope, Error>) -> Void) {
        guard !closed else { completion(.failure(LinkClientError.closed)); return }
        let id = nextRequest
        nextRequest += 1
        pending[id] = completion
        endpoint.sendControl(message, flags: .required, requestID: id)
    }

    private func handle(_ envelope: Envelope) {
        guard let id = envelope.requestID, let completion = pending.removeValue(forKey: id) else { return }
        if envelope.kind == .error {
            do { completion(.failure(LinkClientError.remote(try envelope.decode(ErrorMessage.self)))) }
            catch { completion(.failure(error)); endpoint.close(error: error) }
        } else { completion(.success(envelope)) }
    }

    private func checkKeepalive() {
        guard !closed else { return }
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        let (interval, timeout) = settings.withLock { ($0.keepaliveInterval, $0.receiveTimeout) }
        if now - endpoint.lastByteReceived >= timeout {
            endpoint.close(error: LinkClientError.timedOut)
        } else if ready && now - max(endpoint.lastByteSent, lastPing) >= interval {
            let nonce = nextPingNonce
            nextPingNonce += 1
            lastPing = now
            endpoint.ping(nonce: nonce) { [weak self] result in
                guard let self, case .success(let duration) = result else { return }
                settings.withLock { $0.roundTripTime = duration }
            }
        }
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        timer?.cancel()
        timer = nil
        let requests = pending.values
        pending.removeAll()
        for completion in requests { completion(.failure(error ?? LinkClientError.closed)) }
        let actions = waitingForReady
        waitingForReady.removeAll()
        for action in actions { action() }
        settings.withLock { $0.onClose }?(error)
    }

    private static func recordDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func closeDescriptor(_ fd: Int32) {
        #if canImport(Darwin)
        Darwin.close(fd)
        #else
        Glibc.close(fd)
        #endif
    }
}
