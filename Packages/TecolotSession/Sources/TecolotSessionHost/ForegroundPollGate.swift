//
// ForegroundPollGate.swift
// TecolotSessionHost
//
// Stops foreground-process probes while a pane is quiet. Re-arms probes
// on terminal output or user input. The helper uses it for persistent and
// remote panes, and the app uses it for local panes.
//

/// Runs foreground-process probes only after terminal activity.
///
/// Most foreground process changes write output to the PTY or follow user
/// input. While a pane is quiet, no probe or timer wakeup is needed.
///
/// Activity arms a probe. Callers keep an earlier timer so continuous
/// output does not delay the next probe. A probe settles the gate only
/// after `settleWindow` passes with no new activity. This delay finds
/// silent commands (for example `sleep`) that start right after an Enter
/// echo.
///
/// A probe can see the forked child of the shell before `exec` completes.
/// That child leads the foreground group but runs the shell image. Such a
/// probe does not settle the gate, because no new activity can come before
/// the real program starts (for example, when Gatekeeper holds `exec`).
/// After `pendingExecLimit` with no activity, the gate settles into a slow
/// fallback probe until `pendingExecFallbackLimit` passes. That total limit
/// stops probes for a nested shell of the same type or a subshell, which
/// also look like a forked shell child.
///
/// For persistent and remote panes, a background child (`sleep 30 &`) can
/// exit with no PTY output. When the foreground shell has a child, the
/// settled gate requests the same slow fallback probe until that child exits.
public struct ForegroundPollGate: Sendable, Equatable {
    /// Quiet time after the last activity before a probe settles the gate.
    /// Covers shell `fork`/`exec` after Enter and the local view's 250ms
    /// output throttle.
    public static let defaultSettleWindow: Duration = .milliseconds(500)

    /// Quiet time after which a probe that found a pending `exec` moves from
    /// active probes to the slow fallback probe.
    public static let pendingExecLimit: Duration = .seconds(10)

    /// Total quiet time after which a pending `exec` settles the gate to
    /// `.idle`.
    public static let pendingExecFallbackLimit: Duration = .seconds(60)

    /// Next probe action for the caller.
    public enum Schedule: Sendable, Equatable {
        /// No probe is needed until new activity happens.
        case idle
        /// Probe now (initial state, reset, or re-enable).
        case immediate
        /// Probe after the active delay (1s live or 5s background).
        case active
        /// Probe after the slow fallback delay (5s).
        case fallback
    }

    /// Snapshot taken when a probe starts. Pass it to `record(_:...)` so new
    /// activity or a cancelled probe does not settle the gate too early.
    public struct ProbeToken: Sendable, Equatable {
        fileprivate let epoch: UInt64
        fileprivate let generation: UInt64
        fileprivate let immediateRequest: UInt64
        fileprivate let lastActivity: ContinuousClock.Instant?
        fileprivate let startedAt: ContinuousClock.Instant
    }

    private let settleWindow: Duration
    /// Changes on each `reset()`. `record` ignores tokens from an earlier epoch.
    private var epoch: UInt64 = 0
    private var generation: UInt64 = 0
    private var settledGeneration: UInt64 = 0
    private var immediateRequest: UInt64 = 1
    private var completedImmediateRequest: UInt64 = 0
    private var lastActivity: ContinuousClock.Instant?
    private var backgroundChildren = false
    private var pendingExecFallback = false

    /// Creates a gate that requests an initial probe.
    public init(settleWindow: Duration = defaultSettleWindow) {
        self.settleWindow = settleWindow
    }

    /// Next probe action for the caller.
    public var schedule: Schedule {
        if immediateRequest != completedImmediateRequest {
            return .immediate
        }
        if generation != settledGeneration {
            return .active
        }
        if backgroundChildren || pendingExecFallback {
            return .fallback
        }
        return .idle
    }

    /// True when the gate needs a probe.
    public var shouldProbe: Bool {
        schedule != .idle
    }

    /// Records terminal output or user input and arms active probes.
    public mutating func noteActivity(at now: ContinuousClock.Instant = .now) {
        generation &+= 1
        if let existing = lastActivity {
            lastActivity = max(existing, now)
        } else {
            lastActivity = now
        }
    }

    /// Requests an immediate probe (for example on start or re-enable).
    public mutating func requestImmediateProbe() {
        immediateRequest &+= 1
    }

    /// Captures the current state before a probe starts. A cancelled probe
    /// does not settle the gate.
    public func beginProbe(at now: ContinuousClock.Instant = .now) -> ProbeToken {
        ProbeToken(
            epoch: epoch,
            generation: generation,
            immediateRequest: immediateRequest,
            lastActivity: lastActivity,
            startedAt: now
        )
    }

    /// Records the result of a completed probe. Set `hasBackgroundChildren`
    /// to true only when the shell is foreground and has a child process.
    /// Set `pendingExec` to true when the probe found a forked shell child
    /// that did not start its program yet (see `isPendingExec`). Then the
    /// probe does not settle the gate. Returns false when the token is from
    /// before a `reset()`: then the caller must ignore the probe result.
    @discardableResult
    public mutating func record(
        _ token: ProbeToken,
        hasBackgroundChildren: Bool = false,
        pendingExec: Bool = false
    ) -> Bool {
        guard token.epoch == epoch else {
            return false
        }
        if token.immediateRequest > completedImmediateRequest {
            completedImmediateRequest = token.immediateRequest
        }
        backgroundChildren = hasBackgroundChildren
        if pendingExec, let activity = token.lastActivity {
            let elapsed = activity.duration(to: token.startedAt)
            if elapsed < Self.pendingExecLimit {
                pendingExecFallback = false
                return true
            }
            pendingExecFallback = elapsed < Self.pendingExecFallbackLimit
        } else {
            pendingExecFallback = false
        }
        if let activity = token.lastActivity {
            if activity.duration(to: token.startedAt) >= settleWindow, token.generation > settledGeneration {
                settledGeneration = token.generation
            }
        } else if token.generation > settledGeneration {
            settledGeneration = token.generation
        }
        return true
    }

    /// Resets the gate for a new process. Tokens from before the reset
    /// have no effect.
    public mutating func reset() {
        let next = epoch &+ 1
        self = ForegroundPollGate(settleWindow: settleWindow)
        epoch = next
    }

    /// True when a foreground process is not the shell, runs the shell
    /// executable, has no children, did not complete `exec`, and has the
    /// shell's process name. This is a forked child of the shell before `exec`
    /// completes. If a path is not known, the result is false. An unknown name
    /// or `leaderDidExec` value does not change the result.
    ///
    /// On Darwin, `leaderDidExec` comes from `PROC_FLAG_EXEC` and rejects
    /// nested shells (`zsh`, `vim :shell`, `newgrp`) at once. On Linux, where
    /// `leaderDidExec` is nil, `pendingExecFallbackLimit` bounds that cost.
    public static func isPendingExec(
        shellPID: Int32,
        shellPath: String?,
        shellName: String? = nil,
        leaderPID: Int32,
        leaderPath: String?,
        leaderName: String? = nil,
        leaderHasChildren: Bool = false,
        leaderDidExec: Bool? = nil
    ) -> Bool {
        guard
            shellPID > 0, leaderPID > 0, leaderPID != shellPID,
            !leaderHasChildren,
            leaderDidExec != true,
            let shellPath, !shellPath.isEmpty,
            let leaderPath, shellPath == leaderPath else {
            return false
        }
        if let shellName, let leaderName, !shellName.isEmpty, !leaderName.isEmpty {
            return shellName == leaderName
        }
        return true
    }
}
