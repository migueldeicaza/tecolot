//
//  FindBar.swift
//  Tecolot
//
//  The find bar of every pane: a capsule with the query, the status, the
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
        static let height: CGFloat = 34
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
    private let caseButton = NSButton()
    private let regexButton = NSButton()
    private let wordButton = NSButton()
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let closeButton = NSButton()
    private let content = NSView()
    private let background: NSView

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
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = Layout.height / 2
            glass.contentView = content
            background = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .popover
            material.blendingMode = .withinWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = Layout.height / 2
            material.layer?.masksToBounds = true
            content.translatesAutoresizingMaskIntoConstraints = false
            material.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: material.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: material.trailingAnchor),
                content.topAnchor.constraint(equalTo: material.topAnchor),
                content.bottomAnchor.constraint(equalTo: material.bottomAnchor),
            ])
            background = material
        }
        super.init(frame: .zero)

        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

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

        status.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
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
        stack.spacing = 8
        stack.setCustomSpacing(10, after: status)
        stack.setCustomSpacing(10, after: divider)
        stack.setCustomSpacing(10, after: wordButton)
        stack.setCustomSpacing(2, after: previousButton)
        stack.setCustomSpacing(2, after: nextButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        let preferredWidth = widthAnchor.constraint(equalToConstant: Layout.preferredWidth)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Layout.height),
            preferredWidth,
            widthAnchor.constraint(lessThanOrEqualToConstant: Layout.maximumWidth),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: Layout.minimumFieldWidth),
            status.widthAnchor.constraint(lessThanOrEqualToConstant: Layout.maximumStatusWidth),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureOption(_ button: NSButton, title: String, tooltip: String) {
        button.setButtonType(.toggle)
        button.isBordered = false
        button.title = title
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        button.target = self
        button.action = #selector(optionChanged(_:))
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        styleOption(button)
    }

    /// An option that is on shows in the accent color; one that is off is dimmed.
    private func styleOption(_ button: NSButton) {
        let on = button.state == .on
        let title = NSAttributedString(
            string: button.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: on ? .semibold : .regular),
                .foregroundColor: on ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor,
            ]
        )
        button.attributedTitle = title
        // A toggle that is on draws its alternate title.
        button.attributedAlternateTitle = title
    }

    private func configureSymbol(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.setButtonType(.momentaryChange)
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
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
        styleOption(sender)
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
