import Darwin
import Foundation
import Testing

struct ShellDirectoryReportingTests {
    enum Shell: String, CaseIterable {
        case zsh, bash
    }

    enum Input: String, CaseIterable {
        case printableDirectory, printableHostname, controlDirectory, controlHostname, ordinaryNames

        var directoryName: String {
            switch self {
            case .printableDirectory: Self.printablePayload
            case .controlDirectory: "before" + Self.controls + "]52;c;SGVsbG8=" + Self.controls + "after"
            case .ordinaryNames: #"café 中文 two words \backslash %s"#
            default: "safe-directory"
            }
        }

        var hostname: String {
            switch self {
            case .printableHostname: Self.printablePayload
            case .controlHostname: "before" + Self.controls + "]52;c;SGVsbG8=" + Self.controls + "after"
            case .ordinaryNames: #"hôte two words \backslash %s"#
            default: "safe-host"
            }
        }

        private static let printablePayload = #"x\a\e]52;c;SGVsbG8=\a"#
        // A filename cannot contain NUL. Include each other ASCII control.
        private static let controls = String(String.UnicodeScalarView(
            (1...31).map { Unicode.Scalar($0)! } + [Unicode.Scalar(127)!]
        ))
    }

    @Test(arguments: Shell.allCases, Input.allCases)
    func directoryReportContainsOneSafeOSC7(shell: Shell, input: Input) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shell-directory-report-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingDirectory = directory.appendingPathComponent(input.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: false)
        let resources = try #require(Bundle.main.resourceURL)
        let integration = resources.appendingPathComponent("shell-integration")
        let script: String
        switch shell {
        case .zsh:
            // Noninteractive startup cannot open a TTY. Deferred init uses only
            // fd 1. Discard its initial reports before testing one explicit call.
            script = """
                builtin source "$INTEGRATION/zsh/tecolot-integration" || exit 1
                _tecolot_fd=1
                {
                    _tecolot_deferred_init || exit 1
                    preexec_functions=()
                    chpwd_functions=()
                } >/dev/null
                builtin cd -- "$CASE_DIRECTORY" || exit 1
                HOST="$CASE_HOST"
                _tecolot_report_pwd
                """
        case .bash:
            // The script returns before it defines functions in a noninteractive
            // shell. Load the real function text without interactive hooks or a TTY.
            let source = try String(contentsOf: integration.appendingPathComponent("bash/tecolot.bash"), encoding: .utf8)
            let start = try #require(source.range(of: "function __tecolot_precmd() {\n"))
            let end = try #require(source.range(of: "\n}\n", range: start.upperBound..<source.endIndex))
            script = String(source[start.lowerBound..<end.upperBound]) + """

                builtin cd -- "$CASE_DIRECTORY" || exit 1
                HOSTNAME="$CASE_HOST"
                _tecolot_last_reported_cwd=''
                _tecolot_executing=''
                __tecolot_precmd
                """
        }
        // Script bytes preserve Unicode. Process environment values can use a
        // different Unicode normalization on macOS.
        let inputScript = "CASE_DIRECTORY=" + shellLiteral(workingDirectory.path)
            + "\nCASE_HOST=" + shellLiteral(input.hostname) + "\n" + script
        let result = try await run(shell: shell, script: inputScript, directory: directory, environment: [
            "INTEGRATION": integration.path,
        ])
        #expect(result.status == 0, "shell failed: \(shell.rawValue), \(input.rawValue)")
        #expect(result.stderr.isEmpty, "shell wrote error bytes: \(shell.rawValue), \(input.rawValue)")
        let expected = Data(("\u{1b}]7;kitty-shell-cwd://" + withoutControls(input.hostname)
            + withoutControls(workingDirectory.path) + "\u{7}").utf8)
        // Bash also emits one prompt mark. Match every output byte so that an
        // extra OSC 52, report, terminator, or other control fails the test.
        let expectedOutput: Data
        if shell == .bash {
            expectedOutput = Data("\u{1b}]133;P;k=i\u{7}".utf8) + expected
        } else {
            expectedOutput = expected
        }
        #expect(result.stdout == expectedOutput,
                "report bytes changed: \(shell.rawValue), \(input.rawValue)")
    }

    private func shellLiteral(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func withoutControls(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }))
    }

    private func run(
        shell: Shell, script: String, directory: URL, environment: [String: String]
    ) async throws -> (status: Int32, stdout: Data, stderr: Data) {
        let input = directory.appendingPathComponent("input-script")
        let output = directory.appendingPathComponent("stdout")
        let errors = directory.appendingPathComponent("stderr")
        try Data(script.utf8).write(to: input)
        try Data().write(to: output)
        try Data().write(to: errors)
        let outputHandle = try FileHandle(forWritingTo: output)
        let errorHandle = try FileHandle(forWritingTo: errors)
        defer { try? outputHandle.close(); try? errorHandle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/" + shell.rawValue)
        process.arguments = (shell == .zsh ? ["-f"] : ["--noprofile", "--norc"]) + [input.path]
        process.environment = environment.merging([
            "PATH": "/usr/bin:/bin", "LC_ALL": "en_US.UTF-8", "TERM": "dumb",
            "HOME": directory.path, "ZDOTDIR": directory.path,
            // Use a fixed prompt mark instead of one that includes the process ID.
            "BLE_VERSION": "test",
        ]) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        // Files prevent pipe-buffer deadlocks and keep controls out of the TTY.
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        let deadline = ContinuousClock.now + .seconds(10)
        while process.isRunning && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!process.isRunning, "shell exceeded 10 seconds: \(shell.rawValue)")
        return (process.terminationStatus, try Data(contentsOf: output), try Data(contentsOf: errors))
    }
}
