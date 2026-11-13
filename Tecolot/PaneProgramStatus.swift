import Foundation
import Observation
import TecolotWire

/// Plain text at every presentation boundary, including notifications. The
/// terminal grid remains responsible for its own control-sequence handling.
nonisolated enum ProgramStatusText {
    /// Removes control and directional formatting characters and caps UTF-8 text at the display boundary.
    static func sanitize(_ text: String, limit: Int = 2048) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            let v = scalar.value
            guard
                v > 31, !(127...159).contains(v), !(0x200B...0x200F).contains(v),
                !(0x202A...0x202E).contains(v), !(0x2066...0x2069).contains(v), v != 0xFEFF
            else {
                continue
            }
            guard result.utf8.count + scalar.utf8.count <= limit else {
                break
            }
            result.unicodeScalars.append(scalar)
        }
        return result
    }
}

/// Per-record stabilization avoids starving a stable pane when another record
/// reports progress frequently. Tests drive `advance` with an explicit clock.
nonisolated struct ProgramStatusCoalescer {
    /// A candidate state and the time it began its stabilization interval.
    struct Pending {
        var record: WireProgramStatus
        var since: TimeInterval
    }
    private(set) var records: [WireProgramStatus] = []
    private var pending: [String: Pending] = [:]
    var nextDeadline: TimeInterval? {
        pending.values.map {
            $0.since + 0.3
        }.min()
    }

    /// Reconciles ids immediately while deferring state transitions until they stabilize.
    mutating func submit(_ incoming: [WireProgramStatus], at now: TimeInterval) {
        let ids = Set(incoming.map(\.id))
        records.removeAll {
            !ids.contains($0.id)
        }
        pending = pending.filter {
            ids.contains($0.key)
        }
        for record in incoming {
            if
                let index = records.firstIndex(where: {
                    $0.id == record.id
                }), records[index].state == record.state {
                records[index] = record
                pending.removeValue(forKey: record.id)
            } else if var candidate = pending[record.id], candidate.record.state == record.state {
                candidate.record = record
                pending[record.id] = candidate
            } else {
                pending[record.id] = Pending(record: record, since: now)
            }
        }
        advance(to: now)
    }
    /// Publishes candidates that have held their state for at least 300 ms.
    mutating func advance(to now: TimeInterval) {
        for (id, candidate) in pending where now + 0.000_001 >= candidate.since + 0.3 {
            records.removeAll {
                $0.id == id
            }
            records.append(candidate.record)
            pending.removeValue(forKey: id)
        }
    }
    /// Removes matching published and pending versions together.
    mutating func remove(where predicate: (WireProgramStatus) -> Bool) {
        records.removeAll(where: predicate)
        pending = pending.filter {
            !predicate($0.value.record)
        }
    }
}

/// Per-pane presentation policy. The protocol parser and store stay in SwiftTerm.
@Observable @MainActor
final class PaneProgramStatus {
    private(set) var records: [WireProgramStatus] = []
    private(set) var quiet = false
    private(set) var notified = false
    private(set) var uses7501 = false
    @ObservationIgnored private var coalescer = ProgramStatusCoalescer()
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var resetSerial: UInt64 = 0
    @ObservationIgnored private var fallbackTime: UInt64 = 0
    @ObservationIgnored private var lastFallbackReportTime: UInt64?
    @ObservationIgnored private let now: () -> TimeInterval
    @ObservationIgnored private let schedules: Bool
    @ObservationIgnored var onChange: (() -> Void)?
    let paneID: UUID
    let seen: ProgramActivitySeenStore

    /// Creates pane policy with an injectable clock and scheduler for deterministic tests.
    init(
        paneID: UUID, seen: ProgramActivitySeenStore? = nil,
        now: @escaping () -> TimeInterval = {
            Date().timeIntervalSince1970
        }, schedules: Bool = true
    ) {
        self.paneID = paneID
        self.seen = seen ?? .shared
        self.now = now
        self.schedules = schedules
    }
    deinit { timer?.cancel() }

