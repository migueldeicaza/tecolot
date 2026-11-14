import SwiftUI
import SwiftTerm

extension ProfileSettingsPage {
    @ViewBuilder
    var windowSettings: some View {
        Form {
            Section {
                TextField("Columns", value: binding(\.columns), format: .number)
                TextField("Rows", value: binding(\.rows), format: .number)
            }
            Section("Title") {
                TextField("Custom title", text: Binding(
                    get: {
                        profile.titleOverride ?? ""
                    },
                    set: { newValue in
                        update {
                            $0.titleOverride = newValue.isEmpty ? nil : newValue
                        }
                    }
                ), prompt: Text("Default"))
                ForEach(TerminalTitleComponent.allCases, id: \.self) { component in
                    Toggle(titleComponentLabel(component), isOn: Binding(
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
                }
            }
        }
    }


    private func titleComponentLabel(_ component: TerminalTitleComponent) -> String {
        switch component {
        case .activeTitle:
            return "Active title"
        case .workingDirectory:
            return "Working directory"
        case .fullPath:
            return "Full path"
        case .profileName:
            return "Profile name"
        case .dimensions:
            return "Dimensions"
        }
    }
}

#Preview("Window Settings") {
    ProfileSettingsPagePreview(section: .window)
        .environmentObject(SettingsPreviewData.themes)
        .frame(width: 560, height: 430)
}
