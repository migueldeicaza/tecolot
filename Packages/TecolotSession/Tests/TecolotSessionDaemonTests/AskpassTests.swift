import Foundation
import Synchronization
import Testing
import TecolotSessionClient
import TecolotTransport
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private enum AskpassTestError: Error { case timeout }

private func askpassWait(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw AskpassTestError.timeout
}

private final class AskpassProcess: @unchecked Sendable {
    let process = Process()
    let output = Pipe()
    init(socket: String, token: String, prompt: [String], kind: String = "", wrapper: URL? = nil) throws {
        process.executableURL = try wrapper ?? URL(fileURLWithPath: helperPath())
        process.arguments = (wrapper == nil ? ["askpass"] : []) + prompt
        process.environment = ["TECOLOT_ASKPASS_SOCKET": socket, "TECOLOT_ASKPASS_TOKEN": token,
                               "SSH_ASKPASS_PROMPT": kind]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        try output.fileHandleForWriting.close()
    }
    deinit { if process.isRunning { process.terminate() } }
    func result() async throws -> (Int32, String) {
        try await askpassWait { !process.isRunning }
        return (process.terminationStatus,
                String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}

struct AskpassTests {
    @Test func wrapperRoundTripSuppliesSecretWithHostAndStderr() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.url) }
        let server = try AskpassServer(runtimeDirectory: directory.url)
        defer { server.close() }
        var socketStatus = stat()
        #expect(lstat(server.socketPath, &socketStatus) == 0)
        #expect(socketStatus.st_mode & 0o777 == 0o600)
        let request = Mutex<AskpassRequest?>(nil)
        let token = server.register(host: "user@server:22", stderr: { (1...30).map(String.init).joined(separator: "\n") + "\nDuo login instructions" }) { value, reply in
            request.withLock { $0 = value }
            reply("a secret with spaces")
        }
        let wrapper = try server.createWrapper(helperPath: helperPath())
        var status = stat()
        #expect(lstat(wrapper.path, &status) == 0)
        #expect(status.st_mode & 0o777 == 0o700)
        #expect(String(decoding: try Data(contentsOf: wrapper), as: UTF8.self)
            == "#!/bin/sh\nexec '\(try helperPath())' askpass \"$@\"\n")
        let child = try AskpassProcess(socket: server.socketPath, token: token,
                                      prompt: ["Enter", "passphrase for key:"], wrapper: wrapper)
        let (code, output) = try await child.result()
        #expect(code == 0)
        #expect(output == "a secret with spaces\n")
        let value = try #require(request.withLock { $0 })
        #expect(value.style == .secret)
        #expect(value.hostKey == "user@server:22")
        #expect(value.stderrLines.count == 20)
        #expect(value.stderrLines.first == "12")
        #expect(value.stderrLines.last == "Duo login instructions")
        #expect(value.prompt == "Enter passphrase for key:")
    }

    @Test func cancelAndUnknownTokenFailWithoutOutput() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.url) }
        let server = try AskpassServer(runtimeDirectory: directory.url)
        defer { server.close() }
        let calls = Mutex(0)
        let token = server.register(host: "server") { _, reply in
            calls.withLock { $0 += 1 }
            reply(nil)
        }
        for value in [token, "unknown-token"] {
            let child = try AskpassProcess(socket: server.socketPath, token: value, prompt: ["Password:"])
            let (code, output) = try await child.result()
            #expect(code == 1)
            #expect(output.isEmpty)
        }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func securityKeyNoticeEndsWhenHelperExits() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.url) }
        let server = try AskpassServer(runtimeDirectory: directory.url)
        defer { server.close() }
        let shown = Mutex<AskpassRequest?>(nil)
        let dismissed = Mutex<UUID?>(nil)
        let token = server.register(host: "server", handler: { request, reply in
            shown.withLock { $0 = request }
            reply("must not answer a notice")
        }, onDismiss: { id in dismissed.withLock { $0 = id } })
        let child = try AskpassProcess(socket: server.socketPath, token: token,
                                      prompt: ["Touch your security key"], kind: "none")
        try await askpassWait { shown.withLock { $0 != nil } }
        #expect(shown.withLock { $0?.style } == .notice)
        try await Task.sleep(for: .milliseconds(30))
        #expect(child.process.isRunning)
        #expect(dismissed.withLock { $0 } == nil)
        child.process.terminate()
        let (_, output) = try await child.result()
        try await askpassWait { dismissed.withLock { $0 != nil } }
        #expect(output.isEmpty)
        #expect(dismissed.withLock { $0 } == shown.withLock { $0?.id })
    }

    @Test func serverCloseCancelsPendingPromptAndNotice() async throws {
        for kind in ["", "none"] {
            let directory = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory.url) }
            let server = try AskpassServer(runtimeDirectory: directory.url)
            defer { server.close() }
            let shown = Mutex(false)
            let dismissed = Mutex(false)
            let token = server.register(host: "server", handler: { _, _ in shown.withLock { $0 = true } },
                                        onDismiss: { _ in dismissed.withLock { $0 = true } })
            let child = try AskpassProcess(socket: server.socketPath, token: token,
                                          prompt: ["Prompt"], kind: kind)
            try await askpassWait { shown.withLock { $0 } }
            server.close()
            let (code, output) = try await child.result()
            #expect(code == 1)
            #expect(output.isEmpty)
            #expect(dismissed.withLock { $0 })
        }
    }

    @Test func unregisterClosesPromptAndRejectsOldToken() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.url) }
        let server = try AskpassServer(runtimeDirectory: directory.url)
        defer { server.close() }
        let shown = Mutex(false)
        let token = server.register(host: "server") { _, _ in shown.withLock { $0 = true } }
        let child = try AskpassProcess(socket: server.socketPath, token: token, prompt: ["Password:"])
        try await askpassWait { shown.withLock { $0 } }
        server.unregister(token: token)
        let (code, output) = try await child.result()
        #expect(code == 1)
        #expect(output.isEmpty)
        let next = try AskpassProcess(socket: server.socketPath, token: token, prompt: ["Password:"])
        let (nextCode, nextOutput) = try await next.result()
        #expect(nextCode == 1)
        #expect(nextOutput.isEmpty)
    }

    @Test func malformedReplyFailsWithoutOutput() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.url) }
        let path = directory.url.appendingPathComponent("fake-askpass.sock").path
        let listener = try UnixSocket.listen(path: path)
        defer { close(listener) }
        let child = try AskpassProcess(socket: path, token: "token", prompt: ["Password:"])
        var accepted: Int32?
        try await askpassWait {
            accepted = try? UnixSocket.accept(listener)
            return accepted != nil
        }
        let fd = try #require(accepted)
        defer { close(fd) }
        var bytes = [UInt8](repeating: 0, count: 4096)
        var request = Data()
        // accept can return a nonblocking socket before the helper writes JSON.
        try await askpassWait {
            let count = recv(fd, &bytes, bytes.count, MSG_DONTWAIT)
            if count > 0 { request.append(contentsOf: bytes.prefix(count)) }
            else if count == 0 { Issue.record("The askpass helper closed before its request"); return true }
            else { #expect(errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) }
            return request.contains(10)
        }
        #expect(request.contains(10))
        let reply = Data("{\"ok\":true,\"text\":7}\n".utf8)
        let sent = reply.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
        #expect(sent == reply.count)
        let (code, output) = try await child.result()
        #expect(code == 1)
        #expect(output.isEmpty)
    }

    @Test func overlongRequestFailsWithoutPromptDispatch() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.url) }
        let server = try AskpassServer(runtimeDirectory: directory.url)
        defer { server.close() }
        let calls = Mutex(0)
        let token = server.register(host: "server") { _, reply in
            calls.withLock { $0 += 1 }
            reply("answer")
        }
        let child = try AskpassProcess(socket: server.socketPath, token: token,
                                      prompt: [String(repeating: "a", count: 64 * 1024)])
        let (code, output) = try await child.result()
        #expect(code == 1)
        #expect(output.isEmpty)
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func serverReleaseDismissesSecurityKeyNotice() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.url) }
        var server: AskpassServer? = try AskpassServer(runtimeDirectory: directory.url)
        let shown = Mutex(false)
        let dismissed = Mutex(false)
        let token = server!.register(host: "server", handler: { _, _ in shown.withLock { $0 = true } },
                                     onDismiss: { _ in dismissed.withLock { $0 = true } })
        let child = try AskpassProcess(socket: server!.socketPath, token: token, prompt: ["Touch key"], kind: "none")
        try await askpassWait { shown.withLock { $0 } }
        server = nil
        let (code, output) = try await child.result()
        try await askpassWait { dismissed.withLock { $0 } }
        #expect(code == 1)
        #expect(output.isEmpty)
    }

    @Test func promptStylesAndWrapperQuoteRejection() throws {
        #expect(AskpassRequest.style(prompt: "Password:", kind: "") == .secret)
        #expect(AskpassRequest.style(prompt: "Enter PASSPHRASE:", kind: "") == .secret)
        #expect(AskpassRequest.style(prompt: "Are you sure you want to continue connecting (yes/no)?", kind: "confirm") == .hostKey)
        #expect(AskpassRequest.style(prompt: "Verification code:", kind: "") == .text)
        #expect(AskpassRequest.style(prompt: "Password:", kind: "none") == .notice)
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.url) }
        #expect(throws: TransportError.self) {
            try AskpassServer.writeWrapper(helperPath: "/bad'path", in: directory.url)
        }
    }

    @Test func wrapperIsReplacedOnlyWhenItChanges() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.url) }
        let wrapper = try AskpassServer.writeWrapper(helperPath: "/opt/one/tecolot-sessiond", in: directory.url)
        var first = stat()
        #expect(stat(wrapper.path, &first) == 0)
        #expect(first.st_mode & 0o777 == 0o700)
        // An ssh process can run the wrapper while another one starts: it keeps the same file.
        _ = try AskpassServer.writeWrapper(helperPath: "/opt/one/tecolot-sessiond", in: directory.url)
        var same = stat()
        #expect(stat(wrapper.path, &same) == 0)
        #expect(same.st_ino == first.st_ino)
        _ = try AskpassServer.writeWrapper(helperPath: "/opt/two/tecolot-sessiond", in: directory.url)
        var changed = stat()
        #expect(stat(wrapper.path, &changed) == 0)
        #expect(changed.st_ino != first.st_ino)
        #expect(changed.st_mode & 0o777 == 0o700)
        #expect(try String(contentsOf: wrapper, encoding: .utf8).contains("/opt/two/tecolot-sessiond"))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
        #expect(!names.contains { $0.hasPrefix(".askpass-") })
    }
}
