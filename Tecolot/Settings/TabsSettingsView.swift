import SwiftUI
import SwiftTerm

/// Edits live preferences for tab layout, appearance and the sidebar.
struct TabsSettingsView: View {
    @AppStorage(ProgramActivityPreferences.tabStyleKey) private var tabStyle = ProgramActivityPreferences.tabStyleDefault
    @AppStorage(SidebarPreferences.positionKey) private var sidebarPosition = SidebarPreferences.positionDefault
    @AppStorage(TabStripPreferences.fillKey) private var fill = TabStripPreferences.fillDefault
    @AppStorage(TabStripPreferences.iconCountKey) private var icons = TabStripPreferences.iconCountDefault
    @AppStorage(TabStripPreferences.trackRunningProgramsKey) private var trackRunningPrograms = TabStripPreferences.trackRunningProgramsDefault
    @AppStorage(TabSelectionCommands.useCommandDigitsForTabsKey) private var useCommandDigitsForTabs = TabSelectionCommands.useCommandDigitsForTabsDefault
    @AppStorage(SidebarPreferences.textSizeKey) private var sidebarTextSize = SidebarPreferences.textSizeDefault
    @AppStorage(SidebarPreferences.preserveWidthKey) private var preserveWidth = SidebarPreferences.preserveWidthDefault
    @AppStorage(SidebarPreferences.gestureKey) private var sidebarGesture = SidebarPreferences.gestureDefault
    @AppStorage(TabStripPreferences.colorModeKey) private var color = TabStripPreferences.colorModeDefault.rawValue
    @AppStorage(TabStripPreferences.animationStyleKey) private var animation = TabStripPreferences.animationStyleDefault

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
            Section(SettingID.tabsSectionLayout.title) {
                Picker(SettingID.tabsStyle.title, selection: style) {
                    Text("Above").tag("above")
                    Text("Left side").tag("left")
                    Text("Right side").tag("right")
                }
                .settingsAnchor(.tabsStyle)
                if tabStyle == "horizontal" {
                    Toggle(SettingID.tabsFillAvailableSpace.title, isOn: $fill)
                        .settingsAnchor(.tabsFillAvailableSpace)
                }
                Picker(SettingID.tabsShowIcons.title, selection: iconSelection) {
                    Text("None").tag(0)
                    ForEach(1...(tabStyle == "vertical" ? 3 : 5), id: \.self) {
                        Text("\($0)").tag($0)
                    }
                }
                .disabled(!trackRunningPrograms)
                .settingsAnchor(.tabsShowIcons)
                if !trackRunningPrograms {
                    Text("Turn on Track running programs in General to show tab icons.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle(SettingID.tabsCommandDigits.title, isOn: $useCommandDigitsForTabs)
                    .settingsAnchor(.tabsCommandDigits)
            }
            Section(SettingID.tabsSectionLook.title) {
                Picker(SettingID.tabsIconColor.title, selection: $color) {
                    Text("Always").tag("always")
                    Text("Active tabs").tag("activeTabs")
                    Text("Active panes").tag("activePanes")
                    Text("Never").tag("never")
                }
                .settingsAnchor(.tabsIconColor)
                TitleSourcePicker(setting: .tabsGeneratedTitles)
                Picker(SettingID.tabsAnimationStyle.title, selection: $animation) {
                    Text("Natural").tag("natural")
                    Text("Snappy").tag("snappy")
                    Text("Off").tag("off")
                }
                .settingsAnchor(.tabsAnimationStyle)
            }
            if tabStyle == "vertical" {
                Section(SettingID.tabsSectionSidebar.title) {
                    Picker(SettingID.tabsSidebarTextSize.title, selection: $sidebarTextSize) {
                        Text("System sidebar size").tag(0.0)
                        Text("Small (11 pt)").tag(11.0)
                        Text("Medium (13 pt)").tag(13.0)
                        Text("Large (15 pt)").tag(15.0)
                    }
                    .settingsAnchor(.tabsSidebarTextSize)
                    Toggle(SettingID.tabsSidebarPreserveWidth.title, isOn: $preserveWidth)
                        .settingsAnchor(.tabsSidebarPreserveWidth)
                    Picker(SettingID.tabsSidebarGesture.title, selection: $sidebarGesture) {
                        Text("Swipe").tag("swipe")
                        Text("Option-swipe").tag("optionSwipe")
                        Text("Off").tag("off")
                    }
                    .settingsAnchor(.tabsSidebarGesture)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Tabs")
    }
}

