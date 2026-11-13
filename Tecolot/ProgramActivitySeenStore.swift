import Foundation
import Observation
import TecolotSessionDirectory
import TecolotWire

/// Persists seen reports by durable pane UUID, record path and report time.
/// Writes are debounced on a private queue so marking a report seen never
/// broadcasts a preferences change or blocks terminal drawing.
@Observable
@MainActor
final class ProgramActivitySeenStore {
    static let shared = ProgramActivitySeenStore(legacyDefaults: .standard)

    /// The former defaults key is read only during the one-time file migration.
    static let legacyDefaultsKey = "programActivitySeen"

    /// Versioned on-disk marker history; report ids never become filesystem paths.
    private struct Document: Codable {
        var version = 1
        var markers: [String: UInt64]
    }

    private(set) var revision = 0
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let debounceInterval: TimeInterval
    @ObservationIgnored private let queue = DispatchQueue(label: "tecolot.program-activity-seen")
    @ObservationIgnored private var pendingSave: DispatchWorkItem?
    @ObservationIgnored private var markers: [String: UInt64]

    /// Loads the small JSON document. Tests supply a private temporary directory.
    init(
        directory: URL = RestoreStore.applicationSupport.appendingPathComponent("ProgramActivity", isDirectory: true),
        debounceInterval: TimeInterval = 0.25, legacyDefaults: UserDefaults? = nil
    ) {
        self.directory = directory
        self.debounceInterval = debounceInterval
        let url = directory.appendingPathComponent("seen.json")
        if
            let data = try? Data(contentsOf: url),
            let document = try? JSONDecoder().decode(Document.self, from: data), document.version == 1 {
            markers = document.markers
        } else if
            let data = legacyDefaults?.data(forKey: Self.legacyDefaultsKey),
            let old = try? JSONDecoder().decode([String: UInt64].self, from: data) {
            markers = old
            // Keep the old data until the atomic file write has succeeded.
            if flush() {
                legacyDefaults?.removeObject(forKey: Self.legacyDefaultsKey)
            }
        } else {
            markers = [:]
        }
    }

    deinit {
        pendingSave?.cancel()
    }

    /// Encodes paths unambiguously without treating a report id as a file path.
    static func key(pane: UUID, record: String) -> String {
        pane.uuidString + ":" + Data(record.utf8).base64EncodedString()
    }

    /// A replacement report under the same id is unseen until its time is marked.
    func isSeen(pane: UUID, record: WireProgramStatus) -> Bool {
        _ = revision
        return markers[Self.key(pane: pane, record: record.id)] == record.reportTime
    }

    /// Updates memory immediately, bounds the history, and schedules one file write.
    func markSeen(pane: UUID, records: [WireProgramStatus]) {
        var changed = false
        for record in records {
            let key = Self.key(pane: pane, record: record.id)
            if markers[key] != record.reportTime {
                markers[key] = record.reportTime
                changed = true
            }
        }
        guard changed else {
            return
        }
        if markers.count > 8192 {
            markers = Dictionary(
                uniqueKeysWithValues: markers.sorted {
                    $0.value > $1.value
                }.prefix(8192).map {
                    ($0.key, $0.value)
                }
            )
        }
        revision += 1
        pendingSave?.cancel()
        guard let data = try? JSONEncoder().encode(Document(markers: markers)) else {
            return
        }
        let directory = directory
        let work = DispatchWorkItem {
            _ = Self.write(data, directory: directory)
        }
        pendingSave = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    /// Flushes the latest snapshot at termination and at explicit persistence boundaries.
    @discardableResult
    func flush() -> Bool {
        pendingSave?.cancel()
        pendingSave = nil
        guard let data = try? JSONEncoder().encode(Document(markers: markers)) else {
            return false
        }
        let directory = directory
        return queue.sync {
            Self.write(data, directory: directory)
        }
    }

    /// Uses the same private-directory and atomic-file helpers as restoration.
    nonisolated private static func write(_ data: Data, directory: URL) -> Bool {
        do {
            try DurableStateDirectory.makePrivateDirectory(directory)
            try DurableStateDirectory.writePrivate(data, to: directory.appendingPathComponent("seen.json"))
            return true
        } catch {
            return false
        }
    }
}
