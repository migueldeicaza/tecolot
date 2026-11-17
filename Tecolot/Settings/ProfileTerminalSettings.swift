import SwiftUI
import SwiftTerm

extension ProfileSettingsPage {
    @ViewBuilder
    var terminalSettings: some View {
        Form {
            Section {
                LabeledContent(SettingID.terminalDeclareAs.title) {
                    TerminalNameComboBox(text: binding(\.termName))
                }
                .settingsAnchor(.terminalDeclareAs)
                if profile.termName == "xterm-ghostty" {
                    TextField(SettingID.terminalTermProgram.title, text: binding(\.termProgram))
                        .settingsAnchor(.terminalTermProgram)
                    TextField(SettingID.terminalTermVersion.title, text: binding(\.termVersion))
                        .settingsAnchor(.terminalTermVersion)
                }
                Toggle(SettingID.terminalOSC8Links.title, isOn: binding(\.linkOsc8))
                    .help("Allow terminal programs to set links on text. Turn this off to ignore these links. Tecolot can still detect web addresses in text.")
                    .settingsAnchor(.terminalOSC8Links)
                Toggle(isOn: binding(\.screenChecksumReports)) {
                    Text(SettingID.terminalScreenChecksum.title)
                    Text("DECRQCRA (Request Checksum of Rectangular Area)")
                }
                .help("Answer screen checksum requests. Test tools such as vttest and esctest use them. A program can also use them to read text on the screen, including text from other programs. Keep this off unless you need it.")
                .settingsAnchor(.terminalScreenChecksum)
                Toggle(SettingID.terminalLimitScrollback.title, isOn: Binding(
                    get: {
                        profile.scrollbackLines != nil
                    },
                    set: { limited in
                        update {
                            $0.scrollbackLines = limited ? 10_000 : nil
                        }
                    }
                ))
                .settingsAnchor(.terminalLimitScrollback)
                if profile.scrollbackLines != nil {
                    TextField(SettingID.terminalScrollbackLines.title, value: Binding(
                        get: {
                            profile.scrollbackLines ?? 10_000
                        },
                        set: { newValue in
                            update {
                                $0.scrollbackLines = max(0, newValue)
                            }
                        }
                    ), format: .number)
                    .settingsAnchor(.terminalScrollbackLines)
                }
            }
        }
    }
}

#Preview("Terminal Settings") {
    ProfileSettingsPagePreview(section: .terminal)
        .environmentObject(SettingsPreviewData.themes)
        .frame(width: 680, height: 480)
}
