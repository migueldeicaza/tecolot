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

    init(socket: Int32) {
        channel = MessageChannel(socket: socket)
        terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 24))
        channel.onMessage = { [weak self] envelope in self?.handle(envelope) }
        channel.start()
    }

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        output.withLock { $0 += data }
    }

    /// Feeds output to the terminal (for example a mode change) and reports
    /// the new modes to the client.
    func feed(_ text: String) {
        channel.queue.sync {
            terminal.terminalLock.withLock { terminal.feed(text: text) }
            sendFrame()
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
                                               capabilities: .helper, sessionID: "mirror"),
                             requestID: envelope.requestID)
            case .attach:
                sendFrame()
            // The same calls as SessionHost.handleKey, the .text case and the .input case.
            case .key:
                let key = try envelope.decode(KeyMessage.self)
                terminal.terminalLock.withLock {
                    let result = terminal.sendHostKey(key: key.key, code: key.code, modifiers: key.modifiers,
                                                      eventType: key.eventType, text: key.text,
                                                      shiftedKey: key.shiftedKey, baseLayoutKey: key.baseLayoutKey)
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
        return keys
    }()

    static let modes: [Mode] = [
        Mode(name: "normal", setup: "\u{1b}[?1l\u{1b}>"),
        Mode(name: "application cursor and keypad", setup: "\u{1b}[?1h\u{1b}="),
        Mode(name: "option is not meta", setup: "\u{1b}[?1l\u{1b}>", optionAsMeta: false),
        Mode(name: "kitty disambiguate", setup: "\u{1b}[>1u"),
        Mode(name: "kitty all flags", setup: "\u{1b}[>31u"),
    ]

    func event(_ key: Key, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: key.modifiers, timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil,
                                      characters: key.characters, charactersIgnoringModifiers: key.ignoringModifiers,
                                      isARepeat: false, keyCode: key.keyCode))
    }

    @Test func keysSendTheSameBytesAsLocalPanes() async throws {
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
        let mirror = MirrorHelper(socket: fds[1])
        let session = RemoteSession(socket: fds[0], clientName: "parity", build: "parity")
        let remote = RemoteTerminalView(session: session, font: font)
        let remoteWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                                    styleMask: [.titled], backing: .buffered, defer: false)
        remoteWindow.contentView = remote
        session.start(size: WireGridSize(columns: 80, rows: 24), focused: true)
        #expect(remoteWindow.makeFirstResponder(remote))
        try await wait("connected") { session.state.connected }

        var mismatches: [String] = []
        var compared = 0
        for mode in Self.modes {
            local.feed(text: mode.setup)
            mirror.feed(mode.setup)
            let expectedModes = mirror.terminal.terminalLock.withLock { mirror.terminal.hostInputModes }
            try await wait("modes for \(mode.name)") { session.state.inputModes & 0xffff == expectedModes & 0xffff }
            local.optionAsMetaKey = mode.optionAsMeta
            remote.optionAsMetaKey = mode.optionAsMeta

            for key in Self.keys {
                recorder.bytes = []
                local.keyDown(with: try event(key, in: localWindow))
                let localBytes = recorder.bytes

                mirror.output.withLock { $0 = [] }
                remote.keyDown(with: try event(key, in: remoteWindow))
                // A marker after the key: everything before it is the key's bytes.
                session.send(bytes: [0xff])
                try await wait("\(key) in \(mode.name)") { mirror.output.withLock { $0.last == 0xff } }
                let remoteBytes = mirror.output.withLock { Array($0.dropLast()) }

                compared += 1
                if localBytes != remoteBytes {
                    mismatches.append("\(mode.name) / \(key): local \(Self.hex(localBytes)) remote \(Self.hex(remoteBytes))")
                }
            }
        }
        #expect(compared == Self.modes.count * Self.keys.count)
        let report = mismatches.joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(mismatches.count) of \(compared) differ:\n\(report)")
        session.close()
        mirror.channel.close()
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
