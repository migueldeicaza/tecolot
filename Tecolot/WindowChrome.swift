//
//  WindowChrome.swift
//  Tecolot
//
//  Keeps terminal window chrome stable when AppKit rebuilds native tab views.

import AppKit
import SwiftUI
import TerminalProfilesKit

@MainActor
final class WindowChromeRegistry {
    static let shared = WindowChromeRegistry()

    private let styles = NSMapTable<NSWindow, NSString>(
        keyOptions: [.weakMemory],
        valueOptions: [.strongMemory]
    )
    private let coordinators = NSMapTable<NSWindow, WindowChromeCoordinator>(
        keyOptions: [.weakMemory],
        valueOptions: [.strongMemory]
    )
    private var nextWindowStyle: MacTitlebarStyle?

    private init() {}

    func capture(_ style: MacTitlebarStyle, for window: NSWindow) {
        guard coordinators.object(forKey: window) == nil else { return }
        styles.setObject(style.rawValue as NSString, forKey: window)
    }

    func prepareNextWindow(style: MacTitlebarStyle) {
        nextWindowStyle = style
    }

    func finishNextWindow(_ window: NSWindow?) {
        if let window, let nextWindowStyle {
            capture(nextWindowStyle, for: window)
        }
        nextWindowStyle = nil
    }

    func capturedStyle(for window: NSWindow?) -> MacTitlebarStyle? {
        guard let window, let value = styles.object(forKey: window) else { return nil }
        return MacTitlebarStyle(rawValue: value as String)
    }

    func connect(window: NSWindow, workspace: TerminalPaneWorkspace) {
        if let coordinator = coordinators.object(forKey: window) {
            coordinator.workspace = workspace
            workspace.chromeCoordinator = coordinator
            coordinator.scheduleUpdate()
            return
        }

        let style = capturedStyle(for: window) ?? nextWindowStyle ?? MacTitlebarStyle.load()
        if nextWindowStyle == style {
            nextWindowStyle = nil
        }
        styles.setObject(style.rawValue as NSString, forKey: window)
        let coordinator = WindowChromeCoordinator(
            window: window,
            workspace: workspace,
            style: style
        )
        coordinators.setObject(coordinator, forKey: window)
        workspace.chromeCoordinator = coordinator
        coordinator.start()
    }

    func scheduleUpdate(for window: NSWindow?) {
        guard let window else { return }
        coordinators.object(forKey: window)?.scheduleUpdate()
    }
}

@MainActor
final class WindowChromeCoordinator: NSObject {
    weak var workspace: TerminalPaneWorkspace?

    private weak var window: NSWindow?
    private let style: MacTitlebarStyle
    private var notificationObservers: [NSObjectProtocol] = []
    private var workspaceNotificationObservers: [NSObjectProtocol] = []
    private var tabWindowsObservation: NSKeyValueObservation?
    private var tabVisibilityObservation: NSKeyValueObservation?
    private var selectedTabObservation: NSKeyValueObservation?
    private weak var observedTabGroup: NSWindowTabGroup?
    private var integrationConstraints: [NSLayoutConstraint] = []
    private weak var integratedClipView: NSView?
    private weak var glassView: NSView?
    private var updateIsScheduled = false

    init(window: NSWindow, workspace: TerminalPaneWorkspace, style: MacTitlebarStyle) {
        self.window = window
        self.workspace = workspace
        self.style = style
        super.init()
    }

    deinit {
        let center = NotificationCenter.default
        notificationObservers.forEach(center.removeObserver)
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceNotificationObservers.forEach(workspaceCenter.removeObserver)
        tabWindowsObservation?.invalidate()
        tabVisibilityObservation?.invalidate()
        selectedTabObservation?.invalidate()
    }

