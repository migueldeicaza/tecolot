//
//  SettingsSpotlight.swift
//  Tecolot
//
//  Scrolls to a setting and dims the rest of the Settings window.
//
import AppKit
import SwiftUI

/// Asks the Settings window to show one setting. The serial number makes
/// two requests for the same setting different.
struct SettingsRevealRequest: Equatable {
    let id: SettingID
    let serial: Int
}

struct SettingsSpotlightConfiguration {
    /// The time that the spotlight stays at full strength.
    var duration: TimeInterval = 1.6
    var fadeInDuration: TimeInterval = 0.2
    var fadeOutDuration: TimeInterval = 0.45
    var blurRadius: CGFloat = 12
    var horizontalPadding: CGFloat = 10
    var rowVerticalPadding: CGFloat = 6
    var sectionVerticalPadding: CGFloat = 10
    var cornerRadius: CGFloat = 10
    var dimmingOpacity: CGFloat = 0.26
    var darkDimmingOpacity: CGFloat = 0.5
    /// The corner radius of the Settings window, which the dimming follows.
    /// AppKit does not report it. Windows have rounder corners from macOS 26.
    var windowCornerRadius: CGFloat = {
        if #available(macOS 26, *) {
            return 20
        }
        return 10
    }()
    /// The space kept above and below a row that search scrolls to.
    var scrollMargin: CGFloat = 80
    /// The time between two looks for a row that the page has not made yet.
    var retryInterval: TimeInterval = 0.05
    var retryLimit = 14
    /// How many times to look for the window while Settings opens. These
    /// looks do not count as looks for the row.
    var windowRetryLimit = 100
    /// The time between two checks that the lit rows did not move.
    var positionCheckInterval: TimeInterval = 0.1
    /// The look after which a row that is not on the page gives way to
    /// the row that controls it.
    var fallbackAttempt = 5
}

/// Lives in the background of the Settings window and does the reveal in
/// AppKit, where the scroll view and the window are available.
struct SettingsSpotlightHost: NSViewRepresentable {
    let request: SettingsRevealRequest?
    var configuration = SettingsSpotlightConfiguration()

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.configuration = configuration
        context.coordinator.update(request: request, host: view)
    }

    func makeCoordinator() -> SettingsSpotlightController {
        SettingsSpotlightController()
    }

    static func dismantleNSView(_ view: NSView, coordinator: SettingsSpotlightController) {
        coordinator.invalidate()
    }
}

@MainActor
final class SettingsSpotlightController {
    var configuration = SettingsSpotlightConfiguration()
    private var handled: SettingsRevealRequest?
    private var generation = 0
    private var overlay: NSWindow?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var positionTimer: Timer?

    /// The rows that the last reveal showed (written for tests).
    private(set) var revealedIDs: [SettingID] = []
    /// True when the last reveal showed a whole section (written for tests).
    private(set) var revealedSection = false

    deinit {
        // The window closed without a dismantle call. Leave nothing behind.
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        observers.forEach(NotificationCenter.default.removeObserver)
        positionTimer?.invalidate()
        overlay?.parent?.removeChildWindow(overlay!)
        overlay?.orderOut(nil)
    }

    /// Stops a reveal that waits for its turn and removes the spotlight.
    func invalidate() {
        generation += 1
        handled = nil
        dismiss(animated: false)
    }

    func update(request: SettingsRevealRequest?, host: NSView) {
        guard request != handled else {
            return
        }
        handled = request
        generation += 1
        dismiss(animated: false)
        guard let request else {
            return
        }
        // The page changes in the same update. Look for the row after it.
        attempt(request, host: host, count: 0, windowWaits: 0, generation: generation)
    }

