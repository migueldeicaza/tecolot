//
//  TerminalSurface.swift
//  Tecolot
//
//  What the pane chrome (container, cards, titlebars, divider limits) needs
//  from a terminal view. A local pane uses SwiftTerm's
//  LocalProcessTerminalView; a persistent pane uses RemoteTerminalView, which
//  draws a session that runs in tecolot-sessiond.
//

import AppKit
import SwiftTerm

protocol TerminalSurface: AnyObject {
    var nativeForegroundColor: NSColor { get }
    var nativeBackgroundColor: NSColor { get }
    /// The grid that fits in the view.
    var gridDimensions: (cols: Int, rows: Int) { get }
    var selectionActive: Bool { get }
    func requestRedraw()
}

extension LocalProcessTerminalView: TerminalSurface {
    var gridDimensions: (cols: Int, rows: Int) {
        let dimensions = terminalDimensions
        return (dimensions.cols, dimensions.rows)
    }
}
