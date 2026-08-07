//
//  ProfileStore.swift
//  TerminalProfilesKit
//
//  Persists profiles as one JSON document per profile in Application
//  Support, plus a small store.json holding the default-profile pointer.
//  Files (not UserDefaults) so that import/export shares the on-disk
//  format and the documents stay human-diffable.
//
import Foundation

@MainActor
public final class ProfileStore: ObservableObject {
    /// All profiles, sorted by name
    @Published public private(set) var profiles: [TerminalProfile] = []
    /// The profile used for new windows unless one is chosen explicitly
    @Published public private(set) var defaultProfileID: TerminalProfile.ID

    private let directory: URL
    private let profilesDirectory: URL
    private let stateFile: URL

    private struct StoreState: Codable {
        var version: Int
        var defaultProfileID: UUID
    }

    nonisolated static let documentVersion = 1

    /// - Parameters:
    ///   - directory: overrides the storage location (for tests); nil uses
    ///     Application Support/<bundle id>
    ///   - seedDefault: creates a "Default" profile on first run
    public init (directory: URL? = nil, seedDefault: Bool = true) throws {
        let base = directory ?? ProfileStore.defaultDirectory ()
        self.directory = base
        self.profilesDirectory = base.appendingPathComponent ("Profiles")
        self.stateFile = base.appendingPathComponent ("store.json")

        try FileManager.default.createDirectory (at: profilesDirectory, withIntermediateDirectories: true)

        var loaded = ProfileStore.loadProfiles (in: profilesDirectory)
        if loaded.isEmpty && seedDefault {
            let seeded = TerminalProfile (name: "Default")
            try ProfileStore.write (profile: seeded, in: profilesDirectory)
            loaded = [seeded]
        }
        self.profiles = ProfileStore.sorted (loaded)

        if let data = try? Data (contentsOf: stateFile),
           let state = try? JSONDecoder ().decode (StoreState.self, from: data),
           loaded.contains (where: { $0.id == state.defaultProfileID }) {
            self.defaultProfileID = state.defaultProfileID
        } else {
            self.defaultProfileID = loaded.first?.id ?? UUID ()
            try persistState ()
        }
    }

    nonisolated static func defaultDirectory () -> URL {
        let appSupport = FileManager.default.urls (for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleId = Bundle.main.bundleIdentifier ?? "TerminalProfilesKit"
        return appSupport.appendingPathComponent (bundleId)
    }

    // MARK: - Lookup

    public var defaultProfile: TerminalProfile {
        profile (withID: defaultProfileID) ?? profiles.first ?? TerminalProfile (name: "Default")
    }

    public func profile (withID id: TerminalProfile.ID) -> TerminalProfile? {
        profiles.first { $0.id == id }
    }

    public func profile (named name: String) -> TerminalProfile? {
        profiles.first { $0.name == name }
    }

    // MARK: - Mutation

    public func setDefault (_ id: TerminalProfile.ID) throws {
        guard profile (withID: id) != nil else {
            throw ProfilesError.profileNotFound
        }
        defaultProfileID = id
        try persistState ()
    }

    public func add (_ profile: TerminalProfile) throws {
        guard self.profile (named: profile.name) == nil else {
            throw ProfilesError.duplicateName
        }
        try ProfileStore.write (profile: profile, in: profilesDirectory)
        profiles = ProfileStore.sorted (profiles + [profile])
    }

    public func update (_ profile: TerminalProfile) throws {
        guard let index = profiles.firstIndex (where: { $0.id == profile.id }) else {
            throw ProfilesError.profileNotFound
        }
        if let sameName = self.profile (named: profile.name), sameName.id != profile.id {
            throw ProfilesError.duplicateName
        }
        try ProfileStore.write (profile: profile, in: profilesDirectory)
        var updated = profiles
        updated [index] = profile
        profiles = ProfileStore.sorted (updated)
    }

    @discardableResult
    public func duplicate (_ id: TerminalProfile.ID) throws -> TerminalProfile {
        guard let source = profile (withID: id) else {
            throw ProfilesError.profileNotFound
        }
        var copy = source
        copy.id = UUID ()
        copy.name = uniqueName (basedOn: source.name)
        try add (copy)
        return copy
    }

    public func rename (_ id: TerminalProfile.ID, to newName: String) throws {
        guard var target = profile (withID: id) else {
            throw ProfilesError.profileNotFound
        }
        target.name = newName
        try update (target)
    }

    public func delete (_ id: TerminalProfile.ID) throws {
        guard profiles.count > 1 else {
            throw ProfilesError.cannotDeleteLastProfile
        }
        guard let target = profile (withID: id) else {
            throw ProfilesError.profileNotFound
        }
        try? FileManager.default.removeItem (at: ProfileStore.url (for: target, in: profilesDirectory))
        profiles.removeAll { $0.id == id }
        if defaultProfileID == id {
            defaultProfileID = profiles.first!.id
            try persistState ()
        }
    }

    // MARK: - Import / export

    @discardableResult
    public func importProfile (from url: URL) throws -> TerminalProfile {
        let data = try Data (contentsOf: url)
        let document = try JSONDecoder ().decode (ProfileDocument.self, from: data)
        var incoming = document.profile
        if profile (withID: incoming.id) != nil {
            incoming.id = UUID ()
        }
        if profile (named: incoming.name) != nil {
            incoming.name = uniqueName (basedOn: incoming.name)
        }
        try add (incoming)
        return incoming
    }

    public func exportProfile (_ id: TerminalProfile.ID, to url: URL) throws {
        guard let target = profile (withID: id) else {
            throw ProfilesError.profileNotFound
        }
        let encoder = JSONEncoder ()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode (ProfileDocument (version: ProfileStore.documentVersion, profile: target))
        try data.write (to: url, options: .atomic)
    }

    // MARK: - Helpers

    func uniqueName (basedOn base: String) -> String {
        var candidate = "\(base) copy"
        var counter = 2
        while profile (named: candidate) != nil {
            candidate = "\(base) copy \(counter)"
            counter += 1
        }
        return candidate
    }

    private func persistState () throws {
        let state = StoreState (version: ProfileStore.documentVersion, defaultProfileID: defaultProfileID)
        let data = try JSONEncoder ().encode (state)
        try data.write (to: stateFile, options: .atomic)
    }

    nonisolated static func sorted (_ profiles: [TerminalProfile]) -> [TerminalProfile] {
        profiles.sorted { $0.name.localizedCaseInsensitiveCompare ($1.name) == .orderedAscending }
    }

    nonisolated static func url (for profile: TerminalProfile, in directory: URL) -> URL {
        directory.appendingPathComponent ("\(profile.id.uuidString).json")
    }

    nonisolated static func write (profile: TerminalProfile, in directory: URL) throws {
        let encoder = JSONEncoder ()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode (ProfileDocument (version: documentVersion, profile: profile))
        try data.write (to: url (for: profile, in: directory), options: .atomic)
    }

    nonisolated static func loadProfiles (in directory: URL) -> [TerminalProfile] {
        guard let files = try? FileManager.default.contentsOfDirectory (at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = JSONDecoder ()
        var result: [TerminalProfile] = []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data (contentsOf: file),
               let document = try? decoder.decode (ProfileDocument.self, from: data) {
                result.append (document.profile)
            }
        }
        return result
    }
}
