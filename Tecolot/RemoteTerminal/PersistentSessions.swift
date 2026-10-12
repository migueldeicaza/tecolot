//
//  PersistentSessions.swift
//  Tecolot
//
//  Creates, lists and ends persistent sessions on this Mac. Each session is
//  a tecolot-sessiond process that keeps running when its pane closes or the
//  app quits.
//

import Foundation
import SwiftTerm
import TecolotSessionDirectory
import TecolotTransport

enum PersistentSessionError: LocalizedError {
    case helperMissing

    var errorDescription: String? {
        switch self {
        case .helperMissing: return "The session helper (tecolot-sessiond) is missing from the application."
        }
    }
}

enum PersistentSessions {
    /// The helper next to the app executable.
    static var helperPath: String? {
        Bundle.main.url(forAuxiliaryExecutable: "tecolot-sessiond")?.path
    }

    static func directory() throws -> SessionDirectory {
        try SessionDirectory.standard()
    }

    /// The running sessions, oldest first.
    static func list() -> [SessionRecord] {
        (try? directory().list()) ?? []
    }

    /// Starts a new session for `profile`.
    static func create(profile: TerminalProfile, workingDirectory: String?,
                       columns: Int, rows: Int, cellWidth: Int, cellHeight: Int) throws -> SessionRecord {
        guard let helperPath else { throw PersistentSessionError.helperMissing }
        let launch = makeLaunch(profile: profile, workingDirectory: workingDirectory,
                                columns: columns, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight)
        return try directory().create(launch, helperPath: helperPath)
    }

    static func makeLaunch(profile: TerminalProfile, workingDirectory: String?,
                           columns: Int, rows: Int, cellWidth: Int, cellHeight: Int) -> SessionLaunch {
        var parameters = ProfileApplier.launchParameters(for: profile, initialDirectory: workingDirectory)
        // The shell outlives this copy of the app; Sparkle can replace the
        // bundle under it. Point its resources at a stable copy.
        if let runtime = PersistentRuntimeResources.prepare(),
           let bundle = Bundle.main.resourceURL?.path {
            parameters.environment = parameters.environment.map { $0.replacingOccurrences(of: bundle, with: runtime.path) }
            parameters.args = parameters.args.map { $0.replacingOccurrences(of: bundle, with: runtime.path) }
        }
        // The same image limits as a local pane.
        let kitty = ProfileApplier.terminalOptions(for: profile).kittyGraphics
        return SessionLaunch(executable: parameters.executable, arguments: parameters.args,
                             argv0: parameters.execName, environment: parameters.environment,
                             workingDirectory: parameters.currentDirectory,
                             columns: max(2, columns), rows: max(2, rows),
                             cellWidth: cellWidth, cellHeight: cellHeight,
                             scrollback: profile.scrollbackLines ?? 100_000,
                             termName: profile.termName,
                             cursorStyle: cursorStyleIndex(profile.cursorStyle),
                             featureReport: TerminalFeatureReporting.featureString,
                             labels: ["profile": profile.name, "profileID": profile.id.uuidString],
                             kittyGraphicsStorageLimit: kitty.storageLimitBytesPerScreen,
                             kittyGraphicsLocalMedia: kitty.localMediaPolicy.rawValue)
    }

    static func cursorStyleIndex(_ style: CursorStyle) -> UInt8 {
        switch style {
        case .blinkBlock: return 0
        case .steadyBlock: return 1
        case .blinkUnderline: return 2
        case .steadyUnderline: return 3
        case .blinkBar: return 4
        case .steadyBar: return 5
        }
    }

    static func cursorStyle(_ index: UInt8) -> CursorStyle {
        switch index {
        case 1: return .steadyBlock
        case 2: return .blinkUnderline
        case 3: return .steadyUnderline
        case 4: return .blinkBar
        case 5: return .steadyBar
        default: return .blinkBlock
        }
    }
}

/// Copies the resources that a shell reads while it runs (terminfo and the
/// shell integration) out of the app bundle, once per app version.
enum PersistentRuntimeResources {
    static func prepare() -> URL? {
        guard let bundle = Bundle.main.resourceURL else { return nil }
        let version = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.tirania.Tecolot")
            .appendingPathComponent("Runtime/\(version)", isDirectory: true)
        let manager = FileManager.default
        let marker = base.appendingPathComponent(".complete")
        if manager.fileExists(atPath: marker.path) { return base }
        do {
            try manager.createDirectory(at: base, withIntermediateDirectories: true)
            for name in ["terminfo", "shell-integration"] {
                let source = bundle.appendingPathComponent(name)
                let target = base.appendingPathComponent(name)
                guard manager.fileExists(atPath: source.path) else { continue }
                if manager.fileExists(atPath: target.path) {
                    try manager.removeItem(at: target)
                }
                try manager.copyItem(at: source, to: target)
            }
            manager.createFile(atPath: marker.path, contents: Data())
            return base
        } catch {
            return nil
        }
    }
}
