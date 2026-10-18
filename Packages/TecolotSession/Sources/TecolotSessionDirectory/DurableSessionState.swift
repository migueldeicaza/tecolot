//
// DurableSessionState.swift
// TecolotSessionDirectory
//
// What a helper keeps of its session when the system ends it (log out,
// restart, shut down). The next launch starts a new session from it, in the
// same directory and under the same text.
//
//     <state directory>/<id>/state.json    DurableSessionState
//     <state directory>/<id>/scrollback    ScrollbackFile
//
// The state directory is durable, unlike the runtime directory, which the
// system can clear at restart:
//
//     local    ~/Library/Application Support/<bundle>/Sessions/
//     remote   ~/.tecolot/state/
//
// The helper writes these files only when it receives SIGTERM or SIGHUP.
// The app (or the bridge) deletes them after it used them.
//

import Foundation
import TecolotTransport
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct DurableSessionState: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version = DurableSessionState.currentVersion
    public var id: String
    /// The launch parameters of the session.
    public var launch: SessionLaunch
    public var profileName: String?
    /// The shell's directory at the save, on the helper's host.
    public var directory: PaneDirectory?
    public var title: String
    public var tabName: String?
    /// The boot of the helper's host at the save.
    public var bootID: String?
    public var savedAt: Date
    /// The full-screen program that showed the alternate screen at the save.
    public var alternateScreenProgram: String?

    public init(id: String, launch: SessionLaunch, profileName: String? = nil, directory: PaneDirectory? = nil,
                title: String = "", tabName: String? = nil, bootID: String? = BootIdentifier.current(),
                savedAt: Date = Date(), alternateScreenProgram: String? = nil) {
        self.id = id
        self.launch = launch
        self.profileName = profileName
        self.directory = directory
        self.title = title
        self.tabName = tabName
        self.bootID = bootID
        self.savedAt = savedAt
        self.alternateScreenProgram = alternateScreenProgram
    }

    /// The reason for the restore separator, from the boot of the host now.
    public func reason(currentBoot: String? = BootIdentifier.current(), remote: Bool) -> RestoreSeparator.Reason {
        if let bootID, let currentBoot, bootID != currentBoot {
            return remote ? .hostRestarted : .macRestarted
        }
        return .sessionEnded
    }
}

