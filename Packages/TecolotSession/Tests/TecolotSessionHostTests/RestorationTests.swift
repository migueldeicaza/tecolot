import Foundation
import SwiftTerm
import Testing
import TecolotSessionDirectory
import TecolotWire
@testable import TecolotSessionHost

private func row(_ text: String, wrapped: Bool = false, attribute: WireAttribute = .plain) -> ScrollbackRow {
    ScrollbackRow(isWrapped: wrapped, cells: text.utf8.map { WireCell(.ascii($0), style: WireCellStyle(attribute: attribute)) })
}

struct ScrollbackFileTests {
    @Test func wrappedRowsJoinIntoOneLine() {
        let text = ScrollbackFile.text([row("abcde"), row("fgh", wrapped: true), row("next")])
        #expect(text == "abcdefgh\nnext\n")
    }

    @Test func attributesBecomeSGRAndResetAtLineEnd() {
        let red = WireAttribute(foreground: .ansi(1), style: 1)
        let rows = [ScrollbackRow(isWrapped: false, cells: [WireCell(.ascii(0x41), style: WireCellStyle(attribute: red)),
                                                            WireCell(.ascii(0x42))])]
        #expect(ScrollbackFile.text(rows) == "\u{1B}[0;1;31mA\u{1B}[0mB\n")
        let rgb = WireAttribute(foreground: .rgb(1, 2, 3), background: .ansi(200), underlineStyle: 3)
        #expect(ScrollbackFile.sgr(rgb) == "\u{1B}[0;4:3;38;2;1;2;3;48;5;200m")
        #expect(ScrollbackFile.sgr(WireAttribute(foreground: .ansi(9), background: .ansi(12))) == "\u{1B}[0;91;104m")
    }

    @Test func wideCellsSkipTheirSpacer() {
        let rows = [ScrollbackRow(isWrapped: false, cells: [WireCell(.grapheme("界", width: 2)), WireCell(.spacer),
                                                            WireCell(.ascii(0x78))])]
        #expect(ScrollbackFile.text(rows) == "界x\n")
    }

    @Test func prepareDropsThePromptAndBlankRows() {
        let rows = [row("one"), row("two"), row("$ "), row(""), row("")]
        #expect(ScrollbackFile.prepare(rows, cursorRow: 2, limit: 100).map { ScrollbackFile.text([$0]) } == ["one\n", "two\n"])
        // A prompt that wraps goes with its first row.
        let wrapped = [row("out"), row("$ long"), row("command", wrapped: true)]
        #expect(ScrollbackFile.prepare(wrapped, cursorRow: 2, limit: 100).count == 1)
        // Text below the cursor (a program moved it up) keeps every row.
        let below = [row("a"), row("b"), row("c")]
        #expect(ScrollbackFile.prepare(below, cursorRow: 0, limit: 100).count == 3)
        // After Clear to Start only the prompt is left: nothing to restore.
        #expect(ScrollbackFile.prepare([row("$ ")], cursorRow: 0, limit: 100).isEmpty)
    }

    @Test func prepareKeepsTheLastRowsWithinTheLimit() {
        let rows = (0 ..< 10).map { row("r\($0)") }
        let kept = ScrollbackFile.prepare(rows, cursorRow: nil, limit: 3)
        #expect(ScrollbackFile.text(kept) == "r7\nr8\nr9\n")
        #expect(ScrollbackFile.prepare(rows, cursorRow: nil, limit: 0).isEmpty)
        // A continuation row without its start begins a line.
        let split = ScrollbackFile.prepare([row("aa"), row("bb", wrapped: true)], cursorRow: nil, limit: 1)
        #expect(split.first?.isWrapped == false)
    }

    @Test func fileRoundTrips() throws {
        let header = ScrollbackHeader(paneID: "pane", savedAt: Date(timeIntervalSince1970: 1_000_000), columns: 80,
                                      rows: 0, alternateScreenProgram: "vim")
        let data = try ScrollbackFile.encode([row("hello", attribute: WireAttribute(foreground: .ansi(2)))], header: header)
        let decoded = try ScrollbackFile.decode(data)
        #expect(decoded.header.paneID == "pane")
        #expect(decoded.header.rows == 1)
        #expect(decoded.header.alternateScreenProgram == "vim")
        #expect(decoded.text == "\u{1B}[0;32mhello\u{1B}[0m\n")
    }

