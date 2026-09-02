import Combine
import Foundation

private struct ProfileStoreStateV1: Codable {
    var version: Int
    var defaultProfileID: UUID
}

private struct ProfileDocumentMigrator: VersionedDocumentMigrator {
    let currentVersion = 1

    func sourceVersion(in data: Data) throws -> Int {
        try PersistenceVersionProbe.requiredVersion(in: data)
    }

    func decode(_ data: Data, from sourceVersion: Int) throws -> TerminalProfile {
        guard sourceVersion == 1 else {
            throw VersionedPersistenceError.invalidDocument("Unsupported profile schema.")
        }
        return try JSONDecoder().decode(ProfileDocument.self, from: data).profile
    }

    func validate(_ profile: TerminalProfile) throws {
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              profile.fontSize.isFinite,
              profile.fontSize > 0,
              profile.backgroundOpacity.isFinite,
              (0...1).contains(profile.backgroundOpacity),
              profile.columns > 0,
              profile.rows > 0 else {
            throw VersionedPersistenceError.invalidDocument("The profile contains invalid values.")
        }
    }

    func encodeCurrent(_ profile: TerminalProfile) throws -> Data {
        try ProfileStore.encodedProfile(profile)
    }
}

private struct ProfileStoreStateMigrator: VersionedDocumentMigrator {
    let currentVersion = 1

    func sourceVersion(in data: Data) throws -> Int {
        try PersistenceVersionProbe.requiredVersion(in: data)
    }

    func decode(_ data: Data, from sourceVersion: Int) throws -> ProfileStoreStateV1 {
        guard sourceVersion == 1 else {
            throw VersionedPersistenceError.invalidDocument("Unsupported profile-store schema.")
        }
        return try JSONDecoder().decode(ProfileStoreStateV1.self, from: data)
    }

    func validate(_ value: ProfileStoreStateV1) throws {}

    func encodeCurrent(_ value: ProfileStoreStateV1) throws -> Data {
        try JSONEncoder().encode(value)
    }
}

@MainActor
public final class ProfileStore: ObservableObject {
    @Published public private(set) var profiles: [TerminalProfile] = []
    @Published public private(set) var defaultProfileID: TerminalProfile.ID

    private var profilesDirectory: URL
    private var stateFile: URL
    private var backupDirectory: URL
    private let issueCenter: PersistenceIssueCenter?
    private var storeStateIsReadOnly = false

