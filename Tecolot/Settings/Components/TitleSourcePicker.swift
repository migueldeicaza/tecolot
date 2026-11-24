import SwiftUI

/// Selects the source of tab and window titles. The Tabs page and the
/// profile Window page show the same global value.
struct TitleSourcePicker: View {
    @AppStorage(TabStripPreferences.preferGeneratedTitlesKey) private var preferGeneratedTitles = TabStripPreferences.preferGeneratedTitlesDefault
    let setting: SettingID

    private var source: Binding<TabStripPreferences.TitleSource> {
        Binding(get: {
            TabStripPreferences.TitleSource(preferGeneratedTitles: preferGeneratedTitles)
        }, set: { value in
            preferGeneratedTitles = value.prefersGeneratedTitles
        })
    }

    static let help = "Show the running program and folder, or the items that you select in the Title section of the profile Window page. "
        + "The Active title item is the title that the program sets with an escape sequence (OSC 0 or OSC 2). "
        + "This setting applies to tabs and windows in all profiles."

    var body: some View {
        Picker(setting.title, selection: source) {
            ForEach(TabStripPreferences.TitleSource.allCases, id: \.self) {
                Text($0.title).tag($0)
            }
        }
        .help(Self.help)
        .settingsAnchor(setting)
    }
}
