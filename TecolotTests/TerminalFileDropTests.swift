import AppKit
import Darwin
@testable import SwiftTerm
import Testing
@testable import Tecolot

@MainActor
struct TerminalFileDropTests {
    @Test func droppedFilesPreserveOrderAndUsePaths() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let urls = [
            URL(fileURLWithPath: "/tmp/My document.txt"),
            URL(fileURLWithPath: "/tmp/folder", isDirectory: true),
        ]
        #expect(pasteboard.writeObjects(urls as [NSURL]))
        #expect(TerminalFileDrop.hasFileURLs(in: pasteboard))
        #expect(TerminalFileDrop.text(from: pasteboard, dialect: .zsh) == "'/tmp/My document.txt' /tmp/folder ")
        #expect(TerminalFileDrop.text(from: pasteboard, dialect: .nushell) == "\"/tmp/My document.txt\" /tmp/folder ")
    }

    @Test func rejectsTextAndWebURLs() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for dialect in TerminalShellDialect.allCases {
            #expect(TerminalFileDrop.text(from: pasteboard, dialect: dialect) == nil)
        }
        #expect(!TerminalFileDrop.hasFileURLs(in: pasteboard))
        pasteboard.setString("/tmp/not-a-file-drop", forType: .string)
        #expect(!TerminalFileDrop.hasFileURLs(in: pasteboard))
        #expect(TerminalFileDrop.text(from: pasteboard, dialect: .zsh) == nil)
        pasteboard.clearContents()
        let url = try #require(URL(string: "https://example.com/file.txt"))
        pasteboard.writeObjects([url as NSURL])
        #expect(!TerminalFileDrop.hasFileURLs(in: pasteboard))
        #expect(TerminalFileDrop.text(from: pasteboard, dialect: .unknown) == nil)
    }

    @Test(arguments: TerminalShellDialect.allCases)
    func rejectsNULAndNeverEmitsTerminalControls(dialect: TerminalShellDialect) throws {
        #expect(TerminalFileDrop.shellQuotedPath("/tmp/a\0b", dialect: dialect) == nil)
        let controls = String(String.UnicodeScalarView((1...31).map { Unicode.Scalar($0)! })) + "\u{7f}"
        let quoted = try #require(TerminalFileDrop.shellQuotedPath(controls, dialect: dialect))
        #expect(!quoted.unicodeScalars.contains { $0.value < 32 || $0.value == 127 })
        #expect(TerminalFileDrop.shellQuotedPath("/tmp/abc-XYZ_012.txt:dir", dialect: dialect) == "/tmp/abc-XYZ_012.txt:dir")
    }

    @Test func controlEscapesHaveFixedWidthAndUseTheSelectedDialect() {
        #expect(TerminalFileDrop.shellQuotedPath("a\u{1}fb", dialect: .bash) == "'a'$'\\x01''fb'")
        #expect(TerminalFileDrop.shellQuotedPath("a\u{1}fb", dialect: .zsh) == "'a'$'\\x01''fb'")
        #expect(TerminalFileDrop.shellQuotedPath("a\u{1}fb", dialect: .fish) == "'a'\\x01'fb'")
        #expect(TerminalFileDrop.shellQuotedPath("a\u{1}fb", dialect: .nushell) == "\"a\\u{01}fb\"")
        #expect(TerminalFileDrop.shellQuotedPath("a\u{1}fb", dialect: .elvish) == "\"a\\x01fb\"")
    }

    @Test func nushellQuotesMultiDotComponents() {
        for path in ["/tmp/.../file", "/tmp/..../file", "/tmp/...", ".../file", "..."] {
            #expect(TerminalFileDrop.shellQuotedPath(path, dialect: .nushell) == "\"" + path + "\"")
            #expect(TerminalFileDrop.shellQuotedPath(path, dialect: .zsh) == path)
        }
        for path in ["/tmp/./file", "/tmp/../file", "/tmp/...file", "/tmp/file...", "/tmp/a...b"] {
            #expect(TerminalFileDrop.shellQuotedPath(path, dialect: .nushell) == path)
        }
    }

    @Test func unknownDestinationUsesGhosttyPrintableEscaping() {
        #expect(TerminalFileDrop.shellQuotedPath(
            #"/tmp/ \()[]{}<>"'`!#$&;|*?~=:,é🦉"#, dialect: .unknown
        ) == ##"/tmp/\ \\\(\)\[\]\{\}\<\>\"\'\`\!\#\$\&\;\|\*\?~=:,é🦉"##)
        #expect(TerminalFileDrop.shellQuotedPath(
            "/tmp/line\n\t\r\u{1b}[201~\u{7f}", dialect: .unknown
        ) == ##"/tmp/line\\x0a\\x09\\x0d\\x1b\[201~\\x7f"##)
    }

    @Test(arguments: ShellFixture.installedCases)
    func shellReceivesExactFilenames(shell: ShellFixture) async throws {
        let paths = [
            "", "/tmp/plain.txt", "/tmp/two words", "/tmp/it's a file",
            "/tmp/.../file", "/tmp/..../file", "/tmp/...", ".../file", "...",
            #"/tmp/"quotes" and \\slashes\\\'"#,
            #"/tmp/$(echo injected);`echo bad`&|<>*?[]{}!#~"#,
            "/tmp/café 🦉.txt", "/tmp/cafe\u{301} 🦉.txt", "/tmp/中文",
            "/tmp/line\nbreak\r\ttab", "/tmp/\u{1b}[200~\u{1b}[201~end",
        ] + (1...31).map { "/tmp/control" + String(Unicode.Scalar($0)!) + "aF09" }
          + ["/tmp/control\u{7f}aF09"]
        try await assertRoundTrip(paths, shell: shell)
    }

    @Test(arguments: ShellFixture.installedCases)
    func injectionNamesRemainOneArgumentAndCannotCreateAMarker(shell: ShellFixture) async throws {
        // Keep the exact reported filename as its own command: no extra output
        // and exactly one argument are allowed.
        try await assertRoundTrip(["'; echo INJECTED; #"], shell: shell)
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("INJECTED")
        let paths = [
            "'; /usr/bin/touch \(marker.path); #",
            "\"; /usr/bin/touch \(marker.path); #",
            "$(/usr/bin/touch \(marker.path))",
            "`/usr/bin/touch \(marker.path)`",
            "(/usr/bin/touch \(marker.path))",
        ]
        try await assertRoundTrip(paths, shell: shell)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test(arguments: TerminalShellDialect.allCases, [false, true])
    func dropRoutesToCurrentShellAndPreservesPasteFraming(
        dialect: TerminalShellDialect, bracketed: Bool
    ) async throws {
        let terminal = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let inspector = StubProcessInspector()
        inspector.paths[101] = executablePath(for: dialect)
        terminal.fileDropShellResolver = TerminalShellResolver(processInspector: inspector)
        let receiver = PasteReceiver()
        terminal.terminalDelegate = receiver
        terminal.withTerminal { $0.feed(text: bracketed ? "\u{1b}[?2004h" : "\u{1b}[?2004l") }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let urls = [URL(fileURLWithPath: "/tmp/a'b\\c\n"), URL(fileURLWithPath: "/tmp/second file")]
        pasteboard.writeObjects(urls as [NSURL])
        #expect(TerminalFileDrop.hasFileURLs(in: pasteboard))
        #expect(inspector.descriptors.isEmpty)
        #expect(terminal.insertDroppedFiles(from: pasteboard))
        #expect(inspector.descriptors == [terminal.process.childfd])
        #expect(inspector.processIDs == [101])
        let expected = try #require(TerminalFileDrop.text(from: pasteboard, dialect: dialect))
        let framed = bracketed ? "\u{1b}[200~" + expected + "\u{1b}[201~" : expected
        try await waitUntil("paste was not delivered") { !receiver.data.isEmpty }
        #expect(receiver.data == Data(framed.utf8))

        // The next drop must see a changed executable even with the same PID.
        receiver.data = Data()
        inspector.paths[101] = "/opt/bin/nu"
        #expect(terminal.insertDroppedFiles(from: pasteboard))
        #expect(inspector.processIDs == [101, 101])
        let next = try #require(TerminalFileDrop.text(from: pasteboard, dialect: .nushell))
        try await waitUntil("second paste was not delivered") { !receiver.data.isEmpty }
        #expect(receiver.data == Data((bracketed ? "\u{1b}[200~" + next + "\u{1b}[201~" : next).utf8))
    }

    @Test func droppingFilesFocusesTheDestinationPane() throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let firstController = try #require(workspace.focusedController)
        workspace.split(firstController, orientation: .vertical)
        let secondController = try #require(workspace.focusedController)
        let document = TerminalDocument()
        let hostView = TerminalPaneHostView(workspace: workspace, document: document)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = hostView
        hostView.synchronize(revision: workspace.revision, document: document)
        hostView.layoutSubtreeIfNeeded()
        let firstTerminal = try #require(firstController.terminal as? AppTerminalView)
        let secondTerminal = try #require(secondController.terminal as? AppTerminalView)
        #expect(firstTerminal.registeredDraggedTypes.contains(.fileURL))
        #expect(window.makeFirstResponder(secondTerminal))
        secondController.didBecomeFocused()
        let inspector = StubProcessInspector()
        firstTerminal.fileDropShellResolver = TerminalShellResolver(processInspector: inspector)

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(!firstTerminal.insertDroppedFiles(from: pasteboard))
        #expect(inspector.descriptors.isEmpty)
        #expect(workspace.focusedController === secondController)
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/file.txt") as NSURL])
        #expect(firstTerminal.insertDroppedFiles(from: pasteboard))
        #expect(window.firstResponder === firstTerminal)
        #expect(workspace.focusedController === firstController)
        #expect(TerminalSessionRegistry.shared.controller(for: window) === firstController)
    }

    @Test func hoverOnlyChecksFileURLsAndCopyPermission() {
        let terminal = AppTerminalView(frame: .zero)
        let inspector = StubProcessInspector()
        terminal.fileDropShellResolver = TerminalShellResolver(processInspector: inspector)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let drag = FileDraggingInfo(pasteboard: pasteboard)
        #expect(terminal.draggingEntered(drag).isEmpty)
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/file.txt") as NSURL])
        #expect(terminal.draggingEntered(drag) == .copy)
        #expect(terminal.draggingUpdated(drag) == .copy)
        #expect(terminal.prepareForDragOperation(drag))
        #expect(inspector.descriptors.isEmpty)
        drag.draggingSourceOperationMask = .move
        #expect(terminal.draggingUpdated(drag).isEmpty)
        #expect(!terminal.prepareForDragOperation(drag))
        #expect(!terminal.performDragOperation(drag))
        #expect(inspector.descriptors.isEmpty)
    }

    @Test(.enabled(if: ShellFixture.supportsLiveShellSwitchTest))
    func liveShellSwitchesAndExecUseTheCurrentDialect() async throws {
        let nu = try ShellFixture.nu.executable()
        let elvish = try ShellFixture.elvish.executable()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let terminal = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        terminal.startProcess(executable: "/bin/zsh", args: ["-f", "-i"], environment: [
            "PATH=/usr/bin:/bin:/opt/homebrew/bin", "TERM=xterm-256color", "LC_ALL=en_US.UTF-8",
            "ZDOTDIR=\(directory.path)",
        ], currentDirectory: directory.path)
        defer { terminal.terminate() }
        let receiver = PasteReceiver()
        receiver.forwardTo = terminal
        terminal.terminalDelegate = receiver
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let urls = [directory.appendingPathComponent("'; echo INJECTED; #"),
                    directory.appendingPathComponent("two words ' \\\\ \" 🦉")]
        for url in urls { try Data().write(to: url) }
        pasteboard.writeObjects(urls as [NSURL])
        let expected = Data((urls.map(\.path).joined(separator: "\0") + "\0").utf8)
        let switches: [(String?, TerminalShellDialect)] = [
            (nil, .zsh),
            ("\(nu.path) --no-config-file --no-history", .nushell),
            ("exit", .zsh),
            ("\(elvish.path) -norc", .elvish),
            ("exit", .zsh),
            ("exec \(nu.path) --no-config-file --no-history", .nushell),
        ]
        let initialPID = terminal.process.shellPid
        for (index, step) in switches.enumerated() {
            if let command = step.0 { terminal.send(txt: command + "\n") }
            try await waitUntil("foreground shell did not become \(step.1)") {
                terminal.fileDropShellResolver.dialect(for: terminal.process.childfd) == step.1
            }
            // A command and a file handshake also wait for the new line editor.
            let ready = directory.appendingPathComponent("ready-\(index)")
            terminal.send(txt: "/usr/bin/touch \(ready.path)\n")
            try await waitUntil("\(step.1) did not accept a command") {
                FileManager.default.fileExists(atPath: ready.path)
            }
            let output = directory.appendingPathComponent("arguments-\(index)")
            receiver.data = Data()
            terminal.send(txt: "/usr/bin/printf '%s\\0' ")
            #expect(terminal.insertDroppedFiles(from: pasteboard))
            // SwiftTerm delivers pasteText through an asynchronous delegate
            // callback. Wait for it before simulating the next keyboard event.
            let pasted = try #require(TerminalFileDrop.text(from: pasteboard, dialect: step.1))
            try await waitUntil("paste was not sent to the live shell") {
                receiver.data.range(of: Data(pasted.utf8)) != nil
            }
            terminal.send(txt: (step.1 == .nushell ? "o> " : "> ") + output.path + "\n")
            try await waitUntil("\(step.1) did not preserve dropped argument bytes") {
                (try? Data(contentsOf: output)) == expected
            }
        }
        let group = try #require(SystemTerminalProcessInspector().foregroundProcessGroup(for: terminal.process.childfd))
        #expect(group == initialPID, "exec must replace the original zsh process")
        terminal.send(txt: "exit\n")
        try await waitUntil("shell did not exit") { !terminal.process.running }
    }

    private func assertRoundTrip(_ paths: [String], shell: ShellFixture) async throws {
        let arguments = try paths.map { try #require(TerminalFileDrop.shellQuotedPath($0, dialect: shell.dialect)) }
        let script = "/usr/bin/printf '%s\\0' " + arguments.joined(separator: " ") + "\n"
        let result = try await shell.run(script: script)
        #expect(result.status == 0, "\(shell): \(result.stderr)")
        #expect(result.stderr.isEmpty, "\(shell): \(result.stderr)")
        #expect(result.stdout == Data((paths.joined(separator: "\0") + "\0").utf8), "\(shell) changed argument bytes or produced extra output")
    }
}

