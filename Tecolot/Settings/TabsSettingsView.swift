import SwiftUI
import SwiftTerm

/// Edits live preferences for tab layout, appearance and the sidebar.
struct TabsSettingsView: View {
    @AppStorage(ProgramActivityPreferences.tabStyleKey) private var tabStyle = ProgramActivityPreferences.tabStyleDefault
    @AppStorage(SidebarPreferences.positionKey) private var sidebarPosition = SidebarPreferences.positionDefault
    @AppStorage(TabStripPreferences.fillKey) private var fill = TabStripPreferences.fillDefault
    @AppStorage(TabStripPreferences.iconCountKey) private var icons = TabStripPreferences.iconCountDefault
    @AppStorage(TabSelectionCommands.useCommandDigitsForTabsKey) private var useCommandDigitsForTabs = TabSelectionCommands.useCommandDigitsForTabsDefault
    @AppStorage(SidebarPreferences.textSizeKey) private var sidebarTextSize = SidebarPreferences.textSizeDefault
    @AppStorage(SidebarPreferences.preserveWidthKey) private var preserveWidth = SidebarPreferences.preserveWidthDefault
    @AppStorage(SidebarPreferences.gestureKey) private var sidebarGesture = SidebarPreferences.gestureDefault
    @AppStorage(TabStripPreferences.colorModeKey) private var color = TabStripPreferences.colorModeDefault.rawValue
    @AppStorage(TabStripPreferences.animationStyleKey) private var animation = TabStripPreferences.animationStyleDefault
    @AppStorage(TabStripPreferences.preferGeneratedTitlesKey) private var generatedTitles = TabStripPreferences.preferGeneratedTitlesDefault

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

