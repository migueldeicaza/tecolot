//
//  KeyParityTests.swift
//  TecolotTests
//
//  A key typed in a persistent pane must reach the program as the same bytes
//  as in a local pane. The local side is SwiftTerm's TerminalView. The
//  persistent side is RemoteTerminalView: the test reads the messages it
//  sends and applies them to a headless Terminal with the calls that the
//  helper makes (SessionHost.handleKey, .text, .input).
//

import AppKit
import Foundation
import Synchronization
import Testing
@testable import SwiftTerm
@testable import Tecolot
import TecolotSessionClient
import TecolotTransport
import TecolotWire

/// Records what the local view sends to its process.
final class LocalKeyRecorder: TerminalViewDelegate {
    var bytes: [UInt8] = []
    func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes += data }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// The other end of a RemoteSession: it answers the handshake, reports the
/// terminal modes in frames, and encodes keys as SessionHost does.
final class MirrorHelper: TerminalDelegate, @unchecked Sendable {
    let channel: MessageChannel
    private(set) var terminal: Terminal!
    let output = Mutex<[UInt8]>([])
    private var sequence: UInt64 = 0
    /// What the mirror tells the client that it handles.
    let capabilities: SessionCapabilities
    /// Ignores the client's bytes and encodes every key, as the helper does
    /// when the modes changed before the key arrived.
    let encodesEveryKey = Atomic<Bool>(false)

    init(socket: Int32, capabilities: SessionCapabilities = .helper) {
        self.capabilities = capabilities
        channel = MessageChannel(socket: socket)
        terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 24))
        channel.onMessage = { [weak self] envelope in self?.handle(envelope) }
        channel.start()
    }

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        output.withLock { $0 += data }
    }

    /// Feeds output to the terminal (for example a mode change) and reports
    /// the new modes to the client, unless `reports` is false.
    func feed(_ text: String, reports: Bool = true) {
        channel.queue.sync {
            terminal.terminalLock.withLock { terminal.feed(text: text) }
            if reports { sendFrame() }
        }
    }

    private func sendFrame() {
        sequence += 1
        let modes = terminal.terminalLock.withLock {
            WireModes(input: terminal.hostInputModes | (terminal.bidiArrowKeySwap ? 1 << 16 : 0),
                      pointer: terminal.hostPointerModes)
        }
        channel.send(FrameMessage(sequence: sequence, snapshotSequence: sequence, buffer: .normal, epoch: 0,
                                  firstLine: 0, endLine: 24, viewTop: 0, columns: 80, rows: 24,
                                  cursor: WireCursor(line: 0, column: 0, visible: true, blink: false, style: 0),
                                  modes: modes))
    }

    private func handle(_ envelope: Envelope) {
        do {
            switch envelope.kind {
            case .hello:
                channel.send(HelloReplyMessage(version: SessionProtocol.version, build: "mirror",
                                               capabilities: capabilities, sessionID: "mirror"),
                             requestID: envelope.requestID)
            case .attach:
                sendFrame()
            // The same calls as SessionHost.handleKey, the .text case and the .input case.
            case .key:
                let key = try envelope.decode(KeyMessage.self)
                let encodesEveryKey = encodesEveryKey.load(ordering: .relaxed)
                terminal.terminalLock.withLock {
                    if !encodesEveryKey, let bytes = key.bytes, key.bytesApply(to: terminal.hostInputModes) {
                        terminal.sendUserInput(bytes[...])
                        return
                    }
                    let result = terminal.sendHostKey(key: key.key, code: key.code, modifiers: key.modifiers,
                                                      eventType: key.eventType, text: key.text,
                                                      shiftedKey: key.shiftedKey, baseLayoutKey: key.baseLayoutKey,
                                                      composing: key.composing,
                                                      backspaceSendsControlH: key.backspaceSendsControlH)
                    if result == 0, let text = key.text, !text.isEmpty, key.eventType != 3 {
                        _ = terminal.sendHostText(text)
                    }
                }
            case .text:
                let text = try envelope.decode(TextMessage.self).text
                terminal.terminalLock.withLock { _ = terminal.sendHostText(text) }
            case .input:
                let bytes = try envelope.decode(InputMessage.self).bytes
                terminal.terminalLock.withLock { terminal.sendUserInput(bytes[...]) }
            default:
                break
            }
        } catch {
            Issue.record("mirror decode failed: \(error)")
        }
    }
}

