//
//  ProcessExitMonitor.swift
//  Tecolot
//
//  Observes exit and controls signaling for both directly forked ("owned")
//  child processes and processes adopted after an SCM_RIGHTS hot-reload
//  handoff.
//
//  Why this replaces LocalProcessChildReaper.wait():
//  When the previous Tecolot process exits after handing off its PTY master
//  descriptors via SCM_RIGHTS, macOS (XNU) reparents those child shells to
//  launchd (PID 1). In the new Tecolot process, waitid()/waitpid() fail with
//  ECHILD because the adopted shells are no longer direct children.
//
//  On macOS, kqueue EVFILT_PROC with NOTE_EXIT | NOTE_EXITSTATUS works on any
//  process owned by the same UID — even when reparented to launchd — and
//  delivers the wait(2)-compatible exit status in kevent.data. Combining it
//  with proc_pidinfo(PROC_PIDTBSDINFO) start-time verification closes the
//  PID-reuse window across handoff and before signaling.
//

import Darwin
import Foundation
import os

/// Kernel start timestamp of a process (`proc_bsdinfo.pbi_start_tvsec` / `usec`).
///
/// Pairing a PID with its kernel start time proves that the PID still refers to
/// the exact same process instance across an SCM_RIGHTS handoff and before
/// calling `kill()`, even when `launchd` is the parent and can reap the PID.
nonisolated struct ProcessStartTime: Codable, Hashable, Sendable {
    let seconds: UInt64
    let microseconds: UInt64

    /// Reads the live process's start timestamp via `libproc`, or `nil` if the
    /// PID no longer exists or cannot be inspected.
    static func current(for pid: pid_t) -> ProcessStartTime? {
        guard pid > 0 else {
            return nil
        }
        var info = proc_bsdinfo()
        let expected = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expected)
        guard bytes == expected else {
            return nil
        }
        return ProcessStartTime(
            seconds: info.pbi_start_tvsec,
            microseconds: info.pbi_start_tvusec
        )
    }

    /// Reads the current parent PID (`pbi_ppid`) of `pid`, or `nil` if gone.
    static func parentPID(of pid: pid_t) -> pid_t? {
        guard pid > 0 else {
            return nil
        }
        var info = proc_bsdinfo()
        let expected = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expected)
        guard bytes == expected else {
            return nil
        }
        return pid_t(info.pbi_ppid)
    }
}

/// Whether this process is the kernel parent of `pid` or adopted it across a
/// hot-reload handoff.
nonisolated enum ProcessOwnership: Sendable, Equatable {
    /// Forked by this process: we MUST reap it with `waitid`/`waitpid`.
    case owned
    /// Adopted via `SCM_RIGHTS`: `launchd` owns and reaps it after the sender
    /// exits, so we observe exit with `kqueue` `EVFILT_PROC` (`NOTE_EXITSTATUS`)
    /// and never call `waitpid`.
    case adopted(startTime: ProcessStartTime?)
}

