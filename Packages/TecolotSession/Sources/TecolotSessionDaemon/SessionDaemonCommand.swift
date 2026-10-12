//
// SessionDaemonCommand.swift
// TecolotSessionDaemon
//
// The `tecolot-sessiond` command line:
//
//   serve --id ID --runtime-dir DIR [--ready-fd N] [--foreground]
//   create [--runtime-dir DIR]          SessionLaunch JSON on stdin; prints the record
//   list [--runtime-dir DIR]            prints the records as JSON
//   terminate ID [--signal N] [--runtime-dir DIR]
//   version [--json]
//

import Foundation
import TecolotSessionDirectory
import TecolotTransport
import TecolotWire
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum SessionDaemonCommand {
    /// The build identifier that the helper reports. Set it before `main`.
    nonisolated(unsafe) public static var build = "dev"

    public static func main(_ arguments: [String] = CommandLine.arguments) -> Never {
        var parser = ArgumentList(Array(arguments.dropFirst()))
        let command = parser.next() ?? "help"
        do {
            switch command {
            case "serve": try serve(&parser)
            case "create": try create(&parser)
            case "list": try list(&parser)
            case "terminate": try terminate(&parser)
            case "version": version(&parser)
            case "bridge":
                fail("bridge is not available in this build")
            default:
                fail("usage: tecolot-sessiond serve|create|list|terminate|version")
            }
        } catch {
            fail("\(error)")
        }
        exit(0)
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("tecolot-sessiond: " + message + "\n").utf8))
        exit(1)
    }

    static func directory(_ parser: inout ArgumentList) throws -> SessionDirectory {
        if let path = parser.option("--runtime-dir") {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            try RuntimeDirectory.prepare(url)
            return SessionDirectory(url: url)
        }
        return try SessionDirectory.standard()
    }

    static var executablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    static func serve(_ parser: inout ArgumentList) throws -> Never {
        guard let id = parser.option("--id"), SessionDirectory.isValidIdentifier(id) else {
            fail("serve needs a valid --id")
        }
        let directory = try directory(&parser)
        let readyFD = parser.option("--ready-fd").flatMap(Int32.init)
        if !parser.flag("--foreground") {
            // Detach: start a copy in a new session and exit, so that the
            // process that started us can reap this one at once.
            var arguments = ["tecolot-sessiond", "serve", "--id", id, "--runtime-dir", directory.url.path,
                             "--foreground"]
            if let readyFD { arguments += ["--ready-fd", "\(readyFD)"] }
            _ = try SessionDirectory.spawn(executablePath, arguments: arguments, readyFD: readyFD,
                                           log: directory.logURL(for: id).path, newSession: true)
            exit(0)
        }
        let server: SessionServer
        do {
            server = try SessionServer(directory: directory, id: id, build: build)
        } catch {
            SessionServer.report(readyFD, "error \(error)")
            throw error
        }
        try server.start(readyFD: readyFD)
        server.run()
    }

    static func create(_ parser: inout ArgumentList) throws {
        let directory = try directory(&parser)
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let launch = try JSONDecoder().decode(SessionLaunch.self, from: input)
        let record = try directory.create(launch, helperPath: executablePath)
        try printJSON(record)
    }

    static func list(_ parser: inout ArgumentList) throws {
        let directory = try directory(&parser)
        try printJSON(directory.list())
    }

    static func terminate(_ parser: inout ArgumentList) throws {
        let signalNumber = parser.option("--signal").flatMap(Int32.init) ?? SIGHUP
        let directory = try directory(&parser)
        guard let id = parser.next() else { fail("terminate needs a session id") }
        try directory.terminate(id, signal: signalNumber)
    }

    static func version(_ parser: inout ArgumentList) {
        if parser.flag("--json") {
            print("{\"build\":\"\(build)\",\"protocol\":\(SessionProtocol.version),\"minimumProtocol\":\(SessionProtocol.minimumVersion)}")
        } else {
            print("tecolot-sessiond \(build) (protocol \(SessionProtocol.minimumVersion)...\(SessionProtocol.version))")
        }
    }

    static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

/// A small argument reader: options (`--name value`), flags and positionals.
struct ArgumentList {
    private var items: [String]

    init(_ items: [String]) { self.items = items }

    mutating func next() -> String? {
        guard let index = items.firstIndex(where: { !$0.hasPrefix("--") }) else { return nil }
        return items.remove(at: index)
    }

    mutating func option(_ name: String) -> String? {
        guard let index = items.firstIndex(of: name), index + 1 < items.count else { return nil }
        let value = items[index + 1]
        items.removeSubrange(index ... index + 1)
        return value
    }

    mutating func flag(_ name: String) -> Bool {
        guard let index = items.firstIndex(of: name) else { return false }
        items.remove(at: index)
        return true
    }
}
