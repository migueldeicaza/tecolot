import AppKit

/// Insets standalone pane cards while preserving the margins supplied by window chrome.
struct TerminalPaneCardInsets: Equatable {
    var top: CGFloat
    var left: CGFloat
    var bottom: CGFloat
    var right: CGFloat

    static func uniform(_ spacing: CGFloat) -> Self {
        Self(top: spacing, left: spacing, bottom: spacing, right: spacing)
    }

    /// Window chrome already supplies the outside margins, including the integrated header.
    static let window = Self.uniform(0)

    /// Uses AppKit's bottom-up host coordinates and never creates a negative rectangle.
    func frame(in bounds: NSRect) -> NSRect {
        let x = min(left, bounds.width)
        let y = min(bottom, bounds.height)
        return NSRect(
            x: bounds.minX + x,
            y: bounds.minY + y,
            width: max(0, bounds.width - x - right),
            height: max(0, bounds.height - y - top)
        )
    }
}
