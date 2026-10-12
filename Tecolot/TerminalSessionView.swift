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
import TecolotSessionClient
import TecolotSessionDirectory
import TecolotTransport
import TecolotWire
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

struct PanePresentation: Equatable {
    var title = "Terminal"
    var directory: String?
    var executablePath: String?
    var hasActivity = false
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
    private var postedDirectory: String?
    @ObservationIgnored private var zoomGesture: NSMagnificationGestureRecognizer?
    @ObservationIgnored private var keyEventMonitor: Any?
    @ObservationIgnored private var snapshotWorkItem: DispatchWorkItem?
    private var logging = false

    @ObservationIgnored private(set) var terminal: LocalProcessTerminalView?
    /// The view of a persistent pane; its shell runs in tecolot-sessiond.
    @ObservationIgnored private(set) var persistentView: RemoteTerminalView?
    @ObservationIgnored private var wantsPersistentSession = false
    @ObservationIgnored private var attachSessionID: String?
    /// The persistent session that this pane shows, if any.
    @ObservationIgnored private(set) var persistentSessionID: String?
    /// Set when this pane detaches on purpose, so the closed connection is expected.
    @ObservationIgnored private var persistentDetached = false
    @ObservationIgnored weak var workspace: TerminalPaneWorkspace?
    @ObservationIgnored private var isConfigured = false
    @ObservationIgnored private var didRequestFocus = false

    /// The profile driving this session; replaced by applyProfile(_:)
    private(set) var profile = TerminalProfile(name: "Untitled")
    /// Per-tab theme override; nil follows the profile's theme
    var themeOverride: String?
    /// Drives the per-window theme picker popover
    var showThemePicker = false
    private(set) var displayedWindowTitle = "Tecolot"
    private(set) var panePresentation = PanePresentation()
    @ObservationIgnored private var launchDirectory: String?
    @ObservationIgnored private var didResolveLaunch = false
    @ObservationIgnored private var restoredContent: String?
    @ObservationIgnored var bufferSnapshotHandler: ((String) -> Void)?
    @ObservationIgnored private weak var observedWindow: NSWindow?
    @ObservationIgnored private var windowKeyObserver: NSObjectProtocol?
    @ObservationIgnored private var windowUpdateObserver: NSObjectProtocol?
    @ObservationIgnored private var previewBackgroundOpacity: Double?

    private(set) var hasActivity = false

    /// The terminal view of this pane, local or persistent.
    var surface: (NSView & TerminalSurface)? {
        terminal ?? persistentView
    }

