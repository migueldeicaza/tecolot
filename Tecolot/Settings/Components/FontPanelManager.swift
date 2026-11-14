import AppKit

@MainActor
final class FontPanelManager: NSObject {
    var onSelect: ((NSFont) -> Void)?
    private var currentFont: NSFont

    override init() {
        currentFont = NSFont.monospacedSystemFont(
            ofSize: NSFont.systemFontSize,
            weight: .regular
        )
        super.init()
    }

    func showFontPanel(fontName: String?, size: CGFloat) {
        currentFont = resolveFont(fontName: fontName, size: size)

        let manager = NSFontManager.shared
        let panel = NSFontPanel.shared

        if panel.isVisible {
            complete()
            return
        }

        panel.delegate = self
        manager.target = self
        manager.action = #selector(changeFont(_:))
        panel.setPanelFont(currentFont, isMultiple: false)
        panel.makeKeyAndOrderFront(nil)
    }

    private func resolveFont(fontName: String?, size: CGFloat) -> NSFont {
        guard
            let fontName,
            let font = NSFont(name: fontName, size: size) else {
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return font
    }

    @objc private func changeFont(_ sender: NSFontManager?) {
        guard let sender else {
            return
        }
        let font = sender.convert(currentFont)
        guard font.isFixedPitch else {
            return
        }
        currentFont = font
        onSelect?(font)
    }

    private func complete() {
        let manager = NSFontManager.shared
        if manager.target === self {
            manager.target = nil
        }

        let panel = NSFontPanel.shared
        if panel.delegate === self {
            panel.delegate = nil
        }
        panel.orderOut(nil)
    }
}

extension FontPanelManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        complete()
    }
}
