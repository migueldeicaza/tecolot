//
//  HotReloadableLocalProcess.swift
//  Tecolot
//
//  In-process local PTY controller that supports both normal forkpty() launches
//  and two-phase SCM_RIGHTS handoff / adoption for in-place app upgrades,
//  without requiring an out-of-process session daemon.
//

import Darwin
import Dispatch
import Foundation
import os
import SwiftTerm

/// Snapshot returned by `HotReloadableLocalProcess.pauseForHandoff()`.
///
/// The file descriptor remains owned by `HotReloadableLocalProcess` until
/// `commitHandoff()` is called (after the receiving process ACKs `SCM_RIGHTS`).
nonisolated struct HotReloadProcessPauseSnapshot: Sendable {
    let fd: Int32
    let shellPid: pid_t
    let startTime: ProcessStartTime?
    let ownership: ProcessOwnership
}

/// Callback interface for `HotReloadableLocalProcess`.
nonisolated protocol HotReloadableLocalProcessDelegate: AnyObject, Sendable {
    func hotReloadProcess(_ source: HotReloadableLocalProcess, didReceiveData bytes: [UInt8])
    func hotReloadProcess(_ source: HotReloadableLocalProcess, didTerminateWithExitCode exitCode: Int32?)
    func hotReloadProcess(_ source: HotReloadableLocalProcess, didFailToStart error: LocalProcessError)
}

