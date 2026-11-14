import SwiftUI
import SwiftTerm

extension ProfileSettingsPage {
    @ViewBuilder
    var terminalSettings: some View {
        Form {
            Section {
                LabeledContent("Declare terminal as") {
                    TerminalNameComboBox(text: binding(\.termName))
                }
                if profile.termName == "xterm-ghostty" {
                    TextField("TERM_PROGRAM", text: binding(\.termProgram))
                    TextField("TERM_VERSION", text: binding(\.termVersion))
                }
                Toggle("Enable OSC 8 links", isOn: binding(\.linkOsc8))
                    .help("Allow terminal programs to set links on text. Turn this off to ignore these links. Tecolot can still detect web addresses in text.")
                Toggle(isOn: binding(\.screenChecksumReports)) {
                    Text("Allow programs to read screen contents")
                    Text("DECRQCRA (Request Checksum of Rectangular Area)")
                }
                .help("Answer screen checksum requests. Test tools such as vttest and esctest use them. A program can also use them to read text on the screen, including text from other programs. Keep this off unless you need it.")
                Toggle("Limit scrollback", isOn: Binding(
                    get: {
                        profile.scrollbackLines != nil
                    },
                    set: { limited in
                        update {
                            $0.scrollbackLines = limited ? 10_000 : nil
                        }
                    }
                ))
                if profile.scrollbackLines != nil {
                    TextField("Scrollback lines", value: Binding(
                        get: {
                            profile.scrollbackLines ?? 10_000
                        },
                        set: { newValue in
                            update {
                                $0.scrollbackLines = max(0, newValue)
                            }
                        }
                    ), format: .number)
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
