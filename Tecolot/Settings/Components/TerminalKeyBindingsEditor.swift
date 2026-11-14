import SwiftUI

struct TerminalKeyBindingsEditor: View {
    let profile: TerminalProfile
    let update: ((inout TerminalProfile) -> Void) -> Void

    var body: some View {
        ForEach(profile.keyBindings) { keyBinding in
            TerminalKeyBindingRow(
                keyBinding: keyBinding,
                update: {
                    replace(keyBinding.id, with: $0)
                },
                remove: {
                    remove(keyBinding.id)
                }
            )
        }

        Button("Add Key Mapping", systemImage: "plus", action: add)
            .buttonStyle(.borderless)
    }

    private func add() {
        update {
            $0.keyBindings.append(
                TerminalKeyBinding(key: "", modifiers: [.command], action: .sendText)
            )
        }
    }

    private func replace(_ id: UUID, with keyBinding: TerminalKeyBinding) {
        update { profile in
            guard
                let index = profile.keyBindings.firstIndex(where: {
                    $0.id == id
                }) else {
                return
            }
            profile.keyBindings[index] = keyBinding
        }
    }

    private func remove(_ id: UUID) {
        update {
            $0.keyBindings.removeAll {
                $0.id == id
            }
        }
    }
}

private struct TerminalKeyBindingRow: View {
    let keyBinding: TerminalKeyBinding
    let update: (TerminalKeyBinding) -> Void
    let remove: () -> Void

    var body: some View {
        HStack {
            TextField("Key", text: valueBinding(\.key))
                .frame(width: 70)
                .accessibilityLabel("Key")

            Menu(modifierLabel) {
                Toggle("Command", isOn: modifierBinding(.command))
                Toggle("Shift", isOn: modifierBinding(.shift))
                Toggle("Option", isOn: modifierBinding(.option))
                Toggle("Control", isOn: modifierBinding(.control))
            }
            .frame(width: 90)

            Picker("Action", selection: valueBinding(\.action)) {
                ForEach(TerminalKeyAction.allCases, id: \.self) { action in
                    Text(action.displayName).tag(action)
                }
            }
            .labelsHidden()

            TextField("Value", text: valueBinding(\.value))
                .disabled(!keyBinding.action.usesValue)
                .accessibilityLabel("Text or escape sequence")

            Button("Remove", systemImage: "minus.circle", action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
    }

    private var modifierLabel: String {
        var labels: [String] = []
        if keyBinding.modifiers.contains(.control) {
            labels.append("⌃")
        }
        if keyBinding.modifiers.contains(.option) {
            labels.append("⌥")
        }
        if keyBinding.modifiers.contains(.shift) {
            labels.append("⇧")
        }
        if keyBinding.modifiers.contains(.command) {
            labels.append("⌘")
        }
        return labels.isEmpty ? "None" : labels.joined()
    }

    private func valueBinding<Value>(
        _ keyPath: WritableKeyPath<TerminalKeyBinding, Value>
    ) -> Binding<Value> {
        Binding(
            get: {
                keyBinding[keyPath: keyPath]
            },
            set: { newValue in
                var changed = keyBinding
                changed[keyPath: keyPath] = newValue
                update(changed)
            }
        )
    }

    private func modifierBinding(_ modifier: TerminalKeyModifiers) -> Binding<Bool> {
        Binding(
            get: {
                keyBinding.modifiers.contains(modifier)
            },
            set: { enabled in
                var changed = keyBinding
                if enabled {
                    changed.modifiers.insert(modifier)
                } else {
                    changed.modifiers.remove(modifier)
                }
                update(changed)
            }
        )
    }
}

#Preview("Key Bindings Editor") {
    TerminalKeyBindingsEditor(profile: SettingsPreviewData.profile, update: { _ in })
        .padding()
        .frame(width: 560)
}

#Preview("Key Binding Row") {
    TerminalKeyBindingRow(
        keyBinding: SettingsPreviewData.keyBinding,
        update: { _ in },
        remove: {}
    )
    .padding()
    .frame(width: 560)
}
