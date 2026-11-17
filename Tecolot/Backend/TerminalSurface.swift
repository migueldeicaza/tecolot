//
// TerminalSurface.swift
// Tecolot
//
// What the pane chrome (container, cards, titlebars, divider limits) needs
// from a terminal view (TerminalSurface), and the operations that the pane
// controller runs on it (TerminalPaneSurface). A local pane uses SwiftTerm's
// LocalProcessTerminalView; a persistent pane uses RemoteTerminalView, which
// draws a session that runs in tecolot-sessiond. The controller calls the
// operations without knowing the kind of pane.
//

import AppKit
import SwiftTerm
import TecolotWire

protocol TerminalSurface: AnyObject {
    var nativeForegroundColor: NSColor { get }
    var nativeBackgroundColor: NSColor { get }
    /// The grid that fits in the view.
    var gridDimensions: (cols: Int, rows: Int) { get }
    var selectionActive: Bool { get }
    func requestRedraw()
}

protocol TerminalPaneSurface: TerminalSurface {
    var font: NSFont { get set }
    var backgroundOpacity: CGFloat { get set }
    var allowMouseReporting: Bool { get set }
    var optionAsMetaKey: Bool { get set }
    var isUsingMetalRenderer: Bool { get }
    var metalBufferingMode: MetalBufferingMode { get set }
    func setUseMetal(_ enabled: Bool) throws
    /// Resets the terminal. `.clearToStart` sends nothing to the program.
    func applyReset(_ action: ResetAction)
    /// Runs a Find menu action.
    func runFindAction(_ action: NSTextFinder.Action)
    /// Sends text to the program as if the user typed it.
    func sendTypedText(_ text: String)
    /// Scrolls the viewport by `rows` (negative: up).
    func scrollRows(by rows: Int)
    /// Scrolls to the closest shell prompt above or below the viewport.
    /// Returns false when the view knows at once that there is none.
    func jumpToPrompt(upward: Bool) -> Bool
    /// The text of the whole buffer. A persistent pane asks the helper.
    func bufferText(_ completion: @escaping @MainActor (String) -> Void)
    /// The selected text, or nil when there is no selection.
    func selectedText(_ completion: @escaping @MainActor (String?) -> Void)
}

extension LocalProcessTerminalView: TerminalPaneSurface {
    var gridDimensions: (cols: Int, rows: Int) {
        let dimensions = terminalDimensions
        return (dimensions.cols, dimensions.rows)
    }

    func applyReset(_ action: ResetAction) {
        switch action {
        case .soft: softReset()
        case .hard: resetToInitialState()
        case .clearScrollback: clearScrollback()
        case .clearToStart: TerminalClearAction.perform(on: self)
        }
    }

    func runFindAction(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        performTextFinderAction(item)
    }

    func sendTypedText(_ text: String) {
        send(txt: text)
    }

    func scrollRows(by rows: Int) {
        let state = terminalStateSnapshot()
        scrollTo(row: max(0, state.viewportRow + rows))
    }

    func jumpToPrompt(upward: Bool) -> Bool {
        guard let row = upward ? previousSemanticPromptRow() : nextSemanticPromptRow() else { return false }
        scrollTo(row: row)
        return true
    }

    func bufferText(_ completion: @escaping @MainActor (String) -> Void) {
        completion(String(decoding: getBufferAsData(), as: UTF8.self))
    }

    func selectedText(_ completion: @escaping @MainActor (String?) -> Void) {
        completion(getSelection())
    }
}
