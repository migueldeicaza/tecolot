//
// PaneDirectory.swift
// TecolotSessionDirectory
//
// The working directory of a pane, from the reports of its shell. The app
// uses it for local panes; the helper for persistent sessions.
//
// A report can come from another host: the shell can run `ssh`, and the
// shell on the other host can send its own OSC 7. Restoration keeps only
// the directory on the host of the pane.
//

import Foundation

public struct PaneDirectory: Codable, Hashable, Sendable {
    public enum DirectoryHost: Codable, Hashable, Sendable {
        /// The host that runs the shell of the pane.
        case paneHost
        /// Another host, by the name in the report.
        case other(String)
    }

    public enum Source: String, Codable, Sendable {
        /// An OSC 7 report.
        case osc7
        /// An OSC 1337 CurrentDir or OSC 633 P Cwd report.
        case oscOther
        /// The working directory of the shell process.
        case process
        /// The directory that the pane started in.
        case launch
    }

    public var path: String
    public var host: DirectoryHost
    public var source: Source

    public init(path: String, host: DirectoryHost = .paneHost, source: Source) {
        self.path = path
        self.host = host
        self.source = source
    }

    public var isOnPaneHost: Bool { host == .paneHost }

    /// Reads an OSC 7 value (`file://host/path` or `kitty-shell-cwd://host/path`).
    /// `isPaneHost` tells whether a host name is the pane's host; a report
    /// without a host is from the pane's host. Returns nil for a value that
    /// is not a directory report.
    public static func osc7(_ report: String, isPaneHost: (String) -> Bool) -> PaneDirectory? {
        guard let url = URL(string: report),
              url.scheme == "file" || url.scheme == "kitty-shell-cwd" else { return nil }
        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/") else { return nil }
        if let host = url.host, !host.isEmpty, !isPaneHost(host) {
            return PaneDirectory(path: path, host: .other(host), source: .osc7)
        }
        return PaneDirectory(path: path, source: .osc7)
    }

    /// Reads the payload of OSC 1337 (`CurrentDir=<path>`) or OSC 633
    /// (`P;Cwd=<path>`). These reports have no host.
    /// True when `payload` starts like a directory report of `code`. Checks
    /// the bytes, so that a large OSC 1337 image is not decoded.
    public static func isOtherReport(code: Int, payload: some Collection<UInt8>) -> Bool {
        let prefix: String
        switch code {
        case 1337: prefix = "CurrentDir="
        case 633: prefix = "P;Cwd="
        default: return false
        }
        return payload.starts(with: prefix.utf8)
    }

    public static func otherReport(code: Int, payload: String) -> PaneDirectory? {
        let value: Substring
        switch code {
        case 1337:
            guard payload.hasPrefix("CurrentDir=") else { return nil }
            value = payload.dropFirst("CurrentDir=".count)
        case 633:
            guard payload.hasPrefix("P;Cwd=") else { return nil }
            value = payload.dropFirst("P;Cwd=".count)
        default:
            return nil
        }
        // VS Code escapes some characters as \xHH.
        let path = code == 633 ? unescapeVSCode(String(value)) : String(value)
        guard path.hasPrefix("/") else { return nil }
        return PaneDirectory(path: URL(fileURLWithPath: path).standardizedFileURL.path, source: .oscOther)
    }

    static func unescapeVSCode(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var bytes: [UInt8] = []
        let source = Array(text.utf8)
        var index = 0
        while index < source.count {
            if source[index] == UInt8(ascii: "\\"), index + 3 < source.count, source[index + 1] == UInt8(ascii: "x"),
               let value = UInt8(String(decoding: source[index + 2 ... index + 3], as: UTF8.self), radix: 16) {
                bytes.append(value)
                index += 4
            } else if source[index] == UInt8(ascii: "\\"), index + 1 < source.count, source[index + 1] == UInt8(ascii: "\\") {
                bytes.append(UInt8(ascii: "\\"))
                index += 2
            } else {
                bytes.append(source[index])
                index += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Keeps the last directory reports of one pane. Each report costs one
/// comparison; nothing else runs until a save asks for the directory.
public struct PaneDirectoryTracker: Hashable, Sendable {
    /// The last report from the pane's host: the directory to restore.
    public private(set) var restore: PaneDirectory?
    /// The last report from any host, for display.
    public private(set) var latest: PaneDirectory?
    public var launch: String?

    public init(launch: String? = nil) {
        self.launch = launch
    }

    public mutating func report(_ directory: PaneDirectory) {
        latest = directory
        if directory.isOnPaneHost { restore = directory }
    }

    /// True when a save must read the shell's directory: no report came, or
    /// the last one came from another host.
    public var needsProcessInspection: Bool {
        latest?.isOnPaneHost != true
    }

    /// The directory to save. `inspect` reads the shell's working directory;
    /// it runs only when `needsProcessInspection` is true.
    public func resolved(inspect: () -> String?) -> PaneDirectory? {
        if needsProcessInspection, let path = inspect() {
            return PaneDirectory(path: path, source: .process)
        }
        if let restore { return restore }
        return launch.map { PaneDirectory(path: $0, source: .launch) }
    }
}