    nonisolated static let documentVersion = 1
    private nonisolated static let builtInDefaultProfile = TerminalProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Default"
    )

    public init(
        directory: URL? = nil,
        issueCenter: PersistenceIssueCenter? = nil,
        backupDirectory: URL? = nil
    ) throws {
        let base = directory ?? ProfileStore.defaultDirectory()
        profilesDirectory = base.appendingPathComponent("Profiles")
        stateFile = base.appendingPathComponent("store.json")
        self.backupDirectory = backupDirectory ?? base.appendingPathComponent("Backups")
        self.issueCenter = issueCenter
        defaultProfileID = ProfileStore.builtInDefaultProfile.id

        try FileManager.default.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
        try loadAndCreateDefaultProfileIfNeeded()
    }

    /// Reconnects this store to its persistent location after the app used
    /// temporary storage during a recoverable startup failure.
    public func useStorage(directory: URL, backupDirectory: URL? = nil) throws {
        let profilesDirectory = directory.appendingPathComponent("Profiles")
        try FileManager.default.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
        self.profilesDirectory = profilesDirectory
        stateFile = directory.appendingPathComponent("store.json")
        self.backupDirectory = backupDirectory ?? directory.appendingPathComponent("Backups")
        try loadAndCreateDefaultProfileIfNeeded()
    }

    nonisolated static func defaultDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "com.tirania.Tecolot"
        return appSupport.appendingPathComponent(bundleID)
    }

    public var defaultProfile: TerminalProfile {
        profile(withID: defaultProfileID) ?? profiles.first ?? ProfileStore.builtInDefaultProfile
    }

    public func profile(withID id: TerminalProfile.ID) -> TerminalProfile? {
        profiles.first { $0.id == id }
    }

    public func profile(named name: String) -> TerminalProfile? {
        profiles.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    public func reload() {
        try? loadAndCreateDefaultProfileIfNeeded()
    }

    private func loadAndCreateDefaultProfileIfNeeded() throws {
        let stateResult = VersionedFileLoader.load(
            from: stateFile,
            domain: .profileStore,
            backupRoot: backupDirectory,
            migrator: ProfileStoreStateMigrator()
        )
        storeStateIsReadOnly = stateResult.issue != nil
        issueCenter?.replaceIssues(
            in: .profileStore,
            with: stateResult.issue.map { [$0] } ?? []
        )

        let loaded = loadProfiles()
        let repaired = repairDuplicateNames(
            in: loaded.values,
            preferredID: stateResult.value?.defaultProfileID
        )
        profiles = ProfileStore.sorted(repaired.profiles)
        issueCenter?.replaceIssues(in: .profiles, with: loaded.issues + repaired.issues)

        if let storedID = stateResult.value?.defaultProfileID,
           profiles.contains(where: { $0.id == storedID }) {
            defaultProfileID = storedID
        } else {
            defaultProfileID = profiles.first?.id ?? ProfileStore.builtInDefaultProfile.id
        }

        let loadedWithoutIssues = stateResult.issue == nil
            && loaded.issues.isEmpty
            && repaired.issues.isEmpty
        if profiles.isEmpty && loadedWithoutIssues {
            try add(ProfileStore.builtInDefaultProfile)
        }
    }

    public func setDefault(_ id: TerminalProfile.ID) throws {
        try ensureStoreStateIsWritable()
        guard profile(withID: id) != nil else { throw ProfilesError.profileNotFound }
        let oldID = defaultProfileID
        defaultProfileID = id
        do {
            try persistState()
            issueCenter?.resolve(domain: .profileStore, sourceURL: stateFile)
        } catch {
            defaultProfileID = oldID
            reportWriteFailure(error, domain: .profileStore, sourceURL: stateFile)
            throw error
        }
    }

    public func add(_ profile: TerminalProfile) throws {
        try validateForMutation(profile)
        guard self.profile(named: profile.name) == nil else { throw ProfilesError.duplicateName }
        if profiles.isEmpty {
            try ensureStoreStateIsWritable()
        }
        let url = ProfileStore.url(for: profile, in: profilesDirectory)
        do {
            try ProfileStore.write(profile: profile, in: profilesDirectory)
            issueCenter?.resolve(domain: .profiles, sourceURL: url)
        } catch {
            reportWriteFailure(error, domain: .profiles, sourceURL: url)
            throw error
        }

        let wasEmpty = profiles.isEmpty
        profiles = ProfileStore.sorted(profiles + [profile])
        if wasEmpty {
            defaultProfileID = profile.id
            do {
                try persistState()
            } catch {
                reportWriteFailure(error, domain: .profileStore, sourceURL: stateFile)
                throw error
            }
        }
    }

    public func update(_ profile: TerminalProfile) throws {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            throw ProfilesError.profileNotFound
        }
        try validateForMutation(profile)
        if let sameName = self.profile(named: profile.name), sameName.id != profile.id {
            throw ProfilesError.duplicateName
        }
        let url = ProfileStore.url(for: profile, in: profilesDirectory)
        do {
            try ProfileStore.write(profile: profile, in: profilesDirectory)
            issueCenter?.resolve(domain: .profiles, sourceURL: url)
        } catch {
            reportWriteFailure(error, domain: .profiles, sourceURL: url)
            throw error
        }
        var updated = profiles
        updated[index] = profile
        profiles = ProfileStore.sorted(updated)
    }

    @discardableResult
    public func duplicate(_ id: TerminalProfile.ID) throws -> TerminalProfile {
        guard var copy = profile(withID: id) else { throw ProfilesError.profileNotFound }
        copy.id = UUID()
        copy.name = uniqueName(basedOn: copy.name)
        try add(copy)
        return copy
    }

    public func rename(_ id: TerminalProfile.ID, to newName: String) throws {
        guard var target = profile(withID: id) else { throw ProfilesError.profileNotFound }
        target.name = newName
        try update(target)
    }

    public func delete(_ id: TerminalProfile.ID) throws {
        guard profiles.count > 1 else { throw ProfilesError.cannotDeleteLastProfile }
        guard let target = profile(withID: id) else { throw ProfilesError.profileNotFound }
        if defaultProfileID == id {
            try ensureStoreStateIsWritable()
        }
        let url = ProfileStore.url(for: target, in: profilesDirectory)
        do {
            try FileManager.default.removeItem(at: url)
            issueCenter?.resolve(domain: .profiles, sourceURL: url)
        } catch {
            reportWriteFailure(error, domain: .profiles, sourceURL: url)
            throw error
        }
        profiles.removeAll { $0.id == id }
        if defaultProfileID == id {
            defaultProfileID = profiles.first!.id
            try persistState()
        }
    }

    @discardableResult
    public func importProfile(from url: URL) throws -> TerminalProfile {
        let data = try Data(contentsOf: url)
        let migrator = ProfileDocumentMigrator()
        let sourceVersion = try migrator.sourceVersion(in: data)
        guard sourceVersion <= migrator.currentVersion else {
            throw VersionedPersistenceError.unsupportedVersion(
                found: sourceVersion,
                supported: migrator.currentVersion
            )
        }
        var incoming = try migrator.decode(data, from: sourceVersion)
        try migrator.validate(incoming)
        if profile(withID: incoming.id) != nil { incoming.id = UUID() }
        if profile(named: incoming.name) != nil { incoming.name = uniqueName(basedOn: incoming.name) }
        try add(incoming)
        return incoming
    }

    public func exportProfile(_ id: TerminalProfile.ID, to url: URL) throws {
        guard let target = profile(withID: id) else { throw ProfilesError.profileNotFound }
        try ProfileStore.encodedProfile(target).write(to: url, options: .atomic)
    }

    func uniqueName(basedOn base: String) -> String {
        var candidate = "\(base) copy"
        var counter = 2
        while profile(named: candidate) != nil {
            candidate = "\(base) copy \(counter)"
            counter += 1
        }
        return candidate
    }

    private func validateForMutation(_ profile: TerminalProfile) throws {
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProfilesError.invalidName
        }
        try ProfileDocumentMigrator().validate(profile)
    }

    private func persistState() throws {
        let state = ProfileStoreStateV1(version: Self.documentVersion, defaultProfileID: defaultProfileID)
        let data = try JSONEncoder().encode(state)
        try data.write(to: stateFile, options: .atomic)
    }

    private func ensureStoreStateIsWritable() throws {
        guard !storeStateIsReadOnly else {
            throw PersistenceMutationError.recoveryRequired(.profileStore)
        }
    }

    nonisolated static func sorted(_ profiles: [TerminalProfile]) -> [TerminalProfile] {
        profiles.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    nonisolated static func url(for profile: TerminalProfile, in directory: URL) -> URL {
        directory.appendingPathComponent("\(profile.id.uuidString).json")
    }

    nonisolated static func encodedProfile(_ profile: TerminalProfile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(ProfileDocument(version: documentVersion, profile: profile))
    }

    nonisolated static func write(profile: TerminalProfile, in directory: URL) throws {
        try encodedProfile(profile).write(to: url(for: profile, in: directory), options: .atomic)
    }

    private func loadProfiles() -> (values: [TerminalProfile], issues: [PersistenceIssue]) {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: profilesDirectory,
                includingPropertiesForKeys: nil
            )
        } catch {
            return ([], [PersistenceIssue(
                domain: .profiles,
                sourceURL: profilesDirectory,
                kind: .unreadable,
                message: error.localizedDescription,
                supportedVersion: Self.documentVersion
            )])
        }
        var values: [TerminalProfile] = []
        var issues: [PersistenceIssue] = []
        for file in files where file.pathExtension == "json" {
            let result = VersionedFileLoader.load(
                from: file,
                domain: .profiles,
                backupRoot: backupDirectory,
                migrator: ProfileDocumentMigrator()
            )
            if let profile = result.value { values.append(profile) }
            if let issue = result.issue { issues.append(issue) }
        }
        return (values, issues)
    }

    private func repairDuplicateNames(
        in profiles: [TerminalProfile],
        preferredID: TerminalProfile.ID?
    ) -> (profiles: [TerminalProfile], issues: [PersistenceIssue]) {
        let ordered = profiles.sorted { first, second in
            if first.id == preferredID { return true }
            if second.id == preferredID { return false }
            return first.id.uuidString < second.id.uuidString
        }
        var usedNames = Set<String>()
        var repaired: [TerminalProfile] = []
        var issues: [PersistenceIssue] = []

        for var profile in ordered {
            let baseName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let validBaseName = baseName.isEmpty ? "Recovered Profile" : baseName
            var candidate = validBaseName
            var counter = 1
            while usedNames.contains(normalizedName(candidate)) {
                candidate = counter == 1 ? "\(validBaseName) copy" : "\(validBaseName) copy \(counter)"
                counter += 1
            }
            usedNames.insert(normalizedName(candidate))
            if profile.name != candidate {
                let sourceURL = ProfileStore.url(for: profile, in: profilesDirectory)
                do {
                    let backupURL = try PersistenceBackups.createIfNeeded(
                        for: sourceURL,
                        domain: .profiles,
                        sourceVersion: Self.documentVersion,
                        root: backupDirectory
                    )
                    profile.name = candidate
                    try ProfileStore.write(profile: profile, in: profilesDirectory)
                    _ = backupURL
                } catch {
                    profile.name = candidate
                    issues.append(PersistenceIssue(
                        domain: .profiles,
                        sourceURL: sourceURL,
                        kind: .migrationFailed,
                        message: "The duplicate profile was renamed in memory, but the repair could not be saved: \(error.localizedDescription)",
                        foundVersion: Self.documentVersion,
                        supportedVersion: Self.documentVersion
                    ))
                }
            }
            repaired.append(profile)
        }
        return (repaired, issues)
    }

    private func normalizedName(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func reportWriteFailure(_ error: Error, domain: PersistenceDomain, sourceURL: URL) {
        issueCenter?.report(PersistenceIssue(
            domain: domain,
            sourceURL: sourceURL,
            kind: .writeFailed,
            message: error.localizedDescription,
            supportedVersion: Self.documentVersion
        ))
    }
}
