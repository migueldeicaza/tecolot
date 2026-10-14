//
// SessionDirectory.swift
// TecolotSessionDirectory
//
// Lists, creates and terminates the sessions of one user on one host.
//
// Every session is a separate `tecolot-sessiond serve` process. In the
// runtime directory each session has:
//
//     <id>.sock     the Unix socket that clients connect to
//     <id>.json     metadata (SessionRecord), rewritten by the helper
//     <id>.log      the helper's standard output and error
//
// The app uses this type in-process for local sessions. On a remote host the
// bridge uses it on behalf of the app.
//

import Foundation
import TecolotTransport
import TecolotWire
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The metadata that a helper publishes for its session.
public struct SessionRecord: Codable, Hashable, Sendable {
    public var id: String
    /// The helper process.
    public var pid: Int32
    public var shellPID: Int32
    public var protocolVersion: UInt32
    public var build: String
    public var createdAt: Date
    public var updatedAt: Date
    public var executable: String
    public var workingDirectory: String?
    public var labels: [String: String]
    public var title: String
    /// The last OSC 7 value.
    public var directory: String
    public var columns: Int
    public var rows: Int
    public var attachedClients: Int
    public var lastAttachedAt: Date?
    /// The name of the foreground process of the session's terminal.
    public var foreground: String?
    public var exited: Bool
    public var exitCode: Int32?
    /// The last notification (OSC 9 or OSC 777) that came while no client
    /// was attached. The app shows it.
    public var notification: SessionNotification?

    public init(id: String, pid: Int32, shellPID: Int32, protocolVersion: UInt32, build: String,
                createdAt: Date, executable: String, workingDirectory: String?, labels: [String: String],
                columns: Int, rows: Int) {
        self.id = id
        self.pid = pid
        self.shellPID = shellPID
        self.protocolVersion = protocolVersion
        self.build = build
        self.createdAt = createdAt
        updatedAt = createdAt
        self.executable = executable
        self.workingDirectory = workingDirectory
        self.labels = labels
        title = ""
        directory = ""
        self.columns = columns
        self.rows = rows
        attachedClients = 0
        lastAttachedAt = nil
        exited = false
        exitCode = nil
    }
}

/// A notification that a program in a detached session asked for.
public struct SessionNotification: Codable, Hashable, Sendable {
    /// Counts the notifications of the session, so that the app shows each
    /// one once.
    public var serial: UInt64
    public var title: String
    public var body: String

    public init(serial: UInt64, title: String, body: String) {
        self.serial = serial
        self.title = title
        self.body = body
    }
}

public enum SessionDirectoryError: Error, CustomStringConvertible, Sendable {
    case helperNotFound(String)
    case spawnFailed(Int32)
    case helperFailed(String)
    case timedOut
    case noSuchSession(String)

    public var description: String {
        switch self {
        case .helperNotFound(let path): return "session helper not found at \(path)"
        case .spawnFailed(let code): return "could not start the session helper: \(String(cString: strerror(code)))"
        case .helperFailed(let message): return "the session helper failed: \(message)"
        case .timedOut: return "the session helper did not answer in time"
        case .noSuchSession(let id): return "no session \(id)"
        }
    }
}