@MainActor
private func waitUntil(_ message: String, condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(condition(), Comment(rawValue: message))
}

@MainActor
private final class FileDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}

@MainActor
struct TerminalShellResolverTests {
    @Test(arguments: TerminalShellDialect.allCases)
    func mapsForegroundExecutableBasenames(dialect: TerminalShellDialect) {
        let inspector = StubProcessInspector()
        inspector.paths[101] = executablePath(for: dialect)
        let resolver = TerminalShellResolver(processInspector: inspector)
        #expect(resolver.dialect(for: 42) == dialect)
        #expect(inspector.descriptors == [42])
        #expect(inspector.processIDs == [101])
    }

    @Test func observesNestedShellsAndSamePIDExecReplacement() {
        let inspector = StubProcessInspector()
        inspector.paths = [101: "/bin/zsh", 202: "/opt/homebrew/bin/nu", 303: "/opt/homebrew/bin/elvish"]
        let resolver = TerminalShellResolver(processInspector: inspector)
        for (pid, expected) in [(101, TerminalShellDialect.zsh), (202, .nushell), (303, .elvish), (101, .zsh)] {
            inspector.group = pid_t(pid)
            #expect(resolver.dialect(for: 42) == expected)
        }
        inspector.paths[101] = "/opt/homebrew/bin/nu"
        #expect(resolver.dialect(for: 42) == .nushell)
        #expect(inspector.processIDs == [101, 202, 303, 101, 101])
    }

