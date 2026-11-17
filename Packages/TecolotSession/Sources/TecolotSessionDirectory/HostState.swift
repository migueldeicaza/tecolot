//
// HostState.swift
// TecolotSessionDirectory
//
// Facts about this host that restoration needs: the boot identifier (a new
// value means that the host restarted), the working directory of a process,
// and the nearest directory that exists.
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum BootIdentifier {
    /// The identifier of the current boot, or nil when the system does not
    /// give one. It changes at each restart.
    public static func current() -> String? {
        #if canImport(Darwin)
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return value.isEmpty ? nil : value
        #else
        guard let text = try? String(contentsOfFile: "/proc/sys/kernel/random/boot_id", encoding: .utf8) else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
        #endif
    }
}

public enum ProcessDirectory {
    /// The working directory of process `pid`, or nil when the system does
    /// not tell it (the process ended, or it belongs to another user).
    public static func workingDirectory(of pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        #if canImport(Darwin)
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.hasPrefix("/") ? path : nil
        #else
        guard let path = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/cwd"),
              path.hasPrefix("/") else { return nil }
        // Linux adds this suffix when the directory was removed.
        return path.hasSuffix(" (deleted)") ? nil : path
        #endif
    }

    /// `path` when it is a directory, else its nearest parent that is one.
    /// Returns nil when no part of the path exists, or `path` is not absolute.
    public static func nearestExisting(_ path: String,
                                       isDirectory: (String) -> Bool = ProcessDirectory.isDirectory) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        while true {
            if isDirectory(url.path) { return url.path }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
    }

    /// Where a restored shell starts for a saved directory.
    public struct RestoreTarget: Equatable, Sendable {
        /// The saved directory or its nearest parent that exists; nil when
        /// nothing was saved or no part of the path exists.
        public var path: String?
        /// The shell does not start in the saved directory.
        public var notFound: Bool

        public init(path: String?, notFound: Bool) {
            self.path = path
            self.notFound = notFound
        }
    }

    /// The restore rule of the Mac and of remote hosts: a directory that is
    /// gone becomes its nearest parent.
    public static func restoreTarget(_ saved: String?,
                                     isDirectory: (String) -> Bool = ProcessDirectory.isDirectory) -> RestoreTarget {
        guard let saved else { return RestoreTarget(path: nil, notFound: false) }
        guard let existing = nearestExisting(saved, isDirectory: isDirectory) else {
            return RestoreTarget(path: nil, notFound: true)
        }
        return RestoreTarget(path: existing, notFound: existing != URL(fileURLWithPath: saved).standardizedFileURL.path)
    }

    public static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

public enum HostNames {
    /// The names that a shell on this host can put in an OSC 7 report. Uses
    /// gethostname only: a lookup of the full name can block on the network.
    public static func current() -> [String] {
        var buffer = [CChar](repeating: 0, count: 256)
        let name = gethostname(&buffer, buffer.count) == 0
            ? String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : ""
        var names = ["localhost"]
        if !name.isEmpty {
            let short = name.split(separator: ".").first.map(String.init) ?? name
            names += [name, short, "\(short).local"]
        }
        return names
    }

    public static func contains(_ host: String, in names: [String]) -> Bool {
        names.contains { $0.caseInsensitiveCompare(host) == .orderedSame }
    }
}
