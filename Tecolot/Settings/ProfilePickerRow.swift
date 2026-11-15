import SwiftUI

struct ProfilePickerRow: View {
    let profiles: [TerminalProfile]
    let defaultProfileID: TerminalProfile.ID
    @Binding var selection: TerminalProfile.ID?
    let createProfile: () -> Void
    let duplicateProfile: () -> Void
    let makeProfileDefault: () -> Void
    let manageProfiles: () -> Void

    private var activeProfile: TerminalProfile? {
        selection.flatMap { id in
            profiles.first {
                $0.id == id
            }
        }
    }

    var body: some View {
        Menu {
            ForEach(profiles) { profile in
                // A menu draws a toggle as a checkmark item, and a second
                // Text as secondary text. It ignores stacks and spacers.
                Toggle(isOn: Binding(get: {
                    profile.id == selection
                }, set: { _ in
                    selection = profile.id
                })) {
                    Text(profile.name)
                    if profile.id == defaultProfileID {
                        Text("Default")
                    }
                }
            }
            Divider()
            Button("New Profile", action: createProfile)
            if let profile = activeProfile {
                Button("Duplicate “\(profile.name)”", action: duplicateProfile)
                if profile.id != defaultProfileID {
                    Button("Make “\(profile.name)” the Default", action: makeProfileDefault)
                }
            }
            Divider()
            Button("Manage Profiles…", action: manageProfiles)
        } label: {
            // A plain button style draws this label as written. The menu
            // styles rebuild it as an image followed by a title.
            HStack(spacing: 6) {
                Text(activeProfile?.name ?? "No profile")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(profiles.isEmpty)
        .accessibilityLabel("Profile, \(activeProfile?.name ?? "No profile")")
        .accessibilityHint("Chooses which profile the pages below edit.")
    }
}