    @Test(arguments: ["/usr/bin/ssh", "/opt/bin/tmux", "/usr/bin/vim", "/bin/sh", "/tmp/not-zsh", "/tmp/nu-wrapper", ""])
    func unsupportedForegroundProcessesUseFallback(path: String) {
        let inspector = StubProcessInspector()
        inspector.paths[101] = path
        #expect(TerminalShellResolver(processInspector: inspector).dialect(for: 42) == .unknown)
        #expect(inspector.processIDs == [101])
    }

    @Test func failedQueriesUseFallbackWithoutInspectingAncestors() {
        let inspector = StubProcessInspector()
        let resolver = TerminalShellResolver(processInspector: inspector)
        #expect(resolver.dialect(for: nil) == .unknown)
        #expect(inspector.descriptors.isEmpty)
        for group in [nil, 0, -1] as [pid_t?] {
            inspector.group = group
            #expect(resolver.dialect(for: 42) == .unknown)
        }
        #expect(inspector.processIDs.isEmpty)
        inspector.group = 101
        inspector.paths = [:]
        #expect(resolver.dialect(for: 42) == .unknown)
        #expect(inspector.processIDs == [101])
        #expect(TerminalShellResolver().dialect(for: -1) == .unknown)
    }
}

private final class StubProcessInspector: TerminalProcessInspecting {
    var group: pid_t? = 101
    var paths: [pid_t: String] = [101: "/bin/zsh"]
    var descriptors: [Int32] = []
    var processIDs: [pid_t] = []

