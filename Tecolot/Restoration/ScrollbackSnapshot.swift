//
//  ScrollbackSnapshot.swift
//  Tecolot
//
//  The copy of a local pane's text at quit. The conversion to the rows of a
//  scrollback file is ScrollbackCapture in TecolotSessionHost, which the
//  helper also uses for persistent sessions.
//

import Foundation
import os
import SwiftTerm
import TecolotSessionDirectory
import TecolotSessionHost

nonisolated enum ScrollbackSnapshot {
    /// A copy of a pane, made on the main thread at quit. Encoding it runs
    /// on a background queue.
    struct Pending: Sendable {
        let paneID: UUID
        let snapshot: TerminalContentSnapshot
        let alternateScreenProgram: String?
        let limit: Int

        /// The file, or nil when no row is left to restore.
        func encode(savedAt: Date) -> Data? {
            let rows = ScrollbackCapture.rows(snapshot, limit: limit)
            guard !rows.isEmpty || alternateScreenProgram != nil else { return nil }
            return ScrollbackCapture.encode(rows, of: snapshot, paneID: paneID.uuidString, savedAt: savedAt,
                                            alternateScreenProgram: alternateScreenProgram)
        }
    }
}

/// Finds the directory that a restored shell starts in, without blocking:
/// a path on a network volume or a removable disk can take a long time.
nonisolated enum RestoreDirectoryCheck {
    struct Result: Equatable, Sendable {
        /// The directory, or nil for the profile directory.
        var path: String?
        /// The saved directory was not found (or did not answer in time).
        var notFound: Bool
    }

    static func resolve(_ path: String?, timeout: TimeInterval = 1,
                        isDirectory: @escaping @Sendable (String) -> Bool = ProcessDirectory.isDirectory) async -> Result {
        guard let path else { return Result(path: nil, notFound: false) }
        let found: ProcessDirectory.RestoreTarget? = await withCheckedContinuation { continuation in
            let done = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (ProcessDirectory.RestoreTarget?) -> Void = { value in
                let first = done.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: value) }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                finish(ProcessDirectory.restoreTarget(path, isDirectory: isDirectory))
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
        guard let found else { return Result(path: nil, notFound: true) }
        return Result(path: found.path, notFound: found.notFound)
    }
}
