//
// SessionServer.swift
// TecolotSessionDaemon
//
// Runs one session in a helper process: reads the launch file, starts the
// session host, listens on the session socket and keeps the session record
// up to date.
//

import Foundation
import TecolotSessionDirectory
import TecolotSessionHost
import TecolotTransport
import TecolotWire
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public final class SessionServer: @unchecked Sendable {
    public let directory: SessionDirectory
    public let id: String
    public let host: SessionHost
    private var listener: SocketListener?
    private var record: SessionRecord
    private var recordWritePending = false
    private var attachedCount = 0
    private var exitSeen = false
    private var lingerTimer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private var finished = false

    /// How long a session whose exit no client saw stays available.
    public var unseenExitLinger: TimeInterval = 24 * 60 * 60

    /// Reads (and deletes) the launch file for `id`.
    public init(directory: SessionDirectory, id: String, build: String) throws {
        self.directory = directory
        self.id = id
        let launchURL = directory.launchURL(for: id)
        let data = try Data(contentsOf: launchURL)
        unlink(launchURL.path)
        let launch = try JSONDecoder().decode(SessionLaunch.self, from: data)
        host = SessionHost(id: id, launch: launch, build: build)
        record = SessionRecord(id: id, pid: getpid(), shellPID: 0, protocolVersion: SessionProtocol.version,
                               build: build, createdAt: Date(), executable: launch.executable,
                               workingDirectory: launch.workingDirectory, labels: launch.labels,
                               columns: launch.columns, rows: launch.rows)
        if let linger = ProcessInfo.processInfo.environment["TECOLOT_EXITED_LINGER"].flatMap(TimeInterval.init) {
            unseenExitLinger = linger
        }
    }

    /// Starts the child, listens and publishes the record. Reports the
    /// outcome on `readyFD` ("ready <pid>" or "error <message>").
    public func start(readyFD: Int32?) throws {
        do {
            try host.start()
            let listener = try SocketListener(path: directory.socketPath(for: id), queue: host.queue) { [host] fd in
                host.accept(socket: fd)
            }
            self.listener = listener
            record.shellPID = host.shellPID
            try directory.writeRecord(record)
            listener.start()
        } catch {
            Self.report(readyFD, "error \(error)")
            throw error
        }
        host.onMetadataChange = { [weak self] title, directory in
            guard let self else { return }
            record.title = title
            record.directory = directory
            scheduleRecordWrite()
        }
        host.onAttachmentChange = { [weak self] count in
            guard let self else { return }
            if count > attachedCount { record.lastAttachedAt = Date() }
            attachedCount = count
            record.attachedClients = count
            let size = host.gridSize
            record.columns = size.columns
            record.rows = size.rows
            scheduleRecordWrite()
            if count == 0 && record.exited { exitWhenAppropriate() }
        }
        host.onGridChange = { [weak self] columns, rows in
            guard let self else { return }
            record.columns = columns
            record.rows = rows
            scheduleRecordWrite()
        }
        host.onSessionInfo = { [weak self] info in
            guard let self else { return }
            let name = info.foreground?.name
            guard name != record.foreground else { return }
            record.foreground = name
            scheduleRecordWrite()
        }
        host.onExit = { [weak self] code in
            guard let self else { return }
            record.exited = true
            record.exitCode = code
            // Nobody needs the final screen of a session that a user ended on purpose.
            exitSeen = attachedCount > 0 || host.wasTerminationRequested
            writeRecordNow()
            exitWhenAppropriate()
        }
        installSignalHandlers()
        Self.report(readyFD, "ready \(getpid())")
    }

    /// Runs the dispatch main loop forever.
    public func run() -> Never {
        dispatchMain()
    }

    private func exitWhenAppropriate() {
        guard record.exited, attachedCount == 0 else { return }
        if exitSeen {
            finish()
        } else if lingerTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: host.queue)
            timer.schedule(deadline: .now() + unseenExitLinger)
            timer.setEventHandler { [weak self] in self?.finish() }
            lingerTimer = timer
            timer.resume()
        }
    }

    private func scheduleRecordWrite() {
        guard !recordWritePending else { return }
        recordWritePending = true
        host.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            recordWritePending = false
            writeRecordNow()
        }
    }

    private func writeRecordNow() {
        guard !finished else { return }
        record.updatedAt = Date()
        try? directory.writeRecord(record)
    }

    private func installSignalHandlers() {
        signal(SIGPIPE, SIG_IGN)
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: host.queue)
            source.setEventHandler { [weak self] in self?.shutdown() }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Ends the child and then the helper.
    private func shutdown() {
        if record.exited {
            finish()
            return
        }
        host.terminate(signal: SIGHUP)
        host.queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.finish() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        listener?.stop()
        directory.removeFiles(for: id)
        // A normal end needs no log; a crash leaves it for diagnosis.
        unlink(directory.logURL(for: id).path)
        host.queue.async { exit(0) }
    }

    static func report(_ fd: Int32?, _ message: String) {
        guard let fd, fd >= 0 else { return }
        let line = Array((message + "\n").utf8)
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }
}