/// Self-pipe-interruptible background PTY reader.
///
/// Stopping via `stopAndWait()` wakes `poll()` immediately without closing the
/// PTY master descriptor, guaranteeing zero bytes are read during handoff
/// snapshotting and `SCM_RIGHTS` transfer.
private nonisolated final class InterruptiblePtyReader: @unchecked Sendable {
    private struct State {
        var stopRequested = false
        var drainDeadline: UInt64?
        var stopWriteFD: Int32 = -1
        var started = false
    }

    let fd: Int32
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let finished = DispatchSemaphore(value: 0)
    private let onData: @Sendable ([UInt8]) -> Void
    private let onEOF: @Sendable () -> Void

    init(
        fd: Int32,
        onData: @escaping @Sendable ([UInt8]) -> Void,
        onEOF: @escaping @Sendable () -> Void
    ) {
        self.fd = fd
        self.onData = onData
        self.onEOF = onEOF
    }

    func start() {
        var pipeFDs: [Int32] = [-1, -1]
        guard Darwin.pipe(&pipeFDs) == 0 else {
            finished.signal()
            return
        }
        let stopRead = pipeFDs[0]
        let stopWrite = pipeFDs[1]
        _ = fcntl(stopRead, F_SETFD, FD_CLOEXEC)
        _ = fcntl(stopWrite, F_SETFD, FD_CLOEXEC)
        _ = fcntl(stopRead, F_SETFL, O_NONBLOCK)
        _ = fcntl(stopWrite, F_SETFL, O_NONBLOCK)

        let admitted = state.withLock { s -> Bool in
            guard !s.started, !s.stopRequested else {
                return false
            }
            s.started = true
            s.stopWriteFD = stopWrite
            return true
        }
        guard admitted else {
            Darwin.close(stopRead)
            Darwin.close(stopWrite)
            finished.signal()
            return
        }

        let thread = Thread { [self] in
            defer {
                self.state.withLock { s in
                    if s.stopWriteFD == stopWrite {
                        s.stopWriteFD = -1
                    }
                }
                Darwin.close(stopRead)
                Darwin.close(stopWrite)
                self.finished.signal()
            }
            self.runLoop(stopRead: stopRead)
        }
        thread.name = "tecolot-pty-reader-\(fd)"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stops reading immediately and waits for the reader thread to exit.
    /// Does NOT close `fd`.
    func stopAndWait() {
        let (wasStarted, wakeFD) = state.withLock { s -> (Bool, Int32) in
            s.stopRequested = true
            return (s.started, s.stopWriteFD)
        }
        guard wasStarted else {
            return
        }
        if wakeFD >= 0 {
            var byte: UInt8 = 1
            _ = Darwin.write(wakeFD, &byte, 1)
        }
        finished.wait()
    }

    /// Drains any bytes already queued in the kernel PTY buffer up to `timeout`
    /// and then stops the reader thread. Does NOT close `fd`.
    func drainAndStop(timeout: TimeInterval) {
        let now = DispatchTime.now().uptimeNanoseconds
        let delta = timeout > 0 ? UInt64(timeout * 1_000_000_000) : 0
        let deadline = now &+ delta
        let (wasStarted, wakeFD) = state.withLock { s -> (Bool, Int32) in
            s.drainDeadline = deadline
            return (s.started, s.stopWriteFD)
        }
        guard wasStarted else {
            return
        }
        if wakeFD >= 0 {
            var byte: UInt8 = 1
            _ = Darwin.write(wakeFD, &byte, 1)
        }
        _ = finished.wait(timeout: .now() + max(0.05, timeout + 0.1))
    }

    private func runLoop(stopRead: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65_536)

        while true {
            let (stopRequested, drainDeadline) = state.withLock { ($0.stopRequested, $0.drainDeadline) }
            if stopRequested {
                return
            }

            let pollTimeoutMs: Int32
            if let drainDeadline {
                let now = DispatchTime.now().uptimeNanoseconds
                if now >= drainDeadline {
                    return
                }
                let remainingMs = Int32(min(50, max(1, (drainDeadline - now) / 1_000_000)))
                pollTimeoutMs = remainingMs
            } else {
                pollTimeoutMs = -1
            }

            var pfds = [
                pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                pollfd(fd: stopRead, events: Int16(POLLIN), revents: 0)
            ]

            let ready = Darwin.poll(&pfds, 2, pollTimeoutMs)
            if ready == -1 {
                if errno == EINTR {
                    continue
                }
                onEOF()
                return
            }

            if ready == 0 {
                // Drain poll timed out with no data available: kernel buffer is drained.
                if state.withLock({ $0.drainDeadline != nil }) {
                    return
                }
                continue
            }

            // If a hard stop was requested (handoff pause), exit BEFORE reading
            // from fd so kernel-buffered output stays intact for the new process.
            if (pfds[1].revents & Int16(POLLIN)) != 0 {
                drainPipe(stopRead)
                if state.withLock({ $0.stopRequested }) {
                    return
                }
            }

            let ptyRevents = pfds[0].revents
            if (ptyRevents & Int16(POLLIN)) != 0 {
                let count = buffer.withUnsafeMutableBytes { raw -> Int in
                    var n: Int
                    repeat {
                        n = Darwin.read(fd, raw.baseAddress!, raw.count)
                    } while n == -1 && errno == EINTR
                    return n
                }
                if count > 0 {
                    onData(Array(buffer[0..<count]))
                    continue
                }
                if count == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    continue
                }
                // count == 0 or EIO -> PTY slave closed.
                onEOF()
                return
            }

            if (ptyRevents & Int16(POLLHUP | POLLERR | POLLNVAL)) != 0 {
                onEOF()
                return
            }

            if state.withLock({ $0.drainDeadline != nil }) {
                // Woken for drain with nothing readable on PTY: drain complete.
                return
            }
        }
    }

    private func drainPipe(_ pipeFD: Int32) {
        var scratch = [UInt8](repeating: 0, count: 64)
        while Darwin.read(pipeFD, &scratch, scratch.count) > 0 {}
    }
}

