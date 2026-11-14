import SwiftUI

/// Edits live preferences for tab layout, appearance and the sidebar.
struct TabInterfaceSettingsView: View {
    @AppStorage("tabStyle") private var tabStyle = "horizontal"
    @AppStorage("sidebarPosition") private var sidebarPosition = "left"
    @AppStorage(TabStripPreferences.fillKey) private var fill = false
    @AppStorage(TabStripPreferences.iconCountKey) private var icons = 3
    @AppStorage("useCommandDigitsForTabs") private var useCommandDigitsForTabs = true
    @AppStorage("sidebarTextSize") private var sidebarTextSize = 0.0
    @AppStorage("preserveWidthWhenResizingSidebar") private var preserveWidth = true
    @AppStorage("sidebarGesture") private var sidebarGesture = "swipe"
    @AppStorage(TabStripPreferences.colorModeKey) private var color = "always"
    @AppStorage(TabStripPreferences.animationStyleKey) private var animation = "natural"
    @AppStorage(TabStripPreferences.preferGeneratedTitlesKey) private var generatedTitles = true

    private var style: Binding<String> {
        Binding(get: {
            tabStyle == "horizontal" ? "above" : sidebarPosition
        }, set: { value in
            if value != "above" {
                sidebarPosition = value
            }
            tabStyle = value == "above" ? "horizontal" : "vertical"
        })
    }

    static func displayedIconCount(stored: Int, tabsOnSide: Bool) -> Int {
        tabsOnSide ? min(stored, 3) : stored
    }

    private var iconSelection: Binding<Int> {
        Binding(get: {
            Self.displayedIconCount(stored: icons, tabsOnSide: tabStyle == "vertical")
        }, set: { value in
            icons = value
        })
    }

    var body: some View {
        Form {
            Section("Layout") {
                Picker("Tab style", selection: style) {
                    Text("Above").tag("above")
                    Text("Left side").tag("left")
                    Text("Right side").tag("right")
                }
                if tabStyle == "horizontal" {
                    Toggle("Fill available space", isOn: $fill)
                }
                Picker("Show tab icons", selection: iconSelection) {
                    Text("None").tag(0)
                    ForEach(1...(tabStyle == "vertical" ? 3 : 5), id: \.self) {
                        Text("\($0)").tag($0)
                    }
                }
                Toggle("Use Command-1 through Command-9 to select tabs", isOn: $useCommandDigitsForTabs)
            }
            Section("Look") {
                Picker("Use color for tab icons", selection: $color) {
                    Text("Always").tag("always")
                    Text("Active tabs").tag("activeTabs")
                    Text("Active panes").tag("activePanes")
                    Text("Never").tag("never")
                }
                Toggle("Prefer generated tab titles", isOn: $generatedTitles)
                Picker("Animation style", selection: $animation) {
                    Text("Natural").tag("natural")
                    Text("Snappy").tag("snappy")
                    Text("Off").tag("off")
                }
            }
            if tabStyle == "vertical" {
                Section("Sidebar") {
                    Picker("Sidebar text size", selection: $sidebarTextSize) {
                        Text("System sidebar size").tag(0.0)
                        Text("Small (11 pt)").tag(11.0)
                        Text("Medium (13 pt)").tag(13.0)
                        Text("Large (15 pt)").tag(15.0)
                    }
                    Toggle("Preserve width when resizing sidebar", isOn: $preserveWidth)
                    Picker("Use a gesture to toggle the sidebar", selection: $sidebarGesture) {
                        Text("Swipe").tag("swipe")
                        Text("Option-swipe").tag("optionSwipe")
                        Text("Off").tag("off")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Tabs")
    }
}

/// Edits notification, Dock and per-state program activity preferences.
struct ProgramActivitySettingsView: View {
    @AppStorage(ProgramActivityPreferences.showTabsKey) private var tabs = true
    @AppStorage(ProgramActivityPreferences.notificationsKey) private var notifications = true
    @AppStorage(ProgramActivityPreferences.dockKey) private var dock = true
    @AppStorage(ProgramActivityPreferences.soundsKey) private var sounds = false
    @AppStorage("programActivityWorking") private var working = true
    @AppStorage("programActivityBlocked") private var blocked = true
    @AppStorage("programActivityError") private var error = true
    @AppStorage("programActivityDone") private var done = true
    @AppStorage(ProgramActivityPreferences.bounceKey) private var bounce = true
    @AppStorage(ProgramActivityPreferences.announceKey) private var announce = true
    @AppStorage(ProgramActivityPreferences.colorKey) private var statusColor = true
    @AppStorage(ProgramActivityPreferences.tickerSpeedKey) private var speed = 33.4
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
        }
        .formStyle(.grouped)
        .navigationTitle("Notifications")
    }
}
