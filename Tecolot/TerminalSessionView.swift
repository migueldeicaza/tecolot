//
//  TerminalSessionView.swift
//  Tecolot
//
//  Created by Miguel de Icaza on 8/5/25.
//

import AppKit
import Darwin
import Observation
import SwiftTerm
import SwiftUI
import TerminalProfilesKit
import UniformTypeIdentifiers

@Observable
final class TerminalSessionController: NSObject, LocalProcessTerminalViewDelegate {
    @ObservationIgnored private var didStartProcess = false
    @ObservationIgnored private var pendingFocus = false
    @ObservationIgnored private var pendingStart = false
    @ObservationIgnored private var postedTitle: String = ""
    @ObservationIgnored private var postedDirectory: String?
    @ObservationIgnored private var zoomGesture: NSMagnificationGestureRecognizer?
    private var logging = false

    @ObservationIgnored weak var terminal: LocalProcessTerminalView?
    @ObservationIgnored private var isConfigured = false
    @ObservationIgnored private var didRequestFocus = false

    /// The profile driving this session; replaced by applyProfile(_:)
    private(set) var profile = TerminalProfile(name: "Untitled")
    /// Per-tab theme override; nil follows the profile's theme
    var themeOverride: String?
    /// Drives the per-window theme picker popover
    var showThemePicker = false
    @ObservationIgnored private var launchDirectory: String?
    @ObservationIgnored private var didResolveLaunch = false
    @ObservationIgnored private var windowCloseInterceptor: WindowCloseInterceptor?
    @ObservationIgnored private weak var observedWindow: NSWindow?
    @ObservationIgnored private var windowKeyObserver: NSObjectProtocol?

    private(set) var hasActivity = false

    deinit {
        if let windowKeyObserver {
            NotificationCenter.default.removeObserver(windowKeyObserver)
        }
    }

    /// Consumes the pending LaunchSpec exactly once, from the first view
    /// attach; discarded controller instances never reach this point
    @MainActor
    func resolveLaunchIfNeeded(document: TerminalDocument) {
        guard !didResolveLaunch else { return }
        didResolveLaunch = true
        let spec = AppModel.shared.takePendingLaunch()
        if let profileID = spec?.profileID ?? document.profileID,
           let storedProfile = AppModel.shared.profiles.profile(withID: profileID) {
            profile = storedProfile
        } else {
            profile = AppModel.shared.profiles.defaultProfile
        }
        themeOverride = document.themeOverride
        launchDirectory = spec?.workingDirectory
    }

    /// The directory the shell reported via OSC 7, as a filesystem path
    var currentWorkingDirectory: String? {
        guard let posted = postedDirectory, let url = URL(string: posted) else {
            return nil
        }
        return url.path
    }

    /// The theme currently in effect for this session
    @MainActor
    var effectiveTheme: TerminalTheme {
        AppModel.shared.themes.theme(named: themeOverride ?? profile.themeName)
    }

    /// Applies a new profile to the running session (colors, font, cursor,
    /// keyboard, scrollback); shell settings only affect future launches
    @MainActor
    func applyProfile(_ newProfile: TerminalProfile) {
        profile = newProfile
        applyAppearance()
        updateWindowTitle()
    }

    /// Sets or clears (nil) the per-tab theme override and re-applies colors
    @MainActor
    func applyThemeOverride(_ name: String?) {
        themeOverride = name
        applyAppearance()
    }

    @MainActor
    func applyAppearance() {
        guard let terminal else { return }
        ProfileApplier.apply(profile: profile,
                             themeStore: AppModel.shared.themes,
                             sessionThemeOverride: themeOverride,
                             to: terminal)
        updateWindowTransparency()
    }

    /// A translucent terminal background only composites when the hosting
    /// window is non-opaque; restore normal opacity otherwise
    @MainActor
    private func updateWindowTransparency() {
        guard let window = terminal?.window else { return }
        if profile.backgroundOpacity < 1.0 {
            window.isOpaque = false
            window.backgroundColor = .clear
        } else if !window.isOpaque {
            window.isOpaque = true
            window.backgroundColor = nil
        }
    }