    @Test(arguments: [
        "\u{1B}]0;title\u{07}",          // title
        "\u{1B}]52;c;aGk=\u{07}",        // clipboard
        "\u{1B}[?1049h",                 // mode
        "\u{1B}[2J",                     // erase
        "\u{1B}]7;file:///etc\u{07}",    // directory
        "\u{1B}P+q\u{1B}\\",             // DCS
        "a\rb",                          // carriage return
        "a\u{9B}31m",                    // C1 CSI
        "\u{1B}[31",                     // unterminated
    ])
    func validationRejectsEverythingButSGR(text: String) {
        #expect(throws: ScrollbackFileError.self) { try ScrollbackFile.validate(text) }
    }

    @Test func validationAcceptsSGRAndText() throws {
        try ScrollbackFile.validate("plain\n\u{1B}[0;1;38;2;1;2;3;4:3mbold\u{1B}[0m 界 é\n")
        try ScrollbackFile.validate(RestoreSeparator.line(savedAt: Date(), reason: .macRestarted,
                                                          directoryNotFound: true, program: "vim"))
    }

    @Test func fileWithAControlSequenceDoesNotDecode() throws {
        let header = ScrollbackHeader(paneID: "p", savedAt: Date(), columns: 80, rows: 1)
        var data = try ScrollbackFile.encode([row("x")], header: header)
        data.append(contentsOf: Array("\u{1B}]0;evil\u{07}\n".utf8))
        #expect(throws: ScrollbackFileError.self) { try ScrollbackFile.decode(data) }
        #expect(throws: ScrollbackFileError.self) { try ScrollbackFile.decode(Data("no header".utf8)) }
    }

    @Test func separatorNamesTheReasons() {
        let line = RestoreSeparator.line(savedAt: nil, reason: .hostRestarted, directoryNotFound: true, program: "vim")
        #expect(line.contains("── Restored · the host restarted · the directory was not found · vim was running ──"))
    }
}

struct PaneDirectoryTests {
    @Test func osc7ChecksTheHost() {
        let local = PaneDirectory.osc7("file://mac/Users/me/src", isPaneHost: { $0 == "mac" })
        #expect(local == PaneDirectory(path: "/Users/me/src", source: .osc7))
        let noHost = PaneDirectory.osc7("kitty-shell-cwd:///tmp", isPaneHost: { _ in false })
        #expect(noHost?.isOnPaneHost == true)
        let other = PaneDirectory.osc7("file://server/home/me", isPaneHost: { $0 == "mac" })
        #expect(other?.host == .other("server"))
        #expect(PaneDirectory.osc7("http://mac/tmp", isPaneHost: { _ in true }) == nil)
    }

    @Test func otherReportsHaveNoHost() {
        #expect(PaneDirectory.otherReport(code: 1337, payload: "CurrentDir=/var/tmp")?.path == "/var/tmp")
        #expect(PaneDirectory.otherReport(code: 633, payload: "P;Cwd=/a\\x3bb")?.path == "/a;b")
        #expect(PaneDirectory.otherReport(code: 1337, payload: "SetMark") == nil)
    }

    @Test func trackerKeepsThePaneHostDirectory() {
        var tracker = PaneDirectoryTracker(launch: "/start")
        #expect(tracker.needsProcessInspection)
        #expect(tracker.resolved { nil } == PaneDirectory(path: "/start", source: .launch))
        #expect(tracker.resolved { "/proc" } == PaneDirectory(path: "/proc", source: .process))
        tracker.report(PaneDirectory(path: "/local", source: .osc7))
        #expect(!tracker.needsProcessInspection)
        #expect(tracker.resolved { "/proc" }?.path == "/local")
        // ssh to another host: the shell's directory is still local.
        tracker.report(PaneDirectory(path: "/remote", host: .other("server"), source: .osc7))
        #expect(tracker.latest?.path == "/remote")
        #expect(tracker.resolved { "/shell" }?.path == "/shell")
        #expect(tracker.resolved { nil }?.path == "/local")
    }

    @Test func nearestExistingDirectory() {
        let existing: Set<String> = ["/", "/a"]
        #expect(ProcessDirectory.nearestExisting("/a/b/c", isDirectory: existing.contains) == "/a")
        #expect(ProcessDirectory.nearestExisting("relative", isDirectory: { _ in true }) == nil)
        #expect(ProcessDirectory.nearestExisting("/x", isDirectory: { _ in false }) == nil)
    }

