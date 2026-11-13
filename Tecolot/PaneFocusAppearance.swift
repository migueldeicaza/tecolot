import AppKit

/// Focus decoration shared by cards and the settings preview.
struct PaneFocusAppearance {
    let lineWidth: CGFloat
    let stroke: NSColor
    let header: NSColor
    let shadow: NSColor
    let shadowOpacity: Float

    /// Keeps neutral edges when highlighting is off and preserves a contrast outline.
    init(
        enabled: Bool,
        focused: Bool,
        hasMultiplePanes: Bool = true,
        showsHeader: Bool,
        style: GlobalAppearanceSettings.PaneStyle,
        highlight: Bool,
        color: NSColor,
        foreground: NSColor,
        background: NSColor,
        highContrast: Bool
    ) {
        let decorated = style.showsDecorations
        let outlinesFocus = decorated || highContrast || !showsHeader
        let highlighted = focused && highlight && hasMultiplePanes
        lineWidth = enabled && outlinesFocus ? (focused && (highlighted || highContrast) ? 2 : 1) : 0
        stroke = outlinesFocus && highlighted && (!highContrast || color.alphaComponent >= 0.8)
            ? color : foreground.withAlphaComponent(highContrast ? 0.8 : 0.10)
        if focused && !decorated && (highlighted || highContrast) {
            header = (background.blended(
                withFraction: highContrast ? 0.16 : 0.10 * color.alphaComponent,
                of: highlight ? color.withAlphaComponent(1) : foreground
            ) ?? background)
                .withAlphaComponent(background.alphaComponent)
        } else {
            header = background
        }
        shadow = highlighted ? color.withAlphaComponent(1) : .black
        shadowOpacity = enabled && decorated ? (highlighted ? Float(0.18 * color.alphaComponent) : 0.08) : 0
    }
}
