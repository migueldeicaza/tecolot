import SwiftUI

struct EnvironmentVariableRow: View {
    let variable: TerminalEnvironmentVariable
    let update: (TerminalEnvironmentVariable) -> Void
    let remove: () -> Void

    var body: some View {
        HStack {
            TextField("Name", text: Binding(
                get: {
                    variable.name
                },
                set: { newName in
                    var replacement = variable
                    replacement.name = newName
                    update(replacement)
                }
            ))
            .frame(minWidth: 120)

            if variable.value != nil {
                TextField("Value", text: Binding(
                    get: {
                        variable.value ?? ""
                    },
                    set: { newValue in
                        var replacement = variable
                        replacement.value = newValue
                        update(replacement)
                    }
                ))
            }

            Toggle("Unset", isOn: Binding(
                get: {
                    variable.value == nil
                },
                set: { isUnset in
                    var replacement = variable
                    replacement.value = isUnset ? nil : ""
                    update(replacement)
                }
            ))
            .toggleStyle(.checkbox)

            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove environment variable")
        }
    }
}
