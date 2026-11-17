//
//  HostKeyConfirmation.swift
//  Tecolot
//
//  The sheet that asks the user to accept the key of a host that SSH does
//  not know. It shows the fingerprint from the SSH text in groups that are
//  easy to compare.
//

import AppKit

/// The values in the SSH text for an unknown host key.
struct HostKeyFingerprint: Equatable {
    let hostName: String
    let address: String
    /// For example "ED25519".
    let keyType: String
    /// "SHA256" or "MD5".
    let hash: String
    /// The fingerprint without the hash prefix.
    let value: String

    /// The fingerprint as SSH shows it, for example "SHA256:abc…".
    var full: String { "\(hash):\(value)" }

    /// Groups of 4 characters, 6 groups on each line.
    var groupedLines: [String] {
        let characters = Array(value)
        let groups = stride(from: 0, to: characters.count, by: 4).map {
            String(characters[$0..<min($0 + 4, characters.count)])
        }
        return stride(from: 0, to: groups.count, by: 6).map {
            groups[$0..<min($0 + 6, groups.count)].joined(separator: " ")
        }
    }

    /// Nil if one of the two patterns does not match.
    init?(sshText text: String) {
        let host = /authenticity of host '([^ ]+) \(([^)]+)\)'/
        let key = /(\w+) key fingerprint is (SHA256|MD5):(\S+)/
        guard let hostMatch = text.firstMatch(of: host), let keyMatch = text.firstMatch(of: key) else { return nil }
        hostName = String(hostMatch.1)
        address = String(hostMatch.2)
        keyType = String(keyMatch.1)
        hash = String(keyMatch.2)
        value = String(keyMatch.3)
    }
}

@MainActor
enum HostKeyConfirmation {
    static let width: CGFloat = 360

    /// Sets the text and the accessory view of `alert`. Returns false if the
    /// SSH text has no fingerprint: the alert then shows the SSH text.
    static func configure(_ alert: NSAlert, sshText: String) -> Bool {
        guard let fingerprint = HostKeyFingerprint(sshText: sshText) else { return false }
        alert.informativeText = "Tecolot has not connected to \(fingerprint.hostName) (\(fingerprint.address)) before. Compare this fingerprint with the one from the server’s administrator."
        alert.accessoryView = HostKeyAccessoryView(fingerprint: fingerprint, sshText: sshText) { [weak alert] in
            alert?.layout()
        }
        return true
    }
}

final class HostKeyAccessoryView: NSView {
    let fingerprint: HostKeyFingerprint
    private let output: NSScrollView
    private let disclosure = NSButton()
    private let disclosureLabel = NSTextField(labelWithString: "Show SSH Output")
    private let stack: NSStackView
    private let relayout: () -> Void

    init(fingerprint: HostKeyFingerprint, sshText: String, relayout: @escaping () -> Void) {
        self.fingerprint = fingerprint
        self.relayout = relayout
        let caption = NSTextField(labelWithString: "\(fingerprint.keyType) · \(fingerprint.hash)")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        let copy = NSButton(title: "Copy", target: nil, action: nil)
        copy.bezelStyle = .rounded
        copy.controlSize = .small
        copy.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let captionRow = NSStackView(views: [caption, NSView(), copy])
        captionRow.orientation = .horizontal

        let value = NSTextField(wrappingLabelWithString: fingerprint.groupedLines.joined(separator: "\n"))
        value.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        value.isSelectable = true
        value.setAccessibilityLabel("Fingerprint \(fingerprint.full)")

        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.title = ""
        disclosure.state = .off
        disclosureLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let disclosureRow = NSStackView(views: [disclosure, disclosureLabel])
        disclosureRow.orientation = .horizontal
        disclosureRow.spacing = 4

        let text = NSTextView()
        text.string = sshText
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 2, height: 2)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        output = NSScrollView()
        output.documentView = text
        output.hasVerticalScroller = true
        output.borderType = .bezelBorder
        output.isHidden = true
        let lineHeight = (text.font.map { NSLayoutManager().defaultLineHeight(for: $0) } ?? 13)
        let lines = CGFloat(max(1, sshText.split(whereSeparator: \.isNewline).count))
        let outputHeight = min(120, lines * lineHeight + 8)

        stack = NSStackView(views: [captionRow, value, disclosureRow, output])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        super.init(frame: NSRect(x: 0, y: 0, width: HostKeyConfirmation.width, height: 10))
        addSubview(stack)
        let width = HostKeyConfirmation.width
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.widthAnchor.constraint(equalToConstant: width),
            captionRow.widthAnchor.constraint(equalToConstant: width),
            value.widthAnchor.constraint(equalToConstant: width),
            output.widthAnchor.constraint(equalToConstant: width),
            output.heightAnchor.constraint(equalToConstant: outputHeight),
        ])
        copy.target = self
        copy.action = #selector(copyFingerprint)
        disclosure.target = self
        disclosure.action = #selector(toggleOutput)
        let click = NSClickGestureRecognizer(target: self, action: #selector(toggleFromLabel))
        disclosureLabel.addGestureRecognizer(click)
        fitHeight()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    var isShowingOutput: Bool { !output.isHidden }

    private func fitHeight() {
        stack.layoutSubtreeIfNeeded()
        setFrameSize(NSSize(width: HostKeyConfirmation.width, height: stack.fittingSize.height))
    }

    /// The full fingerprint with its hash prefix.
    @objc func copyFingerprint() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fingerprint.full, forType: .string)
    }

    @objc func toggleFromLabel() {
        disclosure.state = disclosure.state == .on ? .off : .on
        toggleOutput()
    }

    @objc func toggleOutput() {
        output.isHidden = disclosure.state != .on
        fitHeight()
        relayout()
    }
}