    func attach(to terminal: LocalProcessTerminalView) {
        if self.terminal !== terminal {
            isConfigured = false
            didRequestFocus = false
        }
        self.terminal = terminal
        registerWindowIfAvailable()
        if !isConfigured {
            configureTerminal(terminal)
            isConfigured = true
        }
        scheduleStartIfNeeded()
        scheduleFocusIfNeeded()
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // SwiftUI owns window sizing; SwiftTerm resizes the PTY. The size can
        // also be part of the user-selected window title.
        updateWindowTitle()
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        postedTitle = title
        updateWindowTitle()
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        postedDirectory = directory
        updateWindowTitle()
    }

    func noteBell() {
        noteOutputActivity()
        guard !NSApp.isActive else { return }
        BellBadge.noteBell()
    }

    func noteOutputActivity() {
        guard terminal?.window?.isKeyWindow == false else { return }
        setHasActivity(true)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        let exitedCleanly = (exitCode ?? 0) == 0
        switch profile.whenShellExits {
        case .closeWindow:
            terminal?.window?.close()
        case .closeIfExitedCleanly:
            if exitedCleanly {
                terminal?.window?.close()
            } else {
                showCompletionBanner(exitCode: exitCode)
            }
        case .keepOpen:
            showCompletionBanner(exitCode: exitCode)
        }
    }

    private func showCompletionBanner(exitCode: Int32?) {
        let status = exitCode.map { String($0) } ?? "?"
        terminal?.feed(text: "\r\n\u{1b}[7m[Process completed — exit \(status)]\u{1b}[0m\r\n")
    }

    func exportBuffer() {
        saveData {
            self.terminal?.getTerminal().getBufferAsData() ?? Data()
        }
    }

    func exportSelection() {
        saveData {
            guard let selection = self.terminal?.getSelection() else { return Data() }
            return selection.data(using: .utf8) ?? Data()
        }
    }

    /// Scrolls to the closest shell prompt above the viewport. Prompt rows
    /// come from OSC 133 shell integration; SwiftTerm classifies the rows and
    /// leaves the navigation policy to the host.
    @discardableResult
    func scrollToPreviousPrompt() -> Bool {
        scrollToPrompt(searchingUpward: true)
    }

    /// Scrolls to the closest shell prompt below the viewport
    @discardableResult
    func scrollToNextPrompt() -> Bool {
        scrollToPrompt(searchingUpward: false)
    }

    private func scrollToPrompt(searchingUpward: Bool) -> Bool {
        guard let view = terminal else { return false }
        let terminalModel = view.getTerminal()
        guard !terminalModel.isCurrentBufferAlternate else { return false }

        let start = terminalModel.buffer.yDisp
        let step = searchingUpward ? -1 : 1
        // Rows below 0 do not exist; above, the buffer cannot hold more than
        // the scrollback limit plus a screenful, and semanticRowKind returns
        // nil for rows past the end
        let limit = searchingUpward
            ? -1
            : start + (profile.scrollbackLines ?? 100_000) + terminalModel.rows + 1

        var row = start + step
        while row != limit {
            if terminalModel.semanticRowKind(at: row) == .initial {
                view.scrollTo(row: row)
                return true
            }
            row += step
        }
        return false
    }

    func softReset() {
        terminal?.getTerminal().softReset()
        if let terminal {
            terminal.setNeedsDisplay(terminal.frame)
        }
    }

    func hardReset() {
        terminal?.getTerminal().resetToInitialState()
        if let terminal {
            terminal.setNeedsDisplay(terminal.frame)
        }
    }

    var allowMouseReporting: Bool {
        get { terminal?.allowMouseReporting ?? false }
        set { terminal?.allowMouseReporting = newValue }
    }

    var optionAsMetaKey: Bool {
        get { terminal?.optionAsMetaKey ?? false }
        set { terminal?.optionAsMetaKey = newValue }
    }

    var useMetalRenderer: Bool {
        get { terminal?.isUsingMetalRenderer ?? false }
        set {
            guard let terminal else { return }
            do {
                try terminal.setUseMetal(newValue)
            } catch {
                print("METAL TOGGLE FAILED: \(error)")
            }
            terminal.setNeedsDisplay(terminal.bounds)
        }
    }

    var usePerFrameMetalBuffering: Bool {
        get { terminal?.metalBufferingMode == .perFrameAggregated }
        set {
            guard let terminal else { return }
            terminal.metalBufferingMode = newValue ? .perFrameAggregated : .perRowPersistent
            terminal.setNeedsDisplay(terminal.bounds)
        }
    }

    var logHostOutput: Bool {
        get { logging }
        set {
            logging = newValue
            updateLogging()
        }
    }

