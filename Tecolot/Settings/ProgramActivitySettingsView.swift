import SwiftUI

/// Edits live preferences for tab styles and status animations.
struct TabInterfaceSettingsView: View {
    @AppStorage("tabStyle") private var tabStyle = "horizontal"
    @AppStorage("sidebarPosition") private var sidebarPosition = "left"
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
    @AppStorage(TabStripPreferences.fillKey) private var fill = false
    @AppStorage(TabStripPreferences.iconCountKey) private var icons = 3
    var body: some View {
        NavigationStack {
            Form {
                Section("Tabs") {
                    Picker("Tab style", selection: style) {
                        Text("Above").tag("above")
                        Text("Left Side").tag("left")
                        Text("Right Side").tag("right")
                    }
                    if tabStyle == "horizontal" {
                        Toggle("Fill available space", isOn: $fill)
                    }
                    Picker("Show tab icons", selection: $icons) {
                        Text("None").tag(0)
                        ForEach(1...(tabStyle == "vertical" ? 3 : 5), id: \.self) {
                            Text("\($0)").tag($0)
                        }
                    }
                    NavigationLink("Additional Tab Options") {
                        AdditionalTabOptionsView()
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Interface")
        }
    }
}

/// The less frequently changed tab preferences, one level below Interface.
struct AdditionalTabOptionsView: View {
    @AppStorage("tabStyle") private var tabStyle = "horizontal"
    @AppStorage("sidebarTextSize") private var sidebarTextSize = 0.0
    @AppStorage("preserveWidthWhenResizingSidebar") private var preserveWidth = true
    @AppStorage("sidebarGesture") private var sidebarGesture = "swipe"
    @AppStorage(TabStripPreferences.colorModeKey) private var color = "always"
    @AppStorage(TabStripPreferences.animationStyleKey) private var animation = "natural"
    @AppStorage(TabStripPreferences.preferGeneratedTitlesKey) private var generatedTitles = true
    @AppStorage(ProgramActivityPreferences.bounceKey) private var bounce = true
    @AppStorage(ProgramActivityPreferences.announceKey) private var announce = true
    @AppStorage(ProgramActivityPreferences.colorKey) private var statusColor = true
    @AppStorage(ProgramActivityPreferences.tickerSpeedKey) private var speed = 33.4
    var body: some View {
        Form {
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
                        Text("Option-Swipe").tag("optionSwipe")
                        Text("Off").tag("off")
                    }
                }
            }
            Section {
                Picker("Use color for tab icons", selection: $color) {
                    Text("Always").tag("always")
                    Text("Active tabs").tag("activeTabs")
                    Text("Active panes").tag("activePanes")
                    Text("Never").tag("never")
                }
                Toggle("Prefer generated tab titles", isOn: $generatedTitles)
                Toggle("Bounce tab icons", isOn: $bounce)
                Toggle("Announce messages in tabs", isOn: $announce)
                Slider(value: $speed, in: 10...100) {
                    Text("Message scroll speed")
                }
                .disabled(!announce)
                Toggle("Use color for status badges", isOn: $statusColor)
                Picker("Animation style", selection: $animation) {
                    Text("Natural").tag("natural")
                    Text("Snappy").tag("snappy")
                    Text("Off").tag("off")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Additional Tab Options")
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
    var body: some View {
        Form {
            Section("Program Activity") {
                Toggle("Show activity in tabs", isOn: $tabs)
                Toggle("Show system notifications", isOn: $notifications)
                Text(
                    "System notifications appear while Tecolot is inactive. Clicking one reveals its group, tab and pane."
                )
                .font(.caption).foregroundStyle(.secondary)
                Toggle("Badge Dock icon", isOn: $dock)
                Toggle("Play sounds", isOn: $sounds)
            }
            Section("States") {
                Toggle("Working", isOn: $working)
                Toggle("Blocked", isOn: $blocked)
                Toggle("Error", isOn: $error)
                Toggle("Done", isOn: $done)
                Text("Each state controls its tab indicator, system notification, Dock badge and sound.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Notifications")
    }
}
