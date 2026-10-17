import Dispatch
import Foundation
import Synchronization
import TecolotSessionDirectory
import TecolotTransport
import TecolotWire
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum HostLinkState: Sendable {
    case idle, resolving, connecting, authenticating, probing
    case confirmInstall(Int64)
    case installing(Double)
    case startingBridge
    case connected(HelperInfoMessage, connectionGeneration: UInt64)
    case reconnecting(attempt: Int, nextRetry: Date)
    case signInNeeded
    case failed(SSHError)
    case unsupported(os: String, arch: String)
}

public struct HostLinkConfiguration: Sendable {
    public var sshPath = "/usr/bin/ssh"
    public var extraSSHOptions: [String] = []
    public var appRuntimeDirectory: URL
    public var remoteLayout: RemoteLayout
    public var helperSource: any RemoteHelperSource
    public var askpassHelperPath: String?
    public var build: String
    public var idleDelay: TimeInterval = 300
    /// Seconds that the master has to log in. The time while a prompt is open does not count.
    public var masterTimeout: TimeInterval = 60
    public var backoffSchedule: [TimeInterval] = [1, 2, 4, 8, 15, 30]
    public var keepaliveInterval: TimeInterval = 10
    public var receiveTimeout: TimeInterval = 30
    public var serverAliveInterval = 15
    public var serverAliveCountMax = 3
    public var environment = ProcessInfo.processInfo.environment

    public init(appRuntimeDirectory: URL, remoteLayout: RemoteLayout = try! RemoteLayout(),
                helperSource: any RemoteHelperSource, build: String) {
        self.appRuntimeDirectory = appRuntimeDirectory
        self.remoteLayout = remoteLayout
        self.helperSource = helperSource
        self.build = build
    }
}

/// One host connection. State and callbacks run on `queue`.
public final class HostLink: @unchecked Sendable {
    public let queue: DispatchQueue
    public let destination: String
    private let configuration: HostLinkConfiguration
    private let askpassServer: AskpassServer
    private let settings = Mutex(Settings())
    private struct Settings: Sendable {
        var state: HostLinkState = .idle
        var generation: UInt64 = 0
        var masterPID: Int32?
        var bridgePID: Int32?
        var onStateChange: (@Sendable (HostLinkState) -> Void)?
        var askpass: (@Sendable (AskpassRequest, @escaping @Sendable (String?) -> Void) -> Void)?
        var onAskpassDismiss: (@Sendable (UUID) -> Void)?
        var confirmInstall: (@Sendable (String, Int64, @escaping @Sendable (Bool) -> Void) -> Void)?
        var isAppActive: @Sendable () -> Bool = { true }
    }
    private var resolved: SSHConfiguration?
    private var commandLine: SSHCommandLine?
    private var socketPath: String?
    private var master: SSHProcess?
    private var adoptedMaster = false
    private var masterAlive: Bool { master?.isRunning == true || adoptedMaster }
    private var bridge: SSHProcess?
    private var clients: [ObjectIdentifier: SSHProcess] = [:]
    private var link: LinkClient?
    private var bootstrap: RemoteBootstrap?
    private var probe: RemoteProbeResult?
    private var retained = 0
    private var epoch: UInt64 = 0
    private var idleEpoch: UInt64 = 0
    private var attempt = 0
    private var scheduledRetry: DispatchWorkItem?
    private var retryBridgeOnly = false
    private var automatic = false
    private var hasConnected = false
    private var noMultiplexing = false
    private var installConfirmed = false
    private var inactivePrompt = false
    private var cancelledPrompt = false
    private var openPrompts: Set<UUID> = []
    private var masterDeadline = Date.distantFuture
    private var waiting: [Waiting] = []
    private struct Waiting: Sendable {
        /// The action attaches to a session that exists, as after a relaunch.
        var resumes = false
        let run: @Sendable (LinkClient) -> Void
        let fail: @Sendable (Error) -> Void
    }
    /// Network errors retry with backoff after the link connected, or when a
    /// pane waits for a session that exists. Before that, they fail at once,
    /// so that a wrong host name shows its error.
    private var retriesNetworkErrors: Bool { hasConnected || waiting.contains { $0.resumes } }

