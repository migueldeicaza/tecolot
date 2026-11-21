//
//  HotReloadTests.swift
//  TecolotTests
//
//  Verifies SCM_RIGHTS PTY handoff, kqueue EVFILT_PROC (NOTE_EXITSTATUS)
//  exit observation after XNU reparents children to launchd (PID 1),
//  two-phase pause/rollback/commit, and HotReloadInbox ownership.
//

import Darwin
import Foundation
import os
import SwiftTerm
import Testing
@testable import Tecolot

private nonisolated final class TestProcessCollector: HotReloadableLocalProcessDelegate, Sendable {
    private struct State {
        var output = ""
        var terminated = false
        var exitCode: Int32?
        var launchError: LocalProcessError?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let exitSemaphore = DispatchSemaphore(value: 0)

    func hotReloadProcess(_ source: HotReloadableLocalProcess, didReceiveData bytes: [UInt8]) {
        let chunk = String(decoding: bytes, as: UTF8.self)
        state.withLock { $0.output += chunk }
    }

    func hotReloadProcess(_ source: HotReloadableLocalProcess, didTerminateWithExitCode exitCode: Int32?) {
        let shouldSignal = state.withLock { s -> Bool in
            guard !s.terminated else {
                return false
            }
            s.terminated = true
            s.exitCode = exitCode
            return true
        }
        if shouldSignal {
            exitSemaphore.signal()
        }
    }

    func hotReloadProcess(_ source: HotReloadableLocalProcess, didFailToStart error: LocalProcessError) {
        state.withLock { $0.launchError = error }
        exitSemaphore.signal()
    }

    var output: String {
        state.withLock { $0.output }
    }

    func waitForOutput(containing needle: String, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if state.withLock({ $0.output.contains(needle) }) {
                return true
            }
            usleep(10_000)
        }
        return state.withLock { $0.output.contains(needle) }
    }

    func waitForExit(timeout: TimeInterval = 5) -> (terminated: Bool, exitCode: Int32?) {
        _ = exitSemaphore.wait(timeout: .now() + timeout)
        return state.withLock { ($0.terminated, $0.exitCode) }
    }
}

/// Python helper script that simulates an old Tecolot process:
/// 1. Forks a child shell under a real PTY (`pty.fork()`).
/// 2. Listens on a Unix domain socket and speaks Tecolot's framed SCM_RIGHTS
///    hot-reload protocol.
/// 3. Immediately exits via `os._exit(0)` after receiving `Ack`, causing XNU
///    to reparent the live child shell to `launchd` (PID 1).
private let pythonSenderScript = """
import array, json, os, pty, socket, struct, sys

socket_path = sys.argv[1]
token = sys.argv[2]
pane_id = sys.argv[3]
shell_cmd = sys.argv[4]

pid, master_fd = pty.fork()
if pid == 0:
    os.execv("/bin/sh", ["/bin/sh", "-c", shell_cmd])
    os._exit(127)

def read_exact(conn, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise EOFError("short read")
        buf.extend(chunk)
    return bytes(buf)

def recv_json(conn):
    hdr = read_exact(conn, 4)
    length = struct.unpack(">I", hdr)[0]
    return json.loads(read_exact(conn, length).decode("utf-8"))

def send_json(conn, obj):
    payload = json.dumps(obj).encode("utf-8")
    conn.sendall(struct.pack(">I", len(payload)) + payload)

srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(socket_path)
os.chmod(socket_path, 0o600)
srv.listen(1)
# Tell the test harness the socket is listening.
sys.stdout.write("LISTENING\\n")
sys.stdout.flush()

conn, _ = srv.accept()
hello = recv_json(conn)
assert hello["protocolVersion"] == 1
assert hello["token"] == token

send_json(conn, {
    "protocolVersion": 1,
    "sourcePID": os.getpid(),
    "paneCount": 1,
})

send_json(conn, {
    "paneID": pane_id,
    "shellPid": pid,
    "startTime": None,
    "cols": 80,
    "rows": 24,
})

conn.sendmsg(
    [b"\\xfd"],
    [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [master_fd]))],
)

ack = recv_json(conn)
assert ack["ok"] is True and ack["acceptedCount"] == 1

conn.close()
srv.close()
os.close(master_fd)
os._exit(0)
"""