/// Manages a local PTY child process — either forked directly or adopted from
/// a previous Tecolot instance via `SCM_RIGHTS`.
nonisolated final class HotReloadableLocalProcess: @unchecked Sendable {
    private enum Phase {
        case idle
        case starting
        case running
        case terminating
        case pausedForHandoff
        case handedOff
        case exited
        case windingDown
    }

    private struct SessionState {
        var generation: UInt64 = 0
        var phase: Phase = .idle
        var childfd: Int32 = -1
        var shellPid: pid_t = 0
        var startTime: ProcessStartTime?
        var ownership: ProcessOwnership = .owned
        var terminateRequestedDuringStart = false
        var monitor: ProcessExitMonitor?
        var reader: InterruptiblePtyReader?
        var writeChannel: DispatchIO?
        var drainTimeout: TimeInterval = 0.5
        var killEscalationDelay: TimeInterval = 0.5
        var loggingDirectory: String?
        var logFileCounter = 0
    }

    private let session = OSAllocatedUnfairLock(initialState: SessionState())
    private let delegateLock = OSAllocatedUnfairLock<WeakDelegate>(initialState: WeakDelegate())
    private let writeQueue = DispatchQueue(label: "com.tirania.tecolot.pty-writer")
    private let deliveryQueue: DispatchQueue

    private struct WeakDelegate {
        weak var value: (any HotReloadableLocalProcessDelegate)?
    }

    init(delegate: any HotReloadableLocalProcessDelegate, deliveryQueue: DispatchQueue = .main) {
        self.deliveryQueue = deliveryQueue
        delegateLock.withLock { $0.value = delegate }
    }

    /// Primary PTY master descriptor, or `-1` when inactive/handed off.
    var childfd: Int32 {
        session.withLock { $0.childfd }
    }

    /// Shell process PID, or `0` when inactive/handed off.
    var shellPid: pid_t {
        session.withLock { $0.shellPid }
    }

    /// True while a live or draining session is active (not paused/handed off).
    var running: Bool {
        session.withLock {
            $0.phase == .running || $0.phase == .terminating || $0.phase == .exited
        }
    }

    /// True if this process was adopted across an `SCM_RIGHTS` hot reload.
    var isAdopted: Bool {
        session.withLock {
            if case .adopted = $0.ownership {
                return $0.phase != .idle && $0.phase != .handedOff
            }
            return false
        }
    }

    var drainTimeout: TimeInterval {
        get { session.withLock { $0.drainTimeout } }
        set { session.withLock { $0.drainTimeout = newValue } }
    }

    var killEscalationDelay: TimeInterval {
        get { session.withLock { $0.killEscalationDelay } }
        set { session.withLock { $0.killEscalationDelay = newValue } }
    }

    deinit {
        let resources = session.withLock { s -> (
            phase: Phase,
            fd: Int32,
            reader: InterruptiblePtyReader?,
            writeChannel: DispatchIO?,
            monitor: ProcessExitMonitor?,
            killEscalationDelay: TimeInterval
        ) in
            let r = (s.phase, s.childfd, s.reader, s.writeChannel, s.monitor, s.killEscalationDelay)
            s = SessionState()
            return r
        }

        // If handed off cleanly, ownership moved to the new instance: do not
        // signal or touch any descriptor.
        guard resources.phase != .handedOff else {
            return
        }

        if let reader = resources.reader {
            DispatchQueue.global(qos: .utility).async {
                reader.stopAndWait()
            }
        }

        if let monitor = resources.monitor {
            let writeChannel = resources.writeChannel
            let fd = resources.fd
            monitor.terminateForDeinit(killEscalationDelay: resources.killEscalationDelay) {
                writeChannel?.close(flags: .stop)
                if fd >= 0 {
                    Darwin.close(fd)
                }
            }
        } else {
            resources.writeChannel?.close(flags: .stop)
            if resources.fd >= 0 {
                Darwin.close(resources.fd)
            }
        }
    }

    // MARK: - Launch (Owned Mode)

    /// Forks and executes a local command in a new PTY.
    @discardableResult
    func startProcess(
        executable: String = "/bin/bash",
        args: [String] = [],
        environment: [String]? = nil,
        execName: String? = nil,
        currentDirectory: String? = nil,
        windowSize: winsize
    ) -> Result<Void, LocalProcessError> {
        let admitted = session.withLock { s -> Bool in
            guard s.phase == .idle else {
                return false
            }
            s.phase = .starting
            return true
        }
        guard admitted else {
            return .failure(.alreadyRunning)
        }

        var size = windowSize
        var shellArgs = args
        shellArgs.insert(execName ?? executable, at: 0)
        let env = environment ?? Terminal.getEnvironmentVariables(termName: "xterm-256color")

        guard let (shellPid, childfd) = PseudoTerminalHelpers.fork(
            andExec: executable,
            args: shellArgs,
            env: env,
            currentDirectory: currentDirectory,
            desiredWindowSize: &size
        ) else {
            let err = errno
            finishLaunchFailure(.forkFailed(err))
            return .failure(.forkFailed(err))
        }
        _ = fcntl(childfd, F_SETFD, FD_CLOEXEC)

        let startTime = ProcessStartTime.current(for: shellPid)
        return activateSession(
            fd: childfd,
            shellPid: shellPid,
            startTime: startTime,
            ownership: .owned
        )
    }

    // MARK: - Adopt (Hot-Reload Receiver Mode)

    /// Attaches to an already-running shell whose PTY master descriptor was
    /// received over `SCM_RIGHTS`.
    ///
    /// Replaces `waitpid` with `kqueue` `EVFILT_PROC` (`NOTE_EXIT | NOTE_EXITSTATUS`)
    /// so exit detection and exit codes continue working even after XNU
    /// reparents `shellPid` to `launchd` (PID 1).
    @discardableResult
    func attachAdopted(
        fd: Int32,
        shellPid: pid_t,
        startTime: ProcessStartTime?,
        windowSize: winsize,
        sendSigwinch: Bool = true
    ) -> Result<Void, LocalProcessError> {
        let admitted = session.withLock { s -> Bool in
            guard s.phase == .idle else {
                return false
            }
            s.phase = .starting
            return true
        }
        guard admitted else {
            return .failure(.alreadyRunning)
        }

        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var size = windowSize
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: fd, windowSize: &size)

        let effectiveStartTime = startTime ?? ProcessStartTime.current(for: shellPid)
        let result = activateSession(
            fd: fd,
            shellPid: shellPid,
            startTime: effectiveStartTime,
            ownership: .adopted(startTime: effectiveStartTime)
        )

        if case .success = result, sendSigwinch {
            sendWindowSizeChangeSignal(fd: fd, shellPid: shellPid)
        }
        return result
    }

    // MARK: - Two-Phase Hot-Reload Handoff (Sender Mode)

    /// Phase 1 of hot-reload: stops reading from the PTY and pauses exit
    /// monitoring while keeping `childfd`, `shellPid`, and the live child
    /// untouched. Safe to snapshot `Terminal` scrollback after this returns.
    func pauseForHandoff() -> HotReloadProcessPauseSnapshot? {
        let paused = session.withLock { s -> (
            reader: InterruptiblePtyReader?,
            monitor: ProcessExitMonitor?,
            snapshot: HotReloadProcessPauseSnapshot
        )? in
            guard s.phase == .running, s.childfd >= 0, s.shellPid > 0 else {
                return nil
            }
            s.phase = .pausedForHandoff
            let reader = s.reader
            s.reader = nil
            let monitor = s.monitor
            s.monitor = nil
            let startTime = s.startTime ?? ProcessStartTime.current(for: s.shellPid)
            s.startTime = startTime
            let snapshot = HotReloadProcessPauseSnapshot(
                fd: s.childfd,
                shellPid: s.shellPid,
                startTime: startTime,
                ownership: s.ownership
            )
            return (reader, monitor, snapshot)
        }
        guard let paused else {
            return nil
        }
        paused.monitor?.cancel()
        paused.reader?.stopAndWait()
        return paused.snapshot
    }

    /// Phase 2a (rollback): restarts PTY reading and exit monitoring after a
    /// failed or timed-out hot reload so the shell continues uninterrupted.
    func resumeAfterAbortedHandoff() {
        let resumed = session.withLock { s -> (
            generation: UInt64,
            fd: Int32,
            shellPid: pid_t,
            ownership: ProcessOwnership
        )? in
            guard s.phase == .pausedForHandoff, s.childfd >= 0, s.shellPid > 0 else {
                return nil
            }
            s.generation &+= 1
            s.phase = .running
            return (s.generation, s.childfd, s.shellPid, s.ownership)
        }
        guard let resumed else {
            return
        }
        startReaderAndMonitor(
            generation: resumed.generation,
            fd: resumed.fd,
            shellPid: resumed.shellPid,
            ownership: resumed.ownership
        )
    }

    /// Phase 2b (commit): called ONLY after the new process has acknowledged
    /// receiving `childfd` via `SCM_RIGHTS`. Closes this process's local copies
    /// of the PTY descriptor without sending `SIGTERM`/`SIGHUP`.
    func commitHandoff() {
        let cleanup = session.withLock { s -> (fd: Int32, writeChannel: DispatchIO?)? in
            guard s.phase == .pausedForHandoff else {
                return nil
            }
            let fd = s.childfd
            let writeChannel = s.writeChannel
            s.phase = .handedOff
            s.childfd = -1
            s.shellPid = 0
            s.writeChannel = nil
            s.reader = nil
            s.monitor = nil
            return (fd, writeChannel)
        }
        guard let cleanup else {
            return
        }
        cleanup.writeChannel?.close(flags: .stop)
        if cleanup.fd >= 0 {
            Darwin.close(cleanup.fd)
        }
    }

    // MARK: - I/O & Control

    func send(data: ArraySlice<UInt8>) {
        guard !data.isEmpty else {
            return
        }
        guard let channel = session.withLock({ s -> DispatchIO? in
            guard s.phase == .running || s.phase == .terminating else {
                return nil
            }
            return s.writeChannel
        }) else {
            return
        }
        data.withUnsafeBytes { ptr in
            let bytes = DispatchData(bytes: ptr)
            channel.write(offset: 0, data: bytes, queue: writeQueue) { _, _, _ in }
        }
    }

    @discardableResult
    func updateWindowSize(_ size: inout winsize) -> Bool {
        session.withLock { s in
            guard s.phase == .running || s.phase == .terminating, s.childfd >= 0 else {
                return false
            }
            return PseudoTerminalHelpers.setWinSize(
                masterPtyDescriptor: s.childfd,
                windowSize: &size
            ) == 0
        }
    }

    func terminalControlBytesForPaste() -> Set<UInt8>? {
        session.withLock { s in
            guard s.phase == .running || s.phase == .terminating, s.childfd >= 0 else {
                return nil
            }
            return PseudoTerminalHelpers.terminalControlBytesForPaste(masterPtyDescriptor: s.childfd)
        }
    }

    func setHostLogging(directory: String?) {
        session.withLock { s in
            s.loggingDirectory = directory
            s.logFileCounter = 0
        }
    }

    func terminate() {
        let monitor = session.withLock { s -> ProcessExitMonitor? in
            switch s.phase {
            case .starting:
                s.terminateRequestedDuringStart = true
                return nil
            case .running:
                s.phase = .terminating
                return s.monitor
            case .terminating:
                return s.monitor
            default:
                return nil
            }
        }
        _ = monitor?.signal(SIGTERM)
    }

    // MARK: - Private

    private func activateSession(
        fd: Int32,
        shellPid: pid_t,
        startTime: ProcessStartTime?,
        ownership: ProcessOwnership
    ) -> Result<Void, LocalProcessError> {
        let writeFd = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard writeFd >= 0 else {
            let err = errno
            Darwin.close(fd)
            if ownership == .owned {
                let monitor = ProcessExitMonitor(pid: shellPid, ownership: .owned)
                monitor.terminateForDeinit(killEscalationDelay: 0) {}
            }
            finishLaunchFailure(.writeChannelFailed(err))
            return .failure(.writeChannelFailed(err))
        }
        let writeChannel = DispatchIO(type: .stream, fileDescriptor: writeFd, queue: writeQueue) { _ in
            Darwin.close(writeFd)
        }

        let launch = session.withLock { s -> (generation: UInt64, terminateRequested: Bool) in
            s.generation &+= 1
            let terminateRequested = s.terminateRequestedDuringStart
            s.terminateRequestedDuringStart = false
            s.phase = terminateRequested ? .terminating : .running
            s.shellPid = shellPid
            s.childfd = fd
            s.startTime = startTime
            s.ownership = ownership
            s.writeChannel = writeChannel
            return (s.generation, terminateRequested)
        }

        startReaderAndMonitor(
            generation: launch.generation,
            fd: fd,
            shellPid: shellPid,
            ownership: ownership
        )

        if launch.terminateRequested {
            terminate()
        }
        return .success(())
    }

    private func startReaderAndMonitor(
        generation: UInt64,
        fd: Int32,
        shellPid: pid_t,
        ownership: ProcessOwnership
    ) {
        let reader = InterruptiblePtyReader(
            fd: fd,
            onData: { [weak self] bytes in
                self?.handleData(generation: generation, bytes: bytes)
            },
            onEOF: { [weak self] in
                self?.handleReaderEOF(generation: generation)
            }
        )
        let monitor = ProcessExitMonitor(pid: shellPid, ownership: ownership)

        let installed = session.withLock { s -> Bool in
            guard s.generation == generation, s.phase == .running || s.phase == .terminating else {
                return false
            }
            s.reader = reader
            s.monitor = monitor
            return true
        }
        guard installed else {
            return
        }

        reader.start()
        monitor.start { [weak self] status in
            self?.childDidExit(generation: generation, status: status)
        }
    }

    private func handleData(generation: UInt64, bytes: [UInt8]) {
        let logPath = session.withLock { s -> String? in
            guard s.generation == generation else {
                return nil
            }
            guard let dir = s.loggingDirectory else {
                return nil
            }
            let path = dir + "/log-\(s.logFileCounter)"
            s.logFileCounter += 1
            return path
        }
        if let logPath {
            try? Data(bytes).write(to: URL(fileURLWithPath: logPath))
        }
        let delegate = delegateLock.withLock { $0.value }
        delegate?.hotReloadProcess(self, didReceiveData: bytes)
    }

    private func handleReaderEOF(generation: UInt64) {
        // On macOS, PTY EOF and kqueue EVFILT_PROC NOTE_EXIT can race by a few
        // milliseconds. Let ProcessExitMonitor deliver the authoritative exit
        // status; only if no monitor exists (or for an already-gone adopted PID
        // whose monitor didn't fire) do we fall back after a short grace window.
        let shouldScheduleFallback = session.withLock { s -> Bool in
            guard s.generation == generation, s.phase == .running || s.phase == .terminating else {
                return false
            }
            if case .adopted = s.ownership {
                return true
            }
            return s.monitor == nil
        }
        guard shouldScheduleFallback else {
            return
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else {
                return
            }
            let stillWaiting = self.session.withLock { s -> Bool in
                s.generation == generation && (s.phase == .running || s.phase == .terminating)
            }
            if stillWaiting {
                self.childDidExit(generation: generation, status: nil)
            }
        }
    }

    private func childDidExit(generation: UInt64, status: Int32?) {
        let drain = session.withLock { s -> (
            reader: InterruptiblePtyReader?,
            monitor: ProcessExitMonitor?,
            timeout: TimeInterval
        )? in
            guard s.generation == generation, s.phase == .running || s.phase == .terminating else {
                return nil
            }
            s.phase = .exited
            s.shellPid = 0
            return (s.reader, s.monitor, s.drainTimeout)
        }
        guard let drain else {
            return
        }

        drain.monitor?.markExitedAndCancel()
        drain.reader?.drainAndStop(timeout: drain.timeout)
        let exitCode = ProcessExitMonitor.exitCode(fromWaitStatus: status)

        let teardown = session.withLock { s -> (accepted: Bool, fd: Int32, writeChannel: DispatchIO?) in
            guard s.generation == generation, s.phase == .exited else {
                return (false, -1, nil)
            }
            let fd = s.childfd
            let writeChannel = s.writeChannel
            s.childfd = -1
            s.reader = nil
            s.monitor = nil
            s.writeChannel = nil
            s.phase = .windingDown
            return (true, fd, writeChannel)
        }
        guard teardown.accepted else {
            return
        }
        teardown.writeChannel?.close(flags: .stop)
        if teardown.fd >= 0 {
            Darwin.close(teardown.fd)
        }

        deliveryQueue.async { [weak self] in
            guard let self else {
                return
            }
            let shouldDeliver = self.session.withLock { s -> Bool in
                guard s.generation == generation, s.phase == .windingDown else {
                    return false
                }
                s.phase = .idle
                return true
            }
            if shouldDeliver {
                let delegate = self.delegateLock.withLock { $0.value }
                delegate?.hotReloadProcess(self, didTerminateWithExitCode: exitCode)
            }
        }
    }

    private func finishLaunchFailure(_ error: LocalProcessError) {
        let generation = session.withLock { s -> UInt64 in
            s.terminateRequestedDuringStart = false
            s.generation &+= 1
            s.phase = .windingDown
            return s.generation
        }
        deliveryQueue.async { [weak self] in
            guard let self else {
                return
            }
            let shouldDeliver = self.session.withLock { s -> Bool in
                guard s.generation == generation, s.phase == .windingDown else {
                    return false
                }
                s.phase = .idle
                return true
            }
            if shouldDeliver {
                let delegate = self.delegateLock.withLock { $0.value }
                delegate?.hotReloadProcess(self, didFailToStart: error)
            }
        }
    }

    /// Sends `SIGWINCH` to the foreground process group of the adopted PTY so
    /// full-screen TUIs redraw immediately after hot reload.
    private func sendWindowSizeChangeSignal(fd: Int32, shellPid: pid_t) {
        let fgGroup = tcgetpgrp(fd)
        if fgGroup > 0 {
            _ = Darwin.kill(-fgGroup, SIGWINCH)
        }
        if shellPid > 0, fgGroup != shellPid {
            let monitor = session.withLock { $0.monitor }
            _ = monitor?.signal(SIGWINCH)
        }
    }
}