@MainActor
@Suite(.serialized)
struct KeyParityTests {
    struct Key: CustomStringConvertible {
        var name: String
        var keyCode: UInt16
        var characters: String
        var ignoringModifiers: String
        var modifiers: NSEvent.ModifierFlags = []

        var description: String { name }
    }

    struct Mode {
        var name: String
        /// Output that sets the mode in both terminals.
        var setup: String
        var optionAsMeta = true
        var backspaceSendsControlH = false
    }

    static func function(_ value: Int) -> String { String(UnicodeScalar(UInt32(value))!) }

    static let keys: [Key] = {
        var keys: [Key] = [
            Key(name: "a", keyCode: 0, characters: "a", ignoringModifiers: "a"),
            Key(name: "shift-a", keyCode: 0, characters: "A", ignoringModifiers: "A", modifiers: .shift),
            Key(name: "1", keyCode: 18, characters: "1", ignoringModifiers: "1"),
            Key(name: "space", keyCode: 49, characters: " ", ignoringModifiers: " "),
            Key(name: "ctrl-a", keyCode: 0, characters: "\u{01}", ignoringModifiers: "a", modifiers: .control),
            Key(name: "ctrl-c", keyCode: 8, characters: "\u{03}", ignoringModifiers: "c", modifiers: .control),
            Key(name: "ctrl-[", keyCode: 33, characters: "\u{1b}", ignoringModifiers: "[", modifiers: .control),
            Key(name: "ctrl-space", keyCode: 49, characters: "\u{00}", ignoringModifiers: " ", modifiers: .control),
            Key(name: "option-f", keyCode: 3, characters: "ƒ", ignoringModifiers: "f", modifiers: .option),
            Key(name: "return", keyCode: 36, characters: "\r", ignoringModifiers: "\r"),
            Key(name: "tab", keyCode: 48, characters: "\t", ignoringModifiers: "\t"),
            Key(name: "shift-tab", keyCode: 48, characters: "\u{19}", ignoringModifiers: "\u{19}", modifiers: .shift),
            Key(name: "escape", keyCode: 53, characters: "\u{1b}", ignoringModifiers: "\u{1b}"),
            Key(name: "delete", keyCode: 51, characters: "\u{7f}", ignoringModifiers: "\u{7f}"),
            Key(name: "forward-delete", keyCode: 117, characters: function(NSDeleteFunctionKey),
                ignoringModifiers: function(NSDeleteFunctionKey), modifiers: .function),
            Key(name: "home", keyCode: 115, characters: function(NSHomeFunctionKey),
                ignoringModifiers: function(NSHomeFunctionKey), modifiers: .function),
            Key(name: "end", keyCode: 119, characters: function(NSEndFunctionKey),
                ignoringModifiers: function(NSEndFunctionKey), modifiers: .function),
        ]
        let arrows: [(String, UInt16, Int)] = [("left", 123, NSLeftArrowFunctionKey), ("right", 124, NSRightArrowFunctionKey),
                                              ("down", 125, NSDownArrowFunctionKey), ("up", 126, NSUpArrowFunctionKey)]
        for (name, code, scalar) in arrows {
            let text = function(scalar)
            keys.append(Key(name: name, keyCode: code, characters: text, ignoringModifiers: text,
                            modifiers: [.function, .numericPad]))
            keys.append(Key(name: "shift-" + name, keyCode: code, characters: text, ignoringModifiers: text,
                            modifiers: [.function, .numericPad, .shift]))
            keys.append(Key(name: "ctrl-" + name, keyCode: code, characters: text, ignoringModifiers: text,
                            modifiers: [.function, .numericPad, .control]))
            keys.append(Key(name: "option-" + name, keyCode: code, characters: text, ignoringModifiers: text,
                            modifiers: [.function, .numericPad, .option]))
        }
        let functionKeys: [(String, UInt16, Int)] = [("f1", 122, NSF1FunctionKey), ("f5", 96, NSF5FunctionKey),
                                                     ("f12", 111, NSF12FunctionKey)]
        for (name, code, scalar) in functionKeys {
            let text = function(scalar)
            keys.append(Key(name: name, keyCode: code, characters: text, ignoringModifiers: text, modifiers: .function))
            keys.append(Key(name: "shift-" + name, keyCode: code, characters: text, ignoringModifiers: text,
                            modifiers: [.function, .shift]))
        }
        keys.append(Key(name: "keypad-enter", keyCode: 76, characters: "\u{03}", ignoringModifiers: "\u{03}",
                        modifiers: .numericPad))
        keys.append(Key(name: "keypad-1", keyCode: 83, characters: "1", ignoringModifiers: "1", modifiers: .numericPad))
        // Control on a Cyrillic layout: the key at the position of "a".
        keys.append(Key(name: "ctrl-cyrillic-ef", keyCode: 0, characters: "ф", ignoringModifiers: "ф",
                        modifiers: .control))
        keys.append(Key(name: "ctrl-delete", keyCode: 51, characters: "\u{7f}", ignoringModifiers: "\u{7f}",
                        modifiers: .control))
        return keys
    }()

