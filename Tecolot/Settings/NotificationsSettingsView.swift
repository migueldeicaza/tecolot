import SwiftUI
import SwiftTerm

/// Edits notification, Dock and per-state program activity preferences.
struct NotificationsSettingsView: View {
    @AppStorage(ProgramActivityPreferences.showTabsKey) private var tabs = ProgramActivityPreferences.showTabsDefault
    @AppStorage(ProgramActivityPreferences.notificationsKey) private var notifications = ProgramActivityPreferences.notificationsDefault
    @AppStorage(ProgramActivityPreferences.dockKey) private var dock = ProgramActivityPreferences.dockDefault
    @AppStorage(ProgramActivityPreferences.soundsKey) private var sounds = ProgramActivityPreferences.soundsDefault
    @AppStorage(ProgramActivityPreferences.workingKey) private var working = ProgramActivityPreferences.workingDefault
    @AppStorage(ProgramActivityPreferences.blockedKey) private var blocked = ProgramActivityPreferences.blockedDefault
    @AppStorage(ProgramActivityPreferences.errorKey) private var error = ProgramActivityPreferences.errorDefault
    @AppStorage(ProgramActivityPreferences.doneKey) private var done = ProgramActivityPreferences.doneDefault
    @AppStorage(ProgramActivityPreferences.bounceKey) private var bounce = ProgramActivityPreferences.bounceDefault
    @AppStorage(ProgramActivityPreferences.announceKey) private var announce = ProgramActivityPreferences.announceDefault
    @AppStorage(ProgramActivityPreferences.colorKey) private var statusColor = ProgramActivityPreferences.colorDefault
    @AppStorage(ProgramActivityPreferences.tickerSpeedKey) private var speed = ProgramActivityPreferences.tickerSpeedDefault
    var body: some View {
        Form {
            Section("Program activity") {
                Toggle("Notify when a program finishes or needs attention", isOn: $notifications)
                Text(
                    "System notifications appear while Tecolot is inactive. Clicking one reveals its group, tab and pane."
                )
                .font(.caption).foregroundStyle(.secondary)
                Toggle("Badge Dock icon", isOn: $dock)
                if dock {
                    Text("Enable Badge application icon in System Settings → Notifications → Tecolot. Earlier notification permissions may leave badges off.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Notification Settings") {
                        TerminalNotifier.shared.requestBadgeAuthorization()
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                }
                Toggle("Play sounds", isOn: $sounds)
            }
            Section("In tabs") {
                Toggle("Show activity in tabs", isOn: $tabs)
                Toggle("Bounce tab icons", isOn: $bounce)
                Toggle("Announce messages in tabs", isOn: $announce)
                Slider(value: $speed, in: 10...100) {
                    Text("Message scroll speed")
                }
                .disabled(!announce)
                Toggle("Use color for status badges", isOn: $statusColor)
            }
            Section("States") {
                Toggle("Working", isOn: $working)
                Toggle("Blocked", isOn: $blocked)
                Toggle("Error", isOn: $error)
                Toggle("Done", isOn: $done)
                Text("Each state controls its tab indicator. Blocked, Error and Done also control system notifications, Dock badges and sounds.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            FromProgramsSettingsSection()
        }
        .formStyle(.grouped)
        .navigationTitle("Notifications")
    }
}

private struct FromProgramsSettingsSection: View {
    @AppStorage(TerminalNotificationPreferences.bellStyleKey) private var bellStyle = TerminalNotificationPreferences.bellStyleDefault.tagName
    @AppStorage(TerminalNotificationPreferences.allowsProgramNotificationsKey) private var allowsNotifications = TerminalNotificationPreferences.allowsProgramNotificationsDefault
    @AppStorage(TerminalNotificationPreferences.bellMigrationNoteDismissedKey) private var noteDismissed = TerminalNotificationPreferences.bellMigrationNoteDismissedDefault

    var body: some View {
        Section {
            if TerminalNotificationPreferences.showsMigrationNote(
                differed: TerminalNotificationPreferences.bellMigrationDiffered(), dismissed: noteDismissed
            ) {
                HStack(alignment: .top) {
                    Text("Bell and program notifications now apply to all profiles. They were set from your default profile.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        noteDismissed = true
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
            }
            Picker("Bell", selection: $bellStyle) {
                ForEach(BellStyle.allCases, id: \.tagName) { style in
                    Text(style.displayName).tag(style.tagName)
                }
            }
            Toggle("Allow programs to send notifications", isOn: $allowsNotifications)
        } header: {
            Text("From programs")
        } footer: {
            Text("Programs send notifications with OSC 9 or OSC 777. Tecolot shows them when the pane is not in front.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
