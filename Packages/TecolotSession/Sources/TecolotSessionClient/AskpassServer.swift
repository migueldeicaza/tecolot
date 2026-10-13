// AskpassServer.swift
// TecolotSessionClient

import Dispatch
import Foundation
import Synchronization
import TecolotTransport
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum AskpassStyle: Sendable {
    case secret, hostKey, notice, text
}

public struct AskpassRequest: Sendable {
    public let id: UUID
    public let token: String
    public let host: String
    public let stderr: String
    public let prompt: String
    public let kind: String
    public let style: AskpassStyle
    public var hostKey: String { host }
    public var stderrLines: [String] { Array(stderr.split(whereSeparator: \.isNewline).map(String.init).suffix(20)) }

    public static func style(prompt: String, kind: String) -> AskpassStyle {
        if kind == "none" { return .notice }
        let lower = prompt.lowercased()
        if lower.contains("are you sure you want to continue connecting") { return .hostKey }
        if lower.contains("password") || lower.contains("passphrase") { return .secret }
        return .text
    }
}

/// Each SSH process registers one token. Callbacks run on the server queue.
/// The reply can run on any queue. A nil reply cancels the prompt.
public final class AskpassServer: @unchecked Sendable {
    public typealias Reply = @Sendable (String?) -> Void
    public typealias Handler = @Sendable (AskpassRequest, @escaping Reply) -> Void
    public let socketPath: String
    public let queue = DispatchQueue(label: "tecolot.askpass")
    private let runtimeDirectory: URL
    private let queueKey = DispatchSpecificKey<Bool>()
    private let registrations = Mutex<[String: Registration]>([:])
    private var listener: DispatchSourceRead?
    private var connections: [UUID: Connection] = [:]
    private var closed = false

    private struct Registration: Sendable {
        let host: String
        let stderr: @Sendable () -> String
        let handler: Handler
        let onDismiss: @Sendable (UUID) -> Void
    }
    private struct Input: Decodable { let token: String; let prompt: String; let kind: String }
    private struct Output: Encodable { let ok: Bool; let text: String? }
    private final class Connection: @unchecked Sendable {
        let id = UUID()
        let fd: Int32
        let sources = DispatchGroup()
        var closing = false
        var source: DispatchSourceRead?
        var writeSource: DispatchSourceWrite?
        var input = Data()
        var output = Data()
        var offset = 0
        var request: AskpassRequest?
        var onDismiss: (@Sendable (UUID) -> Void)?
        var answered = false
        init(fd: Int32) { self.fd = fd }
        func track(_ source: any DispatchSourceProtocol) {
            sources.enter()
            source.setCancelHandler { [sources] in sources.leave() }
        }
        func close(on queue: DispatchQueue) {
            guard !closing else { return }
            closing = true
            sources.notify(queue: queue) { [fd] in askpassClose(fd) }
        }
    }

