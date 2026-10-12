//
//  RemoteFindBar.swift
//  Tecolot
//
//  Find for persistent panes. The helper searches the whole scrollback; the
//  bar only collects the query and the options. It looks and behaves like
//  the find bar of SwiftTerm's TerminalView, which local panes show.
//

import AppKit

final class RemoteFindBar: NSVisualEffectView, NSSearchFieldDelegate {
    let field = NSSearchField()
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let closeButton = NSButton()
    private let caseButton = NSButton(checkboxWithTitle: "Aa", target: nil, action: nil)
    private let regexButton = NSButton(checkboxWithTitle: ".*", target: nil, action: nil)
    private let wordButton = NSButton(checkboxWithTitle: "Word", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")

    /// The query changed (typing) or an option changed: search again from
    /// where the find started.
    var onQueryChange: (() -> Void)?
    /// Return, Shift-Return or a chevron: go to the next or previous match.
    var onSearch: ((_ backward: Bool) -> Void)?
    var onClose: (() -> Void)?

    var query: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }
    var caseSensitive: Bool { caseButton.state == .on }
    var regularExpression: Bool { regexButton.state == .on }
    var wholeWord: Bool { wordButton.state == .on }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        material = .popover
        blendingMode = .withinWindow
        state = .active
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        field.placeholderString = "Find"
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)

        configure(previousButton, symbol: "chevron.up", tooltip: "Previous", action: #selector(previousTapped))
        configure(nextButton, symbol: "chevron.down", tooltip: "Next", action: #selector(nextTapped))
        configure(closeButton, symbol: "xmark", tooltip: "Close", action: #selector(closeTapped))
        for (button, tooltip) in [(caseButton, "Case Sensitive"), (regexButton, "Regex"), (wordButton, "Whole Word")] {
            button.setButtonType(.switch)
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.toolTip = tooltip
            button.target = self
            button.action = #selector(optionChanged)
        }
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.isHidden = true

        let stack = NSStackView(views: [field, status, previousButton, nextButton,
                                        caseButton, regexButton, wordButton, closeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.bezelStyle = .texturedRounded
        button.setButtonType(.momentaryPushIn)
        button.controlSize = .small
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.toolTip = tooltip
        button.target = self
        button.action = action
    }

    /// Shows a short status ("Not found", or a pattern error); empty hides it.
    func setStatus(_ text: String) {
        status.stringValue = text
        status.toolTip = text.isEmpty ? nil : text
        status.lineBreakMode = .byTruncatingTail
        status.isHidden = text.isEmpty
    }

    func focus() {
        window?.makeFirstResponder(field)
    }

    @objc private func previousTapped() { onSearch?(true) }
    @objc private func nextTapped() { onSearch?(false) }
    @objc private func closeTapped() { onClose?() }
    @objc private func optionChanged() { onQueryChange?() }

    func controlTextDidChange(_ notification: Notification) {
        onQueryChange?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            onClose?()
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            let backward = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            onSearch?(backward)
            return true
        }
        return false
    }
}