    func start() {
        guard let window else { return }
        window.tabbingIdentifier = "TerminalDocument"
        window.tabbingMode = .preferred

        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didUpdateNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didResizeNotification,
            .terminalFocusedPaneDidChange,
            UserDefaults.didChangeNotification,
        ]
        for name in names {
            notificationObservers.append(center.addObserver(
                forName: name,
                object: name == UserDefaults.didChangeNotification ? UserDefaults.standard : window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleUpdate()
                }
            })
        }

        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
            let hostNames: [Notification.Name] = [
                NSWindow.didUpdateNotification,
                NSWindow.didExposeNotification,
            ]
            for name in hostNames {
                notificationObservers.append(center.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] notification in
                    guard let hostWindow = notification.object as? NSWindow,
                          hostWindow.tecolotIsMacOS27TabBarHost else { return }
                    Task { @MainActor [weak self] in
                        self?.scheduleUpdate()
                    }
                })
            }
        }

        workspaceNotificationObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleUpdate()
                }
            }
        )
        scheduleUpdate()
    }

    func scheduleUpdate() {
        guard !updateIsScheduled else { return }
        updateIsScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateIsScheduled = false
            self.updateChrome()
        }
    }

    private func updateChrome() {
        guard let window else { return }
        observeTabGroupIfNeeded(window.tabGroup)

        let resolvedStyle = style.resolved()
        guard resolvedStyle != .native else {
            workspace?.updateWindowTransparency()
            return
        }

        let controller = workspace?.titlebarController
            ?? TerminalSessionRegistry.shared.controller(for: window)
        guard let controller else { return }
        let color = Self.nativeColor(controller.effectiveTheme.background)
        let isDark = controller.effectiveTheme.isDark
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let useGlass = resolvedStyle == .liquidGlass && !reduceTransparency

        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.appearance = nil

        guard let titlebarView = window.tecolotTitlebarView else {
            applyFallbackColor(color, to: window)
            workspace?.updateWindowTransparency()
            return
        }

        let tabBarView = WindowChromeViewLookup.tabBarView(for: window)
        applyAppearance(isDark: isDark, to: titlebarView, tabBarView: tabBarView)
        let didIntegrateTabs = integrateTabs(
            in: window,
            titlebarView: titlebarView,
            tabBarView: tabBarView
        )
        let showsIntegratedTabs = didIntegrateTabs
            && window.tabGroup?.isTabBarVisible == true
            && tabBarView != nil
        window.titleVisibility = showsIntegratedTabs ? .hidden : .visible

        if useGlass {
            if #available(macOS 26.0, *) {
                installGlass(in: titlebarView, tint: color)
            }
        } else {
            removeGlass()
            applySolidColor(color, to: window, titlebarView: titlebarView)
        }
        styleTabViews(
            in: window,
            tabBarView: tabBarView,
            color: color,
            isDark: isDark,
            usesGlass: useGlass
        )
        workspace?.updateWindowTransparency()
    }

    private func observeTabGroupIfNeeded(_ tabGroup: NSWindowTabGroup?) {
        guard observedTabGroup !== tabGroup else { return }
        tabWindowsObservation?.invalidate()
        tabVisibilityObservation?.invalidate()
        selectedTabObservation?.invalidate()
        observedTabGroup = tabGroup
        guard let tabGroup else { return }

        tabWindowsObservation = tabGroup.observe(\.windows, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.resetIntegrationAndScheduleUpdate()
            }
        }
        tabVisibilityObservation = tabGroup.observe(\.isTabBarVisible, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.resetIntegrationAndScheduleUpdate()
            }
        }
        selectedTabObservation = tabGroup.observe(\.selectedWindow, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.scheduleUpdate()
            }
        }
    }

    private func resetIntegrationAndScheduleUpdate() {
        NSLayoutConstraint.deactivate(integrationConstraints)
        integrationConstraints.removeAll()
        integratedClipView = nil
        scheduleUpdate()
    }

    private func integrateTabs(
        in window: NSWindow,
        titlebarView: NSView,
        tabBarView: NSView?
    ) -> Bool {
        guard window.tabGroup?.isTabBarVisible == true,
              let tabBarView,
              let accessoryController = window.tecolotTabBarAccessoryController(for: tabBarView) else {
            resetIntegrationIfNeeded()
            return false
        }

        // AppKit must treat the tab bar as a side titlebar accessory.
        // Otherwise, it reserves a separate row below the titlebar. The left
        // role leaves the right side of the toolbar available for Theme.
        accessoryController.identifier = .tecolotIntegratedTabBar
        if accessoryController.layoutAttribute != .left {
            guard let index = window.titlebarAccessoryViewControllers.firstIndex(
                where: { $0 === accessoryController }
            ) else {
                resetIntegrationIfNeeded()
                return false
            }
            resetIntegrationIfNeeded()
            window.removeTitlebarAccessoryViewController(at: index)
            accessoryController.layoutAttribute = .left
            window.addTitlebarAccessoryViewController(accessoryController)
            scheduleUpdate()
            return false
        }

        // macOS 27 can put NSTabBar in a separate TUINSWindow. Move it to
        // this window's accessory view before adding titlebar constraints.
        if tabBarView.window !== window {
            guard accessoryController.view.window === window else {
                scheduleUpdate()
                return false
            }
            tabBarView.removeFromSuperview()
            accessoryController.view.addSubview(tabBarView)
            scheduleUpdate()
            return false
        }

        guard let toolbarView = titlebarView.tecolotFirstDescendant(named: "NSToolbarView"),
              let clipView = tabBarView.tecolotFirstSuperview(named: "NSTitlebarAccessoryClipView")
                ?? tabBarView.tecolotFirstSuperview(named: "NSTitlebarAccessoryContainerView")
                ?? tabBarView.tecolotAccessoryContainer(under: titlebarView),
              let accessoryView = clipView.subviews.first else {
            resetIntegrationIfNeeded()
            return false
        }

        if integratedClipView === clipView,
           integrationConstraints.allSatisfy(\.isActive) {
            return true
        }

        NSLayoutConstraint.deactivate(integrationConstraints)
        integratedClipView = clipView
        clipView.translatesAutoresizingMaskIntoConstraints = false
        accessoryView.translatesAutoresizingMaskIntoConstraints = false

        let topInset: CGFloat = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 ? 2 : 0
        integrationConstraints = [
            clipView.leadingAnchor.constraint(equalTo: toolbarView.leadingAnchor, constant: 70),
            clipView.trailingAnchor.constraint(equalTo: toolbarView.trailingAnchor, constant: -70),
            clipView.topAnchor.constraint(equalTo: toolbarView.topAnchor, constant: topInset),
            clipView.heightAnchor.constraint(equalTo: toolbarView.heightAnchor),
            accessoryView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            accessoryView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            accessoryView.topAnchor.constraint(equalTo: clipView.topAnchor),
            accessoryView.heightAnchor.constraint(equalTo: clipView.heightAnchor),
        ]

        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26,
           let newTabButton = titlebarView.tecolotFirstDescendant(named: "NSTabBarNewTabButton") {
            let tabHeight = max(newTabButton.frame.width, 28)
            tabBarView.translatesAutoresizingMaskIntoConstraints = false
            integrationConstraints.append(contentsOf: [
                tabBarView.leadingAnchor.constraint(equalTo: accessoryView.leadingAnchor),
                tabBarView.trailingAnchor.constraint(equalTo: accessoryView.trailingAnchor),
                tabBarView.heightAnchor.constraint(equalToConstant: tabHeight),
                tabBarView.centerYAnchor.constraint(equalTo: accessoryView.centerYAnchor),
            ])
        }
        NSLayoutConstraint.activate(integrationConstraints)
        clipView.needsLayout = true
        accessoryView.needsLayout = true
        hideTitlebarSeparators(in: titlebarView)
        return true
    }

    private func resetIntegrationIfNeeded() {
        guard integratedClipView != nil else { return }
        NSLayoutConstraint.deactivate(integrationConstraints)
        integrationConstraints.removeAll()
        integratedClipView = nil
    }

    private func applyAppearance(
        isDark: Bool,
        to titlebarView: NSView,
        tabBarView: NSView?
    ) {
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        titlebarView.appearance = appearance
        tabBarView?.appearance = appearance
    }

    private func applyFallbackColor(_ color: NSColor, to window: NSWindow) {
        window.backgroundColor = color
        window.titleVisibility = .visible
    }

    private func applySolidColor(_ color: NSColor, to window: NSWindow, titlebarView: NSView) {
        let alpha = workspace?.titlebarController?.profile.backgroundOpacity ?? 1
        let titlebarColor = color.withAlphaComponent(alpha)
        titlebarView.wantsLayer = true
        titlebarView.layer?.backgroundColor = titlebarColor.cgColor

        if let container = titlebarView.superview {
            container.wantsLayer = true
            container.layer?.backgroundColor = titlebarColor.cgColor
        }
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26 {
            titlebarView.rootView
                .tecolotDescendants(named: "NSVisualEffectView")
                .first?.isHidden = true
        } else {
            titlebarView.rootView
                .tecolotFirstDescendant(named: "NSTitlebarBackgroundView")?.isHidden = true
        }
    }

    private func styleTabViews(
        in window: NSWindow,
        tabBarView: NSView?,
        color: NSColor,
        isDark: Bool,
        usesGlass: Bool
    ) {
        guard let tabBar = tabBarView else { return }
        let tabButtons = tabBar.tecolotDescendants(named: "NSTabButton")
            .sorted { $0.frame.minX < $1.frame.minX }
        let selectedIndex = window.tabGroup.flatMap { group in
            group.selectedWindow.flatMap(group.windows.firstIndex)
        }
        let unselected = Self.shifted(color, towardWhite: isDark, amount: 0.10)

        for (index, button) in tabButtons.enumerated() {
            let selected = index == selectedIndex
            let background = button.tecolotFirstDescendant(withIdentifier: "_backgroundView")
                ?? button.subviews.last
            background?.wantsLayer = true
            let tabColor = selected ? color : unselected
            background?.layer?.backgroundColor = tabColor
                .withAlphaComponent(usesGlass ? (selected ? 0.24 : 0.12) : 1)
                .cgColor
            button.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        }

        if let newTabButton = tabBar.tecolotFirstDescendant(named: "NSTabBarNewTabButton") {
            newTabButton.wantsLayer = true
            newTabButton.layer?.backgroundColor = unselected
                .withAlphaComponent(usesGlass ? 0.12 : 1)
                .cgColor
            newTabButton.layer?.cornerRadius = min(newTabButton.bounds.width, newTabButton.bounds.height) / 2
            newTabButton.alphaValue = window.isKeyWindow ? 1 : 0.6
        }
    }

    private func hideTitlebarSeparators(in titlebarView: NSView) {
        for separator in titlebarView.rootView.tecolotDescendants(named: "NSTitlebarSeparatorView") {
            separator.isHidden = true
        }
    }

    private func removeGlass() {
        glassView?.removeFromSuperview()
        glassView = nil
    }

    @available(macOS 26.0, *)
    private func installGlass(in titlebarView: NSView, tint: NSColor) {
        let glass: NSGlassEffectView
        if let current = glassView as? NSGlassEffectView, current.superview === titlebarView {
            glass = current
        } else {
            removeGlass()
            glass = NSGlassEffectView(frame: .zero)
            glass.identifier = NSUserInterfaceItemIdentifier("TecolotTitlebarGlass")
            glass.style = .clear
            glass.cornerRadius = 0
            glass.translatesAutoresizingMaskIntoConstraints = false
            titlebarView.addSubview(glass, positioned: .below, relativeTo: titlebarView.subviews.first)
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: titlebarView.leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: titlebarView.trailingAnchor),
                glass.topAnchor.constraint(equalTo: titlebarView.topAnchor),
                glass.bottomAnchor.constraint(equalTo: titlebarView.bottomAnchor),
            ])
            glassView = glass
        }

        let opacity = AppearancePreferences.liquidGlassOpacity()
        glass.tintColor = tint.withAlphaComponent(opacity)
        titlebarView.wantsLayer = true
        titlebarView.layer?.backgroundColor = NSColor.clear.cgColor
        titlebarView.rootView
            .tecolotFirstDescendant(named: "NSTitlebarBackgroundView")?.isHidden = true
    }

    private static func nativeColor(_ color: ProfileColor) -> NSColor {
        NSColor(
            calibratedRed: CGFloat(color.red) / 65_535,
            green: CGFloat(color.green) / 65_535,
            blue: CGFloat(color.blue) / 65_535,
            alpha: 1
        )
    }

    private static func shifted(_ color: NSColor, towardWhite: Bool, amount: CGFloat) -> NSColor {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return color }
        let target: CGFloat = towardWhite ? 1 : 0
        return NSColor(
            calibratedRed: rgb.redComponent + (target - rgb.redComponent) * amount,
            green: rgb.greenComponent + (target - rgb.greenComponent) * amount,
            blue: rgb.blueComponent + (target - rgb.blueComponent) * amount,
            alpha: rgb.alphaComponent
        )
    }
}

