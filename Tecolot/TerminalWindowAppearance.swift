//
//  TerminalWindowAppearance.swift
//  Tecolot
//

import AppKit

@MainActor
enum TerminalWindowAppearance {
    private static let themeBackgrounds = NSMapTable<NSWindow, NSColor>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )

    static func apply(theme: TerminalTheme?, to window: NSWindow) {
        window.appearance = theme.flatMap {
            NSAppearance(named: $0.isDark ? .darkAqua : .aqua)
        }
        if let theme {
            let background = theme.background
            themeBackgrounds.setObject(
                NSColor(
                    srgbRed: CGFloat(background.red) / 65_535,
                    green: CGFloat(background.green) / 65_535,
                    blue: CGFloat(background.blue) / 65_535,
                    alpha: 1
                ),
                forKey: window
            )
        } else {
            themeBackgrounds.removeObject(forKey: window)
        }
        scheduleChromeRefresh(for: window)
    }

    static func scheduleChromeRefresh(for window: NSWindow) {
        // AppKit moves and reuses the native tab bar while selecting a tab.
        // Refresh on the next turn, after that view hierarchy has settled.
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            window.toolbar?.validateVisibleItems()
            guard let frameView = window.contentView?.superview else { return }
            let chromeView = firstDescendant(named: "NSTitlebarContainerView", in: frameView)
                ?? frameView
            applyBackground(themeBackgrounds.object(forKey: window), to: chromeView)
            invalidate(chromeView)
            chromeView.layoutSubtreeIfNeeded()
            chromeView.displayIfNeeded()
        }
    }

    /// Colors AppKit's native titlebar instead of placing a SwiftUI toolbar
    /// background over it. This preserves the native, full-height drag region
    /// and follows Ghostty's MIT-licensed transparent-titlebar implementation:
    /// https://github.com/ghostty-org/ghostty/blob/main/macos/Sources/Features/Terminal/Window%20Styles/TransparentTitlebarTerminalWindow.swift
    private static func applyBackground(_ color: NSColor?, to chromeView: NSView) {
        if #available(macOS 26.0, *) {
            guard let titlebarView = firstDescendant(named: "NSTitlebarView", in: chromeView)
            else { return }
            titlebarView.wantsLayer = color != nil
            titlebarView.layer?.backgroundColor = color?.cgColor
            firstDescendant(named: "NSTitlebarBackgroundView", in: chromeView)?.isHidden =
                color != nil
        } else {
            chromeView.wantsLayer = color != nil
            chromeView.layer?.backgroundColor = color?.cgColor
            chromeView.window?.titlebarAppearsTransparent = color != nil
        }
    }

    private static func invalidate(_ view: NSView) {
        view.needsLayout = true
        view.needsDisplay = true
        view.layer?.setNeedsDisplay()
        view.subviews.forEach(invalidate)
    }

    private static func firstDescendant(named className: String, in view: NSView) -> NSView? {
        if view.className == className {
            return view
        }
        for subview in view.subviews {
            if let match = firstDescendant(named: className, in: subview) {
                return match
            }
        }
        return nil
    }
}
