import AppKit
import TecolotWire

/// The tab/status settings value, read once by ProgramActivitySettings when defaults change.
nonisolated struct ProgramActivityPreferences: Equatable {
    static let showTabsKey = "showProgramActivityInTabs"
    static let showTabsDefault = true
    static let notificationsKey = "programActivitySystemNotifications"
    static let notificationsDefault = true
    static let dockKey = "programActivityBadgeDockIcon"
    static let dockDefault = true
    static let soundsKey = "programActivityPlaySounds"
    static let soundsDefault = false
    static let colorKey = "useColorForStatusBadges"
    static let colorDefault = true
    static let bounceKey = "bouncesTabIcons"
    static let bounceDefault = true
    static let announceKey = "announcesMessagesInTabs"
    static let announceDefault = true
    static let tickerSpeedKey = "tabMessageScrollSpeed"
    static let tickerSpeedDefault = 33.4
    static let tabStyleKey = "tabStyle"
    static let tabStyleDefault = "horizontal"
    static let workingKey = "programActivityWorking"
    static let workingDefault = true
    static let blockedKey = "programActivityBlocked"
    static let blockedDefault = true
    static let errorKey = "programActivityError"
    static let errorDefault = true
    static let doneKey = "programActivityDone"
    static let doneDefault = true
    static let idleKey = "programActivityIdle"
    static let idleDefault = true

    var showTabs = Self.showTabsDefault
    var notifications = Self.notificationsDefault
    var dock = Self.dockDefault
    var sounds = Self.soundsDefault
    var color = Self.colorDefault
    var bounce = Self.bounceDefault
    var announce = Self.announceDefault
    var tickerSpeed = Self.tickerSpeedDefault
    var disabledStates: Set<ProgramStatusState> = []
    /// Returns the stored preference key for one protocol state.
    static func stateKey(_ state: ProgramStatusState) -> String {
        switch state {
        case .working: workingKey
        case .blocked: blockedKey
        case .error: errorKey
        case .done: doneKey
        case .idle: idleKey
        }
    }
    static func stateDefault(_ state: ProgramStatusState) -> Bool {
        switch state {
        case .working: workingDefault
        case .blocked: blockedDefault
        case .error: errorDefault
        case .done: doneDefault
        case .idle: idleDefault
        }
    }
    /// Reads one complete settings snapshot, retaining defaults for unset keys.
    init(defaults: UserDefaults = .standard) {
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) as? Bool ?? fallback
        }
        showTabs = flag(Self.showTabsKey, Self.showTabsDefault)
        notifications = flag(Self.notificationsKey, Self.notificationsDefault)
        dock = flag(Self.dockKey, Self.dockDefault)
        sounds = flag(Self.soundsKey, Self.soundsDefault)
        color = flag(Self.colorKey, Self.colorDefault)
        bounce = flag(Self.bounceKey, Self.bounceDefault)
        announce = flag(Self.announceKey, Self.announceDefault)
        tickerSpeed = min(100, max(10, defaults.object(forKey: Self.tickerSpeedKey) as? Double ?? Self.tickerSpeedDefault))
        disabledStates = Set(ProgramStatusState.allCases.filter {
            !flag(Self.stateKey($0), Self.stateDefault($0))
        })
    }
}

