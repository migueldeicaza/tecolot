import Foundation
import Testing
@testable import Tecolot
import TecolotSessionClient

struct RemoteDestinationTests {
    @Test func destinationValidation() throws {
        for destination in ["server", "user@server", "build-host", "user@[::1]"] {
            try SSHConfiguration.validate(destination)
        }
        for destination in ["", "-server", "user name@server", "server\n", "server\0"] {
            #expect(throws: SSHConfigurationError.invalidDestination) {
                try SSHConfiguration.validate(destination)
            }
        }
    }

    @Test func recentDestinationsMoveToFrontAndHaveALimit() throws {
        let suite = "RemoteDestinationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recent = RecentRemoteDestinations(defaults: defaults)
        for index in 0..<25 { recent.record("host\(index)") }
        #expect(recent.destinations.count == RecentRemoteDestinations.limit)
        #expect(recent.destinations.first == "host24")
        #expect(recent.destinations.last == "host15")
        recent.record("host10")
        #expect(recent.destinations.first == "host10")
        #expect(recent.destinations.filter { $0 == "host10" }.count == 1)
        recent.record("-invalid")
        #expect(recent.destinations.first == "host10")
    }

    @MainActor
    @Test func newTabInheritsRemoteHostWithoutLocalDirectory() throws {
        let suite = "RemoteDestinationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profileID = UUID()
        let remote = WindowOpener.inheritedTabSpec(profileID: profileID, workingDirectory: "/remote/path",
                                                  remoteDestination: "host", defaults: defaults)
        #expect(remote.profileID == profileID)
        #expect(remote.remoteDestination == "host")
        #expect(remote.workingDirectory == nil)
        #expect(remote.persistent)
        let local = WindowOpener.inheritedTabSpec(profileID: profileID, workingDirectory: "/local/path",
                                                 remoteDestination: nil, defaults: defaults)
        #expect(local.workingDirectory == "/local/path")
        #expect(!local.persistent)
        defaults.set(false, forKey: "newTabsUseCurrentProfile")
        defaults.set(false, forKey: "newTabsUseCurrentDirectory")
        let noProfile = WindowOpener.inheritedTabSpec(profileID: profileID, workingDirectory: "/remote/path",
                                                     remoteDestination: "host", defaults: defaults)
        #expect(noProfile.profileID == nil)
        #expect(noProfile.remoteDestination == "host")
        #expect(noProfile.workingDirectory == nil)
    }

    @Test func recentDestinationsFilterInvalidSavedValues() throws {
        let suite = "RemoteDestinationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["host", "host", "-option", "has space", "other"],
                     forKey: RecentRemoteDestinations.key)
        #expect(RecentRemoteDestinations(defaults: defaults).destinations == ["host", "other"])
    }
}