    func foregroundProcessGroup(for fileDescriptor: Int32) -> pid_t? {
        descriptors.append(fileDescriptor)
        return group
    }

    func executablePath(for processID: pid_t) -> String? {
        processIDs.append(processID)
        return paths[processID]
    }
}

private func executablePath(for dialect: TerminalShellDialect) -> String {
    switch dialect {
    case .bash: "/bin/bash"
    case .zsh: "/bin/zsh"
    case .fish: "/opt/homebrew/bin/fish"
    case .nushell: "/opt/bin/nu"
    case .elvish: "/usr/local/bin/elvish"
    case .unknown: "/usr/bin/ssh"
    }
}

@MainActor
private final class PasteReceiver: TerminalViewDelegate {
    var data = Data()
    weak var forwardTo: LocalProcessTerminalView?
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        self.data.append(contentsOf: data)
        forwardTo?.send(source: source, data: data)
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tecolot-file-drop-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

enum ShellFixture: String, CaseIterable, Sendable {
    case bash, zsh, fish, nu, elvish

    static var installedCases: [Self] {
        allCases.filter(\.isInstalled)
    }

    static var supportsLiveShellSwitchTest: Bool {
        nu.isInstalled && elvish.isInstalled
    }

    var isInstalled: Bool {
        executableURL != nil
    }

