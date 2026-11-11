import Foundation

/// A request that `teco` sends to the app as a `tecolot://` URL.
nonisolated struct CommandRequest: Equatable {
    nonisolated enum Action: String, CaseIterable {
        case newWindow = "new-window"
        case newTab = "new-tab"
    }

    var action: Action
    var directory: String?
    var command: String?
    var holdsAfterExit = false

    /// True when the request can run code or start a shell in a chosen place.
    var needsTrust: Bool {
        directory != nil || command != nil
    }
}

/// Builds and reads `tecolot://` URLs.
///
/// The CLI adds the app's current token to the URL. Only processes of the
/// same user can read the token file, so a URL with the right token did not
/// come from a web page or another user.
nonisolated enum CommandURL {
    static let scheme = "tecolot"

    private enum Key {
        static let directory = "directory"
        static let command = "command"
        static let hold = "hold"
        static let token = "token"
    }

    static func url(for request: CommandRequest, token: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = request.action.rawValue
        var items: [URLQueryItem] = []
        if let directory = request.directory { items.append(URLQueryItem(name: Key.directory, value: directory)) }
        if let command = request.command { items.append(URLQueryItem(name: Key.command, value: command)) }
        if request.holdsAfterExit { items.append(URLQueryItem(name: Key.hold, value: "1")) }
        items.append(URLQueryItem(name: Key.token, value: token))
        components.queryItems = items
        return components.url
    }

    static func request(from url: URL) -> CommandRequest? {
        guard url.scheme == scheme,
              let host = url.host(),
              let action = CommandRequest.Action(rawValue: host) else {
            return nil
        }
        return CommandRequest(
            action: action,
            directory: value(Key.directory, in: url),
            command: value(Key.command, in: url),
            holdsAfterExit: value(Key.hold, in: url) == "1"
        )
    }

    static func hasToken(_ token: String, url: URL) -> Bool {
        guard let provided = value(Key.token, in: url) else { return false }
        return provided == token
    }

    private static func value(_ name: String, in url: URL) -> String? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// The token file that the app writes at each launch and the CLI reads.
nonisolated struct CommandToken: Codable, Equatable {
    var processIdentifier: Int32
    var token: String

    static let fileName = "command-line-token.json"

    static func generate(processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier) -> CommandToken {
        var generator = SystemRandomNumberGenerator()
        let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
            .joined()
        return CommandToken(processIdentifier: processIdentifier, token: token)
    }

    static func read(from directory: URL) -> CommandToken? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(CommandToken.self, from: data)
    }

    /// Writes the file so that only the owner can read it at any time.
    func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(Self.fileName)
        let temporary = directory.appendingPathComponent(".\(Self.fileName).\(UUID().uuidString)")
        let data = try JSONEncoder().encode(self)
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, destination.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