    /// True for a pane whose shell runs in a persistent session.
    var isPersistent: Bool {
        persistentView != nil || wantsPersistentSession
    }

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
        wantsPersistentSession = spec?.persistent == true || spec?.attachSessionID != nil
        attachSessionID = spec?.attachSessionID
    }

    /// Sets up a pane of a restored layout.
    @MainActor
    func presetLaunch(_ pane: SavedPane) {
        guard !didResolveLaunch else { return }
        didResolveLaunch = true
        profile = pane.profileID.flatMap { AppModel.shared.profiles.profile(withID: $0) }
            ?? AppModel.shared.profiles.defaultProfile
        themeOverride = pane.themeOverride
        launchDirectory = pane.workingDirectory
        if let sessionID = pane.sessionID {
            wantsPersistentSession = true
            attachSessionID = sessionID
        }
    }

    @MainActor
    func prepareForSplit(from source: TerminalSessionController) {
        guard !didResolveLaunch else { return }
        didResolveLaunch = true
        profile = source.profile
        themeOverride = source.themeOverride
        launchDirectory = source.currentWorkingDirectory
        wantsPersistentSession = source.isPersistent
    }

    /// The directory the shell reported via OSC 7, as a filesystem path
    var currentWorkingDirectory: String? {
        guard let posted = postedDirectory, let url = URL(string: posted) else {
            return nil
        }
        return url.path
    }

    /// A local OSC 7 directory that the titlebar can open in Finder.
    var titlebarWorkingDirectory: String? {
        TerminalWorkingDirectory.path(from: postedDirectory)
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

    /// Saves this session's theme as the profile default.
    @MainActor
    func useThemeForAllWindows(in profiles: ProfileStore) throws {
        var updatedProfile = profile
        updatedProfile.themeName = effectiveTheme.name
        try profiles.update(updatedProfile)
        // Clear the local theme only after the profile save succeeds.
        // Apply the new profile here, before SwiftUI processes the store change.
        themeOverride = nil
        applyProfile(updatedProfile)
    }

    @MainActor
    func applyAppearance() {
        if let persistentView {
            applyPersistentAppearance(to: persistentView)
            return
        }
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
        (terminal.superview as? TerminalSessionContainerView)?.updatePaddingColor()
        terminal.requestRedraw()
        if effectiveBackgroundOpacity >= 1.0 {
            updateWindowTransparency()
        }
        workspace?.hostView?.refreshAppearance()
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
        workspace?.hostView?.refreshAppearance()
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
        guard let window = surface?.window else { return }
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
    func makeTerminalView(document: TerminalDocument) -> NSView & TerminalSurface {
        if let terminal {
            terminal.removeFromSuperview()
            attach(to: terminal)
            return terminal
        }
        if let persistentView {
            persistentView.removeFromSuperview()
            attachPersistentView()
            return persistentView
        }

        resolveLaunchIfNeeded(document: document)
        if wantsPersistentSession, let view = makePersistentView() {
            return view
        }
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
        guard let window = surface?.window else { return }
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
        // A live resize sends many grid changes. Update the title only when
        // it shows the grid size.
        if profile.titleComponents.contains(.dimensions) {
            updateWindowTitle()
        }
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
        guard surface?.window?.isKeyWindow == false else { return }
        setHasActivity(true)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        processTerminated(source: nil, exitCode: exitCode)
    }

    func processTerminated(source _: TerminalView?, exitCode: Int32?) {
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
        surface?.window?.close()
    }

    private func showCompletionBanner(exitCode: Int32?) {
        let status = exitCode.map { String($0) } ?? "?"
        if let persistentView {
            persistentView.showBanner("Process completed — exit \(status)", actionTitle: "Close") { [weak self] in
                self?.persistentView?.session.detach()
                self?.closePaneOrWindow()
            }
            return
        }
        terminal?.feed(text: "\r\n\u{1b}[7m[Process completed — exit \(status)]\u{1b}[0m\r\n")
    }

    func exportBuffer() {
        if let persistentView {
            persistentView.bufferText { [weak self] text in
                self?.saveData { Data(text.utf8) }
            }
            return
        }
        saveData {
            self.terminal?.getBufferAsData() ?? Data()
        }
    }

    func exportSelection() {
        if let persistentView {
            persistentView.selectedText { [weak self] text in
                guard let text else { return }
                self?.saveData { Data(text.utf8) }
            }
            return
        }
        saveData {
            guard let selection = self.terminal?.getSelection() else { return Data() }
            return selection.data(using: .utf8) ?? Data()
        }
    }

    func printBuffer() {
        if let persistentView {
            persistentView.bufferText { [weak self] text in
                self?.printText(text)
            }
            return
        }
        guard let data = terminal?.getBufferAsData(),
              let text = String(data: data, encoding: .utf8) else { return }
        printText(text)
    }

    private func printText(_ text: String) {
        let printView = NSTextView(frame: NSRect(x: 0, y: 0, width: 540, height: 720))
        printView.string = text
        printView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        printView.isEditable = false
        printView.sizeToFit()
        let operation = NSPrintOperation(view: printView)
        operation.jobTitle = surface?.window?.title ?? "Tecolot Terminal"
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
        if let persistentView {
            // The helper has the prompt marks; the scroll happens when it answers.
            persistentView.scrollToPrompt(upward: searchingUpward)
            return true
        }
        guard let view = terminal else { return false }
        let row = searchingUpward
            ? view.previousSemanticPromptRow()
            : view.nextSemanticPromptRow()
        guard let row else { return false }
        view.scrollTo(row: row)
        return true
    }

    func softReset() {
        if let persistentView {
            persistentView.session.reset(.soft)
            return
        }
        terminal?.softReset()
    }

    func hardReset() {
        if let persistentView {
            persistentView.session.reset(.hard)
            return
        }
        terminal?.resetToInitialState()
    }

    /// Clears the screen and the scrollback without sending data to the program.
    func clearToStart() {
        if let persistentView {
            persistentView.session.reset(.clearToStart)
            return
        }
        guard let terminal else { return }
        TerminalClearAction.perform(on: terminal)
    }

    /// Runs a Find menu action in this pane.
    func performFind(_ action: NSTextFinder.Action) {
        if let persistentView {
            persistentView.performFind(action)
            return
        }
        let item = NSMenuItem()
        item.tag = action.rawValue
        terminal?.performTextFinderAction(item)
    }

    /// Sends text to the program as if the user typed it.
    func sendLiteralText(_ text: String) {
        if let persistentView {
            persistentView.session.send(bytes: Array(text.utf8))
            return
        }
        terminal?.send(txt: text)
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
        get { persistentView?.isUsingMetalRenderer ?? terminal?.isUsingMetalRenderer ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: "useMetalRenderer")
            TerminalSessionRegistry.shared.setUseMetalRenderer(newValue)
        }
    }

    func setUseMetalRenderer(_ enabled: Bool) {
        if let persistentView {
            do {
                try persistentView.setUseMetal(enabled)
            } catch {
                print("METAL TOGGLE FAILED: \(error)")
            }
            persistentView.requestRedraw()
            return
        }
        guard let terminal else { return }
        do {
            try terminal.setUseMetal(enabled)
        } catch {
            print("METAL TOGGLE FAILED: \(error)")
        }
        terminal.requestRedraw()
    }

    var usePerFrameMetalBuffering: Bool {
        get { (persistentView?.metalBufferingMode ?? terminal?.metalBufferingMode) == .perFrameAggregated }
        set {
            if let persistentView {
                persistentView.metalBufferingMode = newValue ? .perFrameAggregated : .perRowPersistent
                return
            }
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
        surface?.selectionActive ?? false
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

    /// Ends a local shell. A persistent pane detaches instead: closing a pane
    /// or a window never ends a persistent session.
    func terminate() {
        flushBufferSnapshot()
        if let persistentView {
            persistentDetached = true
            persistentView.session.detach()
            return
        }
        terminal?.terminate()
    }

    /// Ends the persistent session that this pane shows.
    func terminateSession() {
        persistentView?.session.terminate(signal: SIGHUP)
    }

    func requestClose() {
        guard let window = surface?.window else { return }
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
        // Tecolot uses Command keys for its menus and profile bindings.
        // Let menu Copy run when text is selected. Otherwise, send Command-C
        // to programs that use the enhanced keyboard protocol.
        terminal.shouldSendCommandKeyToTerminal = { [weak terminal] event in
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard modifiers == [.command],
                  event.charactersIgnoringModifiers?.lowercased() == "c" else {
                return false
            }
            return terminal?.selectionActive == false
        }

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
        guard let surface,
              event.window === surface.window,
              surface.window?.firstResponder === surface else {
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
            sendBindingText(decodedKeyBindingText(keyBinding.value))
        case .sendEscapeSequence:
            sendBindingText("\u{1b}" + decodedKeyBindingText(keyBinding.value))
        case .scrollPageUp:
            scroll(by: -surface.gridDimensions.rows)
        case .scrollPageDown:
            scroll(by: surface.gridDimensions.rows)
        case .scrollLineUp:
            scroll(by: -1)
        case .scrollLineDown:
            scroll(by: 1)
        }
        return true
    }

    private func sendBindingText(_ text: String) {
        if let persistentView {
            persistentView.session.send(bytes: Array(text.utf8))
        } else {
            terminal?.send(txt: text)
        }
    }

    private func scroll(by rows: Int) {
        if let persistentView {
            persistentView.session.scroll(by: rows)
            return
        }
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
        guard !didRequestFocus, let terminal = surface else { return }
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
        guard let window = surface?.window else { return }
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
                guard let self, let window, let surface = self.surface,
                      window.firstResponder === surface else { return }
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
        guard let terminal = surface else { return }
        let dimensions = terminal.gridDimensions
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
        var presentation = panePresentation
        presentation.title = newTitle.isEmpty ? "Terminal" : newTitle
        presentation.directory = currentWorkingDirectory ?? launchDirectory
        presentation.hasActivity = hasActivity
        if presentation != panePresentation {
            panePresentation = presentation
        }
        if let focused = workspace?.focusedController, focused !== self {
            focused.updateWindowTitle()
            return
        }
        guard let window = terminal.window else { return }
        let document = window.windowController?.document as? NSDocument
        let documentName = document?.displayName ?? ""
        let title = newTitle.isEmpty ? documentName : newTitle
        let hasPaneActivity = workspace?.controllers.contains(where: \.hasActivity)
            ?? hasActivity
        let effectiveTitle = hasPaneActivity ? "● \(title)" : title
        window.title = effectiveTitle
        if displayedWindowTitle != effectiveTitle {
            displayedWindowTitle = effectiveTitle
        }

        if !newTitle.isEmpty {
            document?.displayName = newTitle
        }
        if let workspace {
            TerminalSplitZoomTitlebar.configure(window, workspace: workspace)
        }
    }

    func updatePaneExecutablePath(_ path: String?) {
        guard panePresentation.executablePath != path else { return }
        panePresentation.executablePath = path
        if let workspace, let window = surface?.window ?? workspace.focusedController?.surface?.window {
            TerminalSplitZoomTitlebar.configure(window, workspace: workspace)
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

// MARK: - Persistent sessions

extension TerminalSessionController {
    /// Creates (or attaches to) the persistent session for this pane. Returns
    /// nil, and the pane falls back to a local shell, when that fails.
    @MainActor
    func makePersistentView() -> RemoteTerminalView? {
        let font = ProfileApplier.font(for: profile)
        do {
            let directory = try PersistentSessions.directory()
            let sessionID: String
            if let attachSessionID {
                sessionID = attachSessionID
            } else {
                let record = try PersistentSessions.create(
                    profile: profile, workingDirectory: launchDirectory,
                    columns: profile.columns, rows: profile.rows, cellWidth: 0, cellHeight: 0)
                sessionID = record.id
            }
            let socket = try directory.connect(sessionID)
            let session = makeRemoteSession(socket: socket)
            let view = RemoteTerminalView(session: session, font: font)
            view.sessionController = self
            view.glyphFallbackProvider = NerdFontFallbackProvider.shared
            persistentView = view
            persistentSessionID = sessionID
            attachSessionID = nil
            session.start(size: WireGridSize(columns: profile.columns, rows: profile.rows),
                          focused: false)
            attachPersistentView()
            PersistentLayoutStore.shared.scheduleSave()
            return view
        } catch {
            wantsPersistentSession = false
            let alert = NSAlert()
            alert.messageText = "Could not start a persistent session"
            alert.informativeText = error.localizedDescription
            DispatchQueue.main.async { alert.runModal() }
            return nil
        }
    }

    private func makeRemoteSession(socket: Int32) -> RemoteSession {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        let session = RemoteSession(socket: socket, clientName: "Tecolot", build: version)
        session.onEvent = { [weak self] event in
            DispatchQueue.main.async { self?.handlePersistentEvent(event) }
        }
        return session
    }

    /// Connects again to the session after the connection dropped.
    @MainActor
    func reconnectPersistentSession() {
        guard let persistentView, let sessionID = persistentSessionID else { return }
        do {
            let socket = try PersistentSessions.directory().connect(sessionID)
            let session = makeRemoteSession(socket: socket)
            persistentView.replaceSession(session)
            session.start(size: persistentView.wireGridSize, focused: persistentView.hasFocus)
            applyPersistentAppearance(to: persistentView)
        } catch {
            persistentView.showBanner("The session is no longer running.", actionTitle: "Close") { [weak self] in
                self?.closePaneOrWindow()
            }
        }
    }

    @MainActor
    func attachPersistentView() {
        guard let persistentView else { return }
        registerWindowIfAvailable()
        if !isConfigured {
            isConfigured = true
            // The same renderer settings as local panes (configureTerminal).
            persistentView.metalBufferingMode = .perFrameAggregated
            setUseMetalRenderer(UserDefaults.standard.object(forKey: "useMetalRenderer") as? Bool ?? true)
            applyAppearance()
            persistentView.shouldSendCommandKeyToTerminal = { [weak persistentView] event in
                let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
                guard modifiers == [.command],
                      event.charactersIgnoringModifiers?.lowercased() == "c" else {
                    return false
                }
                return persistentView?.selectionActive == false
            }
            if keyEventMonitor == nil {
                keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    self?.handleKeyBinding(event) == true ? nil : event
                }
            }
        }
        scheduleFocusIfNeeded()
    }

    @MainActor
    func applyPersistentAppearance(to view: RemoteTerminalView) {
        let theme = effectiveTheme
        if theme.isValid {
            let ansi = theme.ansi.map(\.terminalColor)
            view.nativeBackgroundColor = ProfileApplier.nativeColor(theme.background)
            view.nativeForegroundColor = ProfileApplier.nativeColor(theme.foreground)
            view.caretColor = theme.cursor.map { ProfileApplier.nativeColor($0) }
            view.caretTextColor = theme.cursorText.map { ProfileApplier.nativeColor($0) }
            if let selection = theme.selectionBackground {
                view.selectedTextBackgroundColor = ProfileApplier.nativeColor(selection)
            }
            if let selectionText = theme.selectionText {
                view.selectedTextForegroundColor = ProfileApplier.nativeColor(selectionText)
            }
            view.source.theme = (ansi, theme.foreground.terminalColor, theme.background.terminalColor)
            let rgb: (SwiftTerm.Color) -> WireRGB = { color in
                WireRGB(red: color.red, green: color.green, blue: color.blue)
            }
            // The helper answers color queries (OSC 4/10/11) from this theme.
            view.session.setTheme(SetThemeMessage(palette: ansi.map(rgb),
                                                  foreground: rgb(theme.foreground.terminalColor),
                                                  background: rgb(theme.background.terminalColor),
                                                  cursor: theme.cursor.map { rgb($0.terminalColor) }))
        }
        view.font = ProfileApplier.font(for: profile)
        view.fontSmoothing = profile.fontSmoothing
        view.useBrightColors = profile.useBrightColorsForBold
        view.optionAsMetaKey = profile.optionAsMetaKey
        view.backspaceSendsControlH = profile.backspaceSendsControlH
        (view.superview as? TerminalSessionContainerView)?.updatePaddingColor()
        view.requestRedraw()
        updateWindowTransparency()
        workspace?.hostView?.refreshAppearance()
    }

    @MainActor
    func handlePersistentEvent(_ event: RemoteSessionEvent) {
        switch event {
        case .title(let title):
            postedTitle = title
            scheduleTerminalTitleUpdate()
        case .iconTitle:
            break
        case .directory(let directory):
            postedDirectory = directory.isEmpty ? nil : directory
            updateWindowTitle()
        case .bell:
            if profile.bellStyle != .none {
                NSSound.beep()
            }
            noteBell()
        case .clipboardCopy(let data):
            // OSC 52 writes, as the local view does by default.
            if let text = String(data: Data(data), encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        case .clipboardReadRequest(let request, _):
            // Programs cannot read the clipboard, as with the local view.
            persistentView?.session.replyClipboard(request: request, data: nil)
        case .exited(let code):
            processTerminated(source: nil, exitCode: code)
        case .info(let info):
            updatePaneExecutablePath(info.foreground?.path)
        case .closed:
            guard !persistentDetached, let persistentView,
                  persistentView.session.state.exitStatus == nil else { return }
            let alive = persistentSessionID.map { id in
                PersistentSessions.list().contains { $0.id == id && !$0.exited }
            } ?? false
            if alive {
                persistentView.showBanner("Disconnected from the session.", actionTitle: "Reconnect") { [weak self] in
                    self?.reconnectPersistentSession()
                }
            } else {
                persistentView.showBanner("The session helper stopped.", actionTitle: "Close") { [weak self] in
                    self?.closePaneOrWindow()
                }
            }
        case .error:
            break
        }
    }
}

final class TerminalSessionContainerView: NSView {
    // Ghostty uses two points of window padding by default, on all four sides.
    // The top strip also keeps the OSC 9;4 progress bar off the tab bar.
    private static let padding: CGFloat = 2

    static func contentSize(forTerminalSize terminalSize: NSSize) -> NSSize {
        NSSize(
            width: terminalSize.width + padding * 2,
            height: terminalSize.height + padding * 2
        )
    }

    let terminal: NSView & TerminalSurface
    private let topPaddingView = NSView()
    private let leftPaddingView = NSView()
    private let rightPaddingView = NSView()
    private let bottomPaddingView = NSView()
    private let resizeFeedbackView = TerminalResizeFeedbackView()
    private var resizeObservers = [NSObjectProtocol]()
    private var isShowingResizeFeedback = false
    private var paddingConstraints: [NSLayoutConstraint] = []
    private var currentPadding = TerminalSessionContainerView.padding

    init(terminal: NSView & TerminalSurface) {
        self.terminal = terminal
        super.init(frame: NSRect(x: 0, y: 0, width: Self.padding * 2, height: Self.padding * 2))

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
        paddingConstraints = [
            topPaddingView.heightAnchor.constraint(equalToConstant: Self.padding),
            leftPaddingView.widthAnchor.constraint(equalToConstant: Self.padding),
            rightPaddingView.widthAnchor.constraint(equalToConstant: Self.padding),
            bottomPaddingView.heightAnchor.constraint(equalToConstant: Self.padding)
        ]
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: topPaddingView.bottomAnchor),
            terminal.leadingAnchor.constraint(equalTo: leftPaddingView.trailingAnchor),
            terminal.trailingAnchor.constraint(equalTo: rightPaddingView.leadingAnchor),
            terminal.bottomAnchor.constraint(equalTo: bottomPaddingView.topAnchor),

            topPaddingView.topAnchor.constraint(equalTo: topAnchor),
            topPaddingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            topPaddingView.trailingAnchor.constraint(equalTo: trailingAnchor),

            leftPaddingView.topAnchor.constraint(equalTo: topPaddingView.bottomAnchor),
            leftPaddingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftPaddingView.bottomAnchor.constraint(equalTo: bottomPaddingView.topAnchor),

            rightPaddingView.topAnchor.constraint(equalTo: topPaddingView.bottomAnchor),
            rightPaddingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            rightPaddingView.bottomAnchor.constraint(equalTo: bottomPaddingView.topAnchor),

            bottomPaddingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomPaddingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomPaddingView.bottomAnchor.constraint(equalTo: bottomAnchor),

            resizeFeedbackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            resizeFeedbackView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        NSLayoutConstraint.activate(paddingConstraints)
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
            size.width += currentPadding * 2
        }
        if size.height >= 0 {
            size.height += currentPadding * 2
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

    func setPaneCardsEnabled(_ enabled: Bool) {
        let padding: CGFloat = enabled ? 0 : Self.padding
        guard currentPadding != padding else { return }
        currentPadding = padding
        paddingConstraints.forEach { $0.constant = padding }
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
        let dimensions = terminal.gridDimensions
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
            terminal: controller.makeTerminalView(document: document)
        )
    }

    func updateNSView(_ nsView: TerminalSessionContainerView, context: Context) {
        if let local = nsView.terminal as? LocalProcessTerminalView {
            controller.attach(to: local)
        }
        nsView.updatePaddingColor()
    }

    static func dismantleNSView(_ nsView: TerminalSessionContainerView, coordinator: ()) {
        guard let controller = (nsView.terminal as? AppTerminalView)?.sessionController
                ?? (nsView.terminal as? RemoteTerminalView)?.sessionController,
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
