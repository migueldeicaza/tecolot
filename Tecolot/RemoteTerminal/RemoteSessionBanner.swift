//
//  RemoteSessionBanner.swift
//  Tecolot
//
//  A small bar at the bottom of a persistent pane for session state that is
//  not terminal output: the shell ended, or the connection to the helper
//  dropped.
//

import AppKit

final class RemoteSessionBanner: NSView {
    private let label = NSTextField(labelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private let secondaryButton = NSButton(title: "", target: nil, action: nil)
    private var handler: (() -> Void)?
    private var secondaryHandler: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.lineBreakMode = .byTruncatingTail
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = #selector(buttonPressed)
        secondaryButton.bezelStyle = .rounded
        secondaryButton.controlSize = .small
        secondaryButton.target = self
        secondaryButton.action = #selector(secondaryButtonPressed)
        let stack = NSStackView(views: [label, button, secondaryButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    /// A CGColor does not follow the appearance, so the colors are set again
    /// with the appearance of the view: the window of a dark theme is dark.
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    var text: String { label.stringValue }

    func configure(text: String, actionTitle: String?, action: (() -> Void)?,
                   secondaryActionTitle: String? = nil, secondaryAction: (() -> Void)? = nil) {
        label.stringValue = text
        button.title = actionTitle ?? ""
        button.isHidden = actionTitle == nil
        handler = action
        secondaryButton.title = secondaryActionTitle ?? ""
        secondaryButton.isHidden = secondaryActionTitle == nil
        secondaryHandler = secondaryAction
    }

    @objc private func buttonPressed() {
        handler?()
    }

    @objc private func secondaryButtonPressed() {
        secondaryHandler?()
    }
}