public struct DurableStateDirectory: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The directory on a remote host: `~/.tecolot/state`.
    public static func remoteDefault(home: String = NSHomeDirectory()) -> DurableStateDirectory {
        DurableStateDirectory(url: URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".tecolot/state", isDirectory: true))
    }

    /// States older than this are deleted.
    public static let lifetime: TimeInterval = 7 * 24 * 60 * 60

    func folder(for id: String) -> URL { url.appendingPathComponent(id, isDirectory: true) }
    public func stateURL(for id: String) -> URL { folder(for: id).appendingPathComponent("state.json") }
    public func scrollbackURL(for id: String) -> URL { folder(for: id).appendingPathComponent("scrollback") }

    /// Creates the directory with mode 0700, excluded from backups.
    public func prepare() throws {
        try Self.makePrivateDirectory(url)
    }

    /// Creates `url` with mode 0700, excluded from backups.
    public static func makePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(url.path, 0o700)
        #if canImport(Darwin)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try? target.setResourceValues(values)
        #endif
    }

    /// Writes the state and its scrollback (nil writes no text).
    public func write(_ state: DurableSessionState, scrollback: Data?) throws {
        guard SessionDirectory.isValidIdentifier(state.id) else { throw SessionDirectoryError.noSuchSession(state.id) }
        try prepare()
        let folder = folder(for: state.id)
        try Self.makePrivateDirectory(folder)
        if let scrollback {
            try Self.writePrivate(scrollback, to: scrollbackURL(for: state.id))
        } else {
            unlink(scrollbackURL(for: state.id).path)
        }
        // The state goes last: a state file means that the save completed.
        try Self.writePrivate(try SessionDirectory.encoder.encode(state), to: stateURL(for: state.id))
    }

    /// Writes `data` with mode 0600 and replaces `target` atomically.
    public static func writePrivate(_ data: Data, to target: URL) throws {
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).\(getpid())")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw TransportError("open \(temporary.path)") }
        let written = data.withUnsafeBytes { buffer -> Int in
            var offset = 0
            while offset < buffer.count {
                let count = Foundation.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0 { if errno == EINTR { continue }; return -1 }
                offset += count
            }
            return offset
        }
        close(fd)
        guard written == data.count, rename(temporary.path, target.path) == 0 else {
            unlink(temporary.path)
            throw TransportError("write \(target.path)")
        }
    }

    public func read(_ id: String) -> DurableSessionState? {
        guard SessionDirectory.isValidIdentifier(id),
              let data = try? Data(contentsOf: stateURL(for: id)) else { return nil }
        return try? SessionDirectory.decoder.decode(DurableSessionState.self, from: data)
    }

    /// The saved text of a state, with the header; nil when there is none or
    /// it does not decode.
    public func scrollback(_ id: String) -> (header: ScrollbackHeader, text: String)? {
        guard SessionDirectory.isValidIdentifier(id),
              let data = try? Data(contentsOf: scrollbackURL(for: id)) else { return nil }
        return try? ScrollbackFile.decode(data)
    }

    public func remove(_ id: String) {
        guard SessionDirectory.isValidIdentifier(id) else { return }
        try? FileManager.default.removeItem(at: folder(for: id))
    }

    /// The saved states, newest first. Deletes the states older than
    /// `lifetime` and the folders that have no valid state.
    public func list(now: Date = Date()) -> [DurableSessionState] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return [] }
        var states: [DurableSessionState] = []
        for name in names where SessionDirectory.isValidIdentifier(name) {
            guard let state = read(name) else {
                // A save that did not complete, or a file that does not decode.
                let folder = folder(for: name)
                let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, now.timeIntervalSince(modified) > 60 { remove(name) }
                continue
            }
            if now.timeIntervalSince(state.savedAt) > Self.lifetime {
                remove(name)
                continue
            }
            states.append(state)
        }
        return states.sorted { $0.savedAt > $1.savedAt }
    }

    /// Deletes the folders older than `lifetime`. Reads only the folder
    /// times, not the states: the helper writes a state one time.
    public func prune(now: Date = Date()) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return }
        for name in names where SessionDirectory.isValidIdentifier(name) {
            let modified = (try? folder(for: name).resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, now.timeIntervalSince(modified) > Self.lifetime { remove(name) }
        }
    }

    /// The text to feed a new session that replaces `state`: the saved
    /// scrollback and the separator line.
    public func replay(for state: DurableSessionState, rowLimit: Int, remote: Bool,
                       directoryNotFound: Bool = false) -> String {
        var text = ""
        if rowLimit > 0, let saved = scrollback(state.id) {
            text = Self.lastLines(saved.text, limit: rowLimit)
        }
        return text + RestoreSeparator.line(savedAt: state.savedAt, reason: state.reason(remote: remote),
                                            directoryNotFound: directoryNotFound,
                                            program: state.alternateScreenProgram)
    }

    /// The last `limit` lines of `text`.
    public static func lastLines(_ text: String, limit: Int) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        guard lines.count > limit else { return text }
        return lines.suffix(limit).joined(separator: "\n") + "\n"
    }
}

extension DurableStateDirectory {
    /// Changes `launch` to replace the ended session `sessionID`: the saved
    /// directory (or its nearest parent), and a replay of the saved text with
    /// the separator. Without a saved state, the replay is only the separator
    /// ("the session ended"). Returns the state that it used; delete it after
    /// the new session starts.
    @discardableResult
    /// `directoryNotFound` tells whether the launch's directory is not the
    /// directory that the pane asked for; the separator says so when there
    /// is no state.
    public func prepareRestore(_ launch: inout SessionLaunch, sessionID: String, rowLimit: Int, remote: Bool,
                               directoryNotFound: Bool = false, now: Date = Date(),
                               isDirectory: (String) -> Bool = ProcessDirectory.isDirectory) -> DurableSessionState? {
        guard let state = read(sessionID), now.timeIntervalSince(state.savedAt) <= Self.lifetime else {
            launch.replay = RestoreSeparator.line(savedAt: nil, reason: .sessionEnded, directoryNotFound: directoryNotFound)
            return nil
        }
        let target = ProcessDirectory.restoreTarget(state.directory?.path ?? state.launch.workingDirectory,
                                                    isDirectory: isDirectory)
        if let path = target.path { launch.workingDirectory = path }
        launch.replay = replay(for: state, rowLimit: rowLimit, remote: remote, directoryNotFound: target.notFound)
        return state
    }
}
