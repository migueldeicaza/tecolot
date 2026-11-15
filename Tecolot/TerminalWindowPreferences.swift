import AppKit

/// Observes only the appearance defaults used by mounted pane hosts and tab icons.
@MainActor
final class TerminalWindowPreferences: NSObject {
    nonisolated private static let keys = [
        GlobalAppearanceSettings.showPaneHeadersKey,
        GlobalAppearanceSettings.paneCardsBackdropKey,
        GlobalAppearanceSettings.terminalPaddingKey,
        GlobalAppearanceSettings.paneStyleKey,
        GlobalAppearanceSettings.highlightActivePaneKey,
        GlobalAppearanceSettings.paneHighlightColorKey
    ]
    private let defaults: UserDefaults
    private(set) var value: GlobalAppearanceSettings
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        value = GlobalAppearanceSettings(defaults: defaults)
        super.init()
        for key in Self.keys {
            defaults.addObserver(self, forKeyPath: key, options: [], context: nil)
        }
    }

    deinit {
        for key in Self.keys {
            defaults.removeObserver(self, forKeyPath: key)
        }
    }

    nonisolated override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            let next = GlobalAppearanceSettings(defaults: self.defaults)
            guard next != self.value else {
                return
            }
            self.value = next
            self.onChange?()
        }
    }
}

extension GlobalAppearanceSettings {
    init(defaults: UserDefaults) {
        self.init()
        paneCardsEnabled = defaults.object(forKey: Self.showPaneHeadersKey) as? Bool ?? Self.showPaneHeadersDefault
        paneCardsBackdrop = defaults.string(forKey: Self.paneCardsBackdropKey).flatMap(Backdrop.init(rawValue:)) ?? Self.paneCardsBackdropDefault
        terminalPadding = defaults.string(forKey: Self.terminalPaddingKey).flatMap(TerminalPadding.init(rawValue:)) ?? Self.terminalPaddingDefault
        paneStyle = defaults.string(forKey: Self.paneStyleKey).flatMap(PaneStyle.init(rawValue:)) ?? Self.paneStyleDefault
        highlightActivePane = defaults.object(forKey: Self.highlightActivePaneKey) as? Bool ?? Self.highlightActivePaneDefault
        paneHighlightColor = defaults.string(forKey: Self.paneHighlightColorKey).flatMap(HighlightColor.decode)
    }
}

/// KVO for defaults keys without dots. Snapshot comparison prevents redundant invalidation.
@MainActor
final class DefaultsValueObserver<Value: Equatable>: NSObject {
    private let defaults: UserDefaults
    private let keys: [String]
    private let read: (UserDefaults) -> Value
    private var value: Value
    var onChange: ((Value) -> Void)?

    init(defaults: UserDefaults, keys: [String], read: @escaping (UserDefaults) -> Value) {
        precondition(keys.allSatisfy { !$0.contains(".") })
        self.defaults = defaults
        self.keys = keys
        self.read = read
        value = read(defaults)
        super.init()
        for key in keys {
            defaults.addObserver(self, forKeyPath: key, options: [], context: nil)
        }
    }

    deinit {
        for key in keys {
            defaults.removeObserver(self, forKeyPath: key)
        }
    }

    nonisolated override func observeValue(
        forKeyPath keyPath: String?, of object: Any?,
        change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let next = self.read(self.defaults)
            guard next != self.value else { return }
            self.value = next
            self.onChange?(next)
        }
    }
}
