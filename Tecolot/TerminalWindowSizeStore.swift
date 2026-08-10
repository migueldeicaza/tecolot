//
//  TerminalWindowSizeStore.swift
//  Tecolot
//
//  Saves the size of the last normal terminal window. Window-group restores
//  use their own frames and never replace the normal window size.
//

import AppKit

@MainActor
final class TerminalWindowSizeStore {
    static let shared = TerminalWindowSizeStore()

    private enum DefaultsKey {
        static let lastFrameSize = "lastTerminalWindowFrameSize"
    }

    private var observers: [ObjectIdentifier: WindowObserver] = [:]
    private var suppressedWindowIDs: Set<ObjectIdentifier> = []

    private init() {}

    func configure(_ window: NSWindow, restoresSize: Bool = true) {
        let identifier = ObjectIdentifier(window)
        guard observers[identifier] == nil else { return }

        // macOS puts even a single document window in a tab group. All tabs
        // share one frame, so restoring each tab is safe and ensures that
        // startup document windows restore their saved size.
        if restoresSize {
            restoreSize(to: window)
        }
        observers[identifier] = WindowObserver(
            window: window,
            didResize: { [weak self, weak window] in
                guard let window else { return }
                self?.recordResize(of: window)
            },
            didClose: { [weak self] in
                self?.observers.removeValue(forKey: identifier)
                self?.suppressedWindowIDs.remove(identifier)
            }
        )
    }

    /// Applies a saved window-group frame without saving it as the normal
    /// window size. The frame is constrained to the current screen.
    func restoreWindowGroupFrame(_ savedFrame: NSRect, to window: NSWindow) {
        configure(window, restoresSize: false)
        let identifier = ObjectIdentifier(window)
        suppressedWindowIDs.insert(identifier)
        window.setFrame(constrainedFrame(savedFrame, for: window), display: true)
        DispatchQueue.main.async { [weak self] in
            self?.suppressedWindowIDs.remove(identifier)
        }
    }

    private func restoreSize(to window: NSWindow) {
        guard let storedValue = UserDefaults.standard.string(forKey: DefaultsKey.lastFrameSize) else {
            return
        }

        let size = NSSizeFromString(storedValue)
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else {
            return
        }

        var savedFrame = window.frame
        savedFrame.size = size
        window.setFrame(constrainedFrame(savedFrame, for: window), display: false)
    }

    private func recordResize(of window: NSWindow) {
        let identifier = ObjectIdentifier(window)
        guard !suppressedWindowIDs.contains(identifier), isNormal(window) else {
            return
        }
        save(window.frame.size)
    }

    private func isNormal(_ window: NSWindow) -> Bool {
        !window.styleMask.contains(.fullScreen) && !window.isMiniaturized && !window.isZoomed
    }

    private func constrainedFrame(_ frame: NSRect, for window: NSWindow) -> NSRect {
        guard let screen = window.screen ?? NSScreen.main else { return frame }
        let visibleFrame = screen.visibleFrame
        var frame = frame

        frame.size.width = min(max(frame.width, window.minSize.width), visibleFrame.width)
        frame.size.height = min(max(frame.height, window.minSize.height), visibleFrame.height)
        frame.origin.x = min(max(frame.origin.x, visibleFrame.minX), visibleFrame.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visibleFrame.minY), visibleFrame.maxY - frame.height)
        return frame
    }

    private func save(_ size: NSSize) {
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else {
            return
        }
        UserDefaults.standard.set(NSStringFromSize(size), forKey: DefaultsKey.lastFrameSize)
    }
}

private final class WindowObserver {
    private let resizeObserver: NSObjectProtocol
    private let closeObserver: NSObjectProtocol

    init(
        window: NSWindow,
        didResize: @escaping () -> Void,
        didClose: @escaping () -> Void
    ) {
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak window] _ in
            guard let window else { return }
            didResize()
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            didClose()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(resizeObserver)
        NotificationCenter.default.removeObserver(closeObserver)
    }
}
