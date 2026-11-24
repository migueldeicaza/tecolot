import SwiftUI
import SwiftTerm

extension ProfileSettingsPage {
    @ViewBuilder
    var windowSettings: some View {
        Form {
            Section {
                TextField(SettingID.windowColumns.title, value: binding(\.columns), format: .number)
                    .settingsAnchor(.windowColumns)
                TextField(SettingID.windowRows.title, value: binding(\.rows), format: .number)
                    .settingsAnchor(.windowRows)
            }
            Section {
                TitleSourcePicker(setting: .windowTitleSource)
                TextField(SettingID.windowCustomTitle.title, text: Binding(
                    get: {
                        profile.titleOverride ?? ""
                    },
                    set: { newValue in
                        update {
                            $0.titleOverride = newValue.isEmpty ? nil : newValue
                        }
                    }
                ), prompt: Text("Default"))
                .settingsAnchor(.windowCustomTitle)
                ForEach(TerminalTitleComponent.allCases, id: \.self) { component in
                    Toggle(titleComponentSetting(component).title, isOn: Binding(
                        get: {
                            profile.titleComponents.contains(component)
                        },
                        set: { isEnabled in
                            update {
                                if isEnabled {
                                    $0.titleComponents.insert(component)
                                } else {
                                    $0.titleComponents.remove(component)
                                }
                            }
                        }
                    ))
                    .settingsAnchor(titleComponentSetting(component))
                }
            } header: {
                Text(SettingID.windowSectionTitle.title)
            } footer: {
                Text(Self.titleFootnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static var titleFootnote: String {
        let source = TabStripPreferences.TitleSource.self
        return "“\(source.settingTitle)” applies to all profiles. Pane headers always show the items above. "
            + "Tabs and windows show them when “\(source.settingTitle)” is set to “\(source.profile.title)”."
    }

    private func titleComponentSetting(_ component: TerminalTitleComponent) -> SettingID {
        switch component {
        case .activeTitle:
            return .windowTitleActiveTitle
        case .workingDirectory:
            return .windowTitleWorkingDirectory
        case .fullPath:
            return .windowTitleFullPath
        case .profileName:
            return .windowTitleProfileName
        case .dimensions:
            return .windowTitleDimensions
        }
    }
}

#Preview("Window Settings") {
    ProfileSettingsPagePreview(section: .window)
        .environmentObject(SettingsPreviewData.themes)
        .defaultAppStorage(SettingsPreviewData.defaults)
        .frame(width: 560, height: 430)
}
