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
    @State private var lineSpacingPreview: Double
    @State private var isEditingLineSpacing = false
    @State private var backgroundOpacityPreview: Double
    @State private var isEditingBackgroundOpacity = false

    init(
        profile: TerminalProfile,
        update: @escaping ((inout TerminalProfile) -> Void) -> Void
    ) {
        self.profile = profile
        self.update = update
        _lineSpacingPreview = State(initialValue: profile.lineSpacing)
        _backgroundOpacityPreview = State(initialValue: profile.backgroundOpacity)
    }

    var body: some View {
        HStack {
            Button(action: showFontPanel) {
                LabeledContent(SettingID.appearanceFont.title) {
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
        .settingsAnchor(.appearanceFont)
        .onAppear(perform: configureFontPanel)
        .onChange(of: profile) {
            configureFontPanel()
        }
        LabeledContent(SettingID.appearanceLineSpacing.title) {
            HStack(spacing: 8) {
                Slider(
                    value: $lineSpacingPreview,
                    in: TerminalProfile.lineSpacingRange,
                    step: 0.05,
                    onEditingChanged: lineSpacingEditingChanged
                )
                .frame(maxWidth: 160)
                Text(String(format: "%.2f×", lineSpacingPreview))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 42, alignment: .trailing)
            }
        }
        .settingsAnchor(.appearanceLineSpacing)
        .onChange(of: lineSpacingPreview) { _, newValue in
            if !isEditingLineSpacing, newValue != profile.lineSpacing {
                commitLineSpacing(newValue)
            }
        }
        .onChange(of: profile.lineSpacing) { _, newValue in
            if !isEditingLineSpacing {
                lineSpacingPreview = newValue
            }
        }
        Toggle(SettingID.appearanceFontSmoothing.title, isOn: Binding(
            get: {
                profile.fontSmoothing
            },
            set: { newValue in
                update {
                    $0.fontSmoothing = newValue
                }
            }
        ))
        .settingsAnchor(.appearanceFontSmoothing)
        Picker(SettingID.appearanceCursor.title, selection: Binding(
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
        .settingsAnchor(.appearanceCursor)
        Toggle(SettingID.appearanceBrightBold.title, isOn: Binding(
            get: {
                profile.useBrightColorsForBold
            },
            set: { newValue in
                update {
                    $0.useBrightColorsForBold = newValue
                }
            }
        ))
        .settingsAnchor(.appearanceBrightBold)
        LabeledContent(SettingID.appearanceBackgroundOpacity.title) {
            Slider(
                value: $backgroundOpacityPreview,
                in: 0.3...1.0,
                onEditingChanged: backgroundOpacityEditingChanged
            )
            .frame(maxWidth: 200)
        }
        .settingsAnchor(.appearanceBackgroundOpacity)
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
            isEditingLineSpacing = false
            lineSpacingPreview = profile.lineSpacing
            backgroundOpacityPreview = profile.backgroundOpacity
        }
        .onDisappear {
            TerminalSessionRegistry.shared.previewBackgroundOpacity(nil, forProfileID: profile.id)
        }
    }

    private func lineSpacingEditingChanged(_ isEditing: Bool) {
        isEditingLineSpacing = isEditing
        guard !isEditing else {
            return
        }
        commitLineSpacing(lineSpacingPreview)
    }

    private func commitLineSpacing(_ value: Double) {
        let spacing = TerminalProfile.sanitizedLineSpacing(value)
        let save = update
        DispatchQueue.main.async {
            save {
                $0.lineSpacing = spacing
            }
        }
    }

    private func backgroundOpacityEditingChanged(_ isEditing: Bool) {
        isEditingBackgroundOpacity = isEditing
        guard !isEditing else {
            return
        }
        let opacity = backgroundOpacityPreview
        let save = update
        DispatchQueue.main.async {
            save {
                $0.backgroundOpacity = opacity
            }
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
