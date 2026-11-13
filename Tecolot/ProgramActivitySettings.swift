import Foundation
import Observation

extension Notification.Name {
    /// Posted only when a status preference actually changes, never for seen reports.
    static let programActivityPreferencesDidChange = Notification.Name("ProgramActivityPreferencesDidChange")
}

/// Shares one observed preferences snapshot across tabs, windows and Activity.
@Observable
@MainActor
final class ProgramActivitySettings {
    static let shared = ProgramActivitySettings()
    private(set) var value: ProgramActivityPreferences
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observer: NSObjectProtocol?

    /// Tests may provide an isolated defaults domain.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        value = ProgramActivityPreferences(defaults: defaults)
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Ignores unrelated defaults writes and invalidates observers only on a value change.
    func refresh() {
        let next = ProgramActivityPreferences(defaults: defaults)
        guard value != next else {
            return
        }
        value = next
        NotificationCenter.default.post(name: .programActivityPreferencesDidChange, object: self)
    }
}
