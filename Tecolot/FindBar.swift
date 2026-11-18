//
//  FindBar.swift
//  Tecolot
//
//  The find bar of every pane: a pill with the query, the status, the
//  options and the next, previous and close buttons. Local panes get it
//  through SwiftTerm's `findBarProvider`, and the status is a match count
//  ("2/14"). Persistent panes show it themselves: their helper searches the
//  whole scrollback and reports one match at a time, so there the status
//  only says "Not found" or what is wrong with the pattern.
//

import AppKit
import SwiftTerm

final class FindBar: NSView, TerminalFindBar, NSTextFieldDelegate {
    private enum Layout {
        static let height: CGFloat = 38
        /// The terminal places the bar 8 points under its top edge. The pill
        /// is drawn this much higher, to sit just under the pane's header.
        static let lift: CGFloat = 6
        static let preferredWidth: CGFloat = 440
        static let maximumWidth: CGFloat = 560
        static let minimumFieldWidth: CGFloat = 120
        static let maximumStatusWidth: CGFloat = 170
    }

    weak var findBarDelegate: TerminalFindBarDelegate?
    /// The status is a match count.
    private var showsCount = false

    let field = NSTextField()
    private let status = NSTextField(labelWithString: "")
    private let caseButton = FindOptionButton()
    private let regexButton = FindOptionButton()
    private let wordButton = FindOptionButton()
    private let previousButton = ChromeIconButton(treatment: .window)
    private let nextButton = ChromeIconButton(treatment: .window)
    private let closeButton = ChromeIconButton(treatment: .window)
    private let content = NSView()
    private let background = PillView()

    var searchText: String {
        get { field.stringValue }
        set { field.stringValue = Self.singleLine(newValue) }
    }

    /// A line break cannot match: a search is within one line. This drops
    /// the ones of a pasted text or of a selection of several lines.
    private static func singleLine(_ text: String) -> String {
        text.contains(where: \.isNewline) ? text.filter { !$0.isNewline } : text
    }

    var options: SearchOptions {
        SearchOptions(
            caseSensitive: caseButton.state == .on,
            regex: regexButton.state == .on,
            wholeWord: wordButton.state == .on
        )
    }

    /// The bar shows "2/14", so SwiftTerm counts the matches for it.
    let showsMatchCount = true

    /// The text of the status, for tests.
    var statusText: String {
        status.stringValue
    }

    init() {
        super.init(frame: .zero)

        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        field.placeholderString = "Find"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.setAccessibilityLabel("Find")
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)

        status.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.isHidden = true
        // Just above the bar's preferred width: a count fits, and a long
        // message makes the bar wider, up to its maximum, before it is cut.
        status.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(760), for: .horizontal)
        status.setContentHuggingPriority(.required, for: .horizontal)

        let divider = NSBox()
        divider.boxType = .separator

        configureOption(caseButton, title: "Aa", tooltip: "Case Sensitive")
        configureOption(regexButton, title: ".*", tooltip: "Regular Expression")
        configureOption(wordButton, title: "Word", tooltip: "Whole Word")
        configureSymbol(previousButton, symbol: "chevron.up", tooltip: "Previous", action: #selector(previousTapped))
        configureSymbol(nextButton, symbol: "chevron.down", tooltip: "Next", action: #selector(nextTapped))
        configureSymbol(closeButton, symbol: "xmark", tooltip: "Close", action: #selector(closeTapped))

        let stack = NSStackView(views: [
            field,
            status,
            divider,
            caseButton,
            regexButton,
            wordButton,
            previousButton,
            nextButton,
            closeButton
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.setCustomSpacing(8, after: field)
        stack.setCustomSpacing(9, after: status)
        stack.setCustomSpacing(6, after: divider)
        stack.setCustomSpacing(4, after: wordButton)
        stack.setCustomSpacing(0, after: previousButton)
        stack.setCustomSpacing(0, after: nextButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        let preferredWidth = widthAnchor.constraint(equalToConstant: Layout.preferredWidth)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor, constant: -Layout.lift),
            background.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Layout.lift),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            heightAnchor.constraint(equalToConstant: Layout.height),
            preferredWidth,
            widthAnchor.constraint(lessThanOrEqualToConstant: Layout.maximumWidth),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: Layout.minimumFieldWidth),
            status.widthAnchor.constraint(lessThanOrEqualToConstant: Layout.maximumStatusWidth),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureOption(_ button: FindOptionButton, title: String, tooltip: String) {
        button.label = title
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        button.target = self
        button.action = #selector(optionChanged(_:))
    }

    private func configureSymbol(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    /// The pill is not where the bar's frame is: clicks go by the pill.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else {
            return nil
        }
        let local = convert(point, from: superview)
        guard background.frame.contains(local) else {
            return nil
        }
        for subview in subviews.reversed() {
            if let hit = subview.hitTest(local) {
                return hit
            }
        }
        return self
    }

    // The bar floats over the terminal. A click on its padding, the divider
    // or the status must not reach the terminal, which would drop the
    // selection or send the click to the program.
    override func mouseDown(with event: NSEvent) {
    }

    override func mouseDragged(with event: NSEvent) {
    }

    override func mouseUp(with event: NSEvent) {
    }

    override func rightMouseDown(with event: NSEvent) {
    }

    override func rightMouseUp(with event: NSEvent) {
    }

    override func otherMouseDown(with event: NSEvent) {
    }

    override func otherMouseUp(with event: NSEvent) {
    }

    /// A count belongs to the search that was showing: a bar that is shown
    /// again starts without one.
    override func viewDidHide() {
        super.viewDidHide()
        // Not when it is the pane that was hidden, by a tab switch.
        if isHidden {
            setFindStatus(.none)
        }
    }

    func focusSearchField() {
        window?.makeFirstResponder(field)
    }

    func setFindStatus(_ findStatus: TerminalFindStatus) {
        // While the user types, the new count follows the match by a moment;
        // the old one stays until then instead of flickering away.
        if findStatus == .found, showsCount {
            return
        }
        if case .matches = findStatus {
            showsCount = true
        } else {
            showsCount = false
        }
        let text = Self.text(for: findStatus)
        status.stringValue = text
        status.toolTip = text.isEmpty ? nil : text
        status.isHidden = text.isEmpty
    }

    /// What the bar shows for a status: "2/14", "1000+", "Not found" or a message.
    static func text(for status: TerminalFindStatus) -> String {
        switch status {
        case .none, .found:
            return ""
        case let .matches(current, total, capped):
            let count = capped ? "\(total)+" : "\(total)"
            return current > 0 ? "\(current)/\(count)" : count
        case .notFound:
            return "Not found"
        case let .message(message):
            return message
        }
    }

    @objc private func previousTapped() {
        findBarDelegate?.findBar(self, findNext: false)
    }

    @objc private func nextTapped() {
        findBarDelegate?.findBar(self, findNext: true)
    }

    @objc private func closeTapped() {
        findBarDelegate?.findBarClose(self)
    }

    @objc private func optionChanged(_ sender: NSButton) {
        findBarDelegate?.findBarOptionsChanged(self)
    }

    func controlTextDidChange(_ notification: Notification) {
        let text = field.stringValue
        let line = Self.singleLine(text)
        if line != text {
            field.stringValue = line
        }
        findBarDelegate?.findBarSearchTextChanged(self)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            findBarDelegate?.findBarClose(self)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            let backward = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            findBarDelegate?.findBar(self, findNext: !backward)
            return true
        }
        return false
    }
}

