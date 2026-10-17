#if canImport(CryptoKit)
import CryptoKit
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import TecolotSessionClient

struct RemoteBootstrapTests {
    private let helper = Data("#!/bin/sh\n[ \"$1\" = version ] && [ \"$2\" = --json ] || exit 1\nprintf '{\"version\":\"test\"}\\n'\n".utf8)

    @Test func rejectsScriptAndPathInjection() throws {
        for value in ["", "a;exit", "$(id)", "a b", "a/b", "..", "\n"] {
            #expect(throws: RemoteBootstrapError.self) { try RemoteBootstrap.validateComponent(value) }
        }
        for path in ["/absolute", "../escape", "a//b", "a/../b", "a/"] {
            #expect(throws: RemoteBootstrapError.self) { try RemoteLayout(baseDirectory: path) }
        }
        #expect(throws: RemoteBootstrapError.self) { try RemoteLayout(runtimeDirectory: "relative") }
        #expect(throws: RemoteBootstrapError.self) { try RemoteLayout(runtimeDirectory: "/tmp/../x") }
    }

    @Test func removeCommandDeletesOnlyTheBaseDirectory() throws {
        let bootstrap = try RemoteBootstrap(layout: RemoteLayout(baseDirectory: "apps/tecolot"), metadata: [])
        #expect(try bootstrap.removeCommand() == ["rm", "-rf", "--", "./apps/tecolot"])
    }

    @Test(arguments: ["/bin/sh", "/bin/dash"])
    func installsFromSeparateInputAndSecondProbeReusesHelper(shell: String) throws {
        guard FileManager.default.isExecutableFile(atPath: shell) else { return }
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let bootstrap = try makeBootstrap(home: home)
        let probe = try runProbe(bootstrap, home: home, shell: shell, nonce: "first")
        #expect(probe.homeOK)
        #expect(probe.runtimeOK)
        #expect(probe.receiverReady)
        #expect(probe.receivePath == ".tecolot/tmp/first/receive")
        #expect(probe.needsUpload)
        let input = try payload(compressed: probe.hasGzip, home: home)
        let upload = try launch(shell: shell, arguments: [receiver(home, nonce: "first").path], home: home, input: input)
        #expect(upload.status == 0, "\(upload.output)")
        let steps = try bootstrap.parseUploadSteps("noise\n" + upload.output, nonce: "first")
        #expect(steps.map(\.step) == ["prepare", "copy", "unpack", "hash", "chmod", "version", "install", "hash-file", "cleanup"])
        #expect(steps.allSatisfy { $0.succeeded })
        #expect(!FileManager.default.fileExists(atPath: receiver(home, nonce: "first").deletingLastPathComponent().path))
        let second = try runProbe(bootstrap, home: home, shell: shell, nonce: "second")
        #expect(!second.needsUpload)
        #expect(second.runs)
        #expect(!second.receiverReady)
        let binaryID = try #require(second.binaryID)
        let installed = home.appendingPathComponent(".tecolot/bin/\(binaryID)/\(second.release)")
        #expect(try Data(contentsOf: installed.appendingPathComponent("tecolot-sessiond")) == helper)
        #expect(try String(contentsOf: installed.appendingPathComponent("sha256"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == second.expectedHash)
        #expect(try bootstrap.bridgeCommand(probe: second, nonce: "bridge").contains("--runtime-dir \(home.path)/runtime"))
    }

