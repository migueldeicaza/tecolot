// BridgeServer.swift
// TecolotSessionDaemon

import Dispatch
import Foundation
import TecolotSessionDirectory
import TecolotTransport
import TecolotWire
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Relays the directory and session sockets over standard input and output.
final class BridgeServer: @unchecked Sendable {
    private let directory: SessionDirectory
    private let helperPath: String
    private let build: String
    private let user: RemoteUserInfo
    private let environment: [String: String]
    private let endpoint: LinkEndpoint
    private let workQueue = DispatchQueue(label: "tecolot.bridge.directory")
    private let idleTimeout: TimeInterval
    private let channelWindow: UInt64 = 64 * 1024
    private let receiveWindow: UInt64 = 1024 * 1024
    private var helloReceived = false
    private var usedChannels: Set<UInt64> = []
    private var idleTimer: DispatchSourceTimer?

    init(directory: SessionDirectory, helperPath: String, build: String,
         nonce: String?, idleTimeout: TimeInterval) throws {
        self.directory = directory
        self.helperPath = helperPath
        self.build = build
        self.idleTimeout = idleTimeout
        user = try RemoteUserInfo.current()
        var environment = ProcessInfo.processInfo.environment
        if let agent = Self.linkAgent(environment["SSH_AUTH_SOCK"], in: directory.url) {
            environment["SSH_AUTH_SOCK"] = agent
        }
        self.environment = environment
        // A marker with an empty nonce also precedes the first frame.
        endpoint = LinkEndpoint(readFD: STDIN_FILENO, writeFD: STDOUT_FILENO, startNonce: nonce ?? "")
        endpoint.onControl = { [weak self] envelope in self?.handle(envelope) }
        endpoint.onClose = { error in
            if let error {
                FileHandle.standardError.write(Data("tecolot-sessiond: \(error)\n".utf8))
            }
            exit(error == nil ? 0 : 1)
        }
    }

    deinit { idleTimer?.cancel() }

    func run() -> Never {
        endpoint.start()
        endpoint.queue.async { [self] in
            let timer = DispatchSource.makeTimerSource(queue: endpoint.queue)
            let period = max(0.05, min(1, idleTimeout / 4))
            timer.schedule(deadline: .now() + period, repeating: period, leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
                if now - endpoint.lastByteReceived >= idleTimeout {
                    endpoint.close()
                }
            }
            idleTimer = timer
            timer.resume()
        }
        dispatchMain()
    }

