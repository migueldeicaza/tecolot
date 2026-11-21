//
//  FDTransferSocket.swift
//  Tecolot
//
//  Unix domain socket transport with SCM_RIGHTS file-descriptor passing for
//  in-place hot reload of local terminal panes.
//

import Darwin
import Foundation

/// Wire metadata describing one local PTY pane transferred over SCM_RIGHTS.
nonisolated struct HotReloadPaneEntry: Codable, Hashable, Sendable {
    let paneID: UUID
    let shellPid: Int32
    let startTime: ProcessStartTime?
    let cols: Int
    let rows: Int
}

/// A pane entry paired with an open PTY master file descriptor.
///
/// Ownership of `fd` transfers with this value; callers must either hand it to
/// `HotReloadableLocalProcess.attachAdopted(...)` or close it explicitly.
nonisolated struct HotReloadPaneTransfer: Sendable {
    let entry: HotReloadPaneEntry
    let fd: Int32
}

nonisolated enum HotReloadTransferError: LocalizedError, Sendable {
    case socketPathTooLong(String)
    case syscallFailed(String, Int32)
    case timedOut(String)
    case unauthorizedPeer(uid: uid_t, expected: uid_t)
    case tokenMismatch
    case protocolError(String)
    case peerRejected(String)
    case missingFileDescriptor

    var errorDescription: String? {
        switch self {
        case .socketPathTooLong(let path):
            return "Hot-reload socket path exceeds Unix sun_path limit: \(path)"
        case .syscallFailed(let name, let code):
            return "\(name) failed (errno \(code): \(String(cString: strerror(code))))"
        case .timedOut(let phase):
            return "Timed out waiting for hot-reload \(phase)."
        case .unauthorizedPeer(let uid, let expected):
            return "Rejected hot-reload peer with UID \(uid) (expected \(expected))."
        case .tokenMismatch:
            return "Rejected hot-reload peer with invalid authentication token."
        case .protocolError(let detail):
            return "Hot-reload protocol error: \(detail)"
        case .peerRejected(let reason):
            return "New Tecolot instance rejected hot-reload handoff: \(reason)"
        case .missingFileDescriptor:
            return "Expected an SCM_RIGHTS file descriptor from peer, but none arrived."
        }
    }
}

/// Framed Unix socket messages exchanged during hot-reload handoff.
private nonisolated enum HotReloadWire {
    static let protocolVersion = 1
    static let maxFrameSize = 4 * 1024 * 1024

    struct Hello: Codable, Sendable {
        let protocolVersion: Int
        let token: String
        let receiverPID: Int32
    }

    struct Manifest: Codable, Sendable {
        let protocolVersion: Int
        let sourcePID: Int32
        let paneCount: Int
    }

    struct Ack: Codable, Sendable {
        let ok: Bool
        let acceptedCount: Int
        let error: String?
    }
}

