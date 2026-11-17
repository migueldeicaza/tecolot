import SwiftUI
import AppKit
import SwiftTerm

/// Font, cursor, and opacity fields for the Text settings page.
struct ProfileTextSettings: View {
    let profile: TerminalProfile
    let update: ((inout TerminalProfile) -> Void) -> Void

    var body: some View {
        ProfileTextSettingsFields(profile: profile, update: update)
    }
}

struct ProfileTextSettingsFields: View {
    let profile: TerminalProfile
    let update: ((inout TerminalProfile) -> Void) -> Void
    @State private var fontPanelManager = FontPanelManager()
    @State private var backgroundOpacityPreview: Double
    @State private var isEditingBackgroundOpacity = false

    init(
        profile: TerminalProfile,
        update: @escaping ((inout TerminalProfile) -> Void) -> Void
    ) {
        self.profile = profile
        self.update = update
        _backgroundOpacityPreview = State(initialValue: profile.backgroundOpacity)
    }

    var body: some View {
        HStack {
            Button(action: showFontPanel) {
                LabeledContent("Font") {
                    Text(fontDescription)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)

            if profile.fontFamily != nil {
                Button(action: resetFont) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Use system monospaced font")
            }
        }
        .onAppear(perform: configureFontPanel)
        .onChange(of: profile) {
            configureFontPanel()
        }
        Picker("Cursor", selection: Binding(
            get: {
                profile.cursorStyle
            },
            set: { newValue in
                update {
                    $0.cursorStyle = newValue
                }
            }
        )) {
            ForEach(CursorStyle.allCases, id: \.tagName) { style in
                Text(style.displayName).tag(style)
            }
        }
        Toggle("Use bright colors for bold text", isOn: Binding(
            get: {
                profile.useBrightColorsForBold
            },
            set: { newValue in
                update {
                    $0.useBrightColorsForBold = newValue
                }
            }
        ))
        LabeledContent("Background opacity") {
            Slider(
                value: $backgroundOpacityPreview,
                in: 0.3...1.0,
                onEditingChanged: backgroundOpacityEditingChanged
            )
            .frame(maxWidth: 200)
        }
        .onChange(of: backgroundOpacityPreview) { _, newValue in
            TerminalSessionRegistry.shared.previewBackgroundOpacity(
                newValue,
                forProfileID: profile.id
            )
        }
        .onChange(of: profile.backgroundOpacity) { _, newValue in
            if !isEditingBackgroundOpacity {
                backgroundOpacityPreview = newValue
            }
        }
        .onChange(of: profile.id) { oldID, _ in
            TerminalSessionRegistry.shared.previewBackgroundOpacity(nil, forProfileID: oldID)
            backgroundOpacityPreview = profile.backgroundOpacity
        }
        .onDisappear {
            TerminalSessionRegistry.shared.previewBackgroundOpacity(nil, forProfileID: profile.id)
        }
    }

    private func backgroundOpacityEditingChanged(_ isEditing: Bool) {
        isEditingBackgroundOpacity = isEditing
        guard !isEditing else {
            return
        }
        update {
            $0.backgroundOpacity = backgroundOpacityPreview
        }
    }

    private var fontDescription: String {
        let fontName = profile.fontFamily.flatMap {
            NSFont(name: $0, size: CGFloat(profile.fontSize))?.displayName
        } ?? profile.fontFamily ?? "System monospaced"
        return "\(fontName) - \(Int(profile.fontSize)) pt"
    }

    private func showFontPanel() {
        configureFontPanel()
        fontPanelManager.showFontPanel(
            fontName: profile.fontFamily,
            size: CGFloat(profile.fontSize)
        )
    }

    private func configureFontPanel() {
        fontPanelManager.onSelect = { font in
            guard font.pointSize.isFinite, font.pointSize > 0 else {
                return
            }
            update {
                $0.fontFamily = font.fontName
                $0.fontSize = Double(font.pointSize)
            }
        }
    }

    private func resetFont() {
        update {
            $0.fontFamily = nil
        }
    }
}

#Preview("Text Controls") {
    Form {
        ProfileTextSettings(profile: SettingsPreviewData.profile, update: { _ in })
    }
    .formStyle(.grouped)
    .frame(width: 560, height: 250)

}

#Preview("Text Fields") {
    Form {
        ProfileTextSettingsFields(profile: SettingsPreviewData.profile, update: { _ in })
    }
    .formStyle(.grouped)
    .frame(width: 560, height: 250)
}
