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
import UniformTypeIdentifiers

enum TerminalWindowTransparency {
    @MainActor
    static func apply(to window: NSWindow, isEnabled: Bool) {
        if isEnabled {
            guard window.isOpaque || window.backgroundColor != .clear else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
        } else {
            guard !window.isOpaque || window.backgroundColor == .clear else { return }
            window.isOpaque = true
            window.backgroundColor = nil
        }
    }
}

@Observable
final class TerminalSessionController: NSObject, LocalProcessTerminalViewDelegate {
    let id = UUID()
    @ObservationIgnored private let startsProcess: Bool
    @ObservationIgnored private var didStartProcess = false
    @ObservationIgnored private var pendingFocus = false
    @ObservationIgnored private var pendingStart = false
    @ObservationIgnored private var postedTitle: String = ""
    @ObservationIgnored private var displayedTerminalTitle: String = ""
    @ObservationIgnored private var titleUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var postedDirectory: String?
    @ObservationIgnored private var zoomGesture: NSMagnificationGestureRecognizer?
    @ObservationIgnored private var keyEventMonitor: Any?
    @ObservationIgnored private var snapshotWorkItem: DispatchWorkItem?
    private var logging = false

    @ObservationIgnored private(set) var terminal: LocalProcessTerminalView?
    @ObservationIgnored weak var workspace: TerminalPaneWorkspace?
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
    @ObservationIgnored private var restoredContent: String?
    @ObservationIgnored var bufferSnapshotHandler: ((String) -> Void)?
    @ObservationIgnored private weak var observedWindow: NSWindow?
    @ObservationIgnored private var windowKeyObserver: NSObjectProtocol?
    @ObservationIgnored private var windowUpdateObserver: NSObjectProtocol?
    @ObservationIgnored private var previewBackgroundOpacity: Double?

    private(set) var hasActivity = false

    init(startsProcess: Bool = true) {
        self.startsProcess = startsProcess
        super.init()
    }

