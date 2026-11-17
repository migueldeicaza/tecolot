// Askpass.swift
// TecolotSessionDaemon

import Foundation
import TecolotTransport
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A one-request SSH_ASKPASS client. It does not store or log the answer.
public enum Askpass {
    private struct Request: Encodable { let token: String; let prompt: String; let kind: String }
    private struct Response: Decodable { let ok: Bool; let text: String? }

    /// Returns zero only when the app supplied a text answer.
    public static func run(arguments: [String],
                           environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        UnixSocket.setNoSignalOnBrokenPipe(STDOUT_FILENO)
        guard let socket = environment["TECOLOT_ASKPASS_SOCKET"], !socket.isEmpty,
              let token = environment["TECOLOT_ASKPASS_TOKEN"], !token.isEmpty,
              let fd = try? UnixSocket.connect(path: socket) else { return 1 }
        defer { close(fd) }
        let kind = environment["SSH_ASKPASS_PROMPT"] ?? ""
        let request = Request(token: token, prompt: arguments.joined(separator: " "), kind: kind)
        guard var data = try? JSONEncoder().encode(request) else { return 1 }
        data.append(10)
        guard writeAll(data, to: fd) else { return 1 }
        var input = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return 1 }
            // Security key notices stay open until ssh stops the helper or the app closes it.
            if kind == "none" { continue }
            input.append(contentsOf: bytes.prefix(count))
            guard input.count <= 64 * 1024 else { return 1 }
            if let end = input.firstIndex(of: 10) {
                guard end == input.count - 1,
                      let response = try? JSONDecoder().decode(Response.self, from: input.prefix(upTo: end)),
                      response.ok, let text = response.text else { return 1 }
                do { try FileHandle.standardOutput.write(contentsOf: Data((text + "\n").utf8)) }
                catch { return 1 }
                return 0
            }
        }
    }

    private static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes {
                send(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset, Int32(MSG_NOSIGNAL))
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return false }
            offset += count
        }
        return true
    }
}
