import SwiftUI
import SwiftTerm

extension ProfileSettingsPage {
    @ViewBuilder
    var keyboardAndMouseSettings: some View {
        Form {
            Section {
                Toggle("Use Option as Meta key", isOn: binding(\.optionAsMetaKey))
                Toggle("Delete sends Control-H", isOn: binding(\.backspaceSendsControlH))
                Toggle("Hide pointer while typing", isOn: binding(\.hidePointerWhileTyping))
            }
            Section("Key mappings"){
                TerminalKeyBindingsEditor(profile: profile, update: updateIgnoringResult)
            }
        }
    }

}

#Preview("Keyboard and Mouse Settings") {
    ProfileSettingsPagePreview(section: .keyboardAndMouse)
        .environmentObject(SettingsPreviewData.themes)
        .frame(width: 560, height: 430)
}