/// Low-level Darwin `AF_UNIX` + `SCM_RIGHTS` primitives and framed I/O helpers.
nonisolated enum FDTransferSocket {
    /// Generates a 256-bit cryptographically random hex token.
    static func makeRandomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&bytes, bytes.count)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Creates a `0700` private temporary directory and returns a short Unix
    /// socket path well under Darwin's 104-byte `sun_path` limit.
    static func makePrivateSocketPath() throws -> (directoryURL: URL, socketPath: String) {
        let suffix = String(makeRandomToken().prefix(12))
        let dirPath = "/tmp/tecolot-hr-\(getpid())-\(suffix)"
        let dirURL = URL(fileURLWithPath: dirPath, isDirectory: true)
        guard Darwin.mkdir(dirPath, 0o700) == 0 else {
            throw HotReloadTransferError.syscallFailed("mkdir", errno)
        }
        let socketPath = dirURL.appendingPathComponent("h.sock").path
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            _ = Darwin.rmdir(dirPath)
            throw HotReloadTransferError.socketPathTooLong(socketPath)
        }
        return (dirURL, socketPath)
    }

    static func removePrivateSocket(directoryURL: URL, socketPath: String) {
        _ = Darwin.unlink(socketPath)
        _ = Darwin.rmdir(directoryURL.path)
    }

    /// Binds and listens on a Unix domain stream socket at `path`.
    static func listen(at path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw HotReloadTransferError.syscallFailed("socket", errno)
        }
        do {
            try configureSocket(fd)
            var address = try makeUnixAddress(path: path)
            let length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let bindResult = withUnsafePointer(to: &address) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.bind(fd, sockPtr, length)
                }
            }
            guard bindResult == 0 else {
                throw HotReloadTransferError.syscallFailed("bind", errno)
            }
            _ = Darwin.chmod(path, 0o600)
            guard Darwin.listen(fd, 4) == 0 else {
                throw HotReloadTransferError.syscallFailed("listen", errno)
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    /// Connects to a listening Unix domain stream socket at `path`.
    static func connect(to path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw HotReloadTransferError.syscallFailed("socket", errno)
        }
        do {
            try configureSocket(fd)
            var address = try makeUnixAddress(path: path)
            let length = socklen_t(MemoryLayout<sockaddr_un>.size)
            var result: Int32
            repeat {
                result = withUnsafePointer(to: &address) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        Darwin.connect(fd, sockPtr, length)
                    }
                }
            } while result == -1 && errno == EINTR
            guard result == 0 else {
                throw HotReloadTransferError.syscallFailed("connect", errno)
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    /// Accepts one client connection within `timeout` seconds and verifies that
    /// the peer's effective UID matches `geteuid()`.
    static func acceptVerifiedPeer(listeningFD: Int32, timeout: TimeInterval) throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        try waitUntilReady(fd: listeningFD, events: Int16(POLLIN), deadline: deadline, phase: "connection")

        var clientFD: Int32
        repeat {
            clientFD = Darwin.accept(listeningFD, nil, nil)
        } while clientFD == -1 && errno == EINTR
        guard clientFD >= 0 else {
            throw HotReloadTransferError.syscallFailed("accept", errno)
        }

        do {
            try configureSocket(clientFD)
            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            guard Darwin.getpeereid(clientFD, &peerUID, &peerGID) == 0 else {
                throw HotReloadTransferError.syscallFailed("getpeereid", errno)
            }
            let expectedUID = Darwin.geteuid()
            guard peerUID == expectedUID else {
                throw HotReloadTransferError.unauthorizedPeer(uid: peerUID, expected: expectedUID)
            }
            return clientFD
        } catch {
            Darwin.close(clientFD)
            throw error
        }
    }

    /// Sender side: authenticates the connected receiver, streams all pane
    /// entries and PTY master FDs via `SCM_RIGHTS`, and waits for `Ack`.
    static func serveHandoff(
        listeningFD: Int32,
        token: String,
        transfers: [HotReloadPaneTransfer],
        timeout: TimeInterval
    ) throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        let clientFD = try acceptVerifiedPeer(listeningFD: listeningFD, timeout: timeout)
        defer {
            Darwin.close(clientFD)
        }

        let hello: HotReloadWire.Hello = try receiveJSONFrame(from: clientFD, deadline: deadline, phase: "handshake")
        guard hello.protocolVersion == HotReloadWire.protocolVersion else {
            throw HotReloadTransferError.protocolError(
                "Unsupported hot-reload protocol version \(hello.protocolVersion)."
            )
        }
        guard constantTimeEquals(hello.token, token) else {
            throw HotReloadTransferError.tokenMismatch
        }

        let manifest = HotReloadWire.Manifest(
            protocolVersion: HotReloadWire.protocolVersion,
            sourcePID: getpid(),
            paneCount: transfers.count
        )
        try sendJSONFrame(manifest, to: clientFD, deadline: deadline, phase: "manifest")

        for transfer in transfers {
            try sendJSONFrame(transfer.entry, to: clientFD, deadline: deadline, phase: "pane metadata")
            try sendFileDescriptor(transfer.fd, over: clientFD, deadline: deadline)
        }

        let ack: HotReloadWire.Ack = try receiveJSONFrame(from: clientFD, deadline: deadline, phase: "acknowledgement")
        guard ack.ok else {
            throw HotReloadTransferError.peerRejected(ack.error ?? "unknown error")
        }
        return ack.acceptedCount
    }

    /// Receiver side: connects to the sender socket, authenticates with
    /// `token`, receives all pane entries and `SCM_RIGHTS` FDs (marking each
    /// `FD_CLOEXEC`), and sends `Ack`.
    static func receiveHandoff(
        socketPath: String,
        token: String,
        timeout: TimeInterval
    ) throws -> (sourcePID: pid_t, transfers: [HotReloadPaneTransfer]) {
        let deadline = Date().addingTimeInterval(timeout)
        let sockFD = try connect(to: socketPath)
        defer {
            Darwin.close(sockFD)
        }

        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard Darwin.getpeereid(sockFD, &peerUID, &peerGID) == 0 else {
            throw HotReloadTransferError.syscallFailed("getpeereid", errno)
        }
        let expectedUID = Darwin.geteuid()
        guard peerUID == expectedUID else {
            throw HotReloadTransferError.unauthorizedPeer(uid: peerUID, expected: expectedUID)
        }

        let hello = HotReloadWire.Hello(
            protocolVersion: HotReloadWire.protocolVersion,
            token: token,
            receiverPID: getpid()
        )
        try sendJSONFrame(hello, to: sockFD, deadline: deadline, phase: "handshake")

        let manifest: HotReloadWire.Manifest = try receiveJSONFrame(from: sockFD, deadline: deadline, phase: "manifest")
        guard manifest.protocolVersion == HotReloadWire.protocolVersion else {
            throw HotReloadTransferError.protocolError(
                "Unsupported hot-reload protocol version \(manifest.protocolVersion)."
            )
        }
        guard manifest.paneCount >= 0 else {
            throw HotReloadTransferError.protocolError("Negative pane count.")
        }

        var received: [HotReloadPaneTransfer] = []
        received.reserveCapacity(manifest.paneCount)
        do {
            for _ in 0..<manifest.paneCount {
                let entry: HotReloadPaneEntry = try receiveJSONFrame(
                    from: sockFD,
                    deadline: deadline,
                    phase: "pane metadata"
                )
                let fd = try receiveFileDescriptor(from: sockFD, deadline: deadline)
                received.append(HotReloadPaneTransfer(entry: entry, fd: fd))
            }
        } catch {
            for item in received {
                Darwin.close(item.fd)
            }
            let nack = HotReloadWire.Ack(ok: false, acceptedCount: 0, error: error.localizedDescription)
            try? sendJSONFrame(nack, to: sockFD, deadline: deadline, phase: "nack")
            throw error
        }

        let ack = HotReloadWire.Ack(ok: true, acceptedCount: received.count, error: nil)
        try sendJSONFrame(ack, to: sockFD, deadline: deadline, phase: "acknowledgement")
        return (manifest.sourcePID, received)
    }

    // MARK: - SCM_RIGHTS single-FD transfer

    /// Darwin's `__DARWIN_ALIGN32` alignment macro from `<sys/socket.h>`.
    private static func darwinAlign32(_ size: Int) -> Int {
        (size + 3) & ~3
    }

    private static var cmsgHeaderAlignedSize: Int {
        darwinAlign32(MemoryLayout<cmsghdr>.size)
    }

    private static var singleFDCmsgSpace: Int {
        cmsgHeaderAlignedSize + darwinAlign32(MemoryLayout<Int32>.size)
    }

    private static var singleFDCmsgLength: socklen_t {
        socklen_t(cmsgHeaderAlignedSize + MemoryLayout<Int32>.size)
    }

    /// Sends one file descriptor over `sockFD` accompanied by a 1-byte sentinel
    /// payload so `SOCK_STREAM` preserves exact control-message framing.
    static func sendFileDescriptor(_ fd: Int32, over sockFD: Int32, deadline: Date) throws {
        try waitUntilReady(fd: sockFD, events: Int16(POLLOUT), deadline: deadline, phase: "SCM_RIGHTS send")

        var sentinel: UInt8 = 0xFD
        var controlBuffer = [UInt8](repeating: 0, count: singleFDCmsgSpace)
        var fdToSend = fd

        let sent: Int = withUnsafeMutablePointer(to: &sentinel) { sentinelPtr in
            controlBuffer.withUnsafeMutableBytes { cbuf in
                let headerPtr = cbuf.baseAddress!.assumingMemoryBound(to: cmsghdr.self)
                headerPtr.pointee.cmsg_len = singleFDCmsgLength
                headerPtr.pointee.cmsg_level = SOL_SOCKET
                headerPtr.pointee.cmsg_type = SCM_RIGHTS

                let dataPtr = cbuf.baseAddress!.advanced(by: cmsgHeaderAlignedSize)
                withUnsafeBytes(of: &fdToSend) { fdBytes in
                    dataPtr.copyMemory(from: fdBytes.baseAddress!, byteCount: MemoryLayout<Int32>.size)
                }

                var iov = iovec(iov_base: sentinelPtr, iov_len: 1)
                return withUnsafeMutablePointer(to: &iov) { iovPtr in
                    var msg = msghdr()
                    msg.msg_iov = iovPtr
                    msg.msg_iovlen = 1
                    msg.msg_control = cbuf.baseAddress
                    msg.msg_controllen = socklen_t(singleFDCmsgSpace)

                    var result: Int
                    repeat {
                        result = Darwin.sendmsg(sockFD, &msg, 0)
                    } while result == -1 && errno == EINTR
                    return result
                }
            }
        }

        guard sent == 1 else {
            throw HotReloadTransferError.syscallFailed("sendmsg(SCM_RIGHTS)", sent == -1 ? errno : EIO)
        }
    }

    /// Receives one file descriptor from `sockFD` along with its 1-byte
    /// sentinel and sets `FD_CLOEXEC` on the received descriptor.
    static func receiveFileDescriptor(from sockFD: Int32, deadline: Date) throws -> Int32 {
        try waitUntilReady(fd: sockFD, events: Int16(POLLIN), deadline: deadline, phase: "SCM_RIGHTS receive")

        var sentinel: UInt8 = 0
        // Allocate slightly extra room so unexpected trailing control data
        // does not silently truncate.
        let controlCapacity = max(singleFDCmsgSpace, 64)
        var controlBuffer = [UInt8](repeating: 0, count: controlCapacity)
        var msgFlags: Int32 = 0
        var receivedControlLen: socklen_t = 0

        let bytesRead: Int = withUnsafeMutablePointer(to: &sentinel) { sentinelPtr in
            controlBuffer.withUnsafeMutableBytes { cbuf in
                var iov = iovec(iov_base: sentinelPtr, iov_len: 1)
                return withUnsafeMutablePointer(to: &iov) { iovPtr in
                    var msg = msghdr()
                    msg.msg_iov = iovPtr
                    msg.msg_iovlen = 1
                    msg.msg_control = cbuf.baseAddress
                    msg.msg_controllen = socklen_t(controlCapacity)

                    var result: Int
                    repeat {
                        result = Darwin.recvmsg(sockFD, &msg, 0)
                    } while result == -1 && errno == EINTR
                    msgFlags = msg.msg_flags
                    receivedControlLen = msg.msg_controllen
                    return result
                }
            }
        }

        if bytesRead == -1 {
            throw HotReloadTransferError.syscallFailed("recvmsg(SCM_RIGHTS)", errno)
        }
        guard bytesRead == 1 else {
            throw HotReloadTransferError.protocolError("Unexpected EOF while receiving SCM_RIGHTS descriptor.")
        }
        guard (msgFlags & MSG_CTRUNC) == 0 else {
            throw HotReloadTransferError.protocolError("SCM_RIGHTS control message was truncated.")
        }
        guard sentinel == 0xFD else {
            throw HotReloadTransferError.protocolError("Unexpected SCM_RIGHTS framing byte \(sentinel).")
        }

        // Walk control headers to locate SCM_RIGHTS and extract the descriptor.
        var extractedFDs: [Int32] = []
        controlBuffer.withUnsafeBytes { cbuf in
            var offset = 0
            let total = Int(receivedControlLen)
            while offset + MemoryLayout<cmsghdr>.size <= total {
                let header = cbuf.baseAddress!.advanced(by: offset).assumingMemoryBound(to: cmsghdr.self).pointee
                let cmsgLen = Int(header.cmsg_len)
                guard cmsgLen >= cmsgHeaderAlignedSize, offset + cmsgLen <= total else {
                    break
                }
                if header.cmsg_level == SOL_SOCKET && header.cmsg_type == SCM_RIGHTS {
                    let payloadBytes = cmsgLen - cmsgHeaderAlignedSize
                    let fdCount = payloadBytes / MemoryLayout<Int32>.size
                    let payloadBase = cbuf.baseAddress!.advanced(by: offset + cmsgHeaderAlignedSize)
                    for i in 0..<fdCount {
                        var fd: Int32 = -1
                        withUnsafeMutableBytes(of: &fd) { dst in
                            dst.copyMemory(
                                from: UnsafeRawBufferPointer(
                                    start: payloadBase.advanced(by: i * MemoryLayout<Int32>.size),
                                    count: MemoryLayout<Int32>.size
                                )
                            )
                        }
                        extractedFDs.append(fd)
                    }
                }
                offset += darwinAlign32(cmsgLen)
            }
        }

        guard let fd = extractedFDs.first, fd >= 0 else {
            throw HotReloadTransferError.missingFileDescriptor
        }
        // Close any unexpected extra descriptors so we never leak.
        for extra in extractedFDs.dropFirst() where extra >= 0 {
            Darwin.close(extra)
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    // MARK: - Framed JSON I/O

    private static func sendJSONFrame<T: Encodable>(
        _ value: T,
        to sockFD: Int32,
        deadline: Date,
        phase: String
    ) throws {
        let payload = try JSONEncoder().encode(value)
        guard payload.count <= HotReloadWire.maxFrameSize else {
            throw HotReloadTransferError.protocolError("Frame too large (\(payload.count) bytes).")
        }
        var lengthBE = UInt32(payload.count).bigEndian
        let header = withUnsafeBytes(of: &lengthBE) { Data($0) }
        try writeExact(header, to: sockFD, deadline: deadline, phase: phase)
        try writeExact(payload, to: sockFD, deadline: deadline, phase: phase)
    }

    private static func receiveJSONFrame<T: Decodable>(
        from sockFD: Int32,
        deadline: Date,
        phase: String
    ) throws -> T {
        let header = try readExact(4, from: sockFD, deadline: deadline, phase: phase)
        let length = Int(header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
        guard length > 0, length <= HotReloadWire.maxFrameSize else {
            throw HotReloadTransferError.protocolError("Invalid frame length \(length) during \(phase).")
        }
        let payload = try readExact(length, from: sockFD, deadline: deadline, phase: phase)
        return try JSONDecoder().decode(T.self, from: payload)
    }

    private static func writeExact(_ data: Data, to fd: Int32, deadline: Date, phase: String) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                return
            }
            var written = 0
            while written < raw.count {
                try waitUntilReady(fd: fd, events: Int16(POLLOUT), deadline: deadline, phase: phase)
                let count = Darwin.write(fd, base.advanced(by: written), raw.count - written)
                if count == -1 {
                    if errno == EINTR {
                        continue
                    }
                    throw HotReloadTransferError.syscallFailed("write", errno)
                }
                guard count > 0 else {
                    throw HotReloadTransferError.protocolError("Socket closed while writing \(phase).")
                }
                written += count
            }
        }
    }

    private static func readExact(_ count: Int, from fd: Int32, deadline: Date, phase: String) throws -> Data {
        var buffer = Data(count: count)
        try buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else {
                return
            }
            var offset = 0
            while offset < count {
                try waitUntilReady(fd: fd, events: Int16(POLLIN), deadline: deadline, phase: phase)
                let n = Darwin.read(fd, base.advanced(by: offset), count - offset)
                if n == -1 {
                    if errno == EINTR {
                        continue
                    }
                    throw HotReloadTransferError.syscallFailed("read", errno)
                }
                guard n > 0 else {
                    throw HotReloadTransferError.protocolError("Unexpected EOF while reading \(phase).")
                }
                offset += n
            }
        }
        return buffer
    }

    private static func waitUntilReady(fd: Int32, events: Int16, deadline: Date, phase: String) throws {
        while true {
            let remainingMs = Int32(ceil(deadline.timeIntervalSinceNow * 1000))
            if remainingMs <= 0 {
                throw HotReloadTransferError.timedOut(phase)
            }
            var pfd = pollfd(fd: fd, events: events, revents: 0)
            let ready = Darwin.poll(&pfd, 1, remainingMs)
            if ready == -1 {
                if errno == EINTR {
                    continue
                }
                throw HotReloadTransferError.syscallFailed("poll", errno)
            }
            if ready == 0 {
                throw HotReloadTransferError.timedOut(phase)
            }
            return
        }
    }

    private static func configureSocket(_ fd: Int32) throws {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func makeUnixAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let maxLen = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < maxLen else {
            throw HotReloadTransferError.socketPathTooLong(path)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { dest in
            dest.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in bytes.enumerated() {
                dest[index] = byte
            }
        }
        return address
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else {
            return false
        }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[i] ^ b[i]
        }
        return diff == 0
    }
}