@MainActor
enum WindowChromeViewLookup {
    static func tabBarView(
        for window: NSWindow,
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        applicationWindows: [NSWindow]? = nil,
        tabHostClassName: String = "TUINSWindow",
        tabBarClassName: String = "NSTabBar"
    ) -> NSView? {
        if let localTabBar = window.tecolotTitlebarView?
            .tecolotFirstDescendant(named: tabBarClassName) {
            return localTabBar
        }

        guard operatingSystemVersion.majorVersion >= 27 else { return nil }
        if let tabGroup = window.tabGroup,
           tabGroup.selectedWindow !== window {
            return nil
        }

        let groupWindows = window.tabGroup?.windows ?? [window]
        let hostWindows = applicationWindows ?? NSApplication.shared.windows
        let candidates = hostWindows.compactMap { hostWindow -> Candidate? in
            guard String(describing: type(of: hostWindow)) == tabHostClassName,
                  let rootView = hostWindow.contentView?.rootView,
                  let tabBarView = rootView.tecolotFirstDescendantOrSelf(
                    named: tabBarClassName
                  ) else { return nil }

            return Candidate(
                tabBarView: tabBarView,
                score: score(
                    hostWindow: hostWindow,
                    tabBarView: tabBarView,
                    documentWindow: window,
                    groupWindows: groupWindows
                )
            )
        }

        return candidates.max(by: { $0.score < $1.score })?.tabBarView
    }

