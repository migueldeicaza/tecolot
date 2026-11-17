import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum SSHCommandLineError: Error, Equatable, Sendable {
    case invalidCommandWord(String)
    case unsafeSocketDirectory(String)
    case socketPathTooLong
    case fileSystem(Int32)
}

/// Arguments are passed directly to ssh. Only remote command words use a shell.
public struct SSHCommandLine: Sendable {
    public let configuration: SSHConfiguration
    public let sshPath: String
    public let extraOptions: [String]
    public let keepaliveInterval: Int
    public let keepaliveCount: Int

    public init(configuration: SSHConfiguration, sshPath: String = "/usr/bin/ssh",
                extraOptions: [String] = [], keepaliveInterval: Int = 15, keepaliveCount: Int = 3) {
        self.configuration = configuration
        self.sshPath = sshPath
        self.extraOptions = extraOptions
        self.keepaliveInterval = keepaliveInterval
        self.keepaliveCount = keepaliveCount
    }

    private var connectionOptions: [String] {
        var options = ["ControlPersist=no", "ForkAfterAuthentication=no", "StdinNull=no",
                       "ClearAllForwardings=yes", "RemoteCommand=none", "RequestTTY=no",
                       "PermitLocalCommand=no", "ForwardX11=no", "ConnectTimeout=15"]
        if configuration.serverAliveInterval == 0 { options.append("ServerAliveInterval=\(keepaliveInterval)") }
        if configuration.serverAliveCountMax == 0 { options.append("ServerAliveCountMax=\(keepaliveCount)") }
        options.append("Compression=yes")
        return options
    }

    private var sessionOptions: [String] {
        ["SessionType=default", "StdinNull=no", "ForkAfterAuthentication=no", "RemoteCommand=none",
         "RequestTTY=no", "PermitLocalCommand=no"]
    }

    private func arguments(_ options: [String]) -> [String] { options.flatMap { ["-o", $0] } }

    public func master(controlPath: String) -> [String] {
        ["-M", "-N", "-S", controlPath] + arguments(connectionOptions + extraOptions) + [configuration.destination]
    }

    public func client(controlPath: String, command: [String], forwardAgent: Bool = false) throws -> [String] {
        try Self.validate(command: command)
        return ["-S", controlPath, "-T"]
            + arguments(["ControlMaster=no", "BatchMode=yes", "ProxyCommand=false"] + sessionOptions)
            + (forwardAgent ? ["-A"] : []) + [configuration.destination] + command
    }

    public func independent(command: [String], forwardAgent: Bool = false) throws -> [String] {
        try Self.validate(command: command)
        return ["-T"] + arguments(["ControlMaster=no", "ControlPath=none"] + connectionOptions + sessionOptions + extraOptions)
            + (forwardAgent ? ["-A"] : []) + [configuration.destination] + command
    }

    public func check(controlPath: String) -> [String] {
        ["-S", controlPath, "-O", "check", configuration.destination]
    }

    public func exit(controlPath: String) -> [String] {
        ["-S", controlPath, "-O", "exit", configuration.destination]
    }

    public static func validate(command: [String]) throws {
        for word in command {
            guard !word.isEmpty, word.utf8.allSatisfy({ byte in
                (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                    || [UInt8(46), 47, 95, 45].contains(byte)
            }) else { throw SSHCommandLineError.invalidCommandWord(word) }
        }
    }

    public static func controlSocketPath(runtimeDirectory: URL, configuration: SSHConfiguration) throws -> String {
        let name = socketName(Array((configuration.hostKey + " " + configuration.destination).utf8))
        var directory = runtimeDirectory.appendingPathComponent("ssh", isDirectory: true)
        if directory.appendingPathComponent(name).path.utf8.count + 17 > 104 {
            directory = URL(fileURLWithPath: "/tmp/tecolot-ssh-\(getuid())", isDirectory: true)
        }
        let path = directory.appendingPathComponent(name).path
        guard path.utf8.count + 17 <= 104 else { throw SSHCommandLineError.socketPathTooLong }
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw SSHCommandLineError.fileSystem(errno) }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SSHCommandLineError.unsafeSocketDirectory(directory.path) }
        defer { _ = close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFDIR else {
            throw SSHCommandLineError.unsafeSocketDirectory(directory.path)
        }
        guard fchmod(fd, 0o700) == 0 else { throw SSHCommandLineError.fileSystem(errno) }
        return path
    }

    private static func socketName(_ input: [UInt8]) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: Data(input)).prefix(8).map { String(format: "%02x", $0) }.joined()
        #else
        return fallbackSocketName(input)
        #endif
    }

    // Socket names need a stable identifier.
    // Hash the same input twice. The second seed swaps the first seed's halves.
    // Join the low 32 bits of each FNV-1a64 result to make 16 hexadecimal digits.
    static func fallbackSocketName(_ input: [UInt8]) -> String {
        func fnv1a(seed: UInt64) -> UInt64 {
            input.reduce(seed) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
        }
        let first = UInt32(truncatingIfNeeded: fnv1a(seed: 0xcbf29ce484222325))
        let second = UInt32(truncatingIfNeeded: fnv1a(seed: 0x84222325cbf29ce4))
        return String(format: "%08x%08x", first, second)
    }
}
