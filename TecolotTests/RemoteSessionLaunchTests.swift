import Foundation
import Testing
@testable import Tecolot

struct RemoteSessionLaunchTests {
    @Test func launchUsesRemoteShellAndTerminalEnvironment() {
        var profile = TerminalProfile(name: "Remote Test")
        profile.shell = .command("/usr/bin/false", runInShell: false)
        profile.termName = "local-term"
        profile.columns = 97
        profile.rows = 31
        profile.scrollbackLines = 4321
        profile.cursorStyle = .steadyBar
        profile.environmentVariables = [TerminalEnvironmentVariable(name: "PATH", value: "/local/bin")]
        let launch = PersistentSessions.makeRemoteLaunch(
            profile: profile,
            destination: "user@host",
            parentEnvironment: ["PATH": "/mac/bin", "LANG": "fr_FR.UTF-8", "TERM_PROGRAM": "parent"]
        )
        #expect(launch.command == nil)
        #expect(launch.workingDirectory == nil)
        #expect(launch.termName == "xterm-256color")
        #expect(launch.columns == 97 && launch.rows == 31)
        #expect(launch.scrollback == 4321 && launch.cursorStyle == 5)
        #expect(launch.environment.contains("COLORTERM=truecolor"))
        #expect(launch.environment.contains("LANG=fr_FR.UTF-8"))
        #expect(launch.environment.contains("TERM_PROGRAM=tecolot"))
        #expect(launch.environment.contains("TERM_PROGRAM_VERSION=\(TecolotShellIntegration.terminalProgramVersion)"))
        #expect(launch.environment.contains("TERM_FEATURES=\(TerminalFeatureReporting.featureString)"))
        #expect(!launch.environment.contains {
            $0.hasPrefix("PATH=") || $0.hasPrefix("TERMINFO=")
        })
        #expect(launch.labels == ["profile": profile.name, "profileID": profile.id.uuidString, "destination": "user@host"])
        #expect(launch.kittyGraphicsStorageLimit != nil)
        #expect(launch.kittyGraphicsLocalMedia != nil)
    }

    @MainActor
    @Test func inheritedRemoteDirectoryReachesLaunchWithoutLocalLookup() throws {
        let suite = "RemoteLaunchInheritance-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = TerminalProfile(name: "Remote cwd")
        // This directory belongs to the remote host; the app must not resolve it locally.
        let directory = "/remote-only-\(UUID().uuidString)/build"
        let spec = WindowOpener.inheritedTabSpec(
            profileID: profile.id,
            workingDirectory: directory,
            remoteDestination: "studioultra.local",
            defaults: defaults
        )
        let launch = PersistentSessions.makeRemoteLaunch(
            profile: profile,
            destination: spec.remoteDestination!,
            workingDirectory: spec.workingDirectory,
            parentEnvironment: [:]
        )
        #expect(launch.workingDirectory == directory)
        #expect(launch.command == nil)
        #expect(launch.labels["destination"] == "studioultra.local")
        defaults.set(false, forKey: "newTabsUseCurrentDirectory")
        let fresh = WindowOpener.inheritedTabSpec(
            profileID: profile.id,
            workingDirectory: directory,
            remoteDestination: "studioultra.local",
            defaults: defaults
        )
        #expect(PersistentSessions.makeRemoteLaunch(
            profile: profile,
            destination: "studioultra.local",
            workingDirectory: fresh.workingDirectory
        ).workingDirectory == nil)
    }

    @Test func localeUsesTheLocalDefaultRule() {
        let profile = TerminalProfile(name: "Remote Test")
        #expect(PersistentSessions.makeRemoteLaunch(profile: profile, destination: "host", parentEnvironment: [:])
            .environment.contains("LANG=en_US.UTF-8"))
        #expect(!PersistentSessions.makeRemoteLaunch(profile: profile, destination: "host", parentEnvironment: ["LC_ALL": "C"])
            .environment.contains {
                $0.hasPrefix("LANG=")
            })
    }
}
