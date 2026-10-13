import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum SSHConfigurationError: Error, Equatable, Sendable {
    case invalidDestination
    case invalidOutput
    case resolveFailed(Int32, String)
}

/// Values from `ssh -G`. Repeated keys retain their order.
public struct SSHConfiguration: Equatable, Sendable {
    public let destination: String
    public let values: [String: [String]]
    public let user: String
    public let hostName: String
    public let port: Int
    public let controlPath: String?
    public let forwardAgent: Bool
    public let serverAliveInterval: Int
    public let serverAliveCountMax: Int
    public let proxyJump: String?
    public let proxyCommand: String?
    public var hostKey: String { "\(user)@\(hostName):\(port)" }

    public init(destination: String, output: String) throws {
        try Self.validate(destination)
        var parsed: [String: [String]] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { continue }
            parsed[String(parts[0]).lowercased(), default: []].append(String(parts[1]))
        }
        guard let user = parsed["user"]?.first, !user.isEmpty,
              let host = parsed["hostname"]?.first, !host.isEmpty,
              let port = parsed["port"]?.first.flatMap(Int.init), (1...65535).contains(port) else {
            throw SSHConfigurationError.invalidOutput
        }
        func optional(_ key: String) -> String? {
            guard let value = parsed[key]?.first, value.lowercased() != "none", !value.isEmpty else { return nil }
            return value
        }
        self.destination = destination
        values = parsed
        self.user = user
        hostName = host
        self.port = port
        controlPath = optional("controlpath")
        forwardAgent = parsed["forwardagent"]?.first?.lowercased() == "yes"
        serverAliveInterval = parsed["serveraliveinterval"]?.first.flatMap(Int.init) ?? 0
        serverAliveCountMax = parsed["serveralivecountmax"]?.first.flatMap(Int.init) ?? 0
        proxyJump = optional("proxyjump")
        proxyCommand = optional("proxycommand")
    }

    public static func validate(_ destination: String) throws {
        guard !destination.isEmpty, !destination.hasPrefix("-"),
              !destination.contains(where: { $0.isWhitespace || $0.asciiValue == 0 }) else {
            throw SSHConfigurationError.invalidDestination
        }
    }

    public static func resolve(destination: String, sshPath: String = "/usr/bin/ssh",
                               environment: [String: String] = ProcessInfo.processInfo.environment) throws -> SSHConfiguration {
        try validate(destination)
        let process = Process()
        let output = Pipe()
        // A file avoids a pipe deadlock if a Match command writes much stderr.
        let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: errorURL.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: errorURL) }
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? errors.close() }
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = ["-G", destination]
        process.environment = environment
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderr = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
            throw SSHConfigurationError.resolveFailed(process.terminationStatus, stderr)
        }
        return try SSHConfiguration(destination: destination, output: String(decoding: data, as: UTF8.self))
    }
}

/// Reads concrete Host names. It does not evaluate Match conditions.
public enum SSHHostAliases {
    public static func list(configURL: URL = FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent(".ssh/config")) throws -> [String] {
        try load(configURL: configURL)
    }
    public static func load(configURL: URL = FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent(".ssh/config")) throws -> [String] {
        var result: [String] = []
        var names: Set<String> = []
        var activeFiles: Set<String> = []
        let sshDirectory = configURL.deletingLastPathComponent()
        let homeDirectory = sshDirectory.deletingLastPathComponent()
        var inMatch = false

        func expand(_ pattern: String) -> [String] {
            let path: String
            if pattern.hasPrefix("~/") {
                path = homeDirectory.appendingPathComponent(String(pattern.dropFirst(2))).path
            } else if pattern.hasPrefix("/") { path = pattern }
            else { path = sshDirectory.appendingPathComponent(pattern).path }
            var matches = glob_t()
            defer { globfree(&matches) }
            guard glob(path, 0, nil, &matches) == 0, let paths = matches.gl_pathv else { return [] }
            return (0..<Int(matches.gl_pathc)).compactMap { paths[$0].map { String(cString: $0) } }
        }
        func read(_ url: URL, required: Bool) throws {
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard activeFiles.insert(path).inserted else { return }
            defer { activeFiles.remove(path) }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                if required && FileManager.default.fileExists(atPath: url.path) {
                    throw CocoaError(.fileReadUnknown)
                }
                return
            }
            for line in content.split(whereSeparator: \.isNewline) {
                let words = tokenize(String(line))
                guard let key = words.first?.lowercased() else { continue }
                if key == "match" { inMatch = true }
                else if key == "host" {
                    inMatch = false
                    for name in words.dropFirst() where !name.contains(where: { "*?!".contains($0) }) {
                        if names.insert(name).inserted { result.append(name) }
                    }
                } else if key == "include", !inMatch {
                    for pattern in words.dropFirst() {
                        for path in expand(pattern) { try read(URL(fileURLWithPath: path), required: false) }
                    }
                }
            }
        }
        try read(configURL, required: true)
        return result
    }

    private static func tokenize(_ line: String) -> [String] {
        var result: [String] = []
        var word = ""
        var quote: Character?
        var escaped = false
        for character in line {
            if escaped { word.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if let current = quote {
                if character == current { quote = nil } else { word.append(character) }
            } else if character == "\"" || character == "'" { quote = character }
            else if character == "#" { break }
            else if character.isWhitespace || (character == "=" && (result.isEmpty || (result.count == 1 && word.isEmpty))) {
                if !word.isEmpty { result.append(word); word = "" }
            } else { word.append(character) }
        }
        if !word.isEmpty { result.append(word) }
        return result
    }
}