    @Test func restoreTargetTellsWhenTheDirectoryWasNotFound() {
        let existing: Set<String> = ["/", "/a"]
        #expect(ProcessDirectory.restoreTarget("/a/", isDirectory: existing.contains)
            == .init(path: "/a", notFound: false))
        #expect(ProcessDirectory.restoreTarget("/a/b", isDirectory: existing.contains)
            == .init(path: "/a", notFound: true))
        #expect(ProcessDirectory.restoreTarget("/x", isDirectory: { _ in false }) == .init(path: nil, notFound: true))
        #expect(ProcessDirectory.restoreTarget(nil) == .init(path: nil, notFound: false))
    }

    @Test func otherReportIsCheckedOnTheBytes() {
        #expect(PaneDirectory.isOtherReport(code: 1337, payload: Array("CurrentDir=/tmp".utf8)))
        #expect(!PaneDirectory.isOtherReport(code: 1337, payload: Array("File=inline=1:AAAA".utf8)))
        #expect(PaneDirectory.isOtherReport(code: 633, payload: Array("P;Cwd=/tmp".utf8)))
        #expect(!PaneDirectory.isOtherReport(code: 9, payload: Array("CurrentDir=/tmp".utf8)))
    }

    @Test func processDirectoryOfThisProcess() {
        let path = ProcessDirectory.workingDirectory(of: getpid())
        #expect(path == FileManager.default.currentDirectoryPath)
        #expect(BootIdentifier.current()?.isEmpty == false)
    }
}

struct DurableStateTests {
    private func temporaryStates() -> DurableStateDirectory {
        DurableStateDirectory(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("tecolot-states-\(UUID().uuidString)", isDirectory: true))
    }

    @Test func writeReadAndPermissions() throws {
        let states = temporaryStates()
        defer { try? FileManager.default.removeItem(at: states.url) }
        let launch = SessionLaunch(executable: "/bin/sh", environment: [], workingDirectory: "/tmp")
        let state = DurableSessionState(id: "abc123", launch: launch, directory: PaneDirectory(path: "/tmp", source: .osc7),
                                        title: "title", bootID: "boot-1")
        let header = ScrollbackHeader(paneID: "abc123", savedAt: Date(), columns: 80, rows: 1)
        try states.write(state, scrollback: try ScrollbackFile.encode([row("saved text")], header: header))
        #expect(states.read("abc123")?.title == "title")
        #expect(states.scrollback("abc123")?.text == "saved text\n")
        let mode = try FileManager.default.attributesOfItem(atPath: states.stateURL(for: "abc123").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let folderMode = try FileManager.default.attributesOfItem(atPath: states.url.path)[.posixPermissions] as? Int
        #expect(folderMode == 0o700)
        #expect(try states.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(states.list().map(\.id) == ["abc123"])
        states.remove("abc123")
        #expect(states.read("abc123") == nil)
    }

    @Test func oldStatesAreDeleted() throws {
        let states = temporaryStates()
        defer { try? FileManager.default.removeItem(at: states.url) }
        let launch = SessionLaunch(executable: "/bin/sh", environment: [])
        try states.write(DurableSessionState(id: "01d", launch: launch, savedAt: Date().addingTimeInterval(-8 * 86_400)),
                         scrollback: nil)
        try states.write(DurableSessionState(id: "0e1", launch: launch), scrollback: nil)
        #expect(states.list().map(\.id) == ["0e1"])
        #expect(states.read("01d") == nil)
    }

    @Test func prepareRestoreUsesTheStateAndItsDirectory() throws {
        let states = temporaryStates()
        defer { try? FileManager.default.removeItem(at: states.url) }
        let saved = SessionLaunch(executable: "/bin/sh", environment: [], workingDirectory: "/home/me")
        let state = DurableSessionState(id: "5e1", launch: saved, directory: PaneDirectory(path: "/home/me/gone", source: .osc7),
                                        bootID: "previous-boot", alternateScreenProgram: "vim")
        let header = ScrollbackHeader(paneID: "5e1", savedAt: Date(), columns: 80, rows: 2)
        try states.write(state, scrollback: try ScrollbackFile.encode([row("one"), row("two")], header: header))

        var launch = SessionLaunch(executable: "/bin/sh", environment: [], workingDirectory: "/")
        let used = states.prepareRestore(&launch, sessionID: "5e1", rowLimit: 1, remote: true,
                                         isDirectory: { ["/", "/home", "/home/me"].contains($0) })
        #expect(used?.id == "5e1")
        #expect(launch.workingDirectory == "/home/me")
        let replay = try #require(launch.replay)
        #expect(replay.hasPrefix("two\n"))
        #expect(!replay.contains("one"))
        #expect(replay.contains("the host restarted"))
        #expect(replay.contains("the directory was not found"))
        #expect(replay.contains("vim was running"))
        try ScrollbackFile.validate(replay)

        var missing = SessionLaunch(executable: "/bin/sh", environment: [])
        #expect(states.prepareRestore(&missing, sessionID: "0000", rowLimit: 100, remote: false) == nil)
        #expect(missing.replay?.contains("the session ended") == true)
    }

    @Test func expiredStateIsNotRestoredAndPruneDeletesOldFolders() throws {
        let states = temporaryStates()
        defer { try? FileManager.default.removeItem(at: states.url) }
        let launch = SessionLaunch(executable: "/bin/sh", environment: [])
        try states.write(DurableSessionState(id: "01d", launch: launch, savedAt: Date().addingTimeInterval(-8 * 86_400)),
                         scrollback: nil)
        var restored = SessionLaunch(executable: "/bin/sh", environment: [])
        #expect(states.prepareRestore(&restored, sessionID: "01d", rowLimit: 10, remote: true,
                                      directoryNotFound: true) == nil)
        #expect(restored.replay?.contains("the directory was not found") == true)
        states.prune(now: Date().addingTimeInterval(DurableStateDirectory.lifetime - 60))
        #expect(states.read("01d") != nil)
        states.prune(now: Date().addingTimeInterval(DurableStateDirectory.lifetime + 60))
        #expect(states.read("01d") == nil)
    }

    @Test func reasonFollowsTheBoot() {
        let state = DurableSessionState(id: "x", launch: SessionLaunch(executable: "/bin/sh", environment: []), bootID: "a")
        #expect(state.reason(currentBoot: "b", remote: false) == .macRestarted)
        #expect(state.reason(currentBoot: "b", remote: true) == .hostRestarted)
        #expect(state.reason(currentBoot: "a", remote: false) == .sessionEnded)
    }
}

