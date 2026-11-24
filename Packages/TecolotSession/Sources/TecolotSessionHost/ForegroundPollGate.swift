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
/// For persistent and remote panes, a background child (`sleep 30 &`) can
/// exit with no PTY output. When the foreground shell has a child, the
/// settled gate requests a slow fallback probe until that child exits.
public struct ForegroundPollGate: Sendable, Equatable {
    /// Quiet time after the last activity before a probe settles the gate.
    /// Covers shell `fork`/`exec` after Enter and the local view's 250ms
    /// output throttle.
    public static let defaultSettleWindow: Duration = .milliseconds(500)

    /// Next probe action for the caller.
    public enum Schedule: Sendable, Equatable {
        /// No probe is needed until new activity happens.
        case idle
        /// Probe now (initial state, reset, or re-enable).
        case immediate
        /// Probe after the active delay (1s live or 5s background).
        case active
        /// Probe after the background-child fallback delay (5s).
        case backgroundChildren
    }

    /// Snapshot taken when a probe starts. Pass it to `record(_:...)` so new
    /// activity or a cancelled probe does not settle the gate too early.
    public struct ProbeToken: Sendable, Equatable {
        fileprivate let generation: UInt64
        fileprivate let immediateRequest: UInt64
        fileprivate let lastActivity: ContinuousClock.Instant?
        fileprivate let startedAt: ContinuousClock.Instant
    }

    private let settleWindow: Duration
    private var generation: UInt64 = 0
    private var settledGeneration: UInt64 = 0
    private var immediateRequest: UInt64 = 1
    private var completedImmediateRequest: UInt64 = 0
    private var lastActivity: ContinuousClock.Instant?
    private var backgroundChildren = false

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
        if backgroundChildren {
            return .backgroundChildren
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
            generation: generation,
            immediateRequest: immediateRequest,
            lastActivity: lastActivity,
            startedAt: now
        )
    }

    /// Records the result of a completed probe. Set `hasBackgroundChildren`
    /// to true only when the shell is foreground and has a child process.
    public mutating func record(_ token: ProbeToken, hasBackgroundChildren: Bool = false) {
        if token.immediateRequest > completedImmediateRequest {
            completedImmediateRequest = token.immediateRequest
        }
        backgroundChildren = hasBackgroundChildren
        if let activity = token.lastActivity {
            if activity.duration(to: token.startedAt) >= settleWindow, token.generation > settledGeneration {
                settledGeneration = token.generation
            }
        } else if token.generation > settledGeneration {
            settledGeneration = token.generation
        }
    }

    /// Resets the gate for a new process.
    public mutating func reset() {
        self = ForegroundPollGate(settleWindow: settleWindow)
    }
}
