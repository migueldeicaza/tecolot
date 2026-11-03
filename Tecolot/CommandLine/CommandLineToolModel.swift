import AppKit
import Observation
import SwiftUI

struct CommandLineToolCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Install Command-Line Tool…") {
                CommandLineToolModel.shared.install()
            }
        }
    }
}

/// The install state of `teco`, shared by Settings and the app menu.
@Observable
@MainActor
final class CommandLineToolModel {
    static let shared = CommandLineToolModel()

    private static let linkKey = "commandLineToolLink"

    private(set) var status: CommandLineToolInstaller.Status = .notInstalled

    private var installer: CommandLineToolInstaller? {
        Bundle.main.executableURL.map { CommandLineToolInstaller(executable: $0) }
    }

    private var link: URL? {
        get { UserDefaults.standard.string(forKey: Self.linkKey).map { URL(fileURLWithPath: $0) } }
        set { UserDefaults.standard.set(newValue?.path, forKey: Self.linkKey) }
    }

    init() {
        refresh()
    }

    var summary: String {
        switch status {
        case .notInstalled:
            "Not installed"
        case .installed(let link, true):
            "Installed at \(link.path)"
        case .installed(let link, false):
            "Installed at \(link.path) for a different copy of Tecolot"
        }
    }

    var isInstalled: Bool {
        status != .notInstalled
    }

    func refresh() {
        status = installer?.status(link: link) ?? .notInstalled
    }

    /// Asks where to put the link, then makes it.
    func install() {
        guard let installer else { return }
        let panel = NSSavePanel()
        panel.title = "Install Command-Line Tool"
        panel.message = "Choose a folder on your PATH."
        panel.prompt = "Install"
        panel.nameFieldStringValue = CommandLineToolInstaller.toolName
        panel.canCreateDirectories = true
        let directory = link?.deletingLastPathComponent()
            ?? installer.defaultDirectory(home: FileManager.default.homeDirectoryForCurrentUser)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        panel.directoryURL = directory
        NSApp.activate()
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try installer.install(at: destination)
            link = destination
        } catch {
            NSApp.presentError(error)
        }
        refresh()
    }

    func uninstall() {
        guard let installer, let link else { return }
        do {
            try installer.uninstall(link: link)
            self.link = nil
        } catch {
            NSApp.presentError(error)
        }
        refresh()
    }
}