    private func attempt(
        _ request: SettingsRevealRequest,
        host: NSView,
        count: Int,
        windowWaits: Int,
        generation: Int
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + configuration.retryInterval) { [weak self, weak host] in
            guard let self, let host, generation == self.generation else {
                return
            }
            guard let window = host.window else {
                // Settings is still opening. The wait for the window does
                // not use up the looks for the row or for its fallback.
                if windowWaits < self.configuration.windowRetryLimit {
                    self.attempt(
                        request,
                        host: host,
                        count: count,
                        windowWaits: windowWaits + 1,
                        generation: generation
                    )
                }
                return
            }
            if self.reveal(request.id, in: window, allowsFallback: count >= self.configuration.fallbackAttempt) {
                return
            }
            if count < self.configuration.retryLimit {
                self.attempt(
                    request,
                    host: host,
                    count: count + 1,
                    windowWaits: windowWaits,
                    generation: generation
                )
            }
        }
    }

    /// Scrolls to the rows of a setting and puts the spotlight on them.
    /// Returns false when the rows are not in the window.
    @discardableResult
    func reveal(_ id: SettingID, in window: NSWindow, allowsFallback: Bool) -> Bool {
        var shown = id
        var targets = id.revealTargets
        var views = Self.views(for: targets, in: window)
        if views.isEmpty, allowsFallback, let fallback = id.entry.revealedBy {
            shown = fallback
            targets = fallback.revealTargets
            views = Self.views(for: targets, in: window)
        }
        guard let first = views.first, let last = views.last else {
            return false
        }
        // Show the bottom first so that the top wins for a tall section.
        let margin = configuration.scrollMargin
        last.scrollToVisible(last.bounds.insetBy(dx: 0, dy: -margin))
        first.scrollToVisible(first.bounds.insetBy(dx: 0, dy: -margin))
        revealedIDs = targets
        // The padding is for the rows on screen, which are one row after a
        // fallback from a section.
        let isSection = shown.entry.kind == .section
        revealedSection = isSection
        let generation = self.generation
        // The scroll view moves its content after this turn of the run loop.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, generation == self.generation else {
                return
            }
            self.showOverlay(around: Self.views(for: targets, in: window), in: window, isSection: isSection)
        }
        return true
    }

    private static func views(for ids: [SettingID], in window: NSWindow) -> [SettingsAnchorView] {
        ids.flatMap { SettingsAnchorRegistry.shared.views(for: $0, in: window) }
    }

    private func showOverlay(around views: [SettingsAnchorView], in window: NSWindow, isSection: Bool) {
        var cutout = CGRect.null
        for view in views {
            // Window coordinates. The overlay window has the same frame.
            var rect = view.convert(view.bounds, to: nil)
            // Keep the part of a row that the scroll view shows.
            if let clip = view.enclosingScrollView?.contentView {
                rect = rect.intersection(clip.convert(clip.bounds, to: nil))
            }
            cutout = cutout.union(rect)
        }
        guard !cutout.isNull, !cutout.isEmpty else {
            return
        }
        // A row with a short label or only a button has a narrow marker.
        // Use the width of the widest row of the page.
        let scrollView = views.first?.enclosingScrollView
        for view in SettingsAnchorRegistry.shared.views(in: window) where view.enclosingScrollView === scrollView {
            let rect = view.convert(view.bounds, to: nil)
            let minX = min(cutout.minX, rect.minX)
            let maxX = max(cutout.maxX, rect.maxX)
            cutout = CGRect(x: minX, y: cutout.minY, width: maxX - minX, height: cutout.height)
        }
        cutout = cutout.insetBy(
            dx: -configuration.horizontalPadding,
            dy: -(isSection ? configuration.sectionVerticalPadding : configuration.rowVerticalPadding)
        )
        // SwiftUI does not draw views that are added to its hosting view,
        // so the overlay is a child window on top of the Settings window.
        let overlay = NSWindow(
            contentRect: window.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.isReleasedWhenClosed = false
        overlay.animationBehavior = .none
        overlay.setAccessibilityElement(false)
        overlay.contentView = SettingsSpotlightOverlayView(
            frame: NSRect(origin: .zero, size: window.frame.size),
            cutout: cutout,
            configuration: configuration
        )
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        overlay.alphaValue = reduceMotion ? 1 : 0
        window.addChildWindow(overlay, ordered: .above)
        self.overlay = overlay
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = configuration.fadeInDuration
                overlay.animator().alphaValue = 1
            }
        }
        // A click, a key or a scroll means that the user saw the row.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) {
            [weak self, weak window] event in
            if event.window === window {
                self?.dismiss(animated: true)
            }
            return event
        }
        // The hole is in the wrong place after the window changes size,
        // after the page lays out its rows again and after the page scrolls.
        let center = NotificationCenter.default
        var watched: [(Notification.Name, AnyObject)] = [
            (NSWindow.didResizeNotification, window),
            (NSWindow.willCloseNotification, window),
        ]
        for view in views {
            view.onLeaveWindow = { [weak self] in
                self?.dismiss(animated: false)
            }
            view.postsFrameChangedNotifications = true
            watched.append((NSView.frameDidChangeNotification, view))
        }
        if let clip = scrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            watched.append((NSView.boundsDidChangeNotification, clip))
        }
        observers = watched.map { name, object in
            center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.dismiss(animated: false)
                }
            }
        }
        // A row also moves when a view above it moves, which sends no
        // notification for the row. Compare the places while the hole shows.
        let places = views.map { $0.convert($0.bounds, to: nil) }
        positionTimer = Timer.scheduledTimer(withTimeInterval: configuration.positionCheckInterval, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                let moved = zip(views, places).contains { view, place in
                    view.window == nil || view.convert(view.bounds, to: nil) != place
                }
                if moved {
                    self?.dismiss(animated: false)
                }
            }
        }
        let generation = self.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + configuration.fadeInDuration + configuration.duration) {
            [weak self] in
            guard let self, generation == self.generation else {
                return
            }
            self.dismiss(animated: true, duration: self.configuration.fadeOutDuration)
        }
    }

    func dismiss(animated: Bool, duration: TimeInterval = 0.15) {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        positionTimer?.invalidate()
        positionTimer = nil
        guard let overlay else {
            return
        }
        self.overlay = nil
        let remove = {
            overlay.parent?.removeChildWindow(overlay)
            overlay.orderOut(nil)
        }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            remove()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            overlay.animator().alphaValue = 0
        }, completionHandler: remove)
    }
}