    var selectionActive: Bool {
        terminal?.selectionActive ?? false
    }

    func biggerFont() {
        guard let terminal else { return }
        let size = terminal.font.pointSize
        guard size < 72 else { return }
        setFontSize(size + 1, on: terminal)
    }

    func smallerFont() {
        guard let terminal else { return }
        let size = terminal.font.pointSize
        guard size > 5 else { return }
        setFontSize(size - 1, on: terminal)
    }

    func defaultFontSize() {
        guard let terminal else { return }
        setFontSize(CGFloat(profile.fontSize), on: terminal)
    }

    // Changes only the size, keeping the profile's font family
    private func setFontSize(_ size: CGFloat, on terminal: LocalProcessTerminalView) {
        terminal.font = NSFont(descriptor: terminal.font.fontDescriptor, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func terminate() {
        terminal?.terminate()
    }

    @objc private func handleMagnify(_ sender: NSMagnificationGestureRecognizer) {
        if sender.magnification > 0 {
            biggerFont()
        } else {
            smallerFont()
        }
    }

    private func configureTerminal(_ terminal: LocalProcessTerminalView) {
        terminal.metalBufferingMode = .perFrameAggregated
        do {
            try terminal.setUseMetal(false)
        } catch {
            print("METAL DISABLED: \(error)")
        }
        applyAppearance()
        terminal.processDelegate = self

        if zoomGesture == nil {
            let gesture = NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnify(_:)))
            terminal.addGestureRecognizer(gesture)
            zoomGesture = gesture
        }

        logging = NSUserDefaultsController.shared.defaults.bool(forKey: "LogHostOutput")
        updateLogging()
    }

    private func scheduleFocusIfNeeded() {
        guard !didRequestFocus, !pendingFocus else { return }
        pendingFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingFocus = false
            self.focusIfNeeded()
        }
    }

    private func focusIfNeeded() {
        guard !didRequestFocus, let terminal else { return }
        guard let window = terminal.window else {
            scheduleFocusIfNeeded()
            return
        }
        registerWindowIfAvailable()
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
        window.makeFirstResponder(terminal)
        didRequestFocus = true
    }

    private func registerWindowIfAvailable() {
        guard let window = terminal?.window else { return }
        TerminalSessionRegistry.shared.register(controller: self, for: window)
        observeWindowKeyState(for: window)
        installWindowCloseInterceptor(on: window)
        updateWindowTransparency()
    }

    private func observeWindowKeyState(for window: NSWindow) {
        guard observedWindow !== window else { return }
        if let windowKeyObserver {
            NotificationCenter.default.removeObserver(windowKeyObserver)
        }
        observedWindow = window
        windowKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.setHasActivity(false)
        }
        if window.isKeyWindow {
            setHasActivity(false)
        }
    }

    private func setHasActivity(_ hasActivity: Bool) {
        guard self.hasActivity != hasActivity else { return }
        self.hasActivity = hasActivity
        updateWindowTitle()
    }

    private func installWindowCloseInterceptor(on window: NSWindow) {
        if windowCloseInterceptor?.window !== window {
            windowCloseInterceptor = WindowCloseInterceptor(window: window)
        } else {
            windowCloseInterceptor?.install()
        }
    }

    private func scheduleStartIfNeeded() {
        guard !didStartProcess, !pendingStart else { return }
        pendingStart = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingStart = false
            self.startShellIfReady()
        }
    }

    private func startShellIfReady() {
        guard !didStartProcess, let terminal else { return }
        guard terminal.window != nil else {
            scheduleStartIfNeeded()
            return
        }
        terminal.layoutSubtreeIfNeeded()
        let cols = terminal.getTerminal().cols
        let rows = terminal.getTerminal().rows
        guard cols > 2, rows > 2 else {
            scheduleStartIfNeeded()
            return
        }
        didStartProcess = true

        let params = ProfileApplier.launchParameters(for: profile, initialDirectory: launchDirectory)
        terminal.startProcess(executable: params.executable,
                              args: params.args,
                              environment: params.environment,
                              execName: params.execName,
                              currentDirectory: params.currentDirectory)
        terminal.sizeChanged(source: terminal.getTerminal())
    }

    private func updateWindowTitle() {
        guard let terminal else { return }
        let terminalModel = terminal.getTerminal()
        var components: [String] = []

        func appendIfPresent (_ value: String?) {
            guard let value, !value.isEmpty else { return }
            components.append (value)
        }

        appendIfPresent (profile.titleOverride)
        if profile.titleComponents.contains (.activeTitle) {
            appendIfPresent (postedTitle)
        }
        if profile.titleComponents.contains (.dimensions) {
            appendIfPresent ("\(terminalModel.cols) x \(terminalModel.rows)")
        }
        if let directory = currentWorkingDirectory {
            if profile.titleComponents.contains (.fullPath) {
                appendIfPresent (directory)
            } else if profile.titleComponents.contains (.workingDirectory) {
                appendIfPresent (URL (fileURLWithPath: directory).lastPathComponent)
            }
        }
        if profile.titleComponents.contains (.profileName) {
            appendIfPresent (profile.name)
        }

        let newTitle = components.joined (separator: " — ")
        DispatchQueue.main.async {
            guard let window = terminal.window else { return }
            let document = window.windowController?.document as? NSDocument
            let documentName = document?.displayName ?? ""
            let title = newTitle.isEmpty ? documentName : newTitle
            let effectiveTitle = self.hasActivity ? "● \(title)" : title
            window.title = effectiveTitle

            if !newTitle.isEmpty {
                document?.displayName = newTitle
            }
        }
    }

    private func updateLogging() {
        NSUserDefaultsController.shared.defaults.set(logging, forKey: "LogHostOutput")
        let path = logging ? "\(FileManager.default.homeDirectoryForCurrentUser.path)/Downloads/Logs" : nil
        terminal?.setHostLogging(directory: path)
    }

    private func saveData(_ getData: @escaping () -> Data) {
        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true
        if #available(macOS 12.0, *) {
            savePanel.allowedContentTypes = [UTType.text, UTType.plainText]
        } else {
            savePanel.allowedFileTypes = ["txt"]
        }
        savePanel.title = "Export Buffer Contents As Text"
        savePanel.nameFieldStringValue = "TerminalCapture"

        savePanel.begin { result in
            if result == .OK, let url = savePanel.url {
                do {
                    try getData().write(to: url)
                } catch let error as NSError {
                    let alert = NSAlert(error: error)
                    alert.runModal()
                }
            }
        }
    }

}

