import SwiftUI
import SwiftTerm

extension ProfileSettingsPage {
    @ViewBuilder
    var keyboardAndMouseSettings: some View {
        Form {
            Section {
                Toggle(SettingID.keyboardOptionAsMeta.title, isOn: binding(\.optionAsMetaKey))
                    .settingsAnchor(.keyboardOptionAsMeta)
                Toggle(SettingID.keyboardDeleteSendsControlH.title, isOn: binding(\.backspaceSendsControlH))
                    .settingsAnchor(.keyboardDeleteSendsControlH)
                Toggle(SettingID.keyboardHidePointer.title, isOn: binding(\.hidePointerWhileTyping))
                    .settingsAnchor(.keyboardHidePointer)
            }
            Section(SettingID.keyboardKeyMappings.title) {
                TerminalKeyBindingsEditor(profile: profile, update: updateIgnoringResult)
                    .settingsAnchor(.keyboardKeyMappings)
            }
        }
    }

}

#Preview("Keyboard and Mouse Settings") {
    ProfileSettingsPagePreview(section: .keyboardAndMouse)
        .environmentObject(SettingsPreviewData.themes)
        .frame(width: 560, height: 430)
}