/// One of the options of the find bar: its name, in the accent color when
/// it is on, over a highlight that follows the pointer like the one of the
/// pane buttons.
private final class FindOptionButton: NSButton {
    private static let fontSize: CGFloat = 12

    private var hoverState = ChromeButtonHoverState()
    private var hoverTrackingArea: NSTrackingArea?

    /// The name of the option.
    var label = "" {
        didSet {
            updateTitle()
            invalidateIntrinsicContentSize()
        }
    }

    override var state: NSControl.StateValue {
        didSet { updateTitle() }
    }

    /// The width of the name when the option is on, the wider of the two,
    /// so that the bar does not move when an option changes.
    override var intrinsicContentSize: NSSize {
        let width = (label as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: Self.fontSize, weight: .semibold)
        ]).width
        return NSSize(width: ceil(width) + 12, height: 22)
    }

    init() {
        super.init(frame: .zero)
        setButtonType(.toggle)
        isBordered = false
        (cell as? NSButtonCell)?.highlightsBy = []
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// A click, the keyboard and accessibility change the state in the
    /// cell, without the setter above: the name follows before the action.
    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        updateTitle()
        return super.sendAction(action, to: target)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
        // The status can move another option under a pointer that stays still.
        synchronizeHoverWithPointer()
    }

    private func synchronizeHoverWithPointer() {
        if let window, !isHiddenOrHasHiddenAncestor {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            updateHover(bounds.contains(point) ? .enter : .exit)
        } else {
            updateHover(.unavailable)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(.enter)
    }

    override func mouseExited(with event: NSEvent) {
        updateHover(.exit)
    }

    override func mouseDown(with event: NSEvent) {
        updateHover(.press)
        super.mouseDown(with: event)
        updateHover(.release)
        // The button may have been released away from the option.
        synchronizeHoverWithPointer()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateHover(.unavailable)
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        synchronizeHoverWithPointer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateHover(.unavailable)
    }

    private func updateHover(_ event: ChromeButtonHoverState.Event) {
        let previous = hoverState
        hoverState.send(event)
        if previous != hoverState {
            updateTitle()
            needsDisplay = true
        }
    }

    /// The highlight is drawn under the name.
    override func draw(_ dirtyRect: NSRect) {
        if hoverState.highlighted {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            ChromeIconButton.highlightColor(dark: dark, increasedContrast: contrast, treatment: .window).setFill()
            path.fill()
            if contrast {
                NSColor.secondaryLabelColor.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
        super.draw(dirtyRect)
    }

    /// An option that is on shows in the accent color; one that is off is
    /// dimmed, less so under the pointer.
    private func updateTitle() {
        let on = state == .on
        let color: NSColor = on ? .controlAccentColor : hoverState.highlighted ? .secondaryLabelColor : .tertiaryLabelColor
        let text = NSAttributedString(
            string: label,
            attributes: [
                .font: NSFont.systemFont(ofSize: Self.fontSize, weight: on ? .semibold : .regular),
                .foregroundColor: color,
            ]
        )
        attributedTitle = text
        // A toggle that is on draws its alternate title.
        attributedAlternateTitle = text
    }
}

/// The pill behind the find bar: an opaque fill a little apart from the
/// terminal under it, with a hairline edge and a soft shadow.
private final class PillView: NSView {
    private static let fill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.21, alpha: 1)
            : NSColor(white: 0.90, alpha: 1)
    }
    private static let edge = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.14)
            : NSColor(white: 1, alpha: 0.65)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.shadowBlurRadius = 5
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        self.shadow = shadow
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool {
        true
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func updateLayer() {
        guard let layer else {
            return
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = Self.fill.cgColor
            layer.borderColor = Self.edge.cgColor
        }
        layer.cornerRadius = bounds.height / 2
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        // Without a path the shadow is worked out from the pixels each
        // time the terminal under it changes.
        layer.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: bounds.height / 2,
            cornerHeight: bounds.height / 2,
            transform: nil
        )
    }
}