struct TerminalSessionView: NSViewRepresentable {
    var controller: TerminalSessionController
    var document: TerminalDocument

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        controller.resolveLaunchIfNeeded(document: document)
        let options = ProfileApplier.terminalOptions(for: controller.profile)
        let terminal = AppTerminalView(frame: .zero,
                                       font: ProfileApplier.font(for: controller.profile),
                                       options: options)
        terminal.sessionController = controller
        controller.attach(to: terminal)
        return terminal
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        controller.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: ()) {
        if let window = nsView.window {
            TerminalSessionRegistry.shared.unregister(window: window)
        }
        nsView.terminate()
    }
}

private enum BellBadge {
    private static var count = 0
    private static var didBecomeActiveObserver: NSObjectProtocol?

    static func noteBell() {
        startObservingIfNeeded()
        count += 1
        NSApp.dockTile.badgeLabel = String(count)
        NSApp.requestUserAttention(.informationalRequest)
    }

    private static func startObservingIfNeeded() {
        guard didBecomeActiveObserver == nil else { return }
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { _ in
            Self.count = 0
            NSApp.dockTile.badgeLabel = nil
        }
    }
}

final class TerminalSessionRegistry {
    static let shared = TerminalSessionRegistry()
    private let table = NSMapTable<NSWindow, TerminalSessionController>(
        keyOptions: [.weakMemory],
        valueOptions: [.weakMemory]
    )

    func register(controller: TerminalSessionController, for window: NSWindow) {
        table.setObject(controller, forKey: window)
    }

    func unregister(window: NSWindow) {
        table.removeObject(forKey: window)
    }

    func controller(for window: NSWindow?) -> TerminalSessionController? {
        guard let window else { return nil }
        return table.object(forKey: window)
    }
}

@Observable
final class TerminalCommandState {
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    var controller: TerminalSessionController?

    init() {
        startObserving()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func startObserving() {
        let center = NotificationCenter.default
        let update: () -> Void = { [weak self] in
            guard let self else { return }
            self.controller = TerminalSessionRegistry.shared.controller(
                for: NSApp.keyWindow ?? NSApp.mainWindow
            )
        }

        observers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { _ in
            update()
        })
        observers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { _ in
            update()
        })
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            update()
        })
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            update()
        })
        update()
    }
}
