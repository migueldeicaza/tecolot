//
//  TerminalWindowSizeStore.swift
//  Tecolot
//
//  Saves the frame of the last normal terminal window. Window-group restores
//  use their own frames and do not replace the normal window frame.
//

import AppKit

@MainActor
final class TerminalWindowSizeStore {
    static let shared = TerminalWindowSizeStore()

    private enum DefaultsKey {
        static let lastFrame = "lastTerminalWindowFrame"
        static let lastFrameSize = "lastTerminalWindowFrameSize"
    }

    private var observers: [ObjectIdentifier: WindowObserver] = [:]
    private var suppressedWindowIDs: Set<ObjectIdentifier> = []

    private init() {}

    func setProfileContentSize(_ contentSize: NSSize, on window: NSWindow) {
        let oldFrame = window.frame
        let oldContentSize = window.contentLayoutRect.size
        var frame = oldFrame
        frame.size.width += contentSize.width - oldContentSize.width
        frame.size.height += contentSize.height - oldContentSize.height
        frame.origin.y = oldFrame.maxY - frame.height
        window.setFrame(constrainedFrame(frame, for: window), display: false)
    }

    @discardableResult
    func configure(_ window: NSWindow, restoresFrame: Bool = true) -> Bool {
        let identifier = ObjectIdentifier(window)
        guard observers[identifier] == nil else { return false }

        // macOS puts even a single document window in a tab group. All tabs
        // share one frame, so restoring each tab is safe and ensures that
        // startup document windows restore their saved frame.
        let didRestoreFrame = restoresFrame && restoreFrame(to: window)
        if didRestoreFrame {
            recordFrame(of: window)
        }
        observers[identifier] = WindowObserver(
            window: window,
            didChangeFrame: { [weak self, weak window] in
                guard let window else { return }
                self?.recordFrame(of: window)
            },
            didClose: { [weak self] in
                self?.observers.removeValue(forKey: identifier)
                self?.suppressedWindowIDs.remove(identifier)
            }
        )
        return didRestoreFrame
    }

    /// Applies a saved window-group frame without saving it as the normal
    /// window frame. The frame is constrained to the current screen.
    func restoreWindowGroupFrame(_ savedFrame: NSRect, to window: NSWindow) {
        configure(window, restoresFrame: false)
        let identifier = ObjectIdentifier(window)
        suppressedWindowIDs.insert(identifier)
        window.setFrame(constrainedFrame(savedFrame, for: window), display: true)
        DispatchQueue.main.async { [weak self] in
            self?.suppressedWindowIDs.remove(identifier)
        }
    }

    private func restoreFrame(to window: NSWindow) -> Bool {
        if let storedValue = UserDefaults.standard.string(forKey: DefaultsKey.lastFrame) {
            let savedFrame = NSRectFromString(storedValue)
            if isValid(savedFrame) {
                window.setFrame(constrainedFrame(savedFrame, for: window), display: false)
                return true
            }
        }

        guard let storedValue = UserDefaults.standard.string(forKey: DefaultsKey.lastFrameSize) else {
            return false
        }
        let size = NSSizeFromString(storedValue)
        guard isValid(size) else { return false }
        var savedFrame = window.frame
        savedFrame.size = size
        window.setFrame(constrainedFrame(savedFrame, for: window), display: false)
        return true
    }

    private func recordFrame(of window: NSWindow) {
        let identifier = ObjectIdentifier(window)
        guard !suppressedWindowIDs.contains(identifier), isNormal(window) else {
            return
        }
        save(window.frame)
    }

    private func isNormal(_ window: NSWindow) -> Bool {
        !window.styleMask.contains(.fullScreen) && !window.isMiniaturized && !window.isZoomed
    }

    private func constrainedFrame(_ frame: NSRect, for window: NSWindow) -> NSRect {
        guard let screen = screen(containing: frame) ?? window.screen ?? NSScreen.main else {
            return frame
        }
        let visibleFrame = screen.visibleFrame
        var frame = frame

        frame.size.width = min(max(frame.width, window.minSize.width), visibleFrame.width)
        frame.size.height = min(max(frame.height, window.minSize.height), visibleFrame.height)
        frame.origin.x = min(max(frame.origin.x, visibleFrame.minX), visibleFrame.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visibleFrame.minY), visibleFrame.maxY - frame.height)
        return frame
    }

    private func screen(containing frame: NSRect) -> NSScreen? {
        let screen = NSScreen.screens.max { first, second in
            intersectionArea(of: frame, with: first.frame)
                < intersectionArea(of: frame, with: second.frame)
        }
        guard let screen, intersectionArea(of: frame, with: screen.frame) > 0 else {
            return nil
        }
        return screen
    }

    private func intersectionArea(of first: NSRect, with second: NSRect) -> CGFloat {
        let intersection = first.intersection(second)
        return intersection.width * intersection.height
    }

    private func save(_ frame: NSRect) {
        guard isValid(frame) else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: DefaultsKey.lastFrame)
        UserDefaults.standard.set(NSStringFromSize(frame.size), forKey: DefaultsKey.lastFrameSize)
    }

    private func isValid(_ frame: NSRect) -> Bool {
        frame.origin.x.isFinite
            && frame.origin.y.isFinite
            && isValid(frame.size)
    }

    private func isValid(_ size: NSSize) -> Bool {
        size.width.isFinite
            && size.height.isFinite
            && size.width > 0
            && size.height > 0
    }
}

private final class WindowObserver {
    private let resizeObserver: NSObjectProtocol
    private let moveObserver: NSObjectProtocol
    private let closeObserver: NSObjectProtocol

    init(
        window: NSWindow,
        didChangeFrame: @escaping () -> Void,
        didClose: @escaping () -> Void
    ) {
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { _ in
            didChangeFrame()
        }
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { _ in
            didChangeFrame()
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
        NotificationCenter.default.removeObserver(moveObserver)
        NotificationCenter.default.removeObserver(closeObserver)
    }
}
