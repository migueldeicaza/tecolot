//
//  ThemeEditorView.swift
//  Tecolot
//
//  A sheet for creating and editing user-owned terminal themes.
//
import SwiftUI

struct ThemeEditorView: View {
    @ObservedObject var themes: ThemeStore
    let existingUserThemeName: String?

    @Environment(\.dismiss) private var dismiss
    @State private var editedTheme: TerminalTheme
    @State private var saveError: String?

    init (theme: TerminalTheme, themes: ThemeStore, existingUserThemeName: String? = nil) {
        self.themes = themes
        self.existingUserThemeName = existingUserThemeName
        _editedTheme = State (initialValue: theme)
    }

    private var trimmedName: String {
        editedTheme.name.trimmingCharacters (in: .whitespacesAndNewlines)
    }

    private var conflictingTheme: TerminalTheme? {
        themes.themes.first {
            $0.name.localizedCaseInsensitiveCompare (trimmedName) == .orderedSame &&
            existingUserThemeName?.localizedCaseInsensitiveCompare ($0.name) != .orderedSame
        }
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && editedTheme.isValid && conflictingTheme == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Theme") {
                    TextField("Name:", text: $editedTheme.name)
                    if let conflictingTheme {
                        Text("A theme named \(conflictingTheme.name) already exists.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("Terminal colors") {
                    ColorPicker("Foreground", selection: colorBinding (\.foreground))
                    ColorPicker("Background", selection: colorBinding (\.background))
                    optionalColorControl("Cursor", keyPath: \.cursor, defaultColor: editedTheme.foreground)
                    optionalColorControl("Cursor text", keyPath: \.cursorText, defaultColor: editedTheme.foreground)
                    optionalColorControl("Selection background", keyPath: \.selectionBackground, defaultColor: editedTheme.background)
                    optionalColorControl("Selection text", keyPath: \.selectionText, defaultColor: editedTheme.foreground)
                }

                Section("ANSI colors") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 10) {
                        ForEach(0..<16, id: \.self) { index in
                            ColorPicker("ANSI \(index)", selection: ansiColorBinding (at: index))
                                .labelsHidden()
                                .accessibilityLabel("ANSI color \(index)")
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            ThemePreview(theme: editedTheme, fontSize: 11)
                .frame(height: 120)
                .padding()

            Divider()
            HStack {
                if let saveError {
                    Text(saveError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding()
        }
        .frame(width: 560, height: 680)
    }

    private func optionalColorControl (
        _ name: String,
        keyPath: WritableKeyPath<TerminalTheme, ProfileColor?>,
        defaultColor: ProfileColor
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Use default \(name.lowercased())", isOn: Binding(
                get: { editedTheme[keyPath: keyPath] == nil },
                set: { useDefault in
                    editedTheme[keyPath: keyPath] = useDefault ? nil : defaultColor
                }
            ))
            if editedTheme[keyPath: keyPath] != nil {
                ColorPicker(name, selection: optionalColorBinding (keyPath, defaultColor: defaultColor))
            }
        }
    }

    private func colorBinding (_ keyPath: WritableKeyPath<TerminalTheme, ProfileColor>) -> Binding<Color> {
        Binding(
            get: { editedTheme[keyPath: keyPath].swiftUIColor },
            set: { color in
                if let profileColor = ProfileColor (swiftUIColor: color) {
                    editedTheme[keyPath: keyPath] = profileColor
                }
            }
        )
    }

    private func optionalColorBinding (
        _ keyPath: WritableKeyPath<TerminalTheme, ProfileColor?>,
        defaultColor: ProfileColor
    ) -> Binding<Color> {
        Binding(
            get: { (editedTheme[keyPath: keyPath] ?? defaultColor).swiftUIColor },
            set: { color in
                if let profileColor = ProfileColor (swiftUIColor: color) {
                    editedTheme[keyPath: keyPath] = profileColor
                }
            }
        )
    }

    private func ansiColorBinding (at index: Int) -> Binding<Color> {
        Binding(
            get: { editedTheme.ansi [index].swiftUIColor },
            set: { color in
                if let profileColor = ProfileColor (swiftUIColor: color) {
                    editedTheme.ansi [index] = profileColor
                }
            }
        )
    }

    private func save () {
        guard canSave else { return }
        editedTheme.name = trimmedName
        editedTheme.isBuiltIn = false
        do {
            try themes.saveUserTheme(
                editedTheme,
                replacing: existingUserThemeName
            )
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
