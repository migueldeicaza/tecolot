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
        let launch = PersistentSessions.makeRemoteLaunch(profile: profile, destination: "user@host",
            parentEnvironment: ["PATH": "/mac/bin", "LANG": "fr_FR.UTF-8", "TERM_PROGRAM": "parent"])
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
        #expect(!launch.environment.contains { $0.hasPrefix("PATH=") || $0.hasPrefix("TERMINFO=") })
        #expect(launch.labels == ["profile": profile.name, "profileID": profile.id.uuidString, "destination": "user@host"])
        #expect(launch.kittyGraphicsStorageLimit != nil)
        #expect(launch.kittyGraphicsLocalMedia != nil)
    }

    @Test func localeUsesTheLocalDefaultRule() {
        let profile = TerminalProfile(name: "Remote Test")
        #expect(PersistentSessions.makeRemoteLaunch(profile: profile, destination: "host", parentEnvironment: [:])
            .environment.contains("LANG=en_US.UTF-8"))
        #expect(!PersistentSessions.makeRemoteLaunch(profile: profile, destination: "host", parentEnvironment: ["LC_ALL": "C"])
            .environment.contains { $0.hasPrefix("LANG=") })
    }
}