public struct SessionDirectory: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The default directory for this user, created when needed.
    public static func standard() throws -> SessionDirectory {
        SessionDirectory(url: try RuntimeDirectory.defaultURL())
    }

    public func socketPath(for id: String) -> String { url.appendingPathComponent("\(id).sock").path }
    public func recordURL(for id: String) -> URL { url.appendingPathComponent("\(id).json") }
    public func launchURL(for id: String) -> URL { url.appendingPathComponent("\(id).launch") }
    public func logURL(for id: String) -> URL { url.appendingPathComponent("\(id).log") }

    /// A new random session identifier (12 hexadecimal digits keeps socket paths short).
    public static func makeIdentifier() -> String {
        var generator = SystemRandomNumberGenerator()
        let value = generator.next() & 0xFFFF_FFFF_FFFF
        let text = String(value, radix: 16)
        return String(repeating: "0", count: max(0, 12 - text.count)) + text
    }

    public static func isValidIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 32 && id.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    /// True when `record.pid` is still the helper that wrote the record. After
    /// the helper ends, its PID can belong to another process, which started
    /// later. Send a signal to a record's PID only when this is true.
    public static func isHelperRunning(_ record: SessionRecord) -> Bool {
        guard kill(record.pid, 0) == 0, let started = processStartTime(record.pid) else { return false }
        // The helper creates the record just after it starts. The record keeps whole seconds.
        return started <= record.createdAt.addingTimeInterval(5)
    }

    static func processStartTime(_ pid: Int32) -> Date? {
        #if canImport(Darwin)
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
                    + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
        #else
        // Field 22 of /proc/<pid>/stat is the start in clock ticks after boot. The
        // command name (field 2) can contain spaces, so count after its parenthesis.
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let end = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: end)...].split(separator: " ")
        guard fields.count > 19, let ticks = Double(fields[19]),
              let system = try? String(contentsOfFile: "/proc/stat", encoding: .utf8),
              let line = system.split(separator: "\n").first(where: { $0.hasPrefix("btime ") }),
              let boot = Double(line.dropFirst(6).trimmingCharacters(in: .whitespaces)) else { return nil }
        let rate = Double(sysconf(Int32(_SC_CLK_TCK)))
        guard rate > 0 else { return nil }
        return Date(timeIntervalSince1970: boot + ticks / rate)
        #endif
    }

    // MARK: Records

    public func readRecord(_ id: String) -> SessionRecord? {
        guard let data = try? Data(contentsOf: recordURL(for: id)) else { return nil }
        return try? Self.decoder.decode(SessionRecord.self, from: data)
    }

    /// Atomically replaces the record file.
    public func writeRecord(_ record: SessionRecord) throws {
        let data = try Self.encoder.encode(record)
        let target = recordURL(for: record.id)
        let temporary = url.appendingPathComponent(".\(record.id).json.\(getpid())")
        try data.write(to: temporary, options: [])
        chmod(temporary.path, 0o600)
        guard rename(temporary.path, target.path) == 0 else {
            throw TransportError("rename \(target.path)")
        }
    }

    /// Removes the files of a session.
    public func removeFiles(for id: String) {
        unlink(socketPath(for: id))
        unlink(recordURL(for: id).path)
        unlink(launchURL(for: id).path)
    }

    /// The sessions whose helper is still running. Records of helpers that
    /// no longer run are removed.
    public func list() -> [SessionRecord] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return [] }
        var records: [SessionRecord] = []
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let id = String(name.dropLast(5))
            guard Self.isValidIdentifier(id), let record = readRecord(id) else { continue }
            if kill(record.pid, 0) != 0 && errno == ESRCH {
                removeFiles(for: id)
                unlink(logURL(for: id).path)
                continue
            }
            records.append(record)
        }
        return records.sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: Create

    /// Starts a helper for a new session and waits until it accepts clients.
    ///
    /// The helper detaches itself: it starts a second copy in a new session
    /// (setsid) and the first copy exits at once, so the caller never has to
    /// reap the long-lived process.
    public func create(_ launch: SessionLaunch, helperPath: String,
                       timeout: TimeInterval = 10) throws -> SessionRecord {
        guard FileManager.default.isExecutableFile(atPath: helperPath) else {
            throw SessionDirectoryError.helperNotFound(helperPath)
        }
        let id = Self.makeIdentifier()
        let launchData = try JSONEncoder().encode(launch)
        let launchPath = launchURL(for: id).path
        let created = FileManager.default.createFile(atPath: launchPath, contents: launchData,
                                                     attributes: [.posixPermissions: 0o600])
        guard created else { throw TransportError("create \(launchPath)") }

        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else { throw TransportError("pipe") }
        defer { close(pipeFDs[0]) }
        UnixSocket.setCloseOnExec(pipeFDs[0])

        let arguments = ["tecolot-sessiond", "serve", "--id", id, "--runtime-dir", url.path, "--ready-fd", "3"]
        let pid: pid_t
        do {
            pid = try Self.spawn(helperPath, arguments: arguments, readyFD: pipeFDs[1],
                                 log: logURL(for: id).path, newSession: true)
        } catch {
            close(pipeFDs[1])
            unlink(launchPath)
            throw error
        }
        close(pipeFDs[1])
        // Reap the first copy; it exits after it starts the detached one.
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)

        let line = try Self.readLine(pipeFDs[0], timeout: timeout)
        if line.hasPrefix("ready") {
            if let record = readRecord(id) { return record }
            throw SessionDirectoryError.helperFailed("no metadata for \(id)")
        }
        unlink(launchPath)
        throw SessionDirectoryError.helperFailed(line.isEmpty ? "exited during start" : line)
    }

    /// Starts `path` with `arguments`. The child gets `readyFD` as descriptor 3,
    /// /dev/null as input, `log` as output and error, and no other descriptors.
    public static func spawn(_ path: String, arguments: [String], readyFD: Int32?,
                             log: String, newSession: Bool) throws -> pid_t {
        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        if let readyFD { posix_spawn_file_actions_adddup2(&actions, readyFD, 3) }

        #if canImport(Glibc)
        // glibc 2.34 has a close-from action. Use it when it is available.
        // Older systems add one close action for each open descriptor.
        let firstClosed: Int32 = readyFD == nil ? 3 : 4
        if let symbol = dlsym(nil, "posix_spawn_file_actions_addclosefrom_np") {
            typealias CloseFrom = @convention(c) (UnsafeMutablePointer<posix_spawn_file_actions_t>, Int32) -> Int32
            let closeFrom = unsafeBitCast(symbol, to: CloseFrom.self)
            let result = closeFrom(&actions, firstClosed)
            guard result == 0 else { throw SessionDirectoryError.spawnFailed(result) }
        } else {
            let descriptors = try FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")
            for name in descriptors {
                guard let fd = Int32(name), fd >= firstClosed else { continue }
                let result = posix_spawn_file_actions_addclose(&actions, fd)
                guard result == 0 else { throw SessionDirectoryError.spawnFailed(result) }
            }
        }
        #endif

        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var flags = Int32(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        if newSession { flags |= Int32(POSIX_SPAWN_SETSID) }
        #if canImport(Darwin)
        // Only the descriptors set up above reach the child.
        flags |= Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #endif
        posix_spawnattr_setflags(&attributes, Int16(flags))
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        let environment = Self.helperEnvironment()
        var pid: pid_t = 0
        let result = withCStrings(arguments) { argv in
            withCStrings(environment) { envp in
                posix_spawn(&pid, path, &actions, &attributes, argv, envp)
            }
        }
        guard result == 0 else { throw SessionDirectoryError.spawnFailed(result) }
        return pid
    }

    /// The helper's own environment: a few user values, never the app's
    /// whole environment (the session environment comes from the launch file).
    static func helperEnvironment() -> [String] {
        let keep = ["HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "LANG", "TECOLOT_RUNTIME_DIR", "XDG_RUNTIME_DIR"]
        let environment = ProcessInfo.processInfo.environment
        return keep.compactMap { key in environment[key].map { "\(key)=\($0)" } }
    }

    static func readLine(_ fd: Int32, timeout: TimeInterval) throws -> String {
        var collected: [UInt8] = []
        let deadline = Date().addingTimeInterval(timeout)
        var byte: UInt8 = 0
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw SessionDirectoryError.timedOut }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining, 1) * 1000))
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { continue }
            let count = read(fd, &byte, 1)
            if count <= 0 { break }
            if byte == 10 { break }
            collected.append(byte)
            if collected.count > 4096 { break }
        }
        return String(decoding: collected, as: UTF8.self)
    }

    // MARK: Connect and terminate

    /// Connects to a session's socket.
    public func connect(_ id: String) throws -> Int32 {
        try UnixSocket.connect(path: socketPath(for: id))
    }

    /// Asks a session to end: the helper sends `signal` to the shell. When
    /// the helper does not answer, its process gets SIGTERM.
    public func terminate(_ id: String, signal: Int32 = SIGHUP) throws {
        guard let record = readRecord(id) else { throw SessionDirectoryError.noSuchSession(id) }
        if let fd = try? connect(id) {
            var output = WireWriter()
            EnvelopeCodec.append(HelloMessage(build: "directory", clientName: "SessionDirectory"), to: &output)
            EnvelopeCodec.append(TerminateMessage(signal: signal), to: &output)
            let bytes = output.bytes
            let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            close(fd)
            if written == bytes.count { return }
        }
        if Self.isHelperRunning(record) { kill(record.pid, SIGTERM) }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Calls `body` with a NULL-terminated array of C strings.
func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer { for pointer in pointers { free(pointer) } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}