struct HotReloadTests {
    @Test func scmRightsRejectsWrongTokenAndTransfersPipeFDWithCloexec() throws {
        let (dirURL, socketPath) = try FDTransferSocket.makePrivateSocketPath()
        defer { FDTransferSocket.removePrivateSocket(directoryURL: dirURL, socketPath: socketPath) }

        let listenFD = try FDTransferSocket.listen(at: socketPath)
        defer { Darwin.close(listenFD) }

        let expectedToken = FDTransferSocket.makeRandomToken()
        var pipeFDs: [Int32] = [-1, -1]
        #expect(Darwin.pipe(&pipeFDs) == 0)
        defer {
            if pipeFDs[0] >= 0 { Darwin.close(pipeFDs[0]) }
            if pipeFDs[1] >= 0 { Darwin.close(pipeFDs[1]) }
        }

        // First: verify token mismatch is rejected.
        let badServer = DispatchQueue.global().sync { () -> Void in }
        _ = badServer
        let rejectDone = DispatchSemaphore(value: 0)
        let serverErrorBox = OSAllocatedUnfairLock<Error?>(initialState: nil)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try FDTransferSocket.serveHandoff(
                    listeningFD: listenFD,
                    token: expectedToken,
                    transfers: [],
                    timeout: 5
                )
            } catch {
                serverErrorBox.withLock { $0 = error }
            }
            rejectDone.signal()
        }

        #expect(throws: Error.self) {
            _ = try FDTransferSocket.receiveHandoff(
                socketPath: socketPath,
                token: "wrong-token",
                timeout: 5
            )
        }
        _ = rejectDone.wait(timeout: .now() + 5)
        let serverError = serverErrorBox.withLock { $0 }
        #expect(serverError != nil)

        // Second: verify valid SCM_RIGHTS transfer, FD_CLOEXEC, and post-close I/O.
        let paneID = UUID()
        let transfer = HotReloadPaneTransfer(
            entry: HotReloadPaneEntry(paneID: paneID, shellPid: getpid(), startTime: nil, cols: 80, rows: 24),
            fd: pipeFDs[0]
        )
        let okDone = DispatchSemaphore(value: 0)
        let acceptedBox = OSAllocatedUnfairLock<Int?>(initialState: nil)
        DispatchQueue.global(qos: .userInitiated).async {
            let count = try? FDTransferSocket.serveHandoff(
                listeningFD: listenFD,
                token: expectedToken,
                transfers: [transfer],
                timeout: 5
            )
            acceptedBox.withLock { $0 = count }
            okDone.signal()
        }

        let received = try FDTransferSocket.receiveHandoff(
            socketPath: socketPath,
            token: expectedToken,
            timeout: 5
        )
        _ = okDone.wait(timeout: .now() + 5)

        #expect(acceptedBox.withLock { $0 } == 1)
        #expect(received.sourcePID == getpid())
        #expect(received.transfers.count == 1)

        let item = try #require(received.transfers.first)
        defer { Darwin.close(item.fd) }
        #expect(item.entry.paneID == paneID)
        #expect(item.fd != pipeFDs[0])

        let fdFlags = fcntl(item.fd, F_GETFD)
        #expect((fdFlags & FD_CLOEXEC) != 0)

        // Close sender's read end; write into the pipe and read from the transferred FD.
        Darwin.close(pipeFDs[0])
        pipeFDs[0] = -1

        let payload = Array("scm-rights-ok".utf8)
        let written = payload.withUnsafeBytes { Darwin.write(pipeFDs[1], $0.baseAddress!, $0.count) }
        #expect(written == payload.count)

        var readBuf = [UInt8](repeating: 0, count: 64)
        let n = readBuf.withUnsafeMutableBytes { Darwin.read(item.fd, $0.baseAddress!, $0.count) }
        #expect(n == payload.count)
        #expect(String(decoding: readBuf[0..<max(0, n)], as: UTF8.self) == "scm-rights-ok")
    }

    @Test func adoptedProcessSurvivesSenderExitReparentingToLaunchdAndReportsExitCode() throws {
        let (dirURL, socketPath) = try FDTransferSocket.makePrivateSocketPath()
        defer { FDTransferSocket.removePrivateSocket(directoryURL: dirURL, socketPath: socketPath) }

        let token = FDTransferSocket.makeRandomToken()
        let paneID = UUID()

        let sender = Process()
        sender.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        sender.arguments = [
            "-c",
            pythonSenderScript,
            socketPath,
            token,
            paneID.uuidString,
            "echo READY; read line; echo GOT:$line; exit 42"
        ]
        let readyPipe = Pipe()
        sender.standardOutput = readyPipe
        try sender.run()

        // Wait until the Python sender has bound the socket.
        let readyData = readyPipe.fileHandleForReading.availableData
        #expect(String(decoding: readyData, as: UTF8.self).contains("LISTENING"))

        // Receive the PTY master FD via SCM_RIGHTS from Process A.
        let received = try FDTransferSocket.receiveHandoff(
            socketPath: socketPath,
            token: token,
            timeout: 5
        )
        let transfer = try #require(received.transfers.first)
        #expect(transfer.entry.paneID == paneID)
        let shellPid = transfer.entry.shellPid
        #expect(shellPid > 0)

        // Wait for Process A to exit completely so XNU reparents the shell to launchd (PID 1).
        sender.waitUntilExit()
        #expect(sender.terminationStatus == 0)

        // Confirm reparenting to PID 1 AND confirm waitpid() returns ECHILD
        // (the exact failure mode of SwiftTerm's LocalProcessChildReaper.wait()).
        let ppid = ProcessStartTime.parentPID(of: shellPid)
        #expect(ppid == 1)
        var rawStatus: Int32 = 0
        let waitResult = waitpid(shellPid, &rawStatus, WNOHANG)
        #expect(waitResult == -1)
        #expect(errno == ECHILD)

        // Adopt the reparented process in HotReloadableLocalProcess.
        let collector = TestProcessCollector()
        let adopted = HotReloadableLocalProcess(delegate: collector, deliveryQueue: DispatchQueue.global())
        let size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 800, ws_ypixel: 480)
        let attachResult = adopted.attachAdopted(
            fd: transfer.fd,
            shellPid: shellPid,
            startTime: ProcessStartTime.current(for: shellPid),
            windowSize: size,
            sendSigwinch: true
        )
        try attachResult.get()
        #expect(adopted.isAdopted)
        #expect(adopted.running)

        // Verify live bidirectional I/O continues seamlessly after Process A exited.
        #expect(collector.waitForOutput(containing: "READY", timeout: 5))
        let input = Array("hot-reload-works\n".utf8)
        adopted.send(data: input[...])
        #expect(collector.waitForOutput(containing: "GOT:hot-reload-works", timeout: 5))

        // Verify kqueue EVFILT_PROC NOTE_EXIT | NOTE_EXITSTATUS recovers exact exit code 42!
        let exitInfo = collector.waitForExit(timeout: 5)
        #expect(exitInfo.terminated)
        #expect(exitInfo.exitCode == 42)
        #expect(!adopted.running)
    }

    @Test func adoptedReparentedProcessReceivesSigtermAndReportsNilExitCode() throws {
        let (dirURL, socketPath) = try FDTransferSocket.makePrivateSocketPath()
        defer { FDTransferSocket.removePrivateSocket(directoryURL: dirURL, socketPath: socketPath) }

        let token = FDTransferSocket.makeRandomToken()
        let paneID = UUID()

        let sender = Process()
        sender.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        sender.arguments = [
            "-c",
            pythonSenderScript,
            socketPath,
            token,
            paneID.uuidString,
            "echo LIVE; exec sleep 60"
        ]
        let readyPipe = Pipe()
        sender.standardOutput = readyPipe
        try sender.run()

        let readyData = readyPipe.fileHandleForReading.availableData
        #expect(String(decoding: readyData, as: UTF8.self).contains("LISTENING"))

        let received = try FDTransferSocket.receiveHandoff(
            socketPath: socketPath,
            token: token,
            timeout: 5
        )
        let transfer = try #require(received.transfers.first)
        sender.waitUntilExit()

        #expect(ProcessStartTime.parentPID(of: transfer.entry.shellPid) == 1)

        let collector = TestProcessCollector()
        let adopted = HotReloadableLocalProcess(delegate: collector, deliveryQueue: DispatchQueue.global())
        let size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 800, ws_ypixel: 480)
        try adopted.attachAdopted(
            fd: transfer.fd,
            shellPid: transfer.entry.shellPid,
            startTime: ProcessStartTime.current(for: transfer.entry.shellPid),
            windowSize: size,
            sendSigwinch: false
        ).get()

        #expect(collector.waitForOutput(containing: "LIVE", timeout: 5))
        adopted.terminate()

        let exitInfo = collector.waitForExit(timeout: 5)
        #expect(exitInfo.terminated)
        #expect(exitInfo.exitCode == nil)
    }

    @Test func twoPhasePauseRollbackAndCommitHandoffPreserveLiveShell() throws {
        let collectorA = TestProcessCollector()
        var processA: HotReloadableLocalProcess? = HotReloadableLocalProcess(
            delegate: collectorA,
            deliveryQueue: DispatchQueue.global()
        )
        let size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 800, ws_ypixel: 480)
        try #require(processA).startProcess(
            executable: "/bin/sh",
            args: ["-c", "echo STARTED; read a; echo FIRST:$a; read b; echo SECOND:$b; exit 7"],
            windowSize: size
        ).get()
        #expect(collectorA.waitForOutput(containing: "STARTED", timeout: 5))

        // Phase 1 + Rollback: pause, then resume after an aborted hot reload.
        let abortedSnapshot = try #require(processA?.pauseForHandoff())
        #expect(abortedSnapshot.fd >= 0)
        #expect(abortedSnapshot.shellPid > 0)
        processA?.resumeAfterAbortedHandoff()

        let firstLine = Array("after-rollback\n".utf8)
        processA?.send(data: firstLine[...])
        #expect(collectorA.waitForOutput(containing: "FIRST:after-rollback", timeout: 5))

        // Phase 1 + SCM_RIGHTS transfer + Phase 2 Commit.
        let snapshot = try #require(processA?.pauseForHandoff())
        let (dirURL, socketPath) = try FDTransferSocket.makePrivateSocketPath()
        defer { FDTransferSocket.removePrivateSocket(directoryURL: dirURL, socketPath: socketPath) }
        let listenFD = try FDTransferSocket.listen(at: socketPath)
        defer { Darwin.close(listenFD) }

        let token = FDTransferSocket.makeRandomToken()
        let transfer = HotReloadPaneTransfer(
            entry: HotReloadPaneEntry(
                paneID: UUID(),
                shellPid: snapshot.shellPid,
                startTime: snapshot.startTime,
                cols: 80,
                rows: 24
            ),
            fd: snapshot.fd
        )
        let serveDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? FDTransferSocket.serveHandoff(
                listeningFD: listenFD,
                token: token,
                transfers: [transfer],
                timeout: 5
            )
            serveDone.signal()
        }

        let received = try FDTransferSocket.receiveHandoff(socketPath: socketPath, token: token, timeout: 5)
        _ = serveDone.wait(timeout: .now() + 5)
        let handedOff = try #require(received.transfers.first)

        // Commit and deallocate Process A: must NOT send SIGTERM or SIGHUP!
        processA?.commitHandoff()
        processA = nil

        // Attach in Process B and finish the shell cleanly.
        let collectorB = TestProcessCollector()
        let processB = HotReloadableLocalProcess(delegate: collectorB, deliveryQueue: DispatchQueue.global())
        try processB.attachAdopted(
            fd: handedOff.fd,
            shellPid: handedOff.entry.shellPid,
            startTime: handedOff.entry.startTime,
            windowSize: size,
            sendSigwinch: false
        ).get()

        let secondLine = Array("after-commit\n".utf8)
        processB.send(data: secondLine[...])
        #expect(collectorB.waitForOutput(containing: "SECOND:after-commit", timeout: 5))

        let exitInfo = collectorB.waitForExit(timeout: 5)
        #expect(exitInfo.terminated)
        #expect(exitInfo.exitCode == 7)
    }

    @MainActor
    @Test func hotReloadInboxLifecycle() throws {
        let inbox = HotReloadInbox.shared
        inbox.resetForTesting()
        defer { inbox.resetForTesting() }

        var fds: [Int32] = [-1, -1]
        #expect(Darwin.pipe(&fds) == 0)
        defer { Darwin.close(fds[1]) }

        let paneID = UUID()
        let entry = HotReloadPaneEntry(paneID: paneID, shellPid: getpid(), startTime: nil, cols: 80, rows: 24)
        inbox.storeForTesting([HotReloadPaneTransfer(entry: entry, fd: fds[0])])

        #expect(inbox.hasReceivedHandoff)
        #expect(inbox.contains(paneID: paneID))

        let drained = inbox.drainUnclaimedForHandoff()
        #expect(drained.count == 1)
        #expect(!inbox.contains(paneID: paneID))

        inbox.restoreUnclaimed(drained)
        #expect(inbox.contains(paneID: paneID))

        let taken = try #require(inbox.take(paneID: paneID))
        #expect(taken.fd == fds[0])
        #expect(!inbox.contains(paneID: paneID))
        Darwin.close(taken.fd)
    }
}