    var dialect: TerminalShellDialect {
        switch self {
        case .bash: .bash
        case .zsh: .zsh
        case .fish: .fish
        case .nu: .nushell
        case .elvish: .elvish
        }
    }

    var configurationArguments: [String] {
        switch self {
        case .bash: ["--noprofile", "--norc"]
        case .zsh: ["-f"]
        case .fish: ["--no-config"]
        case .nu: ["--no-config-file", "--no-history"]
        case .elvish: ["-norc"]
        }
    }

    func executable() throws -> URL {
        try #require(executableURL, "Incomplete validation: required shell \(rawValue) is not installed")
    }

    private var executableURL: URL? {
        let directories = ["/bin", "/opt/homebrew/bin", "/usr/local/bin",
                           FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return directories.map { URL(fileURLWithPath: $0).appendingPathComponent(rawValue) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func run(script: String) async throws -> (status: Int32, stdout: Data, stderr: String) {
        let executable = try executable()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scriptURL = directory.appendingPathComponent("input-script")
        // UTF-8 script bytes bypass macOS filesystem normalization of argv.
        try Data(script.utf8).write(to: scriptURL)
        let outputURL = directory.appendingPathComponent("stdout")
        let errorURL = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? errors.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = configurationArguments + [scriptURL.path]
        process.environment = ["PATH": "/usr/bin:/bin:/opt/homebrew/bin", "LC_ALL": "en_US.UTF-8", "TERM": "dumb"]
        process.standardInput = FileHandle.nullDevice
        // Files avoid pipe-buffer deadlocks on either stdout or stderr.
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        let deadline = ContinuousClock.now + .seconds(10)
        while process.isRunning && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let stderr = try String(contentsOf: errorURL, encoding: .utf8)
        try #require(!process.isRunning, "\(self) exceeded 10 seconds; stderr: \(stderr)")
        return (process.terminationStatus, try Data(contentsOf: outputURL), stderr)
    }
}