    static let modes: [Mode] = [
        Mode(name: "normal", setup: "\u{1b}[?1l\u{1b}>"),
        Mode(name: "application cursor and keypad", setup: "\u{1b}[?1h\u{1b}="),
        Mode(name: "option is not meta", setup: "\u{1b}[?1l\u{1b}>", optionAsMeta: false),
        Mode(name: "kitty disambiguate", setup: "\u{1b}[>1u"),
        Mode(name: "kitty all flags", setup: "\u{1b}[>31u"),
        Mode(name: "backspace sends ^H", setup: "\u{1b}[<10u\u{1b}[?1l\u{1b}>", backspaceSendsControlH: true),
    ]

    /// Left Shift down and up, as AppKit reports a modifier key.
    func shiftEvents(in window: NSWindow) throws -> [NSEvent] {
        let leftShiftDevice: UInt = 0x02
        let down = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | leftShiftDevice)
        return try [down, []].map { flags in
            try #require(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, characters: "",
                                          charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56))
        }
    }

    func release(_ key: Key, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: key.modifiers, timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil,
                                      characters: key.characters, charactersIgnoringModifiers: key.ignoringModifiers,
                                      isARepeat: false, keyCode: key.keyCode))
    }

    func event(_ key: Key, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: key.modifiers, timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil,
                                      characters: key.characters, charactersIgnoringModifiers: key.ignoringModifiers,
                                      isARepeat: false, keyCode: key.keyCode))
    }

    /// A local pane, and a persistent pane whose helper is a mirror.
    struct Panes {
        let local: TerminalView
        let recorder: LocalKeyRecorder
        let localWindow: NSWindow
        let mirror: MirrorHelper
        let session: RemoteSession
        let remote: RemoteTerminalView
        let remoteWindow: NSWindow

        func close() {
            session.close()
            mirror.channel.close()
        }
    }

    func makePanes(capabilities: SessionCapabilities = .helper) async throws -> Panes {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        let localWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        let local = TerminalView(frame: localWindow.contentLayoutRect)
        let recorder = LocalKeyRecorder()
        local.terminalDelegate = recorder
        localWindow.contentView = local
        #expect(localWindow.makeFirstResponder(local))

        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw TransportError("socketpair") }
        let mirror = MirrorHelper(socket: fds[1], capabilities: capabilities)
        let session = RemoteSession(socket: fds[0], clientName: "parity", build: "parity")
        let remote = RemoteTerminalView(session: session, font: font)
        let remoteWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                                    styleMask: [.titled], backing: .buffered, defer: false)
        remoteWindow.contentView = remote
        session.start(size: WireGridSize(columns: 80, rows: 24), focused: true)
        #expect(remoteWindow.makeFirstResponder(remote))
        try await wait("connected") { session.state.connected }
        return Panes(local: local, recorder: recorder, localWindow: localWindow, mirror: mirror,
                     session: session, remote: remote, remoteWindow: remoteWindow)
    }

    /// Sets a mode in both panes and waits until the persistent pane knows it.
    func setMode(_ mode: Mode, in panes: Panes) async throws {
        panes.local.feed(text: mode.setup)
        panes.mirror.feed(mode.setup)
        let expectedModes = panes.mirror.terminal.terminalLock.withLock { panes.mirror.terminal.hostInputModes }
        try await wait("modes for \(mode.name)") { panes.session.state.inputModes & 0xffff == expectedModes & 0xffff }
        panes.local.optionAsMetaKey = mode.optionAsMeta
        panes.remote.optionAsMetaKey = mode.optionAsMeta
        panes.local.backspaceSendsControlH = mode.backspaceSendsControlH
        panes.remote.backspaceSendsControlH = mode.backspaceSendsControlH
    }

    /// What the program of the persistent pane gets for `send`.
    func remoteBytes(_ panes: Panes, _ name: String, _ send: () throws -> Void) async throws -> [UInt8] {
        panes.mirror.output.withLock { $0 = [] }
        try send()
        // A marker after the key: everything before it is the key's bytes.
        panes.session.send(bytes: [0xff])
        try await wait(name) { panes.mirror.output.withLock { $0.last == 0xff } }
        return panes.mirror.output.withLock { Array($0.dropLast()) }
    }

    /// Types every key in every mode in both panes: a press and a release,
    /// and Left Shift down and up. Returns what the local pane sent and the
    /// keys that differ.
    func compareKeys(_ panes: Panes) async throws -> (sent: [String: [UInt8]], mismatches: [String], compared: Int) {
        var mismatches: [String] = []
        var compared = 0
        var sent: [String: [UInt8]] = [:]
        for mode in Self.modes {
            try await setMode(mode, in: panes)
            for key in Self.keys + [nil] {
                panes.recorder.bytes = []
                if let key {
                    panes.local.keyDown(with: try event(key, in: panes.localWindow))
                    panes.local.keyUp(with: try release(key, in: panes.localWindow))
                } else {
                    try shiftEvents(in: panes.localWindow).forEach(panes.local.flagsChanged)
                }
                let localBytes = panes.recorder.bytes
                let name = key?.name ?? "left shift"

                let remoteBytes = try await remoteBytes(panes, "\(name) in \(mode.name)") {
                    if let key {
                        panes.remote.keyDown(with: try event(key, in: panes.remoteWindow))
                        panes.remote.keyUp(with: try release(key, in: panes.remoteWindow))
                    } else {
                        try shiftEvents(in: panes.remoteWindow).forEach(panes.remote.flagsChanged)
                    }
                }

                compared += 1
                sent["\(mode.name) / \(name)"] = localBytes
                if localBytes != remoteBytes {
                    mismatches.append("\(mode.name) / \(name): local \(Self.hex(localBytes)) remote \(Self.hex(remoteBytes))")
                }
            }
        }
        return (sent, mismatches, compared)
    }

    @Test func keysSendTheSameBytesAsLocalPanes() async throws {
        let panes = try await makePanes()
        defer { panes.close() }
        let (sent, mismatches, compared) = try await compareKeys(panes)
        #expect(compared == Self.modes.count * (Self.keys.count + 1))
        // The new cases send something: Left Shift down and up, a release,
        // Backspace as ^H, and Control on a Cyrillic layout.
        #expect(sent["kitty all flags / left shift"] == Array("\u{1b}[57441;2u\u{1b}[57441;1:3u".utf8))
        #expect(sent["kitty all flags / a"] == Array("\u{1b}[97;;97u\u{1b}[97;1:3u".utf8))
        #expect(sent["backspace sends ^H / delete"] == [0x08])
        #expect(sent["normal / ctrl-cyrillic-ef"] == [0x01])
        let report = mismatches.joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) of \(compared) differ:\n\(report)")
    }

    /// When the modes changed before a key arrived, the helper encodes the
    /// key itself. With the same modes, that gives the same bytes too, except
    /// for one key: without the kitty protocol, SwiftTerm's encoder sends ^H
    /// for Control-Backspace, and the router sends what Backspace sends.
    @Test func helperEncodingSendsTheSameBytesAsLocalPanes() async throws {
        let panes = try await makePanes()
        defer { panes.close() }
        panes.mirror.encodesEveryKey.store(true, ordering: .relaxed)
        let (_, allMismatches, compared) = try await compareKeys(panes)
        let mismatches = allMismatches.filter { !$0.contains(" / ctrl-delete: local 7f remote 08") }
        let report = mismatches.joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) of \(compared) differ:\n\(report)")
    }

    /// The program enables the kitty protocol, and the user types before the
    /// frame with the new modes arrives: the keys get the new modes.
    @Test func aModeChangeCannotRaceAKey() async throws {
        let panes = try await makePanes()
        defer { panes.close() }
        try await setMode(Self.modes[0], in: panes)
        panes.mirror.feed("\u{1b}[>1u", reports: false)
        let keys = Self.keys.filter { ["ctrl-c", "option-f", "escape"].contains($0.name) }
        let bytes = try await remoteBytes(panes, "keys after a mode change") {
            for key in keys {
                panes.remote.keyDown(with: try event(key, in: panes.remoteWindow))
            }
        }
        #expect(Self.hex(bytes) == Self.hex(Array("\u{1b}[99;5u\u{1b}[102;3u\u{1b}[27u".utf8)))
    }

    /// A helper from an older build ignores the options of a key, so the
    /// pane sends the bytes themselves: Backspace still sends ^H.
    @Test func olderHelpersGetTheBytesOfKeys() async throws {
        let panes = try await makePanes(capabilities: SessionCapabilities.helper.subtracting(.keyBytes))
        defer { panes.close() }
        try await setMode(try #require(Self.modes.first { $0.backspaceSendsControlH }), in: panes)
        let delete = try #require(Self.keys.first { $0.name == "delete" })
        let bytes = try await remoteBytes(panes, "backspace") {
            panes.remote.keyDown(with: try event(delete, in: panes.remoteWindow))
        }
        #expect(bytes == [0x08])
    }

    /// With kitty "report all keys", a modifier key goes to the program, but
    /// it keeps the selection (Command-C must still copy it). A key ends it.
    @Test func modifierKeysKeepTheSelection() async throws {
        let panes = try await makePanes()
        defer { panes.close() }
        try await setMode(try #require(Self.modes.first { $0.name == "kitty all flags" }), in: panes)
        panes.remote.selectAll(nil)
        #expect(panes.remote.selectionActive)
        let bytes = try await remoteBytes(panes, "left shift") {
            try shiftEvents(in: panes.remoteWindow).forEach(panes.remote.flagsChanged)
        }
        #expect(!bytes.isEmpty)
        #expect(panes.remote.selectionActive)
        let a = try #require(Self.keys.first { $0.name == "a" })
        _ = try await remoteBytes(panes, "a") {
            panes.remote.keyDown(with: try event(a, in: panes.remoteWindow))
        }
        #expect(!panes.remote.selectionActive)
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.isEmpty ? "(none)" : bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private func wait(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("timed out: \(what)")
    }
}