    public var state: HostLinkState { settings.withLock { $0.state } }
    public var connectionGeneration: UInt64 { settings.withLock { $0.generation } }
    /// Child identifiers for diagnostics.
    public var masterProcessIdentifier: Int32? { settings.withLock { $0.masterPID } }
    public var bridgeProcessIdentifier: Int32? { settings.withLock { $0.bridgePID } }
    public var onStateChange: (@Sendable (HostLinkState) -> Void)? {
        get { settings.withLock { $0.onStateChange } }
        set { settings.withLock { $0.onStateChange = newValue } }
    }
    public var askpass: (@Sendable (AskpassRequest, @escaping @Sendable (String?) -> Void) -> Void)? {
        get { settings.withLock { $0.askpass } }
        set { settings.withLock { $0.askpass = newValue } }
    }
    public var onAskpassDismiss: (@Sendable (UUID) -> Void)? {
        get { settings.withLock { $0.onAskpassDismiss } }
        set { settings.withLock { $0.onAskpassDismiss = newValue } }
    }
    public var confirmInstall: (@Sendable (String, Int64, @escaping @Sendable (Bool) -> Void) -> Void)? {
        get { settings.withLock { $0.confirmInstall } }
        set { settings.withLock { $0.confirmInstall = newValue } }
    }
    public var isAppActive: @Sendable () -> Bool {
        get { settings.withLock { $0.isAppActive } }
        set { settings.withLock { $0.isAppActive = newValue } }
    }

    public init(destination: String, configuration: HostLinkConfiguration, askpassServer: AskpassServer) {
        self.destination = destination
        self.configuration = configuration
        self.askpassServer = askpassServer
        queue = DispatchQueue(label: "tecolot.host-link.\(destination)")
    }

