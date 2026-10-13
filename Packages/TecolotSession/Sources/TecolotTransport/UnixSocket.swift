//
// UnixSocket.swift
// TecolotTransport
//
// Unix domain socket helpers and the per-user runtime directory.
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct TransportError: Error, CustomStringConvertible, Sendable {
    public let operation: String
    public let code: Int32

    public init(_ operation: String, code: Int32 = errno) {
        self.operation = operation
        self.code = code
    }

    public var description: String {
        "\(operation) failed: \(String(cString: strerror(code))) (\(code))"
    }
}

public enum UnixSocket {
    /// The largest socket path, including the terminating NUL.
    public static var maximumPathLength: Int {
        MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    }

    static func makeAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < maximumPathLength else {
            throw TransportError("socket path too long (\(bytes.count) bytes)", code: ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        return address
    }

    static func makeSocket() throws -> Int32 {
        #if canImport(Darwin)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw TransportError("socket") }
        setCloseOnExec(fd)
        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        return fd
    }

    /// Creates a listening socket at `path`, replacing a stale socket file.
    public static func listen(path: String, backlog: Int32 = 16) throws -> Int32 {
        var address = try makeAddress(path)
        let fd = try makeSocket()
        unlink(path)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let error = TransportError("bind \(path)")
            close(fd)
            throw error
        }
        chmod(path, 0o600)
        guard posixListen(fd, backlog) == 0 else {
            let error = TransportError("listen")
            close(fd)
            throw error
        }
        setNonBlocking(fd)
        return fd
    }

    /// Connects to the socket at `path`. The returned descriptor blocks.
    public static func connect(path: String) throws -> Int32 {
        var address = try makeAddress(path)
        let fd = try makeSocket()
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                posixConnect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let error = TransportError("connect \(path)")
            close(fd)
            throw error
        }
        return fd
    }

    /// Accepts one pending connection, or returns nil when none is pending.
    public static func accept(_ listener: Int32) throws -> Int32? {
        while true {
            let fd = posixAccept(listener, nil, nil)
            if fd >= 0 {
                setCloseOnExec(fd)
                #if canImport(Darwin)
                var on: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                #endif
                return fd
            }
            switch errno {
            case EINTR: continue
            case EAGAIN, EWOULDBLOCK, ECONNABORTED: return nil
            default: throw TransportError("accept")
            }
        }
    }

    /// The user ID of the process at the other end of a connected socket.
    public static func peerUID(_ fd: Int32) -> uid_t? {
        #if canImport(Darwin)
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
        #else
        var credentials = ucred()
        var length = socklen_t(MemoryLayout<ucred>.size)
        return getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &length) == 0 ? credentials.uid : nil
        #endif
    }

    /// True when the other end of a connected stream socket is closed. Does not block.
    public static func peerClosed(_ fd: Int32) -> Bool {
        var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&entry, 1, 0) == 1 && entry.revents & Int16(POLLHUP) != 0
    }

    public static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
    }

    /// A write to a closed peer fails with EPIPE instead of raising SIGPIPE,
    /// which would end the process. Works for sockets and pipes on Darwin;
    /// on Linux SIGPIPE is ignored for the process.
    public static func setNoSignalOnBrokenPipe(_ fd: Int32) {
        #if canImport(Darwin)
        // Pipes take the fcntl; sockets take the socket option. Each call
        // fails harmlessly on the other kind of descriptor. Socket options
        // can fail after the peer closes, so posixWrite also uses MSG_NOSIGNAL.
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #elseif canImport(Glibc)
        _ = signal(SIGPIPE, SIG_IGN)
        #endif
    }

    public static func setCloseOnExec(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFD)
        if flags >= 0 { _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC) }
    }
}

// File-scope wrappers: inside UnixSocket the bare names resolve to its static methods.
@inline(__always) private func posixListen(_ fd: Int32, _ backlog: Int32) -> Int32 {
    listen(fd, backlog)
}

@inline(__always) private func posixConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>,
                                                       _ length: socklen_t) -> Int32 {
    connect(fd, address, length)
}

@inline(__always) private func posixAccept(_ fd: Int32, _ address: UnsafeMutablePointer<sockaddr>?,
                                                      _ length: UnsafeMutablePointer<socklen_t>?) -> Int32 {
    accept(fd, address, length)
}

/// The private per-user directory that holds session sockets and metadata.
public enum RuntimeDirectory {
    /// Returns the default directory for this user, creating it when needed.
    ///
    /// On macOS it is `tecolot` inside the per-user temporary directory. On
    /// Linux it is `/tmp/tecolot-<uid>`.
    public static func defaultURL() throws -> URL {
        let url = defaultLocation()
        try prepare(url)
        return url
    }

    public static func defaultLocation() -> URL {
        if let override = ProcessInfo.processInfo.environment["TECOLOT_RUNTIME_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #if canImport(Darwin)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 {
            let temporary = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                                   as: UTF8.self)
            return URL(fileURLWithPath: temporary, isDirectory: true)
                .appendingPathComponent("tecolot", isDirectory: true)
        }
        return URL(fileURLWithPath: "/tmp/tecolot-\(getuid())", isDirectory: true)
        #else
        return URL(fileURLWithPath: "/tmp/tecolot-\(getuid())", isDirectory: true)
        #endif
    }

    /// Creates `url` with mode 0700 and checks that this user owns it, that
    /// it is a real directory (not a symbolic link), and that no other user
    /// can read or write it.
    public static func prepare(_ url: URL) throws {
        let path = url.path
        if mkdir(path, 0o700) != 0 && errno != EEXIST {
            throw TransportError("mkdir \(path)")
        }
        var status = stat()
        guard lstat(path, &status) == 0 else { throw TransportError("lstat \(path)") }
        guard (status.st_mode & S_IFMT) == S_IFDIR else {
            throw TransportError("\(path) is not a directory", code: ENOTDIR)
        }
        guard status.st_uid == getuid() else {
            throw TransportError("\(path) belongs to another user", code: EPERM)
        }
        if status.st_mode & 0o077 != 0 {
            guard chmod(path, 0o700) == 0 else { throw TransportError("chmod \(path)") }
        }
    }
}

// File-scope wrappers for code inside types that declare methods with the
// same names (for example `MessageChannel.close()`).
@inline(__always) func posixRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    read(fd, buffer, count)
}

// Socket flags can no longer be set after a peer closes on Darwin.
// Suppress SIGPIPE at each socket write too. Pipes use their descriptor flag
// on Darwin, and the process signal setting on Linux.
@inline(__always) func posixWrite(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
    // Glibc imports MSG_NOSIGNAL as Int.
    let sent = send(fd, buffer, count, Int32(MSG_NOSIGNAL))
    if sent < 0 && errno == ENOTSOCK { return write(fd, buffer, count) }
    return sent
}

@inline(__always) func posixClose(_ fd: Int32) {
    _ = close(fd)
}
