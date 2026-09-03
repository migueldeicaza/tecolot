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
    /// Windows with a refresh already queued for the next turn of the main
    /// queue. Every pane of a split observes the same window, so without this
    /// an N-pane window would walk the titlebar tree N times per activation.
    private static let pendingRefreshes = NSHashTable<NSWindow>.weakObjects()
    /// Windows whose chrome already shows the stored state. A window is absent
    /// while its titlebar is out of reach (it is not built yet, or the window
    /// is in full screen), which keeps the next update from being skipped.
    private static let settledWindows = NSHashTable<NSWindow>.weakObjects()

    static func apply(theme: TerminalTheme?, backgroundOpacity: Double = 1, to window: NSWindow) {
        let color = theme.map { theme -> NSColor in
            let background = theme.background
            return NSColor(
                srgbRed: CGFloat(background.red) / 65_535,
                green: CGFloat(background.green) / 65_535,
                blue: CGFloat(background.blue) / 65_535,
                // The titlebar is folded into the translucent content region,
                // so an opaque band over a translucent terminal would not match.
                alpha: CGFloat(backgroundOpacity)
            )
        }
        // SwiftUI reapplies this on every update of the terminal view; a
        // repeated refresh would relayout the whole titlebar for nothing.
        guard color != themeBackgrounds.object(forKey: window)
                || !settledWindows.contains(window)
        else { return }

        window.appearance = theme.flatMap {
            NSAppearance(named: $0.isDark ? .darkAqua : .aqua)
        }
        if let color {
            themeBackgrounds.setObject(color, forKey: window)
        } else {
            themeBackgrounds.removeObject(forKey: window)
        }
        scheduleChromeRefresh(for: window)
    }

    static func scheduleChromeRefresh(for window: NSWindow) {
        guard !pendingRefreshes.contains(window) else { return }
        pendingRefreshes.add(window)
        // AppKit moves and reuses the native tab bar while selecting a tab.
        // Refresh on the next turn, after that view hierarchy has settled.
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            pendingRefreshes.remove(window)
            window.toolbar?.validateVisibleItems()
            guard let frameView = window.contentView?.superview,
                  let chromeView = firstDescendant(named: "NSTitlebarContainerView", in: frameView)
            else {
                // In full screen AppKit hosts the titlebar in a separate
                // window. There is no chrome to color here; a later refresh
                // reapplies the current state when it comes back.
                settledWindows.remove(window)
                return
            }
            let settled = applyBackground(themeBackgrounds.object(forKey: window), to: chromeView)
            if settled {
                settledWindows.add(window)
            } else {
                settledWindows.remove(window)
            }
            invalidate(chromeView)
            chromeView.layoutSubtreeIfNeeded()
            chromeView.displayIfNeeded()
        }
    }

    /// Colors AppKit's native titlebar instead of placing a SwiftUI toolbar
    /// background over it. This preserves the native, full-height drag region
    /// and follows Ghostty's MIT-licensed transparent-titlebar implementation:
    /// https://github.com/ghostty-org/ghostty/blob/main/macos/Sources/Features/Terminal/Window%20Styles/TransparentTitlebarTerminalWindow.swift
    /// Returns whether the chrome now shows `color`.
    @discardableResult
    private static func applyBackground(_ color: NSColor?, to chromeView: NSView) -> Bool {
        if #available(macOS 26.0, *) {
            let backgroundView = firstDescendant(named: "NSTitlebarBackgroundView", in: chromeView)
            let titlebarView = firstDescendant(named: "NSTitlebarView", in: chromeView)
            titlebarView?.wantsLayer = color != nil
            titlebarView?.layer?.backgroundColor = color?.cgColor
            // Hide the native background only once the themed layer replaces
            // it, and always restore it when the theme is removed.
            backgroundView?.isHidden = color != nil && titlebarView != nil
            return titlebarView != nil
        } else {
            chromeView.wantsLayer = color != nil
            chromeView.layer?.backgroundColor = color?.cgColor
            chromeView.window?.titlebarAppearsTransparent = color != nil
            return true
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