    deinit {
        scheduledRetry?.cancel()
        link?.close()
        bridge?.stop()
        for child in clients.values { child.stop() }
        master?.stop()
        if adoptedMaster, let commandLine, let socketPath {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: configuration.sshPath)
            process.arguments = commandLine.exit(controlPath: socketPath)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
        }
        let actions = waiting
        queue.async { for action in actions { action.fail(LinkClientError.closed) } }
    }

    public func connect() { queue.async { [self] in connectIfNeeded() } }
    public func retain() { queue.async { [self] in retained += 1; idleEpoch += 1; connectIfNeeded() } }
    public func release() {
        queue.async { [self] in
            retained = max(0, retained - 1)
            guard retained == 0 else { return }
            idleEpoch += 1
            let ticket = idleEpoch
            queue.asyncAfter(deadline: .now() + configuration.idleDelay) { [self] in
                if retained == 0 && idleEpoch == ticket { stopOnQueue() }
            }
        }
    }
    public func stop() { queue.async { [self] in stopOnQueue() } }
    /// Stops the link before it returns, for example when the app quits.
    public func stopNow() {
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync { stopOnQueue() }
    }
    public func reconnectNow() {
        queue.async { [self] in
            resetProcesses()
            attempt = 0; automatic = false
            setState(.idle); connectIfNeeded()
        }
    }
    public func checkLiveness() {
        queue.async { [self] in
            guard let link else {
                if case .reconnecting = state { retryConnection() }
                return
            }
            let ticket = epoch
            link.checkLiveness { [weak self] result in
                guard let self else { return }
                queue.async { [self] in
                    guard epoch == ticket, case .failure = result else { return }
                    networkDrop(stopMaster: true)
                }
            }
        }
    }

    /// Returns the pane socket at once. Takes ownership of the other end.
    /// `created` gets the ID of a new session before the pane attaches to it,
    /// so that the caller keeps the ID also when the attach fails.
    public func openPane(sessionID: String?, launch: RemoteSessionLaunch?,
                         created: (@Sendable (String) -> Void)? = nil,
                         completion: @escaping @Sendable (Result<String, Error>) -> Void) -> Int32 {
        var fds: [Int32] = [-1, -1]
        #if canImport(Darwin)
        let type = SOCK_STREAM
        #else
        let type = Int32(SOCK_STREAM.rawValue)
        #endif
        guard socketpair(AF_UNIX, type, 0, &fds) == 0 else {
            let error = TransportError("socketpair")
            queue.async { completion(.failure(error)) }
            return -1
        }
        for fd in fds { UnixSocket.setCloseOnExec(fd); UnixSocket.setNoSignalOnBrokenPipe(fd) }
        let bound = fds[1]
        enqueue(Waiting(resumes: sessionID != nil, run: { [weak self] client in
            guard let self else { close(bound); return }
            let bind: @Sendable (String) -> Void = { id in
                client.openChannel(sessionID: id, boundDescriptor: bound) { result in
                    self.queue.async { completion(result.map { id }) }
                }
            }
            if let sessionID { bind(sessionID); return }
            // A pane that closed while the link connected gets no session.
            guard !UnixSocket.peerClosed(bound) else {
                close(bound); self.queue.async { completion(.failure(LinkClientError.closed)) }; return
            }
            client.createSession(launch ?? RemoteSessionLaunch()) { result in
                switch result {
                case .success(let record):
                    guard !UnixSocket.peerClosed(bound) else {
                        // No pane shows this session, so end it.
                        close(bound)
                        client.terminateSession(id: record.id, signal: SIGHUP) { _ in }
                        self.queue.async { completion(.failure(LinkClientError.closed)) }
                        return
                    }
                    self.queue.async { created?(record.id) }
                    bind(record.id)
                case .failure(let error): close(bound); self.queue.async { completion(.failure(error)) }
                }
            }
        }, fail: { error in close(bound); completion(.failure(error)) }))
        return fds[0]
    }

    public func listSessions(_ completion: @escaping @Sendable (Result<[SessionRecord], Error>) -> Void) {
        enqueue(Waiting(run: { [self] client in
            client.listSessions { result in self.queue.async { completion(result) } }
        }, fail: { completion(.failure($0)) }))
    }
    public func terminateSession(id: String, signal: Int32 = SIGHUP,
                                 completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        enqueue(Waiting(run: { [self] client in
            client.terminateSession(id: id, signal: signal) { result in self.queue.async { completion(result) } }
        }, fail: { completion(.failure($0)) }))
    }

    /// Deletes the helper from the host. Terminate the sessions first, and
    /// stop the link after: the bridge runs the deleted helper.
    public func removeHelper(_ completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        enqueue(Waiting(run: { [self] _ in
            do {
                let words = try RemoteBootstrap(layout: configuration.remoteLayout, metadata: []).removeCommand()
                let process = try runClient(arguments: clientArguments(words), ticket: epoch) { child, status, _ in
                    if status == 0 { completion(.success(())) }
                    else { completion(.failure(SSHErrorClassifier.classify(stderr: child.stderr))) }
                }
                process.write(Data())
            } catch { completion(.failure(error)) }
        }, fail: { completion(.failure($0)) }))
    }

    private func enqueue(_ action: Waiting) {
        queue.async { [self] in
            if case .connected = state, let link { action.run(link) }
            else if case .failed(let error) = state { action.fail(error) }
            else if case .unsupported(let os, let arch) = state {
                action.fail(RemoteBootstrapError.unsupportedBinary("\(os), \(arch)"))
            } else { waiting.append(action); connectIfNeeded() }
        }
    }
    private func setState(_ state: HostLinkState) {
        let callback = settings.withLock { $0.state = state; return $0.onStateChange }
        callback?(state)
    }
    private func connectIfNeeded() {
        guard case .idle = state else { return }
        epoch += 1
        let ticket = epoch
        inactivePrompt = false; cancelledPrompt = false
        setState(.resolving)
        DispatchQueue.global().async { [self] in
            let result = Result { try SSHConfiguration.resolve(destination: destination,
                      sshPath: configuration.sshPath, environment: configuration.environment) }
            queue.async { [self] in
                guard epoch == ticket else { return }
                do {
                    let config = try result.get()
                    resolved = config
                    commandLine = SSHCommandLine(configuration: config, sshPath: configuration.sshPath,
                        extraOptions: configuration.extraSSHOptions,
                        keepaliveInterval: configuration.serverAliveInterval,
                        keepaliveCount: configuration.serverAliveCountMax)
                    socketPath = try SSHCommandLine.controlSocketPath(runtimeDirectory: configuration.appRuntimeDirectory,
                                                                      configuration: config)
                    if noMultiplexing { prepareProbe(ticket: ticket) }
                    else { try startMaster(ticket: ticket) }
                } catch { fail(error) }
            }
        }
    }

    private func makeProcess(arguments: [String]) throws -> SSHProcess {
        let holder = Mutex<SSHProcess?>(nil)
        let promptEpoch = epoch
        let token = askpassServer.register(host: resolved?.hostKey ?? destination,
            stderr: { holder.withLock { $0?.stderr ?? "" } }, handler: { [weak self] request, reply in
                guard let self else { reply(nil); return }
                queue.async { [self] in
                    guard epoch == promptEpoch else { reply(nil); return }
                    if automatic && !settings.withLock({ $0.isAppActive })() {
                        inactivePrompt = true
                        reply(nil)
                        resetProcesses()
                        setState(.signInNeeded)
                    } else {
                        setState(.authenticating)
                        guard let handler = settings.withLock({ $0.askpass }) else {
                            cancelledPrompt = true
                            reply(nil)
                            if request.style == .notice {
                                handleFailure(SSHErrorClassifier.classify(stderr: "", cancelled: true))
                            }
                            return
                        }
                        openPrompts.insert(request.id)
                        handler(request) { [weak self] text in
                            guard let self else { reply(nil); return }
                            queue.async { [self] in
                                guard epoch == promptEpoch else { reply(nil); return }
                                if text == nil && request.style != .notice { cancelledPrompt = true }
                                reply(text)
                            }
                        }
                    }
                }
            }, onDismiss: { [weak self] id in
                guard let self else { return }
                queue.async { [self] in
                    // The login continues after the prompt, with the full time again.
                    if openPrompts.remove(id) != nil {
                        masterDeadline = Date().addingTimeInterval(configuration.masterTimeout)
                    }
                    settings.withLock { $0.onAskpassDismiss }?(id)
                }
            })
        do {
            guard let helperPath = configuration.askpassHelperPath ?? configuration.helperSource.askpassHelperPath else {
                throw SSHError(kind: .other, message: "Set the local helper path for SSH prompts.")
            }
            let wrapper = try AskpassServer.writeWrapper(helperPath: helperPath,
                                                        in: configuration.appRuntimeDirectory)
            var environment = configuration.environment
            environment["SSH_ASKPASS"] = wrapper.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["TECOLOT_ASKPASS_SOCKET"] = askpassServer.socketPath
            environment["TECOLOT_ASKPASS_TOKEN"] = token
            let process = SSHProcess(path: configuration.sshPath, arguments: arguments, environment: environment,
                                     askpass: askpassServer, token: token,
                                     nullInput: arguments.contains("-M") || arguments.contains("-O"))
            holder.withLock { $0 = process }
            return process
        } catch { askpassServer.unregister(token: token); throw error }
    }

    private func startMaster(ticket: UInt64) throws {
        guard let commandLine, let socketPath else { throw LinkClientError.invalidReply }
        setState(.connecting)
        inactivePrompt = false; cancelledPrompt = false
        if FileManager.default.fileExists(atPath: socketPath) {
            let check = try runClient(arguments: commandLine.check(controlPath: socketPath), ticket: ticket) { [self] child, status, _ in
                if status == 0 {
                    adoptedMaster = true
                    let pid = child.stderr.components(separatedBy: "pid=").last?
                        .prefix(while: { $0.isNumber }).description
                    settings.withLock { $0.masterPID = pid.flatMap(Int32.init) }
                    prepareProbe(ticket: ticket)
                } else {
                    // The socket is in our private directory and its master is gone.
                    unlink(socketPath)
                    do { try launchMaster(ticket: ticket) } catch { fail(error) }
                }
            }
            check.write(Data())
        } else { try launchMaster(ticket: ticket) }
    }

    private func launchMaster(ticket: UInt64) throws {
        guard let commandLine, let socketPath else { throw LinkClientError.invalidReply }
        let process = try makeProcess(arguments: commandLine.master(controlPath: socketPath))
        master = process
        try process.start(queue: queue, captureOutput: true) { [weak self] child, _, _ in
            guard let self, master === child else { return }
            master = nil
            settings.withLock { $0.masterPID = nil }
            var error = SSHErrorClassifier.classify(stderr: child.stderr, cancelled: cancelledPrompt)
            if error.kind == .other, connectionGeneration > 0,
               child.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                   || child.stderr.lowercased().contains("received signal") {
                error = SSHErrorClassifier.classify(stderr: "Connection closed")
            }
            handleFailure(error)
        }
        settings.withLock { $0.masterPID = process.pid }
        process.write(Data())
        openPrompts.removeAll()
        masterDeadline = Date().addingTimeInterval(configuration.masterTimeout)
        waitForMaster(ticket: ticket)
    }

    private func waitForMaster(ticket: UInt64) {
        guard epoch == ticket, let master, master.isRunning else { return }
        if FileManager.default.fileExists(atPath: socketPath!) {
            do {
                _ = try runClient(arguments: commandLine!.check(controlPath: socketPath!), ticket: ticket) { [self] child, status, _ in
                    if status == 0 { prepareProbe(ticket: ticket) }
                    else { handleFailure(SSHErrorClassifier.classify(stderr: child.stderr, cancelled: cancelledPrompt)) }
                }
            } catch { fail(error) }
        } else if openPrompts.isEmpty && Date() >= masterDeadline {
            handleFailure(SSHErrorClassifier.classify(stderr: "Connection timed out"))
        } else {
            queue.asyncAfter(deadline: .now() + 0.05) { [self] in waitForMaster(ticket: ticket) }
        }
    }

    private func runClient(arguments: [String], ticket: UInt64,
                           completion: @escaping @Sendable (SSHProcess, Int32, Data) -> Void) throws -> SSHProcess {
        let process = try makeProcess(arguments: arguments)
        clients[ObjectIdentifier(process)] = process
        try process.start(queue: queue, captureOutput: true) { [weak self] child, status, data in
            guard let self else { return }
            clients.removeValue(forKey: ObjectIdentifier(child))
            guard epoch == ticket else { return }
            completion(child, status, data)
        }
        return process
    }
    private func clientArguments(_ words: [String], agent: Bool = false) throws -> [String] {
        guard let commandLine else { throw LinkClientError.invalidReply }
        if noMultiplexing { return try commandLine.independent(command: words, forwardAgent: agent) }
        return try commandLine.client(controlPath: socketPath!, command: words, forwardAgent: agent)
    }

    private func prepareProbe(ticket: UInt64) {
        setState(.probing)
        DispatchQueue.global().async { [self] in
            let result = Result { () -> RemoteBootstrap in
                var metadata: [RemoteHelperMetadata] = []
                for id in ["darwin-universal", "linux-x86_64", "linux-aarch64"] {
                    if let item = try configuration.helperSource.metadata(for: id) { metadata.append(item) }
                }
                return try RemoteBootstrap(layout: configuration.remoteLayout, metadata: metadata)
            }
            queue.async { [self] in
                guard epoch == ticket else { return }
                do { bootstrap = try result.get(); try runProbe(ticket: ticket) }
                catch { fail(error) }
            }
        }
    }
    private func runProbe(ticket: UInt64) throws {
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let process = try runClient(arguments: clientArguments(["/bin/sh", "-s"]), ticket: ticket) { [self] child, status, output in
            if status != 0 {
                clientFailure(child) { [self] in try runProbe(ticket: epoch) }; return
            }
            do {
                let result = try bootstrap!.parseProbe(String(decoding: output, as: UTF8.self), nonce: nonce)
                probe = result
                try useProbe(result, nonce: nonce, ticket: ticket)
            } catch { fail(error) }
        }
        process.write(Data(try bootstrap!.probeScript(nonce: nonce).utf8))
    }
    private func useProbe(_ result: RemoteProbeResult, nonce: String, ticket: UInt64) throws {
        guard let binaryID = result.binaryID,
              let metadata = try configuration.helperSource.metadata(for: binaryID) else {
            setState(.unsupported(os: result.os, arch: result.arch))
            failWaiting(RemoteBootstrapError.unsupportedBinary("\(result.os), \(result.arch)")); return
        }
        guard result.homeOK else {
            throw SSHError(kind: .other, message: "The helper directory is not safe or cannot be created.")
        }
        guard result.runtimeOK else {
            throw SSHError(kind: .other, message: "The remote runtime directory is not safe or cannot be created.")
        }
        guard result.hasHashTool else {
            throw SSHError(kind: .other, message: "The host has no SHA-256 tool.")
        }
        if result.installedHash == metadata.sha256 && result.runs { try startBridge(ticket: ticket); return }
        let install: @Sendable () -> Void = { [self] in
            do { try installHelper(result, nonce: nonce, ticket: ticket) } catch { fail(error) }
        }
        if installConfirmed { install() }
        else {
            setState(.confirmInstall(metadata.uncompressedSize))
            guard let confirm = settings.withLock({ $0.confirmInstall }) else {
                handleFailure(SSHErrorClassifier.classify(stderr: "", cancelled: true)); return
            }
            let once = Mutex(false)
            confirm(resolved!.hostKey, metadata.uncompressedSize) { [self] yes in
                queue.async { [self] in
                    guard epoch == ticket, !once.withLock({ value in let prior = value; value = true; return prior }) else { return }
                    if yes { installConfirmed = true; install() }
                    else { handleFailure(SSHErrorClassifier.classify(stderr: "", cancelled: true)) }
                }
            }
        }
    }
    private func installHelper(_ result: RemoteProbeResult, nonce: String, ticket: UInt64) throws {
        guard result.receiverReady else {
            throw SSHError(kind: .other, message: "The host could not prepare the helper upload.")
        }
        setState(.installing(0))
        DispatchQueue.global().async { [self] in
            let payload = Result { try configuration.helperSource.payload(for: result.binaryID!, compressed: result.hasGzip,
                                                                         cacheDirectory: configuration.appRuntimeDirectory) }
            queue.async { [self] in
                guard epoch == ticket else { return }
                do {
                    let upload = try payload.get()
                    guard upload.compressed == result.hasGzip else {
                        throw SSHError(kind: .other, message: "The helper upload has the wrong compression format.")
                    }
                    let process = try runClient(arguments: clientArguments(try bootstrap!.receiverCommand(nonce: nonce).split(separator: " ").map(String.init)),
                                                ticket: ticket) { [self] child, status, output in
                        do {
                            let steps = try bootstrap!.parseUploadSteps(String(decoding: output, as: UTF8.self), nonce: nonce)
                            if let failed = steps.first(where: { !$0.succeeded }) {
                                throw SSHError(kind: .other, message: failed.detail,
                                    stderrLines: SSHErrorClassifier.classify(stderr: child.stderr).stderrLines)
                            }
                            if status != 0 {
                                clientFailure(child) { [self] in try runProbe(ticket: epoch) }; return
                            }
                            guard steps.last?.step == "cleanup" else { throw LinkClientError.invalidReply }
                            try startBridge(ticket: ticket)
                        } catch { fail(error) }
                    }
                    process.upload(file: upload.fileURL, queue: queue) { [weak self] progress in
                        guard let self, epoch == ticket else { return }; setState(.installing(progress))
                    }
                } catch { fail(error) }
            }
        }
    }
    private func startBridge(ticket: UInt64) throws {
        guard let probe, let bootstrap else { throw LinkClientError.invalidReply }
        setState(.startingBridge)
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let process = try makeProcess(arguments: clientArguments(try bootstrap.bridgeCommand(probe: probe, nonce: nonce).split(separator: " ").map(String.init),
                                                                agent: resolved?.forwardAgent == true))
        bridge = process
        try process.start(queue: queue, captureOutput: false) { [weak self] child, _, _ in
            guard let self, epoch == ticket, bridge === child else { return }
            bridge = nil
            settings.withLock { $0.bridgePID = nil }
            var error = SSHErrorClassifier.classify(stderr: child.stderr, cancelled: cancelledPrompt)
            if error.kind == .other, connectionGeneration > 0,
               child.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                   || child.stderr.lowercased().contains("received signal") {
                error = SSHErrorClassifier.classify(stderr: "Connection closed")
            }
            if error.kind == .channelRefused {
                clientFailure(child) { [self] in try runProbe(ticket: epoch) }
            } else if masterAlive && retriesNetworkErrors
                        && error.kind != .authentication && error.kind != .hostKeyChanged && error.kind != .cancelled {
                networkDrop(stopMaster: false)
            } else { handleFailure(error) }
        }
        settings.withLock { $0.bridgePID = process.pid }
        let (readFD, writeFD) = try process.bridgeDescriptors()
        let client = LinkClient(readFD: readFD, writeFD: writeFD, expectedNonce: nonce,
                                build: configuration.build, clientName: "Tecolot")
        link = client
        client.keepaliveInterval = configuration.keepaliveInterval
        client.receiveTimeout = configuration.receiveTimeout
        client.onReady = { [weak self, weak client] info in
            guard let self, let client else { return }
            queue.async { [self] in
                guard epoch == ticket, link === client else { return }
                attempt = 0; automatic = false; hasConnected = true
                inactivePrompt = false; cancelledPrompt = false
                let generation = settings.withLock { $0.generation += 1; return $0.generation }
                setState(.connected(info, connectionGeneration: generation))
                let actions = waiting; waiting.removeAll()
                for action in actions { action.run(client) }
            }
        }
        client.onClose = { [weak self, weak client] error in
            guard let self, let client else { return }
            queue.asyncAfter(deadline: .now() + 0.1) { [self] in
                guard epoch == ticket, link === client else { return }
                let timedOut = if case LinkClientError.timedOut? = error { true } else { false }
                // The process callback supplies stderr after the process exits.
                guard timedOut || bridge?.isRunning == true else { return }
                if !retriesNetworkErrors { fail(error ?? LinkClientError.closed) }
                else { networkDrop(stopMaster: timedOut || !masterAlive) }
            }
        }
        client.start()
    }

    private func clientFailure(_ child: SSHProcess,
                               retry: @escaping @Sendable () throws -> Void) {
        let error = SSHErrorClassifier.classify(stderr: child.stderr, cancelled: cancelledPrompt)
        if error.kind == .channelRefused && !noMultiplexing {
            noMultiplexing = true
            endMaster()
            link?.close(); link = nil; bridge?.stop(); bridge = nil
            do { try retry() } catch { fail(error) }
        } else { handleFailure(error) }
    }
    private func handleFailure(_ error: SSHError) {
        if inactivePrompt { resetProcesses(); setState(.signInNeeded); return }
        if error.kind == .network && retriesNetworkErrors { networkDrop(stopMaster: true) }
        else { resetProcesses(); setState(.failed(error)); failWaiting(error) }
    }
    private func networkDrop(stopMaster: Bool) {
        scheduledRetry?.cancel(); scheduledRetry = nil
        epoch += 1
        let ticket = epoch
        link?.close(); link = nil
        bridge?.stop(); bridge = nil
        for child in clients.values { child.stop() }; clients.removeAll()
        settings.withLock { $0.bridgePID = nil }
        if stopMaster { endMaster() }
        guard retained > 0 || !waiting.isEmpty else {
            endMaster()
            hasConnected = false
            setState(.idle); return
        }
        automatic = true; attempt += 1
        let schedule = configuration.backoffSchedule.isEmpty ? [30] : configuration.backoffSchedule
        let delay = max(0, schedule[min(attempt - 1, schedule.count - 1)])
        setState(.reconnecting(attempt: attempt, nextRetry: Date().addingTimeInterval(delay)))
        retryBridgeOnly = !stopMaster && masterAlive
        let retry = DispatchWorkItem { [weak self] in
            guard let self, epoch == ticket else { return }
            retryConnection()
        }
        scheduledRetry = retry
        queue.asyncAfter(deadline: .now() + delay, execute: retry)
    }
    private func retryConnection() {
        guard case .reconnecting = state else { return }
        scheduledRetry?.cancel(); scheduledRetry = nil
        epoch += 1
        let ticket = epoch
        do {
            if retryBridgeOnly && masterAlive {
                if adoptedMaster { try checkAdoptedMaster(ticket: ticket) } else { try startBridge(ticket: ticket) }
            } else { setState(.idle); connectIfNeeded() }
        } catch { fail(error) }
    }
    /// A master from an earlier run is not a child process, so only a check
    /// shows that it still runs. When it is gone, the link logs in again.
    private func checkAdoptedMaster(ticket: UInt64) throws {
        guard let commandLine, let socketPath else { throw LinkClientError.invalidReply }
        _ = try runClient(arguments: commandLine.check(controlPath: socketPath), ticket: ticket) { [self] _, status, _ in
            if status == 0 {
                do { try startBridge(ticket: ticket) } catch { fail(error) }
                return
            }
            // The socket is in our private directory and its master is gone.
            unlink(socketPath)
            adoptedMaster = false
            settings.withLock { $0.masterPID = nil }
            setState(.idle); connectIfNeeded()
        }
    }
    private func fail(_ error: Error) {
        if let ssh = error as? SSHError { handleFailure(ssh) }
        else { handleFailure(SSHErrorClassifier.classify(stderr: String(describing: error))) }
    }
    private func failWaiting(_ error: Error) {
        let actions = waiting; waiting.removeAll()
        for action in actions { action.fail(error) }
    }
    private func resetProcesses() {
        scheduledRetry?.cancel(); scheduledRetry = nil
        epoch += 1
        link?.close(); link = nil
        bridge?.stop(); bridge = nil
        for child in clients.values { child.stop() }; clients.removeAll()
        endMaster()
        settings.withLock { $0.masterPID = nil; $0.bridgePID = nil }
    }
    private func endMaster() {
        // This socket belongs to Tecolot, including a master from an earlier run.
        if masterAlive, let commandLine, let socketPath,
           let process = try? makeProcess(arguments: commandLine.exit(controlPath: socketPath)) {
            try? process.start(queue: queue, captureOutput: true) { _, _, _ in }
            process.write(Data())
        }
        let child = master
        master = nil; adoptedMaster = false
        child?.stop()
        settings.withLock { $0.masterPID = nil }
    }
    private func stopOnQueue() {
        resetProcesses(); idleEpoch += 1; hasConnected = false
        failWaiting(LinkClientError.closed); setState(.idle)
    }
}

/// Stores one link for each resolved host and destination.
public final class HostLinkRegistry: @unchecked Sendable {
    private let links = Mutex<[String: HostLink]>([:])
    public init() {}
    public func link(configuration: SSHConfiguration, hostConfiguration: HostLinkConfiguration,
                     askpassServer: AskpassServer) -> HostLink {
        let key = configuration.hostKey + " " + configuration.destination
        return links.withLock { values in
            if let existing = values[key] { return existing }
            let link = HostLink(destination: configuration.destination, configuration: hostConfiguration,
                                askpassServer: askpassServer)
            values[key] = link
            return link
        }
    }
    deinit { for link in links.withLock({ Array($0.values) }) { link.stop() } }
    /// Stops the masters before it returns, so that none stays after the app quits.
    public func stopAll() { for link in links.withLock({ Array($0.values) }) { link.stopNow() } }
}
