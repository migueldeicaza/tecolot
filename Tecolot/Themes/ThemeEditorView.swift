//
//  ThemeEditorView.swift
//  Tecolot
//
//  A sheet that creates a user theme ("New") or edits one ("Edit…").
//  Changes stay in a draft until "Save & Apply".
//
import AppKit
import SwiftUI

struct ThemeEditorView: View {
    @ObservedObject var themes: ThemeStore
    /// A rename changes the theme name in these profiles.
    let profiles: ProfileStore
    /// The user theme that this sheet edits; nil for a new theme. A theme
    /// forked from a built-in theme is new until it is saved.
    let existingUserThemeName: String?
    /// Called after the theme is saved, with the saved theme.
    let onSave: (TerminalTheme) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: TerminalTheme
    @State private var showsRevertConfirmation = false
    /// The sample under "Colors"; nil hides it.
    @State private var previewPage: ThemePreviewPage?
    @State private var saveError: String?
    /// The color field that has the keyboard focus. While the user types a
    /// hex value, Return confirms the value and does not save the theme.
    @FocusState private var focusedWell: String?
    private let original: TerminalTheme

    init(
        theme: TerminalTheme,
        themes: ThemeStore,
        profiles: ProfileStore,
        existingUserThemeName: String? = nil,
        onSave: @escaping (TerminalTheme) -> Void
    ) {
        self.themes = themes
        self.profiles = profiles
        self.existingUserThemeName = existingUserThemeName
        self.onSave = onSave
        self.original = theme
        _draft = State(initialValue: theme)
    }