    private struct Candidate {
        let tabBarView: NSView
        let score: CGFloat
    }

    private static func score(
        hostWindow: NSWindow,
        tabBarView: NSView,
        documentWindow: NSWindow,
        groupWindows: [NSWindow]
    ) -> CGFloat {
        var result: CGFloat = 0

        if hostWindow.tecolotRelatedWindows.contains(where: { candidate in
            groupWindows.contains(where: { $0 === candidate })
        }) {
            result += 10_000
        }
        if hostWindow.parent === documentWindow
            || documentWindow.parent === hostWindow
            || hostWindow.childWindows?.contains(where: { child in
                groupWindows.contains(where: { $0 === child })
            }) == true {
            result += 8_000
        }

        let tabButtonCount = tabBarView.tecolotDescendants(named: "NSTabButton").count
        if tabButtonCount == groupWindows.count {
            result += 2_000
        }
        if hostWindow.screen === documentWindow.screen {
            result += 1_000
        }

        let tabBarFrame = tabBarView.window.map { tabBarWindow in
            tabBarWindow.convertToScreen(tabBarView.convert(tabBarView.bounds, to: nil))
        } ?? hostWindow.frame
        let documentFrame = documentWindow.frame
        let horizontalOverlap = tabBarFrame.intersection(documentFrame).width
        if horizontalOverlap > 0 {
            result += min(horizontalOverlap, documentFrame.width)
        }
        result -= hypot(
            tabBarFrame.midX - documentFrame.midX,
            tabBarFrame.midY - documentFrame.maxY
        ) / 100
        return result
    }
}