/// Thread-safe exit observer and signal gate for one shell process.
nonisolated final class ProcessExitMonitor: @unchecked Sendable {
    private struct State {
        var signalAllowed = true
        var started = false
        var stopped = false
        var wakeWriteFD: Int32 = -1
    }

    let pid: pid_t
    let ownership: ProcessOwnership

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let reapLock = NSLock()
    private var monitorThread: Thread?

    init(pid: pid_t, ownership: ProcessOwnership) {
        self.pid = pid
        self.ownership = ownership
    }

    /// Normalizes a `wait(2)` / `NOTE_EXITSTATUS` status integer to an exit
    /// code (`0...255`), or `nil` when terminated by a signal or unknown.
    static func exitCode(fromWaitStatus status: Int32?) -> Int32? {
        guard let status, status & 0x7f == 0 else {
            return nil
        }
        return (status >> 8) & 0xff
    }

    /// Sends `sig` to the monitored process if it has not yet exited (and, for
    /// adopted processes with a recorded start time, still matches its kernel
    /// identity).
    @discardableResult
    func signal(_ sig: Int32) -> Bool {
        reapLock.lock()
        defer { reapLock.unlock() }

        let allowed = state.withLock { $0.signalAllowed }
        guard allowed, pid > 0 else {
            return false
        }
        if case .adopted(let expectedStart) = ownership, let expectedStart {
            guard ProcessStartTime.current(for: pid) == expectedStart else {
                state.withLock { $0.signalAllowed = false }
                return false
            }
        }
        return Darwin.kill(pid, sig) == 0
    }

    /// Starts observing process exit on a dedicated waiter thread.
    ///
    /// `onExit` is called at most once with the raw `wait(2)`-formatted status
    /// integer (or `nil` if the status could not be observed, e.g. the adopted
    /// process had already been reaped by `launchd` before registration).
    /// Calling `cancel()` suppresses `onExit` without signaling or reaping.
    func start(onExit: @escaping @Sendable (Int32?) -> Void) {
        var pipeFDs: [Int32] = [-1, -1]
        guard Darwin.pipe(&pipeFDs) == 0 else {
            onExit(nil)
            return
        }
        let wakeRead = pipeFDs[0]
        let wakeWrite = pipeFDs[1]
        _ = fcntl(wakeRead, F_SETFD, FD_CLOEXEC)
        _ = fcntl(wakeWrite, F_SETFD, FD_CLOEXEC)
        _ = fcntl(wakeRead, F_SETFL, O_NONBLOCK)
        _ = fcntl(wakeWrite, F_SETFL, O_NONBLOCK)

        let admitted = state.withLock { s -> Bool in
            guard !s.started, !s.stopped else {
                return false
            }
            s.started = true
            s.wakeWriteFD = wakeWrite
            return true
        }
        guard admitted else {
            Darwin.close(wakeRead)
            Darwin.close(wakeWrite)
            return
        }

        let thread = Thread { [self] in
            defer {
                self.closeWakePipe(wakeRead: wakeRead, wakeWrite: wakeWrite)
            }
            self.runMonitorLoop(wakeRead: wakeRead, onExit: onExit)
        }
        thread.name = ownership == .owned ? "tecolot-owned-exit-\(pid)" : "tecolot-adopted-exit-\(pid)"
        monitorThread = thread
        thread.start()
    }

    /// Cancels monitoring without signaling or reaping the process.
    /// Used when detaching for hot-reload handoff.
    func cancel() {
        let wakeFD = state.withLock { s -> Int32 in
            s.stopped = true
            return s.wakeWriteFD
        }
        if wakeFD >= 0 {
            var byte: UInt8 = 1
            _ = Darwin.write(wakeFD, &byte, 1)
        }
    }

    /// Marks the process as no longer signalable (e.g. after PTY EOF) and
    /// cancels the exit monitor.
    func markExitedAndCancel() {
        let wakeFD = state.withLock { s -> Int32 in
            s.signalAllowed = false
            s.stopped = true
            return s.wakeWriteFD
        }
        if wakeFD >= 0 {
            var byte: UInt8 = 1
            _ = Darwin.write(wakeFD, &byte, 1)
        }
    }

    /// Sends `SIGTERM`, escalates to `SIGKILL` after `killEscalationDelay`, and
    /// reaps owned children without blocking the caller. Never called on a
    /// detached/handed-off process.
    func terminateForDeinit(killEscalationDelay: TimeInterval, onFinished: @escaping @Sendable () -> Void) {
        cancel()
        _ = signal(SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + killEscalationDelay) { [self] in
            _ = self.signal(SIGKILL)
        }
        switch ownership {
        case .owned:
            let thread = Thread { [self] in
                _ = self.reapOwnedChild()
                onFinished()
            }
            thread.name = "tecolot-child-reaper-\(pid)"
            thread.start()
        case .adopted:
            // launchd reaps adopted processes; we must not call waitpid.
            onFinished()
        }
    }

    // MARK: - Private

    private func closeWakePipe(wakeRead: Int32, wakeWrite: Int32) {
        state.withLock { s in
            if s.wakeWriteFD == wakeWrite {
                s.wakeWriteFD = -1
            }
        }
        Darwin.close(wakeRead)
        Darwin.close(wakeWrite)
    }

    private func runMonitorLoop(wakeRead: Int32, onExit: @escaping @Sendable (Int32?) -> Void) {
        let kq = Darwin.kqueue()
        guard kq >= 0 else {
            // Fallback if kqueue creation fails: owned children can still waitpid.
            if ownership == .owned {
                let status = reapOwnedChild()
                deliverIfActive(status: status, onExit: onExit)
            } else {
                state.withLock { $0.signalAllowed = false }
                deliverIfActive(status: nil, onExit: onExit)
            }
            return
        }
        _ = fcntl(kq, F_SETFD, FD_CLOEXEC)
        defer {
            Darwin.close(kq)
        }

        // Register wake pipe + process exit knote together.
        // For adopted processes, NOTE_EXITSTATUS instructs XNU to populate
        // kevent.data with the wait(2)-formatted exit status even though we are
        // not the parent process.
        let procFlags: UInt32 = switch ownership {
        case .owned:
            UInt32(NOTE_EXIT)
        case .adopted:
            UInt32(NOTE_EXIT) | UInt32(NOTE_EXITSTATUS)
        }

        var changes = [
            Darwin.kevent(
                ident: UInt(wakeRead),
                filter: Int16(EVFILT_READ),
                flags: UInt16(EV_ADD | EV_ENABLE),
                fflags: 0,
                data: 0,
                udata: nil
            ),
            Darwin.kevent(
                ident: UInt(pid),
                filter: Int16(EVFILT_PROC),
                flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
                fflags: procFlags,
                data: 0,
                udata: nil
            )
        ]

        // Register first with an output event list sized to receive immediate
        // EV_ERROR responses (such as ESRCH when the process already exited).
        var regResults = [Darwin.kevent(), Darwin.kevent()]
        var zeroTimeout = timespec(tv_sec: 0, tv_nsec: 0)
        var regCount: Int32 = 0
        repeat {
            regCount = kevent(kq, &changes, 2, &regResults, 2, &zeroTimeout)
        } while regCount == -1 && errno == EINTR

        if regCount == -1 {
            let err = errno
            if err == ESRCH {
                handleImmediateExit(onExit: onExit)
                return
            }
            if ownership == .owned {
                let status = reapOwnedChild()
                deliverIfActive(status: status, onExit: onExit)
            } else {
                state.withLock { $0.signalAllowed = false }
                deliverIfActive(status: nil, onExit: onExit)
            }
            return
        }

        // Inspect any events returned immediately during registration.
        if regCount > 0 {
            for index in 0..<Int(regCount) {
                let ev = regResults[index]
                if ev.filter == Int16(EVFILT_READ), Int32(ev.ident) == wakeRead {
                    return
                }
                if ev.filter == Int16(EVFILT_PROC) {
                    if (ev.flags & UInt16(EV_ERROR)) != 0 {
                        // ESRCH means the target process already exited (and may
                        // already have been reaped by launchd).
                        handleImmediateExit(onExit: onExit)
                        return
                    }
                    handleProcExitEvent(ev, onExit: onExit)
                    return
                }
            }
        }

        // After EVFILT_PROC is armed, verify adopted process identity so a PID
        // that was already reused before registration is caught immediately.
        if case .adopted(let expectedStart) = ownership, let expectedStart {
            if let currentStart = ProcessStartTime.current(for: pid), currentStart != expectedStart {
                state.withLock { $0.signalAllowed = false }
                deliverIfActive(status: nil, onExit: onExit)
                return
            }
        }

        // Block until either the process exits or cancel() writes to wakeRead.
        var event = Darwin.kevent()
        while true {
            if state.withLock({ $0.stopped }) {
                return
            }
            let count = kevent(kq, nil, 0, &event, 1, nil)
            if count == -1 {
                if errno == EINTR {
                    continue
                }
                return
            }
            guard count > 0 else {
                continue
            }
            if event.filter == Int16(EVFILT_READ), Int32(event.ident) == wakeRead {
                return
            }
            if event.filter == Int16(EVFILT_PROC) {
                handleProcExitEvent(event, onExit: onExit)
                return
            }
        }
    }

    private func handleImmediateExit(onExit: @escaping @Sendable (Int32?) -> Void) {
        switch ownership {
        case .owned:
            let status = reapOwnedChild()
            deliverIfActive(status: status, onExit: onExit)
        case .adopted:
            state.withLock { $0.signalAllowed = false }
            deliverIfActive(status: nil, onExit: onExit)
        }
    }

    private func handleProcExitEvent(_ event: Darwin.kevent, onExit: @escaping @Sendable (Int32?) -> Void) {
        if state.withLock({ $0.stopped }) {
            return
        }
        switch ownership {
        case .owned:
            let status = reapOwnedChild()
            deliverIfActive(status: status, onExit: onExit)
        case .adopted:
            reapLock.lock()
            state.withLock { $0.signalAllowed = false }
            reapLock.unlock()

            let status: Int32? = (event.fflags & UInt32(NOTE_EXITSTATUS)) != 0
                ? Int32(truncatingIfNeeded: event.data)
                : nil
            deliverIfActive(status: status, onExit: onExit)
        }
    }

    private func deliverIfActive(status: Int32?, onExit: @escaping @Sendable (Int32?) -> Void) {
        let shouldDeliver = state.withLock { s -> Bool in
            guard !s.stopped else {
                return false
            }
            s.stopped = true
            s.signalAllowed = false
            return true
        }
        if shouldDeliver {
            onExit(status)
        }
    }

    /// Reaps a directly forked child using the same `waitid(WNOWAIT)` +
    /// `waitpid` sequence as SwiftTerm's `LocalProcessChildReaper` so the PID
    /// cannot be reused while a concurrent `signal()` holds `reapLock`.
    private func reapOwnedChild() -> Int32? {
        var info = siginfo_t()
        var waitResult: Int32
        repeat {
            waitResult = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT)
        } while waitResult == -1 && errno == EINTR

        reapLock.lock()
        guard waitResult == 0 else {
            state.withLock { $0.signalAllowed = false }
            reapLock.unlock()
            return nil
        }
        defer {
            state.withLock { $0.signalAllowed = false }
            reapLock.unlock()
        }

        var status: Int32 = 0
        var waitedPID: pid_t
        repeat {
            waitedPID = waitpid(pid, &status, 0)
        } while waitedPID == -1 && errno == EINTR
        return waitedPID == pid ? status : nil
    }
}