/// Reduces all pane records into the tab indicator, badge and accessible announcement.
nonisolated struct TabStatus: Equatable {
    /// A report with durable pane identity and the user's seen state.
    struct Record: Equatable {
        var paneID: UUID
        var value: WireProgramStatus
        var unseen: Bool
    }
    /// Orders attention badges independently of the winning program indicator.
    enum Badge: Int, Comparable {
        case quiet, notified, done, error, blocked
        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
        var symbol: String? {
            switch self {
            case .quiet:
                nil
            case .notified:
                "bell.fill"
            case .done:
                "checkmark"
            case .error:
                "xmark"
            case .blocked:
                "exclamationmark"
            }
        }
    }
    var winner: Record?
    var badge: Badge?
    var badgeRecord: Record?
    var blocked: [Record] = []
    var unseen = false
    var state: ProgramStatusState? {
        winner?.value.state
    }
    var progress: Int? {
        winner?.value.progress
    }
    var message: String? {
        winner?.value.message
    }
    var app: String? {
        winner?.value.app
    }
    var badgeSymbol: String? {
        guard badge == .blocked else {
            return badge?.symbol
        }
        switch badgeRecord?.value.kind {
        case "permission":
            return "hand.raised.fill"
        case "question":
            return "questionmark"
        case "auth":
            return "key.fill"
        default:
            return "exclamationmark"
        }
    }
    var accessibilityValue: String {
        let record = badgeRecord ?? winner
        let label: String
        switch record?.value.state {
        case .blocked:
            switch record?.value.kind {
            case "permission":
                label = "Needs permission"
            case "question":
                label = "Needs an answer"
            case "auth":
                label = "Needs authentication"
            default:
                label = "Needs you"
            }
        case .error:
            label = "Failed"
        case .done:
            label = "Finished"
        case .working:
            label = "Working"
        case .idle:
            label = "Idle"
        case nil:
            label = badge == .notified ? "Notified" : (badge == .quiet ? "Activity" : "")
        }
        let percentage = progress.map {
            ", \($0)%"
        } ?? ""
        return label + percentage + (record?.value.message.flatMap {
            $0.isEmpty ? nil : ": " + $0
        } ?? "")
    }
    static func activityAccessibilityValue(count: Int) -> String {
        "\(count) \(count == 1 ? "tab" : "tabs") with unseen activity"
    }
    static let none = TabStatus()
    /// Applies state priority, report recency, Mute and disabled-state policy across panes.
    static func reduce(
        _ records: [Record], quiet: Bool = false, notified: Bool = false,
        muted: Bool = false, disabledStates: Set<ProgramStatusState> = []
    ) -> Self {
        let sorted = records.filter {
            !disabledStates.contains($0.value.state)
        }.sorted {
            if $0.value.state.priority != $1.value.state.priority {
                return $0.value.state.priority > $1.value.state.priority
            }
            return $0.value.reportTime > $1.value.reportTime
        }
        var panes = Set<UUID>()
        let paneWinners = sorted.filter {
            panes.insert($0.paneID).inserted
        }
        let attention = sorted.first {
            $0.unseen && ($0.value.state == .blocked || $0.value.state.isCompletion)
        }
        let badge: Badge? =
            attention.map {
                $0.value.state == .blocked ? .blocked : ($0.value.state == .error ? .error : .done)
            }
            ?? (notified ? .notified : (quiet ? .quiet : nil))
        return TabStatus(
            winner: sorted.first, badge: muted ? nil : badge, badgeRecord: attention,
            blocked: muted ? [] : paneWinners.filter {
                $0.unseen && $0.value.state == .blocked
            },
            unseen: !muted && (attention != nil || notified || quiet)
        )
    }
    /// Counts tabs with unseen completion or blocked badges, once per tab.
    static func dockCount(_ statuses: [Self]) -> Int {
        statuses.filter {
            $0.badge.map {
                $0 >= .done
            } == true
        }.count
    }
}

extension TabStatus.Badge {
    @MainActor var color: NSColor {
        switch self {
        case .quiet:
            .tertiaryLabelColor
        case .notified:
            .systemBlue
        case .done:
            .systemGreen
        case .error:
            .systemRed
        case .blocked:
            .systemOrange
        }
    }
}

extension PaneProgramStatus {
    var activityRecords: [TabStatus.Record] {
        records.map {
            TabStatus.Record(paneID: paneID, value: $0, unseen: !seen.isSeen(pane: paneID, record: $0))
        }
    }
    var tabStatus: TabStatus {
        TabStatus.reduce(
            activityRecords, quiet: quiet, notified: notified,
            disabledStates: ProgramActivitySettings.shared.value.disabledStates
        )
    }
}
