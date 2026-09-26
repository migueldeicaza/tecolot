import AppKit
import SwiftTerm
import Testing
@testable import Tecolot

@MainActor
struct TerminalClearActionTests {
    @Test func clearToStartClearsTheVisibleScreenAndScrollback() {
        let terminal = makeTerminal()
        terminal.feed(text: "one\r\ntwo\r\nthree\r\nfour")

        TerminalClearAction.perform(on: terminal)

        #expect(bufferContents(of: terminal).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func makeTerminal() -> AppTerminalView {
        AppTerminalView(
            frame: .zero,
            font: nil,
            options: TerminalOptions(cols: 20, rows: 3, scrollback: 10)
        )
    }

    private func bufferContents(of terminal: AppTerminalView) -> String {
        String(decoding: terminal.getBufferAsData(), as: UTF8.self)
    }
}
