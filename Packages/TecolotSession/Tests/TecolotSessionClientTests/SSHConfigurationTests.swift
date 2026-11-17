import Foundation
import Testing
@testable import TecolotSessionClient
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private func sshFixture(_ extra: String = "") throws -> SSHConfiguration {
    try SSHConfiguration(destination: "work", output: """
    user alice
    hostname server.example
    port 2222
    controlpath none
    forwardagent yes
    serveraliveinterval 0
    serveralivecountmax 0
    proxyjump none
    proxycommand none
    \(extra)
    """)
}

struct SSHConfigurationTests {
    @Test func parsesEffectiveConfiguration() throws {
        let config = try sshFixture("IdentityFile ~/.ssh/id_one\nidentityfile ~/.ssh/id_two\nsetenv FIRST=one SECOND=two")
        #expect(config.hostKey == "alice@server.example:2222")
        #expect(config.values["identityfile"] == ["~/.ssh/id_one", "~/.ssh/id_two"])
        #expect(config.values["setenv"] == ["FIRST=one SECOND=two"])
        #expect(config.controlPath == nil)
        #expect(config.proxyJump == nil)
        #expect(config.proxyCommand == nil)
        #expect(config.forwardAgent)
    }

    @Test func rejectsOptionsAndBadPort() {
        #expect(throws: SSHConfigurationError.invalidDestination) {
            try SSHConfiguration(destination: "-Fbad", output: "user a\nhostname b\nport 22")
        }
        #expect(throws: SSHConfigurationError.invalidOutput) {
            try SSHConfiguration(destination: "work", output: "user a\nhostname b\nport 70000")
        }
    }

    @Test func resolvesWithConfiguredExecutableAndEnvironment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fake-ssh")
        try """
        #!/bin/sh
        test "$1" = -G && test "$2" = work || exit 9
        i=0
        while test "$i" -lt 4096; do
            printf 'identityfile /test/repeated_identity_file\\n'
            printf 'A test message that fills the stderr pipe buffer.\\n' >&2
            i=$((i + 1))
        done
        printf 'user %s\\nhostname server.example\\nport 22\\n' "$TEST_SSH_USER"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let config = try SSHConfiguration.resolve(destination: "work", sshPath: script.path,
                                                   environment: ["TEST_SSH_USER": "remote"])
        #expect(config.user == "remote")
        #expect(config.values["identityfile"]?.count == 4096)
    }

    @Test func aliasesFollowIncludesInOrderAndStopCycles() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ssh = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh.appendingPathComponent("parts"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let config = ssh.appendingPathComponent("config")
        try """
        Host first *.example ?test !excluded
        Include parts/*.conf
        Host after first
        Match exec true
          Include hidden.conf
        Host last
        Include ~/.ssh/end.conf
        """.write(to: config, atomically: true, encoding: .utf8)
        try "Host second\nInclude config\n".write(to: ssh.appendingPathComponent("parts/a.conf"), atomically: true, encoding: .utf8)
        try "Host = \"third\" second # comment\n".write(to: ssh.appendingPathComponent("parts/b.conf"), atomically: true, encoding: .utf8)
        try "Host hidden\n".write(to: ssh.appendingPathComponent("hidden.conf"), atomically: true, encoding: .utf8)
        try "Host end\n".write(to: ssh.appendingPathComponent("end.conf"), atomically: true, encoding: .utf8)
        #expect(try SSHHostAliases.list(configURL: config) == ["first", "second", "third", "after", "last", "end"])
    }

    @Test func buildsMasterAndClientArguments() throws {
        let builder = SSHCommandLine(configuration: try sshFixture(), extraOptions: ["LogLevel=DEBUG"])
        #expect(builder.master(controlPath: "/private/socket") == [
            "-M", "-N", "-S", "/private/socket", "-o", "ControlPersist=no",
            "-o", "ForkAfterAuthentication=no", "-o", "StdinNull=no", "-o", "ClearAllForwardings=yes",
            "-o", "RemoteCommand=none", "-o", "RequestTTY=no", "-o", "PermitLocalCommand=no",
            "-o", "ForwardX11=no", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3", "-o", "Compression=yes", "-o", "LogLevel=DEBUG", "work"])
        #expect(try builder.client(controlPath: "/private/socket", command: ["/bin/sh", "-s"]) == [
            "-S", "/private/socket", "-T", "-o", "ControlMaster=no", "-o", "BatchMode=yes",
            "-o", "ProxyCommand=false", "-o", "SessionType=default", "-o", "StdinNull=no",
            "-o", "ForkAfterAuthentication=no", "-o", "RemoteCommand=none", "-o", "RequestTTY=no",
            "-o", "PermitLocalCommand=no", "work", "/bin/sh", "-s"])
        #expect(try builder.client(controlPath: "/s", command: ["bridge"], forwardAgent: true).contains("-A"))
        #expect(builder.check(controlPath: "/s") == ["-S", "/s", "-O", "check", "work"])
        #expect(builder.exit(controlPath: "/s") == ["-S", "/s", "-O", "exit", "work"])
    }

    @Test func keepsUserKeepaliveAndUsesIndependentConnectionOptions() throws {
        let config = try SSHConfiguration(destination: "work", output:
            "user a\nhostname h\nport 22\nserveraliveinterval 8\nserveralivecountmax 9")
        let builder = SSHCommandLine(configuration: config, keepaliveInterval: 20, keepaliveCount: 4)
        #expect(!builder.master(controlPath: "/s").contains(where: { $0.hasPrefix("ServerAlive") }))
        let independent = try builder.independent(command: ["/bin/sh", "-s"])
        #expect(!independent.contains("-S"))
        #expect(!independent.contains("-M"))
        #expect(!independent.contains("BatchMode=yes"))
        #expect(!independent.contains("ProxyCommand=false"))
        #expect(independent.contains("ClearAllForwardings=yes"))
        #expect(independent.contains("ControlPath=none"))
        #expect(independent.contains("SessionType=default"))
    }

    @Test func refusesShellSyntax() {
        for word in ["", "two words", "$HOME", "~/helper", "a;b", "a&&b", "'quoted'", "a\nb", "a=b"] {
            #expect(throws: SSHCommandLineError.invalidCommandWord(word)) {
                try SSHCommandLine.validate(command: [word])
            }
        }
        #expect(throws: Never.self) { try SSHCommandLine.validate(command: ["/bin/sh", "-s", ".tecolot/bin/v1/helper"]) }
    }

    @Test func socketPathUsesStableNameAndPrivateDirectory() throws {
        let runtime = URL(fileURLWithPath: "/tmp/tecolot-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtime) }
        let path = try SSHCommandLine.controlSocketPath(runtimeDirectory: runtime, configuration: sshFixture())
        #if canImport(CryptoKit)
        #expect(URL(fileURLWithPath: path).lastPathComponent == "f5d3abb767cfe201")
        #else
        #expect(URL(fileURLWithPath: path).lastPathComponent == "25dbeec5fecbd15c")
        #endif
        let attributes = try FileManager.default.attributesOfItem(atPath: runtime.appendingPathComponent("ssh").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(path.utf8.count + 17 <= 104)
    }

    @Test func socketNameFallbackUsesTwoFNV1aSeeds() {
        #expect(SSHCommandLine.fallbackSocketName([]) == "84222325cbf29ce4")
        #expect(SSHCommandLine.fallbackSocketName(Array("hello".utf8)) == "80aabd0b7eb8cbd4")
        let input = Array("alice@server.example:2222 work".utf8)
        #expect(SSHCommandLine.fallbackSocketName(input) == "25dbeec5fecbd15c")
    }

    @Test func socketPathRejectsSymlinksAndUsesShortFallback() throws {
        let runtime = URL(fileURLWithPath: "/tmp/tecolot-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtime) }
        try FileManager.default.createSymbolicLink(atPath: runtime.appendingPathComponent("ssh").path,
                                                   withDestinationPath: "/tmp")
        #expect(throws: SSHCommandLineError.unsafeSocketDirectory(runtime.appendingPathComponent("ssh").path)) {
            try SSHCommandLine.controlSocketPath(runtimeDirectory: runtime, configuration: sshFixture())
        }
        let longRuntime = runtime.appendingPathComponent(String(repeating: "x", count: 150))
        let fallback = URL(fileURLWithPath: "/tmp/tecolot-ssh-\(getuid())")
        let existed = FileManager.default.fileExists(atPath: fallback.path)
        defer { if !existed { _ = rmdir(fallback.path) } }
        let path = try SSHCommandLine.controlSocketPath(runtimeDirectory: longRuntime, configuration: sshFixture())
        #expect(path.hasPrefix("/tmp/tecolot-ssh-\(getuid())/"))
    }

    @Test func classifiesOpenSSHErrorsAndKeepsTwentyLines() {
        let samples: [(String, SSHError.Kind)] = [
            ("ssh: connect to host example port 22: Connection timed out", .network),
            ("ssh: connect to host example port 22: Connection refused", .network),
            ("ssh: connect to host example port 22: Network is unreachable", .network),
            ("ssh: connect to host example port 22: No route to host", .network),
            ("ssh: Could not resolve hostname example: nodename nor servname provided, or not known", .network),
            ("client_loop: send disconnect: Broken pipe", .network),
            ("Connection reset by 192.0.2.1 port 22", .network),
            ("alice@example: Permission denied (publickey,password).", .authentication),
            ("Received disconnect from 192.0.2.1 port 22:2: Too many authentication failures", .authentication),
            ("@@@@@@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@@@@@@", .hostKeyChanged),
            ("Host key verification failed.", .hostKeyChanged),
            ("channel 1: open failed: administratively prohibited: open failed", .channelRefused),
            ("mux_client_request_session: session request failed: Session open refused by peer", .channelRefused),
            ("channel 2: open failed: connect failed", .channelRefused),
            ("administratively prohibited", .channelRefused),
            ("Session open refused", .channelRefused),
            ("mux_client_request_session: session request failed", .channelRefused),
            ("ssh_askpass returned failure", .cancelled),
            ("Authentication cancelled by user", .cancelled),
            ("User canceled the SSH prompt", .cancelled),
            ("Bad configuration option: unknown", .other)]
        for (sample, expected) in samples {
            let error = SSHErrorClassifier.classify(stderr: sample)
            #expect(error.kind == expected)
            #expect(error.retryAutomatically == (expected == .network))
        }
        #expect(SSHErrorClassifier.classify(stderr: "Permission denied", cancelled: true).kind == .cancelled)
        let error = SSHErrorClassifier.classify(stderr: (1...30).map(String.init).joined(separator: "\n"))
        #expect(error.stderrLines.count == 20)
        #expect(error.stderrLines.first == "11")
        #expect(error.stderrLines.last == "30")
    }
}
