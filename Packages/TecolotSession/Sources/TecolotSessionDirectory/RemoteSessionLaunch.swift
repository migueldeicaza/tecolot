import Foundation
import TecolotTransport
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The remote user's account values. The resolver does not read the local account.
public struct RemoteUserInfo: Hashable, Sendable {
    public var name: String
    public var home: String
    public var shell: String

    public init(name: String, home: String, shell: String) {
        self.name = name
        self.home = home
        self.shell = shell
    }

    public static func current() throws -> RemoteUserInfo {
        var capacity = max(Int(sysconf(Int32(_SC_GETPW_R_SIZE_MAX))), 16_384)
        while true {
            var entry = passwd()
            var result: UnsafeMutablePointer<passwd>?
            var buffer = [CChar](repeating: 0, count: capacity)
            let values = try buffer.withUnsafeMutableBufferPointer { storage -> RemoteUserInfo? in
                let status = getpwuid_r(getuid(), &entry, storage.baseAddress, storage.count, &result)
                if status == ERANGE { return nil }
                guard status == 0, result != nil else {
                    throw TransportError("getpwuid_r", code: status == 0 ? ENOENT : status)
                }
                return RemoteUserInfo(name: entry.pw_name.map { String(cString: $0) } ?? "",
                                      home: entry.pw_dir.map { String(cString: $0) } ?? "/",
                                      shell: entry.pw_shell.map { String(cString: $0) } ?? "/bin/sh")
            }
            if let values { return values }
            guard capacity < 1_048_576 else { throw TransportError("getpwuid_r", code: ERANGE) }
            capacity *= 2
        }
    }
}

/// A launch request that uses the remote account and environment.
public struct RemoteSessionLaunch: Codable, Hashable, Sendable {
    public var command: String?
    public var environment: [String]
    public var unset: [String]
    public var workingDirectory: String?
    public var columns: Int
    public var rows: Int
    public var cellWidth: Int
    public var cellHeight: Int
    public var scrollback: Int
    public var termName: String
    public var cursorStyle: UInt8
    public var featureReport: String?
    public var theme: SessionTheme?
    public var labels: [String: String]
    public var kittyGraphicsStorageLimit: UInt32?
    public var kittyGraphicsLocalMedia: UInt8?
    /// The most rows of scrollback that the helper saves when the host ends
    /// it; 0 saves no text.
    public var restoreRows: Int?
    /// Replaces this ended session: the bridge reads its durable state,
    /// starts the new session in its directory and replays its text.
    public var restoreSessionID: String?

    public init(command: String? = nil, environment: [String] = [], unset: [String] = [],
                workingDirectory: String? = nil, columns: Int = 80, rows: Int = 24,
                cellWidth: Int = 0, cellHeight: Int = 0, scrollback: Int = 100_000,
                termName: String = "xterm-256color", cursorStyle: UInt8 = 0,
                featureReport: String? = nil, theme: SessionTheme? = nil,
                labels: [String: String] = [:], kittyGraphicsStorageLimit: UInt32? = nil,
                kittyGraphicsLocalMedia: UInt8? = nil, restoreRows: Int? = nil,
                restoreSessionID: String? = nil) {
        self.command = command
        self.environment = environment
        self.unset = unset
        self.workingDirectory = workingDirectory
        self.columns = columns
        self.rows = rows
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.scrollback = scrollback
        self.termName = termName
        self.cursorStyle = cursorStyle
        self.featureReport = featureReport
        self.theme = theme
        self.labels = labels
        self.kittyGraphicsStorageLimit = kittyGraphicsStorageLimit
        self.kittyGraphicsLocalMedia = kittyGraphicsLocalMedia
        self.restoreRows = restoreRows
        self.restoreSessionID = restoreSessionID
    }

    /// Where the shell starts. A directory that is gone becomes its nearest
    /// parent, as on the Mac, but only a parent in the home directory: a
    /// remote pane can report a path of another host (a nested ssh), and its
    /// nearest parent here is not useful. Else the home directory.
    public func startDirectory(home: String,
                               directoryExists: (String) -> Bool = ProcessDirectory.isDirectory) -> ProcessDirectory.RestoreTarget {
        let target = ProcessDirectory.restoreTarget(workingDirectory, isDirectory: directoryExists)
        guard let path = target.path else { return ProcessDirectory.RestoreTarget(path: home, notFound: target.notFound) }
        let homePath = URL(fileURLWithPath: home).standardizedFileURL.path
        if !target.notFound || path == homePath || path.hasPrefix(homePath.hasSuffix("/") ? homePath : homePath + "/") {
            return target
        }
        return ProcessDirectory.RestoreTarget(path: home, notFound: true)
    }

    public func resolve(passwd: RemoteUserInfo, bridgeEnvironment: [String: String],
                        directoryExists: (String) -> Bool = ProcessDirectory.isDirectory) -> SessionLaunch {
        let shell = passwd.shell.isEmpty ? "/bin/sh" : passwd.shell
        let shellName = URL(fileURLWithPath: shell).lastPathComponent
        let removed = Set(["SSH_TTY", "TERM", "PWD", "OLDPWD", "SHLVL", "_"])
        var values = bridgeEnvironment.filter { !removed.contains($0.key) && !$0.key.hasPrefix("TECOLOT_BRIDGE_") }
        values["HOME"] = passwd.home
        values["USER"] = passwd.name
        values["LOGNAME"] = passwd.name
        values["SHELL"] = shell
        for entry in environment {
            guard let separator = entry.firstIndex(of: "="), separator != entry.startIndex else { continue }
            values[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
        }
        for name in unset { values.removeValue(forKey: name) }
        values["TERM"] = termName

        let directory = startDirectory(home: passwd.home, directoryExists: directoryExists).path ?? passwd.home
        return SessionLaunch(executable: shell, arguments: command.map { ["-c", $0] } ?? [],
                             argv0: "-" + shellName,
                             environment: values.keys.sorted().map { "\($0)=\(values[$0]!)" },
                             workingDirectory: directory, columns: columns, rows: rows,
                             cellWidth: cellWidth, cellHeight: cellHeight, scrollback: scrollback,
                             termName: termName, cursorStyle: cursorStyle,
                             featureReport: featureReport, theme: theme, labels: labels,
                             kittyGraphicsStorageLimit: kittyGraphicsStorageLimit,
                             kittyGraphicsLocalMedia: kittyGraphicsLocalMedia,
                             stateDirectory: DurableStateDirectory.remoteDefault(home: passwd.home).url.path,
                             restoreRows: restoreRows)
    }
}