private extension NSWindow {
    var tecolotTitlebarView: NSView? {
        guard let root = contentView?.rootView,
              root.responds(to: Selector(("titlebarView"))) else { return nil }
        return root.value(forKey: "titlebarView") as? NSView
    }

    var tecolotIsMacOS27TabBarHost: Bool {
        String(describing: type(of: self)) == "TUINSWindow"
            && contentView?.rootView.tecolotFirstDescendantOrSelf(named: "NSTabBar") != nil
    }

    var tecolotRelatedWindows: [NSWindow] {
        let selector = Selector(("uiWindows"))
        guard responds(to: selector),
              let value = perform(selector)?.takeUnretainedValue() as? [NSWindow] else {
            return []
        }
        return value
    }

    func tecolotTabBarAccessoryController(
        for tabBarView: NSView
    ) -> NSTitlebarAccessoryViewController? {
        if let tagged = titlebarAccessoryViewControllers.first(where: {
            $0.identifier == .tecolotIntegratedTabBar
        }) {
            return tagged
        }
        if let controller = titlebarAccessoryViewControllers.first(where: { controller in
            controller.view === tabBarView
                || controller.view.tecolotContains(tabBarView)
        }) {
            return controller
        }

        // AppKit can add an empty bottom accessory first and attach the tab
        // bar elsewhere in the titlebar hierarchy on the next layout pass.
        return titlebarAccessoryViewControllers.first { controller in
            controller.identifier == nil
                && controller.layoutAttribute == .bottom
                && String(describing: type(of: controller.view)) == "NSView"
                && controller.view.subviews.isEmpty
        }
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let tecolotIntegratedTabBar = NSUserInterfaceItemIdentifier(
        "TecolotIntegratedTabBar"
    )
}

private extension NSView {
    var rootView: NSView {
        var result = self
        while let parent = result.superview {
            result = parent
        }
        return result
    }