    deinit {
        if let windowKeyObserver {
            NotificationCenter.default.removeObserver(windowKeyObserver)
        }
        if let windowUpdateObserver {
            NotificationCenter.default.removeObserver(windowUpdateObserver)
        }
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
        }
        titleUpdateTask?.cancel()
        snapshotWorkItem?.cancel()
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
        themeOverride = spec?.themeOverride ?? document.themeOverride
        launchDirectory = spec?.workingDirectory
        restoredContent = document.content
    }

    @MainActor
    func prepareForSplit(from source: TerminalSessionController) {
        guard !didResolveLaunch else { return }
        didResolveLaunch = true
        profile = source.profile
        themeOverride = source.themeOverride
        launchDirectory = source.currentWorkingDirectory
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
        previewBackgroundOpacity = nil
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
        if effectiveBackgroundOpacity < 1.0 {
            updateWindowTransparency()
        }
        var appearanceProfile = profile
        appearanceProfile.backgroundOpacity = effectiveBackgroundOpacity
        ProfileApplier.apply(profile: appearanceProfile,
                             themeStore: AppModel.shared.themes,
                             sessionThemeOverride: themeOverride,
                             to: terminal)
        if let container = terminal.superview as? TerminalSessionContainerView {
            container.updatePadding(profile.terminalPadding)
            container.updatePaddingColor()
        }
        terminal.requestRedraw()
        if effectiveBackgroundOpacity >= 1.0 {
            updateWindowTransparency()
        }
    }

    /// Applies an unsaved opacity value while the Settings slider is active.
    /// A nil value restores the persisted profile value.
    @MainActor
    func previewBackgroundOpacity(_ opacity: Double?) {
        let oldOpacity = effectiveBackgroundOpacity
        previewBackgroundOpacity = opacity
        let newOpacity = effectiveBackgroundOpacity
        guard oldOpacity != newOpacity else { return }
        guard let terminal else {
            updateWindowTransparency()
            return
        }

        // The window must support alpha before the terminal draws a translucent
        // frame. Restore an opaque window only after the terminal is opaque.
        if newOpacity < 1.0 {
            updateWindowTransparency()
        }
        terminal.backgroundOpacity = CGFloat(newOpacity)
        (terminal.superview as? TerminalSessionContainerView)?.updatePaddingColor()
        terminal.requestRedraw()
        if newOpacity >= 1.0 {
            updateWindowTransparency()
        }
    }

    var effectiveBackgroundOpacity: Double {
        previewBackgroundOpacity ?? profile.backgroundOpacity
    }

    /// A translucent terminal background only composites when the hosting
    /// window is non-opaque; restore normal opacity otherwise
    @MainActor
    private func updateWindowTransparency() {
        if let workspace {
            workspace.updateWindowTransparency()
            return
        }
        guard let window = terminal?.window else { return }
        TerminalWindowTransparency.apply(
            to: window,
            isEnabled: effectiveBackgroundOpacity < 1.0
        )
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

    @MainActor
    func makeTerminalView(document: TerminalDocument) -> LocalProcessTerminalView {
        if let terminal {
            terminal.removeFromSuperview()
            attach(to: terminal)
            return terminal
        }

        resolveLaunchIfNeeded(document: document)
        let options = ProfileApplier.terminalOptions(for: profile)
        let terminal = AppTerminalView(
            frame: .zero,
            font: ProfileApplier.font(for: profile),
            options: options
        )
        terminal.sessionController = self
        // Bundled Symbols Nerd Font supplies icons the profile font lacks.
        terminal.glyphFallbackProvider = NerdFontFallbackProvider.shared
        attach(to: terminal)
        if !startsProcess {
            restoreBufferIfNeeded(on: terminal)
        }
        return terminal
    }

    func didBecomeFocused() {
        guard let window = terminal?.window else { return }
        workspace?.markFocused(self)
        TerminalSessionRegistry.shared.focus(controller: self, for: window)
        setHasActivity(false)
        updateWindowTitle()
    }

    func requestFocus() {
        didRequestFocus = false
        scheduleFocusIfNeeded()
    }

    func sizeChanged(source _: LocalProcessTerminalView, newCols _: Int, newRows _: Int) {
        // LocalProcessTerminalView updates the PTY. Do not resize the window here.
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        postedTitle = title
        scheduleTerminalTitleUpdate()
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        postedDirectory = directory
        updateWindowTitle()
    }

    // MARK: Kitty clipboard protocol, OSC 5522
    //
    // LocalProcessTerminalView forwards these TerminalViewDelegate hooks to
    // its processDelegate. The complete standard-clipboard service, together
    // with the policy in ProfileApplier.terminalOptions, makes DEC private
    // mode 5522 report as supported.

    func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities {
        // macOS has no primary selection, so only the standard clipboard.
        [.standardRead, .standardWrite]
    }

    func kittyClipboardRequestPermission(
        source: TerminalView,
        request: KittyClipboardPermissionRequest
    ) -> KittyClipboardPermissionResult {
        let verb = request.direction == .read ? "read" : "write"
        let who = request.name.isEmpty ? "An unnamed program" : request.name
        let alert = NSAlert()
        alert.messageText = "Allow the program to \(verb) the clipboard?"
        // The name and the MIME list come from the program in the terminal.
        // Show them as data, never as instructions.
        alert.informativeText =
            "\(who) asks to \(verb) these clipboard types:\n\n"
            + request.mimeTypes.joined(separator: ", ")
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        if request.canRememberPassword {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Remember for this session"
        }
        // The hook is synchronous, so the prompt is modal.
        guard alert.runModal() == .alertFirstButtonReturn else {
            return .deny
        }
        let remember = request.canRememberPassword && alert.suppressionButton?.state == .on
        return .allow(rememberPassword: remember)
    }

    func noteBell() {
        noteOutputActivity()
        guard !NSApp.isActive else { return }
        BellBadge.noteBell()
    }

    func noteOutputActivity() {
        scheduleBufferSnapshot()
        guard terminal?.window?.isKeyWindow == false else { return }
        setHasActivity(true)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        let exitedCleanly = (exitCode ?? 0) == 0
        switch profile.whenShellExits {
        case .closeWindow:
            closePaneOrWindow()
        case .closeIfExitedCleanly:
            if exitedCleanly {
                closePaneOrWindow()
            } else {
                showCompletionBanner(exitCode: exitCode)
            }
        case .keepOpen:
            showCompletionBanner(exitCode: exitCode)
        }
    }

    private func closePaneOrWindow() {
        if workspace?.close(self) == true {
            return
        }
        terminal?.window?.close()
    }

    private func showCompletionBanner(exitCode: Int32?) {
        let status = exitCode.map { String($0) } ?? "?"
        terminal?.feed(text: "\r\n\u{1b}[7m[Process completed — exit \(status)]\u{1b}[0m\r\n")
    }

    func exportBuffer() {
        saveData {
            self.terminal?.getBufferAsData() ?? Data()
        }
    }

    func exportSelection() {
        saveData {
            guard let selection = self.terminal?.getSelection() else { return Data() }
            return selection.data(using: .utf8) ?? Data()
        }
    }

    func printBuffer() {
        guard let data = terminal?.getBufferAsData(),
              let text = String(data: data, encoding: .utf8) else { return }
        let printView = NSTextView(frame: NSRect(x: 0, y: 0, width: 540, height: 720))
        printView.string = text
        printView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        printView.isEditable = false
        printView.sizeToFit()
        let operation = NSPrintOperation(view: printView)
        operation.jobTitle = terminal?.window?.title ?? "Tecolot Terminal"
        operation.run()
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
        let row = searchingUpward
            ? view.previousSemanticPromptRow()
            : view.nextSemanticPromptRow()
        guard let row else { return false }
        view.scrollTo(row: row)
        return true
    }

    func softReset() {
        terminal?.softReset()
    }

    func hardReset() {
        terminal?.resetToInitialState()
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
            UserDefaults.standard.set(newValue, forKey: "useMetalRenderer")
            TerminalSessionRegistry.shared.setUseMetalRenderer(newValue)
        }
    }

    func setUseMetalRenderer(_ enabled: Bool) {
        guard let terminal else { return }
        do {
            try terminal.setUseMetal(enabled)
        } catch {
            print("METAL TOGGLE FAILED: \(error)")
        }
        terminal.requestRedraw()
    }

    var usePerFrameMetalBuffering: Bool {
        get { terminal?.metalBufferingMode == .perFrameAggregated }
        set {
            guard let terminal else { return }
            terminal.metalBufferingMode = newValue ? .perFrameAggregated : .perRowPersistent
            terminal.requestRedraw()
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
        flushBufferSnapshot()
        terminal?.terminate()
    }

    func requestClose() {
        guard let window = terminal?.window else { return }
        guard let workspace, workspace.paneCount > 1 else {
            window.performClose(nil)
            return
        }

        guard TerminalClosePolicy.requiresConfirmation(for: self) else {
            workspace.close(self)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Close this pane?"
        alert.informativeText = "A process is still running."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.workspace?.close(self)
        }
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
        setUseMetalRenderer(UserDefaults.standard.object(forKey: "useMetalRenderer") as? Bool ?? true)
        applyAppearance()
        terminal.processDelegate = self

        if zoomGesture == nil {
            let gesture = NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnify(_:)))
            terminal.addGestureRecognizer(gesture)
            zoomGesture = gesture
        }

        if keyEventMonitor == nil {
            keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleKeyBinding(event) == true ? nil : event
            }
        }

        logging = NSUserDefaultsController.shared.defaults.bool(forKey: "LogHostOutput")
        updateLogging()
    }

    private func handleKeyBinding(_ event: NSEvent) -> Bool {
        guard let terminal,
              event.window === terminal.window,
              terminal.window?.firstResponder === terminal else {
            return false
        }

        if profile.hidePointerWhileTyping {
            NSCursor.setHiddenUntilMouseMoves(true)
        }

        let key = normalizedKey(for: event)
        let modifiers = terminalModifiers(for: event.modifierFlags)
        guard let keyBinding = profile.keyBindings.first(where: {
            $0.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key &&
            $0.modifiers == modifiers
        }) else {
            return false
        }

        switch keyBinding.action {
        case .sendText:
            terminal.send(txt: decodedKeyBindingText(keyBinding.value))
        case .sendEscapeSequence:
            terminal.send(txt: "\u{1b}" + decodedKeyBindingText(keyBinding.value))
        case .scrollPageUp:
            scroll(by: -terminal.terminalDimensions.rows)
        case .scrollPageDown:
            scroll(by: terminal.terminalDimensions.rows)
        case .scrollLineUp:
            scroll(by: -1)
        case .scrollLineDown:
            scroll(by: 1)
        }
        return true
    }

    private func scroll(by rows: Int) {
        guard let terminal else { return }
        let state = terminal.terminalStateSnapshot()
        terminal.scrollTo(row: max(0, state.viewportRow + rows))
    }

    private func terminalModifiers(for flags: NSEvent.ModifierFlags) -> TerminalKeyModifiers {
        var result: TerminalKeyModifiers = []
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        return result
    }

    private func normalizedKey(for event: NSEvent) -> String {
        switch event.keyCode {
        case 122: return "f1"
        case 120: return "f2"
        case 99: return "f3"
        case 118: return "f4"
        case 96: return "f5"
        case 97: return "f6"
        case 98: return "f7"
        case 100: return "f8"
        case 101: return "f9"
        case 109: return "f10"
        case 103: return "f11"
        case 111: return "f12"
        case 105: return "f13"
        case 107: return "f14"
        case 113: return "f15"
        case 106: return "f16"
        case 64: return "f17"
        case 79: return "f18"
        case 80: return "f19"
        case 90: return "f20"
        case 36: return "return"
        case 48: return "tab"
        case 51: return "delete"
        case 53: return "escape"
        case 115: return "home"
        case 116: return "pageup"
        case 117: return "forwarddelete"
        case 119: return "end"
        case 121: return "pagedown"
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        default:
            return event.charactersIgnoringModifiers?.lowercased() ?? ""
        }
    }

    private func decodedKeyBindingText(_ text: String) -> String {
        var result = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let escaped = iterator.next() else {
                result.append(character)
                continue
            }
            switch escaped {
            case "e": result.append("\u{1b}")
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "\\": result.append("\\")
            default:
                result.append("\\")
                result.append(escaped)
            }
        }
        return result
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
        // A view update can request focus while the app is in the background.
        // Do not let an internal focus request activate the app or raise a window.
        guard NSApp.isActive, window.isKeyWindow else { return }
        window.makeFirstResponder(terminal)
        didRequestFocus = true
        didBecomeFocused()
    }

    private func registerWindowIfAvailable() {
        guard let window = terminal?.window else { return }
        TerminalSessionRegistry.shared.register(controller: self, workspace: workspace, for: window)
        observeWindowKeyState(for: window)
        updateWindowTransparency()
    }

    private func observeWindowKeyState(for window: NSWindow) {
        guard observedWindow !== window else { return }
        if let windowKeyObserver {
            NotificationCenter.default.removeObserver(windowKeyObserver)
        }
        if let windowUpdateObserver {
            NotificationCenter.default.removeObserver(windowUpdateObserver)
        }
        observedWindow = window
        windowKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            Task { @MainActor [weak self, weak window] in
                self?.setHasActivity(false)
                if let window {
                    TerminalWindowAppearance.scheduleChromeRefresh(for: window)
                }
            }
        }
        windowUpdateObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            // didUpdate posts on nearly every pass of the event loop, once per
            // pane. Test the responder before spending a task on it.
            MainActor.assumeIsolated {
                guard let self, let window, window.firstResponder === self.terminal else { return }
                self.didBecomeFocused()
            }
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

    private func scheduleStartIfNeeded() {
        guard startsProcess, !didStartProcess, !pendingStart else { return }
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
        let dimensions = terminal.terminalDimensions
        guard dimensions.cols > 2, dimensions.rows > 2 else {
            scheduleStartIfNeeded()
            return
        }
        didStartProcess = true

        restoreBufferIfNeeded(on: terminal)

        let params = ProfileApplier.launchParameters(for: profile, initialDirectory: launchDirectory)
        terminal.startProcess(executable: params.executable,
                              args: params.args,
                              environment: params.environment,
                              execName: params.execName,
                              currentDirectory: params.currentDirectory)
        terminal.sizeChanged(source: terminal,
                             newCols: dimensions.cols,
                             newRows: dimensions.rows)
    }

    private func restoreBufferIfNeeded(on terminal: LocalProcessTerminalView) {
        guard let restoredContent, !restoredContent.isEmpty else { return }
        self.restoredContent = nil
        let limit = UserDefaults.standard.object(forKey: "restoredRowsLimit") as? Int ?? 1_000
        guard limit > 0 else { return }

        var lines = restoredContent.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        let visibleLines = lines.suffix(limit)
        guard !visibleLines.isEmpty else { return }
        terminal.feed(text: visibleLines.joined(separator: "\n") + "\n")
    }

    private func scheduleBufferSnapshot() {
        guard bufferSnapshotHandler != nil else { return }
        guard snapshotWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.flushBufferSnapshot()
        }
        snapshotWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    func flushBufferSnapshot() {
        guard snapshotWorkItem != nil else { return }
        snapshotWorkItem?.cancel()
        snapshotWorkItem = nil
        guard let bufferSnapshotHandler,
              let data = terminal?.getBufferAsData(),
              let content = String(data: data, encoding: .utf8) else { return }
        bufferSnapshotHandler(content)
    }

    private func scheduleTerminalTitleUpdate() {
        titleUpdateTask?.cancel()
        titleUpdateTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(75))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.titleUpdateTask = nil
            self.displayedTerminalTitle = self.postedTitle
            self.updateWindowTitle()
        }
    }

    private func updateWindowTitle() {
        if let focused = workspace?.focusedController, focused !== self {
            focused.updateWindowTitle()
            return
        }
        guard let terminal else { return }
        let dimensions = terminal.terminalDimensions
        var components: [String] = []

        func appendIfPresent (_ value: String?) {
            guard let value, !value.isEmpty else { return }
            components.append (value)
        }

        appendIfPresent (profile.titleOverride)
        if profile.titleComponents.contains (.activeTitle) {
            appendIfPresent (displayedTerminalTitle)
        }
        if profile.titleComponents.contains (.dimensions) {
            appendIfPresent ("\(dimensions.cols) x \(dimensions.rows)")
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
        guard let window = terminal.window else { return }
        let document = window.windowController?.document as? NSDocument
        let documentName = document?.displayName ?? ""
        let title = newTitle.isEmpty ? documentName : newTitle
        let hasPaneActivity = workspace?.controllers.contains(where: \.hasActivity)
            ?? hasActivity
        let effectiveTitle = hasPaneActivity ? "● \(title)" : title
        window.title = effectiveTitle

        if !newTitle.isEmpty {
            document?.displayName = newTitle
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

final class TerminalSessionContainerView: NSView {
    static func contentSize(
        forTerminalSize terminalSize: NSSize,
        padding: TerminalViewPadding
    ) -> NSSize {
        NSSize(
            width: terminalSize.width + CGFloat(padding.left + padding.right),
            height: terminalSize.height + CGFloat(padding.top + padding.bottom)
        )
    }

    let terminal: LocalProcessTerminalView
    private let topPaddingView = NSView()
    private let leftPaddingView = NSView()
    private let rightPaddingView = NSView()
    private let bottomPaddingView = NSView()
    private let resizeFeedbackView = TerminalResizeFeedbackView()
    private var topPaddingConstraint: NSLayoutConstraint!
    private var leadingPaddingConstraint: NSLayoutConstraint!
    private var bottomPaddingConstraint: NSLayoutConstraint!
    private var trailingPaddingConstraint: NSLayoutConstraint!
    private var resizeObservers = [NSObjectProtocol]()
    private var isShowingResizeFeedback = false
    private(set) var terminalPadding: TerminalViewPadding

    init(terminal: LocalProcessTerminalView, padding: TerminalViewPadding) {
        self.terminal = terminal
        self.terminalPadding = padding
        super.init(frame: .zero)

        terminal.translatesAutoresizingMaskIntoConstraints = false
        let paddingViews = [topPaddingView, leftPaddingView, rightPaddingView, bottomPaddingView]
        for view in paddingViews {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.wantsLayer = true
            addSubview(view)
        }

        addSubview(terminal)
        resizeFeedbackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(resizeFeedbackView)
        topPaddingConstraint = topPaddingView.heightAnchor.constraint(
            equalToConstant: CGFloat(padding.top)
        )
        leadingPaddingConstraint = leftPaddingView.widthAnchor.constraint(
            equalToConstant: CGFloat(padding.left)
        )
        bottomPaddingConstraint = bottomPaddingView.heightAnchor.constraint(
            equalToConstant: CGFloat(padding.bottom)
        )
        trailingPaddingConstraint = rightPaddingView.widthAnchor.constraint(
            equalToConstant: CGFloat(padding.right)
        )
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: topPaddingView.bottomAnchor),
            terminal.leadingAnchor.constraint(equalTo: leftPaddingView.trailingAnchor),
            terminal.trailingAnchor.constraint(equalTo: rightPaddingView.leadingAnchor),
            terminal.bottomAnchor.constraint(equalTo: bottomPaddingView.topAnchor),

            topPaddingView.topAnchor.constraint(equalTo: topAnchor),
            topPaddingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            topPaddingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            topPaddingConstraint,

            leftPaddingView.topAnchor.constraint(equalTo: topPaddingView.bottomAnchor),
            leftPaddingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftPaddingView.bottomAnchor.constraint(equalTo: bottomPaddingView.topAnchor),
            leadingPaddingConstraint,

            rightPaddingView.topAnchor.constraint(equalTo: topPaddingView.bottomAnchor),
            rightPaddingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            rightPaddingView.bottomAnchor.constraint(equalTo: bottomPaddingView.topAnchor),
            trailingPaddingConstraint,

            bottomPaddingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomPaddingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomPaddingView.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomPaddingConstraint,

            resizeFeedbackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            resizeFeedbackView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updatePaddingColor()
    }

    deinit {
        resizeObservers.forEach(NotificationCenter.default.removeObserver)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        var size = terminal.intrinsicContentSize
        if size.width >= 0 {
            size.width += CGFloat(terminalPadding.left + terminalPadding.right)
        }
        if size.height >= 0 {
            size.height += CGFloat(terminalPadding.top + terminalPadding.bottom)
        }
        return size
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        resizeObservers.forEach(NotificationCenter.default.removeObserver)
        resizeObservers.removeAll()

        guard let newWindow else { return }
        observeLiveResize(of: newWindow)
    }

    override func layout() {
        super.layout()
        guard isShowingResizeFeedback else { return }
        updateResizeFeedback()
    }

    func updatePaddingColor() {
        let color = terminal.nativeBackgroundColor.cgColor
        topPaddingView.layer?.backgroundColor = color
        leftPaddingView.layer?.backgroundColor = color
        rightPaddingView.layer?.backgroundColor = color
        bottomPaddingView.layer?.backgroundColor = color
    }

    func updatePadding(_ padding: TerminalViewPadding) {
        guard terminalPadding != padding else { return }
        terminalPadding = padding
        topPaddingConstraint.constant = CGFloat(padding.top)
        leadingPaddingConstraint.constant = CGFloat(padding.left)
        bottomPaddingConstraint.constant = CGFloat(padding.bottom)
        trailingPaddingConstraint.constant = CGFloat(padding.right)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func observeLiveResize(of window: NSWindow) {
        let center = NotificationCenter.default
        resizeObservers = [
            center.addObserver(
                forName: NSWindow.willStartLiveResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.beginResizeFeedback()
            },
            center.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.updateResizeFeedback()
            },
            center.addObserver(
                forName: NSWindow.didEndLiveResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.hideResizeFeedback()
            },
        ]
    }

    private func beginResizeFeedback() {
        isShowingResizeFeedback = true
        updateResizeFeedback()
    }

    private func updateResizeFeedback() {
        guard isShowingResizeFeedback else { return }
        terminal.layoutSubtreeIfNeeded()
        let dimensions = terminal.terminalDimensions
        resizeFeedbackView.show(columns: dimensions.cols, rows: dimensions.rows)
    }

    private func hideResizeFeedback() {
        isShowingResizeFeedback = false
        resizeFeedbackView.isHidden = true
    }
}

private final class TerminalResizeFeedbackView: NSVisualEffectView {
    private let dimensionsLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        isHidden = true

        dimensionsLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
        dimensionsLabel.textColor = .labelColor
        dimensionsLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dimensionsLabel)
        NSLayoutConstraint.activate([
            dimensionsLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            dimensionsLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            dimensionsLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            dimensionsLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(columns: Int, rows: Int) {
        dimensionsLabel.stringValue = "\(columns) x \(rows)"
        isHidden = false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

struct TerminalSessionView: NSViewRepresentable {
    var controller: TerminalSessionController
    var document: TerminalDocument

    func makeNSView(context: Context) -> TerminalSessionContainerView {
        TerminalSessionContainerView(
            terminal: controller.makeTerminalView(document: document),
            padding: controller.profile.terminalPadding
        )
    }

    func updateNSView(_ nsView: TerminalSessionContainerView, context: Context) {
        controller.attach(to: nsView.terminal)
        nsView.updatePadding(controller.profile.terminalPadding)
        nsView.updatePaddingColor()
    }

    static func dismantleNSView(_ nsView: TerminalSessionContainerView, coordinator: ()) {
        guard let controller = (nsView.terminal as? AppTerminalView)?.sessionController,
              let window = nsView.window else { return }
        TerminalSessionRegistry.shared.unregister(controller: controller, from: window)
    }
}

#Preview("Terminal Session") {
    @Previewable @State var controller = TerminalSessionController(startsProcess: false)

    TerminalSessionView(
        controller: controller,
        document: TerminalDocument(
            content: "miguel@mac tecolot % swift test\nBuild complete! (2.4s)\nAll tests passed.\n"
        )
    )
    .frame(width: 720, height: 420)
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
    private final class WindowSessions {
        final class Entry {
            weak var controller: TerminalSessionController?
            weak var workspace: TerminalPaneWorkspace?

            init(controller: TerminalSessionController, workspace: TerminalPaneWorkspace?) {
                self.controller = controller
                self.workspace = workspace
            }
        }

        var entries: [Entry] = []
        weak var focusedController: TerminalSessionController?
        let closeInterceptor: WindowCloseInterceptor

        init(window: NSWindow) {
            closeInterceptor = WindowCloseInterceptor(window: window)
        }
    }

    private let table = NSMapTable<NSWindow, WindowSessions>(
        keyOptions: [.weakMemory],
        valueOptions: [.strongMemory]
    )

    func register(
        controller: TerminalSessionController,
        workspace: TerminalPaneWorkspace?,
        for window: NSWindow
    ) {
        let sessions = table.object(forKey: window) ?? WindowSessions(window: window)
        let previousController = sessions.focusedController
            ?? sessions.entries.compactMap(\.controller).first
        sessions.entries.removeAll { $0.controller == nil }
        if !sessions.entries.contains(where: { $0.controller === controller }) {
            sessions.entries.append(WindowSessions.Entry(controller: controller, workspace: workspace))
        }
        sessions.focusedController = sessions.focusedController ?? controller
        table.setObject(sessions, forKey: window)
        sessions.closeInterceptor.install()
        let currentController = sessions.focusedController
            ?? sessions.entries.compactMap(\.controller).first
        if previousController !== currentController {
            NotificationCenter.default.post(name: .terminalFocusedPaneDidChange, object: window)
        }
    }

    func unregister(controller: TerminalSessionController, from window: NSWindow) {
        guard let sessions = table.object(forKey: window) else { return }
        let previousController = sessions.focusedController
            ?? sessions.entries.compactMap(\.controller).first
        sessions.entries.removeAll { $0.controller == nil || $0.controller === controller }
        if sessions.focusedController === controller {
            sessions.focusedController = sessions.entries.compactMap(\.controller).first
        }
        if sessions.entries.isEmpty {
            sessions.closeInterceptor.uninstall()
            table.removeObject(forKey: window)
            NotificationCenter.default.post(name: .terminalFocusedPaneDidChange, object: window)
        } else {
            let currentController = sessions.focusedController
                ?? sessions.entries.compactMap(\.controller).first
            if previousController !== currentController {
                NotificationCenter.default.post(name: .terminalFocusedPaneDidChange, object: window)
            }
        }
    }

    func focus(controller: TerminalSessionController, for window: NSWindow) {
        register(controller: controller, workspace: controller.workspace, for: window)
        guard table.object(forKey: window)?.focusedController !== controller else { return }
        table.object(forKey: window)?.focusedController = controller
        NotificationCenter.default.post(name: .terminalFocusedPaneDidChange, object: window)
    }

    func controller(for window: NSWindow?) -> TerminalSessionController? {
        guard let window else { return nil }
        guard let sessions = table.object(forKey: window) else { return nil }
        return sessions.focusedController ?? sessions.entries.compactMap(\.controller).first
    }

    func controllers(for window: NSWindow?) -> [TerminalSessionController] {
        guard let window, let sessions = table.object(forKey: window) else { return [] }
        sessions.entries.removeAll { $0.controller == nil }
        return sessions.entries.compactMap(\.controller)
    }

    func setUseMetalRenderer(_ enabled: Bool) {
        for window in NSApp.windows {
            for controller in controllers(for: window) {
                controller.setUseMetalRenderer(enabled)
            }
        }
    }

    func previewBackgroundOpacity(_ opacity: Double?, forProfileID profileID: UUID) {
        for window in NSApp.windows {
            for controller in controllers(for: window) where controller.profile.id == profileID {
                controller.previewBackgroundOpacity(opacity)
            }
        }
    }

    func workspace(for window: NSWindow?) -> TerminalPaneWorkspace? {
        controller(for: window)?.workspace
    }
}

extension Notification.Name {
    static let terminalFocusedPaneDidChange = Notification.Name("TerminalFocusedPaneDidChange")
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
            forName: .terminalFocusedPaneDidChange,
            object: nil,
            queue: .main
        ) { _ in
            update()
        })
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