/// Dims the window and leaves a soft-edged hole over the setting.
final class SettingsSpotlightOverlayView: NSView {
    private let cutout: CGRect
    private let configuration: SettingsSpotlightConfiguration
    private let dimming = CAShapeLayer()

    init(frame: NSRect, cutout: CGRect, configuration: SettingsSpotlightConfiguration) {
        self.cutout = cutout
        self.configuration = configuration
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        // Keeps the dimming inside the round corners of the window.
        layer?.cornerRadius = configuration.windowCornerRadius
        layer?.cornerCurve = .continuous
        layer?.addSublayer(dimming)
        setAccessibilityElement(false)
        updateDimming()
    }

    @available(*, unavailable) required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        updateDimming()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateDimming()
    }

    private func updateDimming() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let opacity = isDark ? configuration.darkDimmingOpacity : configuration.dimmingOpacity
        let path = CGMutablePath()
        // The dimmed area is larger than the view so that only the edge of
        // the hole gets a shadow.
        path.addRect(bounds.insetBy(dx: -4 * configuration.blurRadius, dy: -4 * configuration.blurRadius))
        path.addRoundedRect(
            in: cutout,
            cornerWidth: min(configuration.cornerRadius, cutout.width / 2),
            cornerHeight: min(configuration.cornerRadius, cutout.height / 2)
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimming.frame = bounds
        dimming.path = path
        dimming.fillRule = .evenOdd
        dimming.fillColor = NSColor.black.withAlphaComponent(opacity).cgColor
        // The shadow of the dimmed area falls into the hole and makes its
        // edge soft.
        dimming.shadowColor = NSColor.black.cgColor
        dimming.shadowOpacity = Float(opacity)
        dimming.shadowRadius = configuration.blurRadius / 2
        dimming.shadowOffset = .zero
        CATransaction.commit()
    }
}
