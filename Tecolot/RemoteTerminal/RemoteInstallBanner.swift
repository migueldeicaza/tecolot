//
//  RemoteInstallBanner.swift
//  Tecolot
//
//  A bar at the top of a remote pane that asks before Tecolot installs its
//  helper on a host for the first time. The terminal content moves down
//  below it.
//

import AppKit

final class RemoteInstallBanner: NSView {
    let prompt: RemoteInstallPrompt
    private let titleLabel: NSTextField
    private let textLabel: NSTextField
    private let notNowButton = NSButton(title: "Not Now", target: nil, action: nil)
    private let installButton = PaneDefaultButton(title: "Install", target: nil, action: nil)
    private let answer: (Bool) -> Void

    /// `isActive` tells when Return belongs to this banner: the pane under
    /// it has the focus.
    init(prompt: RemoteInstallPrompt, isActive: @escaping () -> Bool, answer: @escaping (Bool) -> Void) {
        self.prompt = prompt
        self.answer = answer
        titleLabel = NSTextField(labelWithString: prompt.title)
        textLabel = NSTextField(wrappingLabelWithString: prompt.text)
        super.init(frame: .zero)
        wantsLayer = true
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        textLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        textLabel.textColor = .secondaryLabelColor
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for button in [notNowButton, installButton] {
            button.bezelStyle = .rounded
            button.target = self
        }
        notNowButton.action = #selector(notNow)
        installButton.action = #selector(install)
        installButton.keyEquivalent = "\r"
        installButton.isActive = isActive

        let texts = NSStackView(views: [titleLabel, textLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        let buttons = NSStackView(views: [notNowButton, installButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.setHuggingPriority(.required, for: .horizontal)
        buttons.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [texts, buttons])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        addSubview(separator)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: separator.topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(prompt.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    /// A CGColor does not follow the appearance, so the color is set again
    /// with the appearance of the view: the window of a dark theme is dark.
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    @objc func install() { answer(true) }
    @objc func notNow() { answer(false) }
}

/// A default button in a pane. Return activates it only while its pane has
/// the focus, so that Return in another pane does not.
final class PaneDefaultButton: NSButton {
    var isActive: () -> Bool = { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isActive() else { return false }
        return super.performKeyEquivalent(with: event)
    }
}
