import Foundation
import Testing
import TecolotSessionDirectory

struct RemoteSessionLaunchTests {
    let user = RemoteUserInfo(name: "remote-user", home: "/home/remote-user", shell: "/bin/zsh")

    @Test func loginShellUsesRemoteAccountAndCleanBaseEnvironment() {
        let base = ["HOME": "/Users/local", "USER": "local", "LOGNAME": "local", "SHELL": "/bin/local",
                    "SSH_TTY": "/dev/pts/1", "TERM": "old", "PWD": "/old", "OLDPWD": "/older",
                    "SHLVL": "4", "_": "/bin/old", "TECOLOT_BRIDGE_NONCE": "secret",
                    "TECOLOT_BRIDGE_BUILD": "old", "PATH": "/remote/bin", "LANG": "en_US.UTF-8",
                    "SSH_CONNECTION": "connection", "SSH_CLIENT": "client", "SSH_AUTH_SOCK": "/agent"]
        let resolved = RemoteSessionLaunch().resolve(passwd: user, bridgeEnvironment: base, directoryExists: { _ in false })
        #expect(resolved.executable == "/bin/zsh")
        #expect(resolved.argv0 == "-zsh")
        #expect(resolved.arguments.isEmpty)
        #expect(resolved.workingDirectory == user.home)
        let values = environment(resolved)
        #expect(values["HOME"] == user.home)
        #expect(values["USER"] == user.name)
        #expect(values["LOGNAME"] == user.name)
        #expect(values["SHELL"] == user.shell)
        #expect(values["TERM"] == "xterm-256color")
        #expect(values["PATH"] == "/remote/bin")
        #expect(values["LANG"] == "en_US.UTF-8")
        #expect(values["SSH_CONNECTION"] == "connection")
        #expect(values["SSH_CLIENT"] == "client")
        #expect(values["SSH_AUTH_SOCK"] == "/agent")
        for name in ["SSH_TTY", "PWD", "OLDPWD", "SHLVL", "_", "TECOLOT_BRIDGE_NONCE", "TECOLOT_BRIDGE_BUILD"] {
            #expect(values[name] == nil)
        }
    }

    @Test func overlaysApplyBeforeUnsetsAndTermIsFinal() {
        let launch = RemoteSessionLaunch(command: "printf '%s' hello", environment: [
            "PATH=/profile/bin", "CUSTOM=one=two", "LANG=fr_FR.UTF-8", "TERM=ignored",
            "DROP=new", "BAD", "=missing-name",
        ], unset: ["DROP", "LANG", "TERM"], workingDirectory: "/remote/project", termName: "custom-term")
        let resolved = launch.resolve(passwd: user, bridgeEnvironment: ["DROP": "old", "LANG": "old"],
                                      directoryExists: { $0 == "/remote/project" })
        #expect(resolved.arguments == ["-c", "printf '%s' hello"])
        #expect(resolved.workingDirectory == "/remote/project")
        let values = environment(resolved)
        #expect(values["PATH"] == "/profile/bin")
        #expect(values["CUSTOM"] == "one=two")
        #expect(values["DROP"] == nil)
        #expect(values["LANG"] == nil)
        #expect(values["TERM"] == "custom-term")
        #expect(values["BAD"] == nil)
        #expect(values[""] == nil)
        #expect(resolved.environment == resolved.environment.sorted())
    }

    @Test func missingDirectoryAndEmptyAccountShellUseDefaults() {
        let launch = RemoteSessionLaunch(workingDirectory: "/missing")
        let resolved = launch.resolve(passwd: RemoteUserInfo(name: "user", home: "/home/user", shell: ""),
                                      bridgeEnvironment: [:], directoryExists: { _ in false })
        #expect(resolved.executable == "/bin/sh")
        #expect(resolved.argv0 == "-sh")
        #expect(environment(resolved)["SHELL"] == "/bin/sh")
        #expect(resolved.workingDirectory == "/home/user")
    }

    @Test func launchCodableAndAppearanceArePreserved() throws {
        let theme = SessionTheme(palette: [], foreground: WireRGBCodable(r: 1, g: 2, b: 3),
                                 background: WireRGBCodable(r: 4, g: 5, b: 6))
        let request = RemoteSessionLaunch(command: "echo hi", environment: ["NAME=value"], unset: ["DROP"],
                                          columns: 132, rows: 40, cellWidth: 9, cellHeight: 18,
                                          scrollback: 1234, termName: "custom", cursorStyle: 4,
                                          featureReport: "feature", theme: theme, labels: ["profile": "Remote"],
                                          kittyGraphicsStorageLimit: 123, kittyGraphicsLocalMedia: 2)
        let bytes = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(RemoteSessionLaunch.self, from: bytes)
        #expect(decoded == request)
        let resolved = decoded.resolve(passwd: user, bridgeEnvironment: [:], directoryExists: { _ in false })
        #expect(resolved.columns == 132)
        #expect(resolved.rows == 40)
        #expect(resolved.cellWidth == 9)
        #expect(resolved.cellHeight == 18)
        #expect(resolved.scrollback == 1234)
        #expect(resolved.termName == "custom")
        #expect(resolved.cursorStyle == 4)
        #expect(resolved.featureReport == "feature")
        #expect(resolved.theme == theme)
        #expect(resolved.labels == ["profile": "Remote"])
        #expect(resolved.kittyGraphicsStorageLimit == 123)
        #expect(resolved.kittyGraphicsLocalMedia == 2)
    }

    private func environment(_ launch: SessionLaunch) -> [String: String] {
        Dictionary(uniqueKeysWithValues: launch.environment.map { entry in
            let split = entry.firstIndex(of: "=")!
            return (String(entry[..<split]), String(entry[entry.index(after: split)...]))
        })
    }
}