    private var trimmedName: String {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var conflictingTheme: TerminalTheme? {
        themes.conflictingTheme(forName: trimmedName, exceptUserTheme: existingUserThemeName)
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && draft.isValid && conflictingTheme == nil
    }

    /// The colors that "Revert…" restores.
    private var revertSource: TerminalTheme {
        if let base = draft.baseThemeName,
           let theme = themes.themes.first(where: { $0.name == base }) {
            return theme
        }
        return original
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Colors")
                            .font(.headline)
                        Spacer()
                        Picker("Preview", selection: $previewPage) {
                            Text("None").tag(ThemePreviewPage?.none)
                            Divider()
                            ForEach(ThemePreviewPage.allCases) { page in
                                Text(page.title).tag(Optional(page))
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                    if let previewPage {
                        ThemePreviewPageView(page: previewPage, theme: draft)
                            .frame(height: 180)
                            .clipShape(.rect(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                    }
                    colorGroups
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 640, height: 600)
        .confirmationDialog(
            "Revert the colors?",
            isPresented: $showsRevertConfirmation
        ) {
            Button("Revert", role: .destructive, action: revert)
        } message: {
            Text("The colors change back to those of \u{201C}\(revertSource.name)\u{201D}.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "paintpalette")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Theme name", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: 320)
                if let conflictingTheme {
                    Text(conflictingTheme.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame
                         ? "A theme named \u{201C}\(conflictingTheme.name)\u{201D} already exists."
                         : "The name is too similar to \u{201C}\(conflictingTheme.name)\u{201D}.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            ThemeKindBadge(isDark: draft.isDark)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var colorGroups: some View {
        VStack(alignment: .leading, spacing: 16) {
            ThemeColorGroup(title: "Terminal") {
                Grid(horizontalSpacing: 10, verticalSpacing: 4) {
                    GridRow {
                        ForEach(Self.terminalLabels, id: \.self) { label in
                            Text(label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    GridRow {
                        well("background", colorBinding(\.background))
                        well("foreground", colorBinding(\.foreground))
                        well("cursor", optionalColorBinding(\.cursor, effective: draft.effectiveCursor))
                        well("cursorText", optionalColorBinding(\.cursorText, effective: draft.effectiveCursorText))
                        well("selection", optionalColorBinding(
                            \.selectionBackground,
                            effective: draft.effectiveSelectionBackground
                        ))
                        well("selectionText", optionalColorBinding(
                            \.selectionText,
                            effective: draft.effectiveSelectionText
                        ))
                    }
                }
            }
            ThemeColorGroup(title: "ANSI Standard") {
                ansiGrid(range: 0..<8)
            }
            ThemeColorGroup(title: "ANSI Bright") {
                ansiGrid(range: 8..<16)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
    }

    private func well(_ id: String, _ color: Binding<ProfileColor>) -> some View {
        HexColorWell(color: color, focus: $focusedWell, id: id)
    }

    private func ansiGrid(range: Range<Int>) -> some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 4) {
            GridRow {
                ForEach(range, id: \.self) { index in
                    Text(Self.ansiLabels[index % 8])
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            GridRow {
                ForEach(range, id: \.self) { index in
                    well("ansi\(index)", ansiBinding(at: index))
                        .accessibilityLabel(Text("ANSI color \(index)"))
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Revert…") {
                showsRevertConfirmation = true
            }
            .disabled(Self.colors(of: draft) == Self.colors(of: revertSource))
            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel", role: .cancel) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button("Save & Apply", action: save)
                .keyboardShortcut(focusedWell == nil ? KeyboardShortcut.defaultAction : nil)
                .disabled(!canSave)
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Bindings

    private func colorBinding(_ keyPath: WritableKeyPath<TerminalTheme, ProfileColor>) -> Binding<ProfileColor> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { draft[keyPath: keyPath] = $0 }
        )
    }

    /// Shows the effective color of an optional slot. An edit stores an
    /// explicit value.
    private func optionalColorBinding(
        _ keyPath: WritableKeyPath<TerminalTheme, ProfileColor?>,
        effective: ProfileColor
    ) -> Binding<ProfileColor> {
        Binding(
            get: { draft[keyPath: keyPath] ?? effective },
            set: { draft[keyPath: keyPath] = $0 }
        )
    }

    private func ansiBinding(at index: Int) -> Binding<ProfileColor> {
        Binding(
            get: { draft.ansi.indices.contains(index) ? draft.ansi[index] : draft.foreground },
            set: { color in
                guard draft.ansi.indices.contains(index) else { return }
                draft.ansi[index] = color
            }
        )
    }

    // MARK: Actions

    private func revert() {
        let source = revertSource
        draft.ansi = source.ansi
        draft.foreground = source.foreground
        draft.background = source.background
        draft.cursor = source.cursor
        draft.cursorText = source.cursorText
        draft.selectionBackground = source.selectionBackground
        draft.selectionText = source.selectionText
    }

    private func save() {
        guard canSave else { return }
        var theme = draft
        theme.name = trimmedName
        theme.isBuiltIn = false
        do {
            try ThemeLibrary(themes: themes, profiles: profiles)
                .save(theme, replacing: existingUserThemeName)
            onSave(theme)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    // MARK: Helpers

    private static let terminalLabels = [
        "Background", "Text", "Cursor", "Cursor Text", "Selection", "Selected Text"
    ]
    private static let ansiLabels = [
        "Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"
    ]

    private static func colors(of theme: TerminalTheme) -> [ProfileColor?] {
        theme.ansi + [theme.foreground, theme.background, theme.cursor, theme.cursorText,
                      theme.selectionBackground, theme.selectionText]
    }
}

/// "Dark Theme" or "Light Theme", from the background of the theme.
struct ThemeKindBadge: View {
    let isDark: Bool

    var body: some View {
        Label(isDark ? "Dark Theme" : "Light Theme", systemImage: isDark ? "moon" : "sun.max")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary, in: .capsule)
    }
}

private struct ThemeColorGroup<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            content
        }
    }
}

/// A color block that opens the color panel, above an editable hex value.
///
/// A typed value goes into the binding as soon as it is a valid color, so
/// that "Save & Apply" gets it also while the field has the focus. The
/// binding changes only when the user changes the value: a field that only
/// gets and loses the focus does not change an optional slot from "use the
/// default" to a fixed color.
struct HexColorWell: View {
    @Binding var color: ProfileColor
    var focus: FocusState<String?>.Binding
    let id: String
    @State private var text = ""

    private var isFocused: Bool { focus.wrappedValue == id }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(color.swiftUIColor)
                .overlay(NativeColorWell(color: $color))
                .frame(height: 30)
            Divider()
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(.callout, design: .monospaced))
                .multilineTextAlignment(.center)
                .focused(focus, equals: id)
                .onSubmit(commit)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(.background)
        }
        .clipShape(.rect(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        .frame(minWidth: 64, maxWidth: .infinity)
        .onAppear { text = Self.display(color) }
        .onChange(of: text) { _, newText in
            guard isFocused, let parsed = Self.parse(newText), parsed != color else { return }
            color = parsed
        }
        .onChange(of: color) { _, newColor in
            // Show a color that comes from somewhere else (the color panel,
            // "Revert…"), also while the field has the focus. Do not change
            // the text when it already shows this color, while the user types.
            if Self.parse(text) != newColor {
                text = Self.display(newColor)
            }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused {
                commit()
            }
        }
    }

    /// Writes a changed, valid value, then shows the value in the standard
    /// form. An invalid value shows the current color again.
    private func commit() {
        if let parsed = Self.parse(text), parsed != color {
            color = parsed
        }
        text = Self.display(color)
    }

    static func parse(_ text: String) -> ProfileColor? {
        var spec = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !spec.hasPrefix("#") && !spec.lowercased().hasPrefix("rgb:") {
            spec = "#" + spec
        }
        return ProfileColor(hex: spec)
    }

    static func display(_ color: ProfileColor) -> String {
        color.hexString.uppercased().replacingOccurrences(of: "RGB:", with: "rgb:")
    }
}

/// An AppKit color well without alpha. SwiftUI ColorPicker cannot show a
/// large color block, so this well only takes the clicks.
private struct NativeColorWell: NSViewRepresentable {
    @Binding var color: ProfileColor

    func makeCoordinator() -> Coordinator {
        Coordinator(color: $color)
    }

    func makeNSView(context: Context) -> NSColorWell {
        let well = NSColorWell(style: .default)
        well.supportsAlpha = false
        well.isBordered = false
        // SwiftUI draws the flat color block under the well. The well
        // stays almost transparent, but it still gets clicks and opens
        // the color panel.
        well.alphaValue = 0.02
        well.target = context.coordinator
        well.action = #selector(Coordinator.colorChanged(_:))
        well.color = color.swiftUIColor.nsColor
        return well
    }

    func updateNSView(_ well: NSColorWell, context: Context) {
        context.coordinator.color = $color
        if ProfileColor(nsColor: well.color)?.roundedTo8Bits != color.roundedTo8Bits {
            well.color = color.swiftUIColor.nsColor
        }
    }

    final class Coordinator: NSObject {
        var color: Binding<ProfileColor>

        init(color: Binding<ProfileColor>) {
            self.color = color
        }

        @objc func colorChanged(_ sender: NSColorWell) {
            // 8 bits for each channel, so that the value shows as "#RRGGBB".
            if let value = ProfileColor(nsColor: sender.color)?.roundedTo8Bits,
               value != color.wrappedValue {
                color.wrappedValue = value
            }
        }
    }
}

private extension Color {
    var nsColor: NSColor { NSColor(self) }
}

#Preview("Theme Editor") {
    ThemeEditorView(
        theme: SettingsPreviewData.themes.duplicate(
            of: SettingsPreviewData.themes.theme(
                named: SettingsPreviewData.profile.darkThemeName
            )
        ),
        themes: SettingsPreviewData.themes,
        profiles: SettingsPreviewData.profiles,
        onSave: { _ in }
    )
}
