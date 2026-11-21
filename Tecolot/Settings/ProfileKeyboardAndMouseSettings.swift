import SwiftUI
import SwiftTerm

/// The rows of the "Option key as Meta" picker. A profile keeps the choice in
/// two fields: `optionAsMetaKey` and `optionMetaSide`. The Terminal menu's
/// "Use Option as Meta Key" changes only the pane's value, not the profile;
/// the pane keeps the side from the profile.
enum OptionMetaKeys: CaseIterable, CustomStringConvertible {
    case both, left, right, neither

    init(profile: TerminalProfile) {
        guard profile.optionAsMetaKey else {
            self = .neither
            return
        }
        switch profile.optionMetaSide {
        case .both: self = .both
        case .left: self = .left
        case .right: self = .right
        }
    }

    /// "Neither key" keeps the side, so that the Terminal menu's "Use Option
    /// as Meta Key" gives back the keys that the profile had.
    func apply(to profile: inout TerminalProfile) {
        switch self {
        case .both:
            profile.optionAsMetaKey = true
            profile.optionMetaSide = .both
        case .left:
            profile.optionAsMetaKey = true
            profile.optionMetaSide = .left
        case .right:
            profile.optionAsMetaKey = true
            profile.optionMetaSide = .right
        case .neither:
            profile.optionAsMetaKey = false
        }
    }

    var description: String {
        switch self {
        case .both: return "Both keys"
        case .left: return "Left key only"
        case .right: return "Right key only"
        case .neither: return "Neither key"
        }
    }
}

extension ProfileSettingsPage {
    /// Writes only the two Option fields onto the stored profile, as
    /// `binding(_:)` does for one field.
    var optionMetaKeysBinding: Binding<OptionMetaKeys> {
        Binding(
            get: { OptionMetaKeys(profile: profile) },
            set: { keys in
                updateIgnoringResult { keys.apply(to: &$0) }
            }
        )
    }

    @ViewBuilder
    var keyboardAndMouseSettings: some View {
        Form {
            Section {
                Picker(SettingID.keyboardOptionAsMeta.title, selection: optionMetaKeysBinding) {
                    ForEach(OptionMetaKeys.allCases, id: \.self) { keys in
                        Text(keys.description).tag(keys)
                    }
                }
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
