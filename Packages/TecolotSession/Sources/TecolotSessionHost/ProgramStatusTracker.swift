import Foundation
import SwiftTerm
import Synchronization
import TecolotWire

/// Host policy around SwiftTerm's protocol store. This also runs in the app
/// for local panes. Suppression removes only the matching record, never its
/// descendants (SwiftTerm's clear API deliberately clears a whole subtree).
public final class ProgramStatusTracker: Sendable {
    /// Thread-protected native records, suppression versions and reset bookkeeping.
    private struct State {
        var raw: [WireProgramStatus] = []
        var suppressed: [String: WireProgramStatus] = [:]
        var uses7501 = false
        var resetSerial: UInt64 = 0
        var normalBuffer: ObjectIdentifier?
        var wasAlternate: Bool?
        var progress: WireProgress?
        var progressReportTime: UInt64 = 0
        var lastTime: UInt64 = 0
        var hasExited = false
    }
    private let state = Mutex(State())
    private let reportProbe = Mutex<ProgramStatusReportProbe?>(nil)
    /// Creates an empty tracker without accessing the terminal emulator.
    public init() {}

    /// Returns inherited app identities, stable report times and legacy progress for clients.
    public var snapshot: ProgramStatusMessage {
        state.withLock { value in
            let current = value.raw.filter {
                value.suppressed[$0.id] != $0
            }
            let byID = Dictionary(uniqueKeysWithValues: current.map {
                ($0.id, $0)
            })
            let inherited = current.map { original in
                var record = original
                var ancestor = original.id
                while record.app == nil {
                    if let app = byID[ancestor]?.app {
                        record.app = app
                        break
                    }
                    guard !ancestor.isEmpty else {
                        break
                    }
                    ancestor = ancestor.lastIndex(of: "/").map {
                        String(ancestor[..<$0])
                    } ?? ""
                }
                return record
            }
            var snapshot = ProgramStatusMessage(
                records: inherited,
                uses7501: value.uses7501, resetSerial: value.resetSerial, progress: value.progress
            )
            snapshot.progressReportTime = value.progressReportTime
            return snapshot
        }
    }

    /// Reconciles SwiftTerm's ordered store while preserving report times on untouched ids.
    /// Future native states are ignored instead of crashing every session in the helper.
    public func receive(_ records: [TerminalProgramStatus], now: Date = Date(), isReport: Bool = true) {
        state.withLock { value in
            if !records.isEmpty {
                value.uses7501 = true
            }
            let previous = Dictionary(uniqueKeysWithValues: value.raw.map {
                ($0.id, $0)
            })
            // SwiftTerm moves a reported id to the end of its LRU store. A same-size
            // or growing snapshot therefore identifies even an identical repeat report;
            // shrinking snapshots are removals and must not rearm the last survivor.
            let updatedID = isReport && records.count >= value.raw.count ? records.last?.id : nil
            value.raw = records.compactMap { record in
                guard let state = ProgramStatusState(rawValue: record.state.rawValue) else {
                    return nil
                }
                var next = WireProgramStatus(
                    id: record.id, state: state,
                    kind: record.kind?.rawValue, progress: record.progress, app: record.app,
                    title: record.title, message: record.message
                )
                if var old = previous[record.id] {
                    let time = old.reportTime
                    old.reportTime = 0
                    if old == next, record.id != updatedID {
                        next.reportTime = time
                        return next
                    }
                }
                value.lastTime = max(value.lastTime + 1, UInt64(max(0, now.timeIntervalSince1970 * 1_000_000)))
                next.reportTime = value.lastTime
                return next
            }
            value.suppressed = value.suppressed.filter { id, record in
                value.raw.contains(record) && record.id == id
            }
            if value.hasExited {
                for record in value.raw where !record.state.isCompletion {
                    value.suppressed[record.id] = record
                }
            }
        }
    }

    /// Validates asynchronous OSC events and restores their ordering relative to prompts.
    /// This also recognizes accepted clears when the native store was already empty.
    @discardableResult
    public func observeReport(_ payload: [UInt8], records: [TerminalProgramStatus], touchReport: Bool = true) -> Bool {
        guard
            !state.withLock({
                $0.hasExited
            }) else {
            return false
        }
        let result = reportProbe.withLock { probe in
            if probe == nil {
                probe = ProgramStatusReportProbe()
            }
            return probe!.validate(payload)
        }
        guard result.accepted else {
            return false
        }
        receive(records, isReport: false)
        if result.clear {
            noteRealClear()
        } else if let id = result.id {
            rearmReport(id: id, touchReport: touchReport)
        }
        return true
    }

    /// Rearms a validated report only if its process is still live at this atomic step.
    func rearmReport(id: String, touchReport: Bool) {
        state.withLock { value in
            guard !value.hasExited else {
                return
            }
            value.suppressed.removeValue(forKey: id)
            if
                touchReport, let index = value.raw.firstIndex(where: {
                    $0.id == id
                }) {
                value.lastTime = max(value.lastTime + 1, UInt64(Date().timeIntervalSince1970 * 1_000_000))
                value.raw[index].reportTime = value.lastTime
            }
        }
    }

    /// Remembers accepted native clears even when SwiftTerm had no record to remove.
    public func noteRealClear() {
        state.withLock {
            $0.uses7501 = true
        }
    }
    /// Retains legacy progress and assigns a monotonic version for seen-keypress clearing.
    public func progress(_ report: WireProgress) {
        state.withLock {
            $0.progress = report
            $0.progressReportTime = max($0.progressReportTime + 1, UInt64(Date().timeIntervalSince1970 * 1_000_000))
        }
    }

