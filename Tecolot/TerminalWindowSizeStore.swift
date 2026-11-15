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

    private var pendingFrame: NSRect?
    private var pendingSave: DispatchWorkItem?
    private var terminationObserver: NSObjectProtocol?
    private let saveInterval: TimeInterval
    private let didSave: () -> Void
    private let defaults: UserDefaults
    private let profileContentSize: (TerminalProfile) -> NSSize
    init(defaults: UserDefaults = .standard, saveInterval: TimeInterval = 0.1, didSave: @escaping () -> Void = {}, profileContentSize: @escaping (TerminalProfile) -> NSSize = TerminalProfileWindowSizer.contentSize) {
        self.defaults = defaults
        self.saveInterval = saveInterval
        self.didSave = didSave
        self.profileContentSize = profileContentSize
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    deinit {
        pendingSave?.cancel()
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    /// Saves the latest normal frame synchronously at lifecycle boundaries.
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let frame = pendingFrame else { return }
        pendingFrame = nil
        save(frame)
    }

    /// Gives every manager-created window a profile/saved size and an explicit position.
    func prepare(
        _ window: NSWindow,
        profile: TerminalProfile,
        style: SidebarPreferences,
        policy: TerminalWindowInitialFrame,
        cascadeFrom source: NSWindow?
    ) {
        var restored = false
        switch policy {
        case .windowGroup(let frame), .cascaded(let frame):
            let destination: NSRect
            if case .cascaded = policy {
                destination = frame.offsetBy(dx: 20, dy: -20)
            } else {
                destination = frame
            }
            restoreWindowGroupFrame(destination, to: window)
            return
        case .profile:
            setProfileContentSize(contentSize(for: window, profile: profile, style: style), on: window)
            configure(window, restoresFrame: false)
        case .saved:
            restored = configure(window, restoresFrame: true)
            if !restored {
                setProfileContentSize(contentSize(for: window, profile: profile, style: style), on: window)
            }
        }
        if let source {
            var frame = window.frame
            frame.origin = NSPoint(x: source.frame.minX + 20, y: source.frame.maxY - frame.height - 20)
            window.setFrame(constrainedFrame(frame, for: window), display: false)
        } else if !restored {
            window.center()
        }
    }

    private func contentSize(for window: NSWindow, profile: TerminalProfile, style: SidebarPreferences) -> NSSize {
        var size = profileContentSize(profile)
        window.contentView?.layoutSubtreeIfNeeded()
        if
            let owner = window.windowController as? TerminalWindowController,
            let host = owner.group.selectedTab?.loadedWorkspace?.hostView,
            host.visibleCards.count == 1, let card = host.visibleCards.first,
            let content = window.contentView {
            // Header preferences change the chrome. Measure the mounted container.
            size.width += content.bounds.width - card.content.bounds.width
            size.height += content.bounds.height - card.content.bounds.height
            size.height += card.content.topPadding - GlobalAppearanceSettings.storedTerminalPadding.topPoints(cardsEnabled: false)
        } else {
            size.width += style.style == .above || style.hidden ? 16 : style.width + 8
            size.height += style.style == .above ? 54 : (style.style == .right || style.hidden ? 52 : 16)
        }
        return size
    }

    func setProfileContentSize(_ contentSize: NSSize, on window: NSWindow) {
        let oldFrame = window.frame
        let oldContentSize = window.styleMask.contains(.fullSizeContentView)
            ? (window.contentView?.bounds.size ?? window.frame.size) : window.contentLayoutRect.size
        var frame = oldFrame
        frame.size.width += contentSize.width - oldContentSize.width
        frame.size.height += contentSize.height - oldContentSize.height
        frame.origin.y = oldFrame.maxY - frame.height
        window.setFrame(constrainedFrame(frame, for: window), display: false)
    }

    @discardableResult
    func configure(_ window: NSWindow, restoresFrame: Bool = true) -> Bool {
        let identifier = ObjectIdentifier(window)
        guard observers[identifier] == nil else {
            return false
        }

        // Each terminal window has one frame, regardless of its tab count.
        let didRestoreFrame = restoresFrame && restoreFrame(to: window)
        if didRestoreFrame {
            recordFrame(of: window)
        }
        observers[identifier] = WindowObserver(
            window: window,
            didChangeFrame: { [weak self, weak window] in
                guard let window else {
                    return
                }
                self?.recordFrame(of: window)
            },
            didEndResize: { [weak self] in
                self?.flush()
            },
            didClose: { [weak self] in
                self?.flush()
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
        if let storedValue = defaults.string(forKey: DefaultsKey.lastFrame) {
            let savedFrame = NSRectFromString(storedValue)
            if isValid(savedFrame) {
                window.setFrame(constrainedFrame(savedFrame, for: window), display: false)
                return true
            }
        }

        guard let storedValue = defaults.string(forKey: DefaultsKey.lastFrameSize) else {
            return false
        }
        let size = NSSizeFromString(storedValue)
        guard isValid(size) else {
            return false
        }
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
        pendingFrame = window.frame
        guard pendingSave == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + saveInterval, execute: work)
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
        guard isValid(frame) else {
            return
        }
        didSave()
        defaults.set(NSStringFromRect(frame), forKey: DefaultsKey.lastFrame)
        defaults.set(NSStringFromSize(frame.size), forKey: DefaultsKey.lastFrameSize)
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
    private let endResizeObserver: NSObjectProtocol

    init(
        window: NSWindow,
        didChangeFrame: @escaping () -> Void,
        didEndResize: @escaping () -> Void,
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
        endResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main
        ) { _ in
            didChangeFrame()
            didEndResize()
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
        NotificationCenter.default.removeObserver(endResizeObserver)
    }
}