    /// Applies host resets and prefers native records over synthetic OSC 9;4 progress.
    func receive(_ snapshot: ProgramStatusMessage) {
        if snapshot.resetSerial != resetSerial {
            resetSerial = snapshot.resetSerial
            uses7501 = false
            coalescer = ProgramStatusCoalescer()
            lastFallbackReportTime = nil
        }
        if snapshot.uses7501 {
            uses7501 = true
        }
        if uses7501 {
            submit(snapshot.records)
        } else if let progress = snapshot.progress {
            if snapshot.progressReportTime == 0 {
                receiveProgress(progress)
            } else if lastFallbackReportTime != snapshot.progressReportTime {
                lastFallbackReportTime = snapshot.progressReportTime
                receiveProgress(progress, reportTime: snapshot.progressReportTime)
            }
        } else {
            submit([])
        }
    }
    /// Maps legacy progress to a synthetic root until a real OSC 7501 report arrives.
    func receiveProgress(_ progress: WireProgress, reportTime: UInt64? = nil) {
        guard !uses7501 else {
            return
        }
        let state: ProgramStatusState
        switch progress.state {
        case 0:
            submit([])
            return
        case 1, 3:
            state = .working
        case 2:
            state = .error
        default:
            return
        }
        fallbackTime = max(fallbackTime + 1, UInt64(max(0, now() * 1_000_000)))
        submit([
            WireProgramStatus(
                state: state, progress: progress.state == 1 ? progress.progress.map(Int.init) : nil,
                reportTime: reportTime ?? fallbackTime
            )
        ])
    }
    /// Sanitizes display text and preserves seen status across progress-only blocked updates.
    private func submit(_ incoming: [WireProgramStatus]) {
        let safe = incoming.map { value in
            var record = value
            record.message = record.message.map {
                ProgramStatusText.sanitize($0)
            }
            record.title = record.title.map {
                ProgramStatusText.sanitize($0, limit: 192)
            }
            return record
        }
        let continuingSeen = safe.filter { next in
            next.state == .blocked
                && records.contains { old in
                    old.id == next.id && old.state == next.state && old.kind == next.kind && old.message == next.message
                        && seen.isSeen(pane: paneID, record: old)
                }
        }
        seen.markSeen(pane: paneID, records: continuingSeen)
        coalescer.submit(safe, at: now())
        publish()
        schedule()
    }
    /// Publishes stabilized records and schedules the next pending transition.
    func flush() {
        coalescer.advance(to: now())
        publish()
        schedule()
    }
    /// Maintains one cancellable wake-up for the next stabilization deadline.
    private func schedule() {
        timer?.cancel()
        timer = nil
        guard schedules, let deadline = coalescer.nextDeadline else {
            return
        }
        let delay = max(0, deadline - now())
        timer = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            self?.flush()
        }
    }
    /// Invalidates observers only when the published records change.
    private func publish() {
        let next = coalescer.records
        guard records != next else {
            return
        }
        records = next
        onChange?()
    }
    /// Retains completion reports at shell prompts and process exit.
    func dropTransient() {
        coalescer.remove {
            !$0.state.isCompletion
        }
        publish()
        schedule()
    }
    /// Marks current reports seen and clears output and notification attention.
    func markSeen() {
        seen.markSeen(pane: paneID, records: records)
        if quiet || notified {
            quiet = false
            notified = false
        }
    }
    @discardableResult
    /// Drops the exact completion versions already seen before this keypress.
    func keypress() -> [WireProgramStatus] {
        let removed = records.filter {
            $0.state.isCompletion && seen.isSeen(pane: paneID, record: $0)
        }
        coalescer.remove { record in
            removed.contains(record)
        }
        publish()
        schedule()
        return removed
    }
    /// Output is quiet when its tab is hidden or its window is not key.
    static func isQuiet(tabShown: Bool, windowKey: Bool) -> Bool {
        !tabShown || !windowKey
    }
    /// Raises quiet attention once for output outside the visible key tab.
    func noteOutput(tabShown: Bool, windowKey: Bool) {
        guard Self.isQuiet(tabShown: tabShown, windowKey: windowKey), !quiet else {
            return
        }
        quiet = true
        onChange?()
    }
    /// Raises notified attention for a bell or explicit notification outside the visible pane.
    func noteNotification(isSeen: Bool) {
        guard !isSeen, !notified else {
            return
        }
        notified = true
        onChange?()
    }
}