    func tecolotFirstSuperview(named name: String) -> NSView? {
        guard let superview else { return nil }
        if String(describing: type(of: superview)) == name { return superview }
        return superview.tecolotFirstSuperview(named: name)
    }

    func tecolotContains(_ candidate: NSView) -> Bool {
        self === candidate || subviews.contains { $0.tecolotContains(candidate) }
    }

    func tecolotFirstDescendant(named name: String) -> NSView? {
        for subview in subviews {
            if String(describing: type(of: subview)) == name { return subview }
            if let match = subview.tecolotFirstDescendant(named: name) { return match }
        }
        return nil
    }

    func tecolotFirstDescendantOrSelf(named name: String) -> NSView? {
        if String(describing: type(of: self)) == name { return self }
        return tecolotFirstDescendant(named: name)
    }

    func tecolotDescendants(named name: String) -> [NSView] {
        subviews.flatMap { subview -> [NSView] in
            let match = String(describing: type(of: subview)) == name ? [subview] : []
            return match + subview.tecolotDescendants(named: name)
        }
    }

    func tecolotFirstDescendant(withIdentifier identifier: String) -> NSView? {
        for subview in subviews {
            if subview.identifier?.rawValue == identifier { return subview }
            if let match = subview.tecolotFirstDescendant(withIdentifier: identifier) { return match }
        }
        return nil
    }

    func tecolotAccessoryContainer(under titlebarView: NSView) -> NSView? {
        var candidate = superview
        while let view = candidate, view !== titlebarView {
            if view.superview === titlebarView { return view }
            candidate = view.superview
        }
        return nil
    }
}

struct WindowChromeConnection: NSViewRepresentable {
    let workspace: TerminalPaneWorkspace

    func makeNSView(context: Context) -> WindowChromeConnectionView {
        WindowChromeConnectionView(workspace: workspace)
    }

    func updateNSView(_ nsView: WindowChromeConnectionView, context: Context) {
        nsView.workspace = workspace
        nsView.connectIfPossible()
    }
}

final class WindowChromeConnectionView: NSView {
    var workspace: TerminalPaneWorkspace

    init(workspace: TerminalPaneWorkspace) {
        self.workspace = workspace
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        connectIfPossible()
    }

    func connectIfPossible() {
        guard let window else { return }
        WindowChromeRegistry.shared.connect(window: window, workspace: workspace)
    }
}
