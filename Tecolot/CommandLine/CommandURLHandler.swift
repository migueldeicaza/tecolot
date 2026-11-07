import AppKit
import os

/// Owns the command-line token for this launch and runs `tecolot://` URLs.
@MainActor
final class CommandURLHandler {
    static let shared = CommandURLHandler()

    private let logger = Logger(subsystem: "com.tirania.Tecolot", category: "CommandURL")
    private var token: CommandToken?

    /// Makes a new token. Call it once at each launch, so URLs from older
    /// launches stop working.
    func rotateToken() {
        let token = CommandToken.generate()
        do {
            try token.write(to: AppModel.applicationSupportDirectory())
            self.token = token
        } catch {
            logger.error("Could not write the command-line token: \(error.localizedDescription)")
        }
    }

    /// Returns false when the URL is not a Tecolot command.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard let request = CommandURL.request(from: url) else {
            logger.error("Ignored an unknown URL: \(url.absoluteString, privacy: .private)")
            return false
        }
        if isTrusted(url) || !request.needsTrust {
            perform(request)
        } else {
            confirm(request)
        }
        return true
    }

    private func isTrusted(_ url: URL) -> Bool {
        guard let token else { return false }
        return CommandURL.hasToken(token.token, url: url)
    }

    private func confirm(_ request: CommandRequest) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = request.command == nil
            ? "Open a terminal from a link?"
            : "Run a command from a link?"
        var details = ["Another app or a web page asked Tecolot to open a terminal."]
        if let command = request.command { details.append("Command: \(command)") }
        if let directory = request.directory { details.append("Directory: \(directory)") }
        details.append("Continue only if you started this action.")
        alert.informativeText = details.joined(separator: "\n\n")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: request.command == nil ? "Open" : "Run")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        perform(request)
    }

    private func perform(_ request: CommandRequest) {
        let spec = LaunchSpec(
            workingDirectory: request.directory,
            command: request.command,
            holdsAfterExit: request.holdsAfterExit
        )
        switch request.action {
        case .newWindow:
            WindowOpener.openWindow(spec: spec)
        case .newTab:
            var tabSpec = WindowOpener.inheritedTabSpec()
            tabSpec.workingDirectory = spec.workingDirectory ?? tabSpec.workingDirectory
            tabSpec.command = spec.command
            tabSpec.holdsAfterExit = spec.holdsAfterExit
            WindowOpener.openTab(spec: tabSpec)
        }
    }
}
