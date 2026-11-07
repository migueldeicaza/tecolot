import Foundation

/// Installs `teco` as a symlink to the app executable at a path that the
/// user picks.
nonisolated struct CommandLineToolInstaller {
    static let toolName = "teco"

    nonisolated enum Status: Equatable {
        case notInstalled
        /// `current` is false when the link points to another copy of Tecolot.
        case installed(link: URL, current: Bool)
    }

    nonisolated enum InstallError: LocalizedError {
        case occupied(URL)

        var errorDescription: String? {
            switch self {
            case .occupied(let url):
                "\(url.path) already exists and is not a link to Tecolot. Remove it, then try again."
            }
        }
    }

    var executable: URL
    var fileManager = FileManager.default

    /// The first folder the panel shows: /usr/local/bin when the user can
    /// write to it, otherwise ~/.local/bin.
    func defaultDirectory(home: URL) -> URL {
        let local = URL(fileURLWithPath: "/usr/local/bin")
        if fileManager.isWritableFile(atPath: local.path) { return local }
        return home.appendingPathComponent(".local/bin")
    }

    func status(link: URL?) -> Status {
        guard let link, isTecolotLink(link) else { return .notInstalled }
        let destination = try? fileManager.destinationOfSymbolicLink(atPath: link.path)
        return .installed(link: link, current: destination == executable.path)
    }

    func install(at link: URL) throws {
        try fileManager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? fileManager.attributesOfItem(atPath: link.path)) != nil {
            guard isTecolotLink(link) else { throw InstallError.occupied(link) }
            try fileManager.removeItem(at: link)
        }
        try fileManager.createSymbolicLink(at: link, withDestinationURL: executable)
    }

    func uninstall(link: URL) throws {
        guard isTecolotLink(link) else { return }
        try fileManager.removeItem(at: link)
    }

    /// A link counts as ours when it points to any Tecolot app executable,
    /// so moving or updating the app does not block a reinstall.
    func isTecolotLink(_ link: URL) -> Bool {
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else {
            return false
        }
        return destination.hasSuffix(".app/Contents/MacOS/\(executable.lastPathComponent)")
    }
}
