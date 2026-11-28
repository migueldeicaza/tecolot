import SwiftUI
import SwiftTerm

extension ProfileSettingsPage {
    @ViewBuilder
    var shellSettings: some View {
        Form {
            Section {
                Picker(SettingID.shellRun.title, selection: shellKindBinding) {
                    Text("Default login shell").tag(ShellKind.loginShell)
                    Text("Command").tag(ShellKind.command)
                }
                .settingsAnchor(.shellRun)
                if case .command(let commandLine, let runInShell) = profile.shell {
                    TextField(SettingID.shellCommand.title, text: Binding(
                        get: {
                            commandLine
                        },
                        set: { newValue in
                            update {
                                $0.shell = .command(newValue, runInShell: runInShell)
                            }
                        }
                    ))
                    .settingsAnchor(.shellCommand)
                    Toggle(SettingID.shellRunInsideShell.title, isOn: Binding(
                        get: {
                            runInShell
                        },
                        set: { newValue in
                            update {
                                $0.shell = .command(commandLine, runInShell: newValue)
                            }
                        }
                    ))
                    .settingsAnchor(.shellRunInsideShell)
                }
                Picker(SettingID.shellWhenExits.title, selection: binding(\.whenShellExits)) {
                    ForEach(ShellExitBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.description).tag(behavior)
                    }
                }
                .settingsAnchor(.shellWhenExits)
                Picker(SettingID.shellAskBeforeClosing.title, selection: binding(\.askBeforeClosing)) {
                    ForEach(AskBeforeClosing.allCases, id: \.self) { policy in
                        Text(policy.description).tag(policy)
                    }
                }
                .settingsAnchor(.shellAskBeforeClosing)
            }
            Section {
                Picker(SettingID.shellSession.title, selection: binding(\.sessionPersistence)) {
                    ForEach(SessionPersistence.allCases, id: \.self) { persistence in
                        Text(persistence.description).tag(persistence)
                    }
                }
                .settingsAnchor(.shellSession)
            } footer: {
                Text("A persistent session keeps the shell running when you close its pane or quit Tecolot. " +
                    "Use File > Sessions > Attach to Session to show it again. Applies to new tabs and windows.")
            }
            Section {
                Text("Tecolot inherits the app environment, then applies these changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .settingsAnchor(.shellEnvironment)
                ForEach(profile.environmentVariables) { variable in
                    EnvironmentVariableRow(variable: variable) { replacement in
                        update { profile in
                            guard
                                let index = profile.environmentVariables.firstIndex(where: {
                                    $0.id == replacement.id
                                }) else {
                                return
                            }
                            profile.environmentVariables[index] = replacement
                        }
                    } remove: {
                        update { profile in
                            profile.environmentVariables.removeAll {
                                $0.id == variable.id
                            }
                        }
                    }
                    .settingsAnchor(.shellEnvironment)
                }
                Button("Add Environment Variable") {
                    update {
                        $0.environmentVariables.append(TerminalEnvironmentVariable(name: "", value: ""))
                    }
                }
                .settingsAnchor(.shellEnvironment)
            } header: {
                Text(SettingID.shellEnvironment.title)
            } footer: {
                Text("Unset removes an inherited value. An empty value is passed as an empty string. Later entries with the same name win.")
            }
        }
    }


    private enum ShellKind: Hashable {
        case loginShell, command
    }

    private var shellKindBinding: Binding<ShellKind> {
        Binding(
            get: {
                if case .command = profile.shell {
                    return .command
                }
                return .loginShell
            },
            set: { kind in
                update {
                    switch kind {
                    case .loginShell:
                        $0.shell = .loginShell
                    case .command:
                        $0.shell = .command("", runInShell: true)
                    }
                }
            }
        )
    }

}

#Preview("Session Settings") {
    ProfileSettingsPagePreview(section: .shell)
        .environmentObject(SettingsPreviewData.themes)
        .frame(width: 560, height: 430)
}
