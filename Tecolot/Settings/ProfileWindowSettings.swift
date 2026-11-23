import SwiftUI
import SwiftTerm

extension ProfileSettingsPage {
    @ViewBuilder
    var windowSettings: some View {
        Form {
            Section {
                CommittedIntegerField(SettingID.windowColumns.title, value: profile.columns) { columns in
                    update { $0.columns = columns }
                }
                .settingsAnchor(.windowColumns)
                CommittedIntegerField(SettingID.windowRows.title, value: profile.rows) { rows in
                    update { $0.rows = rows }
                }
                .settingsAnchor(.windowRows)
            }
            Section(SettingID.windowSectionTitle.title) {
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
            }
        }
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
        .frame(width: 560, height: 430)
}
