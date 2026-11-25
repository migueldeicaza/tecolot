import SwiftUI
import SwiftTerm

extension ProfileSettingsPage {
    var appearanceSettings: some View {
        Form {
            Section {
                ProfileTextSettings(profile: profile, update: updateIgnoringResult)
                    .padding(.horizontal)
                    .frame(maxHeight: 230)
            }
            ThemeModeSection(isDark: false, profile: profile, themes: themes, update: update)
            ThemeModeSection(isDark: true, profile: profile, themes: themes, update: update)
            Section {
                Toggle(
                    SettingID.appearanceWindowChrome.title,
                    isOn: binding(\.useThemeColorsForWindowChrome)
                )
                .settingsAnchor(.appearanceWindowChrome)
            } header: {
                Text("Window chrome")
            } footer: {
                Text("Applies the theme to the title bar, tabs, and toolbar controls. Turn this off to follow the system appearance.")
            }
        }
    }

}

#Preview("Appearance Settings") {
    ProfileSettingsPagePreview(section: .appearance)
        .environmentObject(SettingsPreviewData.profiles)
        .environmentObject(SettingsPreviewData.themes)
        .environmentObject(SettingsPreviewData.themeIndex)
        .environmentObject(SystemAppearance(isDark: false))
        .frame(width: 720, height: 720)
}
