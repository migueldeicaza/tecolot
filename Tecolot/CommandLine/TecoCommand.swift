import AppKit
import ArgumentParser

/// The `teco` command-line tool. It runs from the app executable when the
/// executable is started with the name `teco`, usually through a symlink.
nonisolated struct TecoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "teco",
        abstract: "Control Tecolot from the command line.",
        subcommands: [NewWindow.self, NewTab.self]
    )

    struct NewWindow: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Open a new Tecolot window.")
        @OptionGroup var options: TecoOpenOptions

        func run() throws {
            try TecoClient().send(options.request(for: .newWindow))
        }
    }

    struct NewTab: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Open a new tab in the front Tecolot window.")
        @OptionGroup var options: TecoOpenOptions

        func run() throws {
            try TecoClient().send(options.request(for: .newTab))
        }
    }
}

struct TecoOpenOptions: ParsableArguments {
    @Option(name: .shortAndLong, help: "The working directory. The default is the current directory.")
    var directory: String?

    @Flag(help: "Keep the terminal open after the command exits.")
    var hold = false

    @Argument(parsing: .captureForPassthrough,
              help: "A command to run in the login shell. Give one quoted string, or the program and its arguments.")
    var command: [String] = []

    func request(for action: CommandRequest.Action) -> CommandRequest {
        let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let path = directory.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, relativeTo: current) } ?? current
        return CommandRequest(
            action: action,
            directory: path.standardizedFileURL.path,
            command: Self.commandLine(from: command),
            holdsAfterExit: hold
        )
    }

    /// One argument is a shell command line. More arguments are a program
    /// and its arguments, so each one is quoted.
    static func commandLine(from arguments: [String]) -> String? {
        let arguments = arguments.first == "--" ? Array(arguments.dropFirst()) : arguments
        switch arguments.count {
        case 0: return nil
        case 1: return arguments[0]
        default: return arguments.map(shellQuoted).joined(separator: " ")
        }
    }

    static func shellQuoted(_ argument: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:,+@%")
        if !argument.isEmpty, argument.unicodeScalars.allSatisfy(safe.contains) { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

nonisolated struct TecoError: Error, CustomStringConvertible {
    var description: String
}

/// Adds the token of the running app to requests and sends them as URLs.
nonisolated struct TecoClient {
    private let applicationURL: URL
    private let bundleIdentifier: String

    init() throws {
        // `teco` is usually a symlink to the app executable.
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            throw TecoError(description: "Cannot find the Tecolot executable.")
        }
        let application = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard application.pathExtension == "app",
              let identifier = Bundle(url: application)?.bundleIdentifier else {
            throw TecoError(description: "teco must be a link to the executable inside Tecolot.app.")
        }
        applicationURL = application
        bundleIdentifier = identifier
    }

    func send(_ request: CommandRequest) throws {
        let token = try runningToken()
        guard let url = CommandURL.url(for: request, token: token.token) else {
            throw TecoError(description: "Cannot make the request URL.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try wait { completion in
            NSWorkspace.shared.open([url], withApplicationAt: applicationURL,
                                    configuration: configuration) { _, error in completion(error) }
        }
    }

    /// The token of the running app. Starts the app when it is not running.
    private func runningToken() throws -> CommandToken {
        if let token = currentToken() { return token }
        let configuration = NSWorkspace.OpenConfiguration()
        // An inactive launch does not open the startup window before the
        // request arrives.
        configuration.activates = false
        try wait { completion in
            NSWorkspace.shared.openApplication(at: applicationURL,
                                               configuration: configuration) { _, error in completion(error) }
        }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let token = currentToken() { return token }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw TecoError(description: "Tecolot did not start in time.")
    }

    /// The token file is valid only while the app that wrote it runs.
    private func currentToken() -> CommandToken? {
        let directory = AppModel.applicationSupportDirectory(bundleIdentifier: bundleIdentifier)
        guard let token = CommandToken.read(from: directory),
              let application = NSRunningApplication(processIdentifier: token.processIdentifier),
              application.bundleIdentifier == bundleIdentifier,
              !application.isTerminated else {
            return nil
        }
        return token
    }

    private func wait(_ operation: (@escaping @Sendable (Error?) -> Void) -> Void) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let result = ErrorBox()
        operation { error in
            result.error = error
            semaphore.signal()
        }
        semaphore.wait()
        if let error = result.error {
            throw TecoError(description: error.localizedDescription)
        }
    }
}

private nonisolated final class ErrorBox: @unchecked Sendable {
    var error: Error?
}