    @Test func damagedUploadFailsHashAndRemovesTemporaryFiles() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let bootstrap = try makeBootstrap(home: home)
        let probe = try runProbe(bootstrap, home: home, shell: "/bin/sh", nonce: "damaged")
        let bytes = try payload(compressed: probe.hasGzip, home: home, bytes: Data("damaged".utf8))
        let result = try launch(shell: "/bin/sh", arguments: [receiver(home, nonce: "damaged").path], home: home, input: bytes)
        #expect(result.status != 0)
        #expect(try bootstrap.parseUploadSteps(result.output, nonce: "damaged").contains { $0.step == "hash" && !$0.succeeded })
        #expect(!FileManager.default.fileExists(atPath: receiver(home, nonce: "damaged").deletingLastPathComponent().path))
    }

    @Test func executionFailureReportsVersionAndRemovesTemporaryFiles() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let bytes = Data("#!/bin/sh\nexit 126\n".utf8)
        let bootstrap = try makeBootstrap(home: home, bytes: bytes)
        let probe = try runProbe(bootstrap, home: home, shell: "/bin/sh", nonce: "noexec")
        let result = try launch(shell: "/bin/sh", arguments: [receiver(home, nonce: "noexec").path], home: home,
                                input: payload(compressed: probe.hasGzip, home: home, bytes: bytes))
        #expect(result.status != 0)
        let failure = try #require(try bootstrap.parseUploadSteps(result.output, nonce: "noexec").last)
        #expect(failure.step == "version")
        #expect(!failure.succeeded)
        #expect(failure.detail.contains("noexec"))
        #expect(!FileManager.default.fileExists(atPath: receiver(home, nonce: "noexec").deletingLastPathComponent().path))
    }

    @Test func copyFailureReportsDiskSpaceAndRemovesTemporaryFiles() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let bootstrap = try makeBootstrap(home: home)
        _ = try runProbe(bootstrap, home: home, shell: "/bin/sh", nonce: "disk")
        let commands = home.appendingPathComponent("commands")
        try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        let cat = commands.appendingPathComponent("cat")
        try "#!/bin/sh\nexit 1\n".write(to: cat, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cat.path)
        let result = try launch(shell: "/bin/sh", arguments: [receiver(home, nonce: "disk").path], home: home, input: Data(),
                                path: commands.path + ":/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(result.status != 0)
        let failure = try #require(try bootstrap.parseUploadSteps(result.output, nonce: "disk").last)
        #expect(failure.step == "copy")
        #expect(!failure.succeeded)
        #expect(failure.detail.contains("disk space"))
        #expect(!FileManager.default.fileExists(atPath: receiver(home, nonce: "disk").deletingLastPathComponent().path))
    }

    @Test func rawUploadUsesTheSameReceiver() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let bootstrap = try makeBootstrap(home: home)
        _ = try runProbe(bootstrap, home: home, shell: "/bin/sh", nonce: "raw")
        let file = receiver(home, nonce: "raw")
        let script = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "compressed='1'", with: "compressed='0'")
        try script.write(to: file, atomically: false, encoding: .utf8)
        let result = try launch(shell: "/bin/sh", arguments: [file.path], home: home, input: helper)
        #expect(result.status == 0, "\(result.output)")
    }

    @Test func concurrentUploadsKeepOneCompleteInstall() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let bootstrap = try makeBootstrap(home: home)
        let first = try runProbe(bootstrap, home: home, shell: "/bin/sh", nonce: "one")
        _ = try runProbe(bootstrap, home: home, shell: "/bin/sh", nonce: "two")
        let bytes = try payload(compressed: first.hasGzip, home: home)
        let one = try start(shell: "/bin/sh", arguments: [receiver(home, nonce: "one").path], home: home)
        let two = try start(shell: "/bin/sh", arguments: [receiver(home, nonce: "two").path], home: home)
        try one.input.fileHandleForWriting.write(contentsOf: bytes)
        try one.input.fileHandleForWriting.close()
        try two.input.fileHandleForWriting.write(contentsOf: bytes)
        try two.input.fileHandleForWriting.close()
        let oneOutput = one.output.fileHandleForReading.readDataToEndOfFile()
        let twoOutput = two.output.fileHandleForReading.readDataToEndOfFile()
        one.process.waitUntilExit(); two.process.waitUntilExit()
        #expect(one.process.terminationStatus == 0, "\(String(decoding: oneOutput, as: UTF8.self))")
        #expect(two.process.terminationStatus == 0, "\(String(decoding: twoOutput, as: UTF8.self))")
        #expect(try runProbe(bootstrap, home: home, shell: "/bin/sh", nonce: "three").needsUpload == false)
    }

    @Test func unsupportedUnameDoesNotCreateReceiver() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let commands = home.appendingPathComponent("commands")
        try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        let uname = commands.appendingPathComponent("uname")
        try "#!/bin/sh\ncase $1 in -s) echo FreeBSD ;; -m) echo i686 ;; esac\n".write(to: uname, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: uname.path)
        let bootstrap = try makeBootstrap(home: home)
        let output = try launch(shell: "/bin/sh", arguments: ["-s"], home: home,
                                input: Data(bootstrap.probeScript(nonce: "unsupported").utf8),
                                path: commands.path + ":/usr/bin:/bin:/usr/sbin:/sbin")
        let result = try bootstrap.parseProbe(output.output, nonce: "unsupported")
        #expect(result.os == "FreeBSD")
        #expect(result.arch == "i686")
        #expect(result.binaryID == nil)
        #expect(!result.receiverReady)
        #expect(throws: RemoteBootstrapError.self) { try bootstrap.bridgeCommand(probe: result, nonce: "bridge") }
    }

    @Test(arguments: ["included", "excluded", "disabled", "unavailable"], ["/bin/sh", "/bin/dash"])
    func probesManagerKillPolicyAndUserLinger(policy: String, shell: String) throws {
        guard FileManager.default.isExecutableFile(atPath: shell) else { return }
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let commands = home.appendingPathComponent("commands")
        try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        let managerKill = policy == "disabled" ? "no" : "yes"
        let excludedUsers = policy == "excluded" ? "root remote-test-user other" : "root remote-test-user-other other"
        let loginctl = commands.appendingPathComponent("loginctl")
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> "$HOME/loginctl-arguments"
        case "$*" in
          "show-user -p KillUserProcesses -p KillExcludeUsers")
            [ "\(policy)" != unavailable ] || exit 1
            printf '%s\\n' 'KillUserProcesses=\(managerKill)' 'KillExcludeUsers=\(excludedUsers)'
            ;;
          "show-user $(/usr/bin/id -u) -p Linger --value") printf '%s\\n' yes ;;
          *) exit 9 ;;
        esac
        """.write(to: loginctl, atomically: false, encoding: .utf8)
        let id = commands.appendingPathComponent("id")
        try """
        #!/bin/sh
        if [ "$1" = -un ]; then printf '%s\\n' remote-test-user; else exec /usr/bin/id "$@"; fi
        """.write(to: id, atomically: false, encoding: .utf8)
        for command in [loginctl, id] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
        }
        let bootstrap = try makeBootstrap(home: home)
        let output = try launch(shell: shell, arguments: ["-s"], home: home,
                                input: Data(bootstrap.probeScript(nonce: "login-policy").utf8),
                                path: commands.path + ":/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(output.status == 0, "\(output.output)")
        let result = try bootstrap.parseProbe(output.output, nonce: "login-policy")
        let expected = policy == "unavailable" ? "" : (policy == "included" ? "yes" : "no")
        #expect(result.fields["kill-user-processes"] == expected)
        #expect(result.fields["linger"] == "yes")
        let arguments = try String(contentsOf: home.appendingPathComponent("loginctl-arguments"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(arguments == ["show-user \(getuid()) -p Linger --value",
                              "show-user -p KillUserProcesses -p KillExcludeUsers"])
    }

    @Test func unsafeRuntimeStopsReceiverCreationWhenHomeIsSafe() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let runtime = home.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)
        let result = try runProbe(makeBootstrap(home: home), home: home, shell: "/bin/sh", nonce: "runtime-unsafe")
        #expect(result.homeOK)
        #expect(!result.runtimeOK)
        #expect(!result.receiverReady)
        #expect(result.receivePath == nil)
        #expect(!FileManager.default.fileExists(atPath: receiver(home, nonce: "runtime-unsafe").path))
    }

    @Test func rejectsUnsafeHomeAndRuntimeDirectories() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let base = home.appendingPathComponent(".tecolot")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: base.path)
        let runtime = home.appendingPathComponent("runtime")
        try FileManager.default.createSymbolicLink(at: runtime, withDestinationURL: home)
        let result = try runProbe(makeBootstrap(home: home), home: home, shell: "/bin/sh", nonce: "unsafe")
        #expect(!result.homeOK)
        #expect(!result.runtimeOK)
        #expect(!result.receiverReady)
    }

    private func makeHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tecolot-bootstrap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func makeBootstrap(home: URL, bytes: Data? = nil) throws -> RemoteBootstrap {
        let contents = bytes ?? helper
        let hash = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
        return try RemoteBootstrap(layout: RemoteLayout(runtimeDirectory: home.appendingPathComponent("runtime").path), metadata:
            ["darwin-universal", "linux-x86_64", "linux-aarch64"].map {
                RemoteHelperMetadata(binaryID: $0, version: "test", sha256: hash, uncompressedSize: Int64(contents.count))
            })
    }
    private func receiver(_ home: URL, nonce: String) -> URL { home.appendingPathComponent(".tecolot/tmp/\(nonce)/receive") }
    private func runProbe(_ bootstrap: RemoteBootstrap, home: URL, shell: String, nonce: String) throws -> RemoteProbeResult {
        let output = try launch(shell: shell, arguments: ["-s"], home: home, input: Data(bootstrap.probeScript(nonce: nonce).utf8))
        #expect(output.status == 0, "\(output.output)")
        return try bootstrap.parseProbe("startup noise\nTECOLOT-PROBE-BEGIN other\n" + output.output + "\nend noise", nonce: nonce)
    }
    private func payload(compressed: Bool, home: URL, bytes: Data? = nil) throws -> Data {
        let data = bytes ?? helper
        guard compressed else { return data }
        return try launch(shell: "/usr/bin/gzip", arguments: ["-c", "-n"], home: home, input: data).data
    }
    private func start(shell: String, arguments: [String], home: URL, path: String? = nil) throws -> (process: Process, input: Pipe, output: Pipe) {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        if let path { environment["PATH"] = path }
        process.environment = environment
        process.currentDirectoryURL = home
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        return (process, input, output)
    }
    private func launch(shell: String, arguments: [String], home: URL, input: Data, path: String? = nil) throws -> (status: Int32, output: String, data: Data) {
        let command = try start(shell: shell, arguments: arguments, home: home, path: path)
        try command.input.fileHandleForWriting.write(contentsOf: input)
        try command.input.fileHandleForWriting.close()
        let data = command.output.fileHandleForReading.readDataToEndOfFile()
        command.process.waitUntilExit()
        return (command.process.terminationStatus, String(decoding: data, as: UTF8.self), data)
    }
}

#endif