    /// Learns the normal buffer lazily from a real delegate callback, without terminal input.
    public func initializeBuffer(_ terminal: Terminal) {
        guard !terminal.isCurrentBufferAlternate else {
            return
        }
        state.withLock {
            if $0.normalBuffer == nil {
                $0.normalBuffer = ObjectIdentifier(terminal.buffer)
                $0.wasAlternate = false
            }
        }
    }

    /// Detects RIS without injecting escapes. The pin exposes no public Terminal accessor.
    /// Native store clearing alone cannot distinguish clear from RIS, and sends no change
    /// for an empty store. Identity is needed to reenable OSC 9;4 and advance resetSerial.
    /// Screen switches keep the normal buffer; RIS replaces it and explicitly notifies.
    /// Before a normal buffer has ever been observed, an alternate-to-normal switch is
    /// ambiguous, so learn that baseline without discarding reports. A native reset
    /// callback would be needed to distinguish a first RIS from that first screen return.
    @discardableResult
    public func bufferActivated(_ terminal: Terminal) -> Bool {
        state.withLock { value in
            if terminal.isCurrentBufferAlternate {
                value.wasAlternate = true
                return false
            }
            let identity = ObjectIdentifier(terminal.buffer)
            let old = value.normalBuffer
            let previousMode = value.wasAlternate
            value.normalBuffer = identity
            value.wasAlternate = false
            let replaced = old.map {
                $0 != identity
            } ?? (previousMode != true)
            guard replaced else {
                return false
            }
            value.raw = []
            value.suppressed = [:]
            value.progress = nil
            value.progressReportTime = 0
            value.uses7501 = false
            value.hasExited = false
            value.resetSerial &+= 1
            return true
        }
    }

    /// Keeps completion reports after process exit and rejects later transient reports.
    public func processExited() {
        state.withLock {
            $0.hasExited = true
        }
        dropTransient()
    }

    /// Hides idle, working and blocked at a shell prompt or process exit, retaining
    /// done/error reports and avoiding native subtree clears that could erase children.
    public func dropTransient() {
        state.withLock { value in
            for record in value.raw where !record.state.isCompletion {
                value.suppressed[record.id] = record
            }
            if value.progress?.state != 2 {
                value.progress = nil
            }
        }
    }

    /// Removes only the completion versions the user saw before pressing a key.
    /// A later report under the same id survives a delayed client clear.
    public func clearSeen(_ records: [WireProgramStatus]) {
        state.withLock { value in
            if
                records.contains(where: {
                    $0.id.isEmpty && $0.state == .error && $0.reportTime == value.progressReportTime
                }),
                value.progress?.state == 2 {
                value.progress = nil
            }
            for record in records
                where record.state.isCompletion
                && value.raw.contains(where: {
                    $0.id == record.id && $0.reportTime == record.reportTime
                }) {
                value.suppressed[record.id] = value.raw.first {
                    $0.id == record.id && $0.reportTime == record.reportTime
                }
            }
        }
    }
}

/// The OSC observer is asynchronous. Validate reports with SwiftTerm itself
/// before using their ordered events to reconcile a prompt and a following
/// report from the same output batch. No probe response ever reaches a PTY.
private final class ProgramStatusReportProbe: @unchecked Sendable {
    /// Discards probe replies so validation can never send output to a PTY.
    private final class Quiet: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }
    private let delegate: Quiet
    private let terminal: Terminal
    /// Creates an isolated, tiny emulator used only to validate OSC reports.
    init() {
        let delegate = Quiet()
        self.delegate = delegate
        terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 2, rows: 2, scrollback: 0))
    }
    /// Uses the pinned parser to validate reports and clears before asynchronous reconciliation.
    func validate(_ payload: [UInt8]) -> (accepted: Bool, clear: Bool, id: String?) {
        guard payload.count <= 4087, payload != [63] else {
            return (false, false, nil)
        }
        terminal.clearProgramStatus()
        // SwiftTerm trims ASCII space and 0x09...0x0D only. Unicode trimming
        // can turn a malformed pair into a clear that the native parser ignored.
        let whitespace = CharacterSet(charactersIn: " \t\n\r\u{000b}\u{000c}")
        var fields: [String: String] = [:]
        for pair in String(decoding: payload, as: UTF8.self).split(separator: ":") {
            guard let equal = pair.firstIndex(of: "=") else {
                continue
            }
            let key = pair[..<equal].trimmingCharacters(in: whitespace)
            let value = pair[pair.index(after: equal)...].trimmingCharacters(in: whitespace)
            if
                value.utf8.allSatisfy({
                    (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                        || [95, 46, 44, 43, 47, 61, 45].contains($0)
                }) {
                fields[key] = value
            }
        }
        let clear = fields["state"] == "clear"
        if clear {
            let id = fields["id"].map {
                ":id=" + $0
            } ?? ""
            terminal.feed(text: "\u{1b}]7501;state=idle" + id + "\u{7}")
            guard !terminal.programStatusRecords.isEmpty else {
                return (false, true, nil)
            }
        }
        let bytes = Array("\u{1b}]7501;".utf8) + payload + [7]
        terminal.feed(buffer: bytes[...])
        return (
            clear ? terminal.programStatusRecords.isEmpty : !terminal.programStatusRecords.isEmpty, clear,
            terminal.programStatusRecords.first?.id
        )
    }
}