struct SessionHostRestorationTests {
    @Test func replayShowsBeforeTheShellAndCannotSetTheTitle() async throws {
        let launch = SessionLaunch(executable: "/bin/sh", arguments: ["-c", "exec sleep 30"],
                                   environment: ["PATH=/usr/bin:/bin"], workingDirectory: "/", columns: 40, rows: 10,
                                   replay: "old text\n" + RestoreSeparator.line(savedAt: nil, reason: .appQuit))
        let host = SessionHost(id: "replay\(UInt32.random(in: 0 ... .max))", launch: launch, build: "test")
        try host.start()
        defer { host.terminate(signal: SIGKILL) }
        let text = host.terminal.contentSnapshot(region: .viewport).rows.map(\.text)
        #expect(text[0] == "old text")
        #expect(text[1].contains("Restored · Tecolot quit"))

        let unsafe = SessionLaunch(executable: "/bin/sh", arguments: ["-c", "exec sleep 30"],
                                   environment: ["PATH=/usr/bin:/bin"], columns: 40, rows: 10,
                                   replay: "\u{1B}]0;evil\u{07}text\n")
        let rejected = SessionHost(id: "reject\(UInt32.random(in: 0 ... .max))", launch: unsafe, build: "test")
        try rejected.start()
        defer { rejected.terminate(signal: SIGKILL) }
        #expect(rejected.terminal.contentSnapshot(region: .viewport).rows.allSatisfy { $0.text.isEmpty })
    }

    @Test func durableStateCopiesTheNormalBuffer() throws {
        let host = makeHost(columns: 20, rows: 4)
        host.inject("\u{1b}[32mgreen\u{1b}[0m line\r\nsecond\r\n$ ")
        host.inject("\u{1b}]7;file://localhost/var/tmp\u{07}")
        let (state, data) = host.durableState(title: "t")
        #expect(state.directory == PaneDirectory(path: "/var/tmp", source: .osc7))
        #expect(state.alternateScreenProgram == nil)
        let decoded = try ScrollbackFile.decode(try #require(data))
        // The prompt is gone; the new shell shows its own.
        #expect(decoded.text == "\u{1B}[0;32mgreen\u{1B}[0m line\nsecond\n")

        host.inject("\u{1b}[?1049h\u{1b}[2Jeditor")
        let (_, altData) = host.durableState(title: "t")
        let alternate = try ScrollbackFile.decode(try #require(altData))
        #expect(alternate.text.contains("second"))
        #expect(!alternate.text.contains("editor"))
    }

    @Test func noTextWhenTheLimitIsZero() {
        let launch = SessionLaunch(executable: "/bin/sh", environment: [], columns: 20, rows: 4, restoreRows: 0)
        let host = SessionHost(id: "zero", launch: launch, build: "test")
        host.inject("text\r\n")
        #expect(host.durableState(title: "").1 == nil)
    }
}
