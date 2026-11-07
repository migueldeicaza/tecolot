import SwiftUI

struct CommandLineToolSection: View {
    @State private var model = CommandLineToolModel.shared

    var body: some View {
        Section("Command-Line Tool") {
            LabeledContent("teco:") {
                Text(model.summary)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack {
                Button(model.isInstalled ? "Reinstall…" : "Install…") {
                    model.install()
                }
                if model.isInstalled {
                    Button("Uninstall") {
                        model.uninstall()
                    }
                }
            }
            Text("Open windows and tabs from the shell. Make sure the folder is on your PATH, then run teco --help.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { model.refresh() }
    }
}