    public init(runtimeDirectory: URL) throws {
        try RuntimeDirectory.prepare(runtimeDirectory)
        self.runtimeDirectory = runtimeDirectory
        socketPath = runtimeDirectory.appendingPathComponent("askpass.sock").path
        let fd = try UnixSocket.listen(path: socketPath)
        queue.setSpecific(key: queueKey, value: true)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnections(fd) }
        source.setCancelHandler { Self.closeFD(fd) }
        listener = source
        source.resume()
    }

    deinit {
        listener?.cancel()
        for connection in connections.values {
            connection.writeSource?.cancel()
            connection.source?.cancel()
            connection.close(on: queue)
            if let dismiss = connection.onDismiss {
                let id = connection.id
                queue.async { dismiss(id) }
            }
        }
        if !closed { unlink(socketPath) }
    }

    @discardableResult
    public func register(host: String, stderr: @escaping @Sendable () -> String = { "" },
                         handler: @escaping Handler,
                         onDismiss: @escaping @Sendable (UUID) -> Void = { _ in }) -> String {
        let token = UUID().uuidString + UUID().uuidString
        registrations.withLock {
            $0[token] = Registration(host: host, stderr: stderr, handler: handler, onDismiss: onDismiss)
        }
        return token
    }

    public func unregister(token: String) {
        _ = registrations.withLock { $0.removeValue(forKey: token) }
        queue.async { [self] in
            for connection in Array(connections.values) where connection.request?.token == token {
                finish(connection)
            }
        }
    }

    /// Stops the listener and dismisses all pending prompts before this method returns.
    public func close() {
        let action = { [self] in
            guard !closed else { return }
            closed = true
            registrations.withLock { $0.removeAll() }
            listener?.cancel()
            listener = nil
            for connection in Array(connections.values) { finish(connection) }
            unlink(socketPath)
        }
        if DispatchQueue.getSpecific(key: queueKey) == true { action() }
        else { queue.sync(execute: action) }
    }

    public func createWrapper(helperPath: String) throws -> URL {
        try Self.writeWrapper(helperPath: helperPath, in: runtimeDirectory)
    }

    public static func writeWrapper(helperPath: String, in directory: URL) throws -> URL {
        guard !helperPath.contains("'"), !helperPath.contains("\0") else {
            throw TransportError("askpass helper path contains a quote or NUL", code: EINVAL)
        }
        try RuntimeDirectory.prepare(directory)
        let url = directory.appendingPathComponent("askpass")
        try Data("#!/bin/sh\nexec '\(helperPath)' askpass \"$@\"\n".utf8).write(to: url, options: .atomic)
        guard chmod(url.path, 0o700) == 0 else { throw TransportError("chmod askpass wrapper") }
        return url
    }

    private func acceptConnections(_ fd: Int32) {
        guard !closed else { return }
        while let accepted = try? UnixSocket.accept(fd) {
            guard UnixSocket.peerUID(accepted) == getuid() else { Self.closeFD(accepted); continue }
            UnixSocket.setNonBlocking(accepted)
            UnixSocket.setNoSignalOnBrokenPipe(accepted)
            let connection = Connection(fd: accepted)
            let source = DispatchSource.makeReadSource(fileDescriptor: accepted, queue: queue)
            source.setEventHandler { [weak self, weak connection] in
                guard let connection else { return }
                self?.read(connection)
            }
            connection.track(source)
            connection.source = source
            connections[connection.id] = connection
            source.resume()
        }
    }

    private func read(_ connection: Connection) {
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = bytes.withUnsafeMutableBytes { Self.readFD(connection.fd, $0.baseAddress, $0.count) }
            if count == 0 { finish(connection); return }
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { finish(connection) }
                return
            }
            guard connection.request == nil, !connection.answered else { finish(connection); return }
            connection.input.append(contentsOf: bytes.prefix(count))
            guard connection.input.count <= 64 * 1024 else { finish(connection); return }
            if let end = connection.input.firstIndex(of: 10) {
                guard end == connection.input.count - 1,
                      let input = try? JSONDecoder().decode(Input.self, from: connection.input.prefix(upTo: end)),
                      let registration = registrations.withLock({ $0[input.token] }) else {
                    respond(connection, text: nil)
                    return
                }
                let stderr = registration.stderr().split(whereSeparator: \.isNewline).suffix(20).joined(separator: "\n")
                let request = AskpassRequest(id: connection.id, token: input.token, host: registration.host,
                    stderr: stderr, prompt: input.prompt, kind: input.kind,
                    style: AskpassRequest.style(prompt: input.prompt, kind: input.kind))
                connection.request = request
                connection.input.removeAll()
                connection.onDismiss = registration.onDismiss
                registration.handler(request) { [weak self, weak connection] text in
                    guard let self, let connection else { return }
                    queue.async { [self, connection] in
                        guard connections[connection.id] != nil, request.style != .notice else { return }
                        respond(connection, text: text)
                    }
                }
                return
            }
        }
    }

    private func respond(_ connection: Connection, text: String?) {
        guard !connection.answered else { return }
        connection.answered = true
        guard var data = try? JSONEncoder().encode(Output(ok: text != nil, text: text)) else {
            finish(connection); return
        }
        data.append(10)
        connection.output = data
        flush(connection)
    }

    private func flush(_ connection: Connection) {
        while connection.offset < connection.output.count {
            let count = connection.output.withUnsafeBytes { buffer in
                send(connection.fd, buffer.baseAddress!.advanced(by: connection.offset),
                     buffer.count - connection.offset, Int32(MSG_NOSIGNAL))
            }
            if count > 0 { connection.offset += count; continue }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                guard connection.writeSource == nil else { return }
                let source = DispatchSource.makeWriteSource(fileDescriptor: connection.fd, queue: queue)
                connection.track(source)
                source.setEventHandler { [weak self, weak connection] in
                    guard let connection else { return }
                    self?.flush(connection)
                }
                connection.writeSource = source
                source.resume()
                return
            }
            finish(connection); return
        }
        finish(connection)
    }

    private func finish(_ connection: Connection) {
        guard connections.removeValue(forKey: connection.id) != nil else { return }
        connection.writeSource?.cancel()
        connection.source?.cancel()
        connection.close(on: queue)
        connection.onDismiss?(connection.id)
    }

    private static func closeFD(_ fd: Int32) { askpassClose(fd) }
    private static func readFD(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        askpassRead(fd, buffer, count)
    }
}

private func askpassClose(_ fd: Int32) { _ = close(fd) }
private func askpassRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    read(fd, buffer, count)
}
