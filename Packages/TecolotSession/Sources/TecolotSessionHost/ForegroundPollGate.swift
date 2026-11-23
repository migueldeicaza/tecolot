//
// ForegroundPollGate.swift
// TecolotSessionHost
//
// Skips foreground-process polls while the shell waits at a prompt.
// The helper uses it for persistent and remote panes, and the app uses
// it for local panes.
//

/// Uses OSC 133 shell-integration marks to skip process polls.
///
/// A prompt mark is `A` (prompt start) or `D` (command finished). After a
/// prompt mark, the shell is usually the foreground program. But a prompt
/// can start child processes, for example `starship` or `$(__git_ps1)`.
/// Thus the polls continue until a poll finds only the shell. Then they
/// stop until the next `C` mark (command executed).
///
/// The line editor can start a program with no `C` mark, for example
/// Ctrl-X Ctrl-E. Most of these programs use the alternate screen, so a
/// screen switch starts the polls again (`arm()`).
///
/// The gate trusts the marks only after it sees a `C` mark. If the shell
/// sends no marks, or sends only `A`, each poll is permitted.
public struct ForegroundPollGate: Sendable, Equatable {
    private var trusted = false
    private var atPrompt = false
    private var settled = false

    /// Creates a gate that permits each poll until it sees a `C` mark.
    public init() {}

    /// Records an OSC 133 payload (the bytes after `133;`).
    public mutating func observe(osc133 payload: some Collection<UInt8>) {
        switch payload.first {
        case UInt8(ascii: "A"), UInt8(ascii: "D"):
            atPrompt = true
            settled = false
        case UInt8(ascii: "C"):
            trusted = true
            atPrompt = false
            settled = false
        default:
            break
        }
    }

    /// Starts the polls again, for example after a screen switch.
    public mutating func arm() {
        settled = false
    }

    /// Returns true if a poll can find a change. This does not change the
    /// gate: a poll that is cancelled before `record` does not count.
    public func shouldProbe() -> Bool {
        !(trusted && atPrompt && settled)
    }

    /// Records the result of a poll. `idle` is true when the poll found
    /// only the shell, with no other foreground program and no child.
    public mutating func record(idle: Bool) {
        if atPrompt, idle {
            settled = true
        }
    }

    /// Forgets the marks (terminal reset or a new process).
    public mutating func reset() {
        self = ForegroundPollGate()
    }
}