    private func handle(_ envelope: Envelope) {
        do {
            guard let requestID = envelope.requestID else {
                throw WireError.invalidValue("directory request has no request ID")
            }
            if envelope.kind == .linkHello {
                guard !helloReceived else { throw WireError.invalidValue("duplicate LinkHello") }
                let hello = try envelope.decode(LinkHelloMessage.self)
                guard hello.minimumVersion <= LinkProtocol.version,
                      hello.maximumVersion >= LinkProtocol.minimumVersion else {
                    endpoint.sendControl(ErrorMessage(code: .versionMismatch, failedKind: envelope.kind,
                                                       message: "no common link protocol version"), requestID: requestID)
                    return
                }
                guard hello.receiveWindow > 0 else { throw WireError.invalidValue("zero link window") }
                helloReceived = true
                endpoint.setPeerReceiveWindow(hello.receiveWindow)
                endpoint.sendControl(helperInfo(), requestID: requestID)
                return
            }
            guard helloReceived else { throw WireError.invalidValue("LinkHello is required") }
            switch envelope.kind {
            case .listSessions:
                _ = try envelope.decode(ListSessionsMessage.self)
                workQueue.async { [self] in
                    reply(envelope) {
                        let json = Array(try Self.recordEncoder().encode(directory.list()))
                        endpoint.sendControl(SessionListMessage(json: json), requestID: requestID)
                    }
                }
            case .createSession:
                let message = try envelope.decode(CreateSessionMessage.self)
                let launch = try JSONDecoder().decode(RemoteSessionLaunch.self, from: Data(message.json))
                workQueue.async { [self] in
                    reply(envelope) {
                        var local = launch.resolve(passwd: user, bridgeEnvironment: environment)
                        // A restored pane whose session ended: start the new
                        // session from the session's durable state.
                        let states = DurableStateDirectory.remoteDefault(home: user.home)
                        var used: DurableSessionState?
                        if let id = launch.restoreSessionID, SessionDirectory.isValidIdentifier(id) {
                            let notFound = launch.startDirectory(home: user.home).notFound
                            used = states.prepareRestore(&local, sessionID: id, rowLimit: launch.restoreRows ?? 1_000,
                                                         remote: true, directoryNotFound: notFound)
                        }
                        let record = try directory.create(local, helperPath: helperPath)
                        if let used { states.remove(used.id) }
                        if launch.restoreSessionID != nil { states.prune() }
                        let json = Array(try Self.recordEncoder().encode(record))
                        endpoint.sendControl(SessionCreatedMessage(json: json), requestID: requestID)
                    }
                }
            case .terminateSession:
                let message = try envelope.decode(TerminateSessionMessage.self)
                guard SessionDirectory.isValidIdentifier(message.id) else { throw WireError.invalidValue("session ID") }
                workQueue.async { [self] in
                    reply(envelope) {
                        try directory.terminate(message.id, signal: message.signal)
                        endpoint.sendControl(DirectoryDoneMessage(), requestID: requestID)
                    }
                }
            case .openChannel:
                let message = try envelope.decode(OpenChannelMessage.self)
                guard message.channel > 0, !usedChannels.contains(message.channel), message.receiveWindow > 0,
                      SessionDirectory.isValidIdentifier(message.sessionID) else {
                    throw WireError.invalidValue("invalid channel request")
                }
                usedChannels.insert(message.channel)
                workQueue.async { [self] in
                    reply(envelope) {
                        let fd = try connectSession(message.sessionID)
                        var buffer: Int32 = 32 * 1024
                        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buffer, socklen_t(MemoryLayout<Int32>.size))
                        endpoint.queue.async { [self] in
                            endpoint.bindChannel(message.channel, descriptor: fd,
                                                 receiveWindow: channelWindow, sendWindow: message.receiveWindow)
                            endpoint.sendControl(ChannelOpenedMessage(channel: message.channel,
                                                                      receiveWindow: channelWindow), requestID: requestID)
                        }
                    }
                }
            default:
                endpoint.sendControl(ErrorMessage(code: .unsupported, failedKind: envelope.kind,
                                                   message: "unsupported directory request"), requestID: requestID)
            }
        } catch { fail(envelope, error: error) }
    }

    private func reply(_ envelope: Envelope, body: () throws -> Void) {
        do { try body() } catch { fail(envelope, error: error) }
    }

    private func fail(_ envelope: Envelope, error: Error) {
        endpoint.sendControl(ErrorMessage(code: error is WireError ? .badRequest : .unavailable,
                                           failedKind: envelope.kind, message: "\(error)"), requestID: envelope.requestID)
    }

    private func connectSession(_ id: String) throws -> Int32 {
        do { return try directory.connect(id) }
        catch {
            let path = directory.socketPath(for: id)
            guard !FileManager.default.fileExists(atPath: path), let record = directory.readRecord(id),
                  SessionDirectory.isHelperRunning(record), kill(record.pid, SIGUSR1) == 0 else { throw error }
            let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
            repeat {
                if let fd = try? directory.connect(id) { return fd }
                usleep(10_000)
            } while DispatchTime.now().uptimeNanoseconds < deadline
            throw error
        }
    }

    private func helperInfo() -> HelperInfoMessage {
        var system = utsname()
        _ = uname(&system)
        var host = [CChar](repeating: 0, count: 256)
        _ = gethostname(&host, host.count)
        return HelperInfoMessage(build: build, os: Self.cString(system.sysname), arch: Self.cString(system.machine),
                                 machineID: Self.machineID(), hostName: String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
                                 runtimeDirectory: directory.url.path, home: user.home,
                                 shell: user.shell.isEmpty ? "/bin/sh" : user.shell, receiveWindow: receiveWindow)
    }

    /// A forwarded agent socket ends with its ssh connection, but a session
    /// continues after it. Sessions get a fixed path in the runtime directory,
    /// which points to the agent of the newest bridge. Returns that path.
    static func linkAgent(_ socket: String?, in runtime: URL) -> String? {
        guard let socket, !socket.isEmpty else { return nil }
        let path = runtime.appendingPathComponent("agent.sock").path
        // A bridge that starts in a session already has the fixed path.
        guard socket != path else { return path }
        let temporary = runtime.appendingPathComponent(".agent-\(getpid()).sock").path
        unlink(temporary)
        guard symlink(socket, temporary) == 0 else { return nil }
        guard rename(temporary, path) == 0 else { unlink(temporary); return nil }
        return path
    }

    private static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { bytes in String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) }
    }

    private static func machineID() -> String {
        #if canImport(Darwin)
        var identifier = UUID().uuid
        var timeout = timespec(tv_sec: 1, tv_nsec: 0)
        guard gethostuuid(&identifier, &timeout) == 0 else { return "" }
        return UUID(uuid: identifier).uuidString.lowercased()
        #else
        for path in ["/etc/machine-id", "/var/lib/dbus/machine-id"] {
            if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !id.isEmpty { return id }
            }
        }
        return ""
        #endif
    }

    private static func recordEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
