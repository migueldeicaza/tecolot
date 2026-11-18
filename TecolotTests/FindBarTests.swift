import AppKit
import SwiftTerm
import Testing
@testable import Tecolot

@MainActor
struct FindBarTests {
    final class Recorder: TerminalFindBarDelegate {
        var events: [String] = []
        func findBarSearchTextChanged(_ bar: TerminalFindBar) {
            events.append("text:\(bar.searchText)")
        }
        func findBarOptionsChanged(_ bar: TerminalFindBar) {
            events.append("options")
        }
        func findBar(_ bar: TerminalFindBar, findNext forward: Bool) {
            events.append(forward ? "next" : "previous")
        }
        func findBarClose(_ bar: TerminalFindBar) {
            events.append("close")
        }
    }

    @Test func statusShowsTheMatchCount() {
        let bar = FindBar()
        #expect(bar.statusText.isEmpty)
        bar.setFindStatus(.matches(current: 1, total: 1896, capped: false))
        #expect(bar.statusText == "1/1896")
        bar.setFindStatus(.matches(current: 3, total: 1000, capped: true))
        #expect(bar.statusText == "3/1000+")
        // A match whose count is still to come keeps the count on screen.
        bar.setFindStatus(.found)
        #expect(bar.statusText == "3/1000+")
        #expect(bar.showsMatchCount)
        bar.setFindStatus(.matches(current: 0, total: 7, capped: false))
        #expect(bar.statusText == "7")
        bar.setFindStatus(.notFound)
        #expect(bar.statusText == "Not found")
        bar.setFindStatus(.message("Invalid regular expression"))
        #expect(bar.statusText == "Invalid regular expression")
        // A bar that was hidden starts without the old count.
        bar.setFindStatus(.matches(current: 3, total: 14, capped: false))
        bar.isHidden = true
        bar.isHidden = false
        bar.setFindStatus(.found)
        #expect(bar.statusText.isEmpty)
        // Without a count to keep, a match clears the status.
        bar.setFindStatus(.found)
        #expect(bar.statusText.isEmpty)
        bar.setFindStatus(.notFound)
        bar.setFindStatus(.none)
        #expect(bar.statusText.isEmpty)
    }

    @Test func aLongMessageWidensTheBar() {
        let bar = FindBar()
        bar.translatesAutoresizingMaskIntoConstraints = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 100))
        host.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: host.topAnchor),
            bar.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        bar.setFindStatus(.matches(current: 1, total: 1896, capped: false))
        host.layoutSubtreeIfNeeded()
        #expect(bar.frame.width == 440)
        bar.setFindStatus(.message("Invalid regular expression"))
        host.layoutSubtreeIfNeeded()
        #expect(bar.frame.width > 440)
        #expect(bar.frame.width <= 560)
        bar.setFindStatus(.notFound)
        host.layoutSubtreeIfNeeded()
        #expect(bar.frame.width == 440)
    }

    @Test func controlsReportToTheDelegate() throws {
        let bar = FindBar()
        let recorder = Recorder()
        bar.findBarDelegate = recorder
        // Setting the query is not an edit.
        bar.searchText = "zebra"
        #expect(recorder.events.isEmpty)
        bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: bar.field))
        #expect(recorder.events == ["text:zebra"])
        // A pasted line break is dropped.
        bar.field.stringValue = "zebra\n"
        bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: bar.field))
        #expect(bar.searchText == "zebra")
        #expect(recorder.events == ["text:zebra", "text:zebra"])
        recorder.events.removeLast()
        // So is one in a query that the terminal sets, from a selection.
        bar.searchText = "ze\nbra"
        #expect(bar.searchText == "zebra")
        #expect(recorder.events == ["text:zebra"])

        func button(_ tooltip: String) throws -> NSButton {
            var found: NSButton?
            func visit(_ view: NSView) {
                if let button = view as? NSButton, button.toolTip == tooltip {
                    found = button
                }
                view.subviews.forEach(visit)
            }
            visit(bar)
            return try #require(found)
        }
        #expect(bar.options == SearchOptions())
        // An option that is on shows in the accent color, at the same width.
        let caseSensitive = try button("Case Sensitive")
        let width = caseSensitive.intrinsicContentSize.width
        func color() -> NSColor? {
            caseSensitive.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        }
        #expect(color() == .tertiaryLabelColor)
        try button("Case Sensitive").performClick(nil)
        #expect(color() == .controlAccentColor)
        #expect(caseSensitive.intrinsicContentSize.width == width)
        try button("Whole Word").performClick(nil)
        #expect(bar.options == SearchOptions(caseSensitive: true, regex: false, wholeWord: true))
        try button("Regular Expression").performClick(nil)
        #expect(bar.options.regex)
        try button("Previous").performClick(nil)
        try button("Next").performClick(nil)
        try button("Close").performClick(nil)
        #expect(recorder.events == ["text:zebra", "options", "options", "options", "previous", "next", "close"])
    }
}
