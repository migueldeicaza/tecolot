//
//  TerminalWindowAppearance.swift
//  Tecolot
//

import AppKit

@MainActor
enum TerminalWindowAppearance {
    static func apply(theme: TerminalTheme?, to window: NSWindow) {
        window.appearance = theme.flatMap {
            NSAppearance(named: $0.isDark ? .darkAqua : .aqua)
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
            invalidate(chromeView)
            chromeView.layoutSubtreeIfNeeded()
            chromeView.displayIfNeeded()
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
