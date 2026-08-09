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
    let id = UUID()
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

    private(set) var hasActivity = false

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
        (terminal.superview as? TerminalSessionContainerView)?.updatePaddingColor()
        updateWindowTransparency()
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
        attach(to: terminal)
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

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // SwiftUI owns window sizing; SwiftTerm resizes the PTY. The size can
        // also be part of the user-selected window title.
        updateWindowTitle()
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        postedTitle = title
        scheduleTerminalTitleUpdate()
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
            self.terminal?.getTerminal().getBufferAsData() ?? Data()
        }
    }

    func exportSelection() {
        saveData {
            guard let selection = self.terminal?.getSelection() else { return Data() }
            return selection.data(using: .utf8) ?? Data()
        }
    }

    func printBuffer() {
        guard let data = terminal?.getTerminal().getBufferAsData(),
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
        terminal.setNeedsDisplay(terminal.bounds)
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
            scroll(by: -terminal.getTerminal().rows)
        case .scrollPageDown:
            scroll(by: terminal.getTerminal().rows)
        case .scrollLineUp:
            scroll(by: -1)
        case .scrollLineDown:
            scroll(by: 1)
        }
        return true
    }

    private func scroll(by rows: Int) {
        guard let terminal else { return }
        let model = terminal.getTerminal()
        terminal.scrollTo(row: max(0, model.buffer.yDisp + rows))
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
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
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
        ) { [weak self] _ in
            self?.setHasActivity(false)
        }
        windowUpdateObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            guard let self, let window, window.firstResponder === self.terminal else { return }
            self.didBecomeFocused()
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

        restoreBufferIfNeeded(on: terminal)

        let params = ProfileApplier.launchParameters(for: profile, initialDirectory: launchDirectory)
        terminal.startProcess(executable: params.executable,
                              args: params.args,
                              environment: params.environment,
                              execName: params.execName,
                              currentDirectory: params.currentDirectory)
        terminal.sizeChanged(source: terminal.getTerminal())
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
              let data = terminal?.getTerminal().getBufferAsData(),
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
        let terminalModel = terminal.getTerminal()
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
    // Ghostty uses two points of window padding by default. The side and
    // bottom padding keep terminal content clear of the window border.
    private static let padding: CGFloat = 2

    let terminal: LocalProcessTerminalView
    private let leftPaddingView = NSView()
    private let rightPaddingView = NSView()
    private let bottomPaddingView = NSView()

    init(terminal: LocalProcessTerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)

        terminal.translatesAutoresizingMaskIntoConstraints = false
        let paddingViews = [leftPaddingView, rightPaddingView, bottomPaddingView]
        for view in paddingViews {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.wantsLayer = true
            addSubview(view)
        }

        addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: topAnchor),
            terminal.leadingAnchor.constraint(equalTo: leftPaddingView.trailingAnchor),
            terminal.trailingAnchor.constraint(equalTo: rightPaddingView.leadingAnchor),
            terminal.bottomAnchor.constraint(equalTo: bottomPaddingView.topAnchor),

            leftPaddingView.topAnchor.constraint(equalTo: topAnchor),
            leftPaddingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftPaddingView.bottomAnchor.constraint(equalTo: bottomPaddingView.topAnchor),
            leftPaddingView.widthAnchor.constraint(equalToConstant: Self.padding),

            rightPaddingView.topAnchor.constraint(equalTo: topAnchor),
            rightPaddingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            rightPaddingView.bottomAnchor.constraint(equalTo: bottomPaddingView.topAnchor),
            rightPaddingView.widthAnchor.constraint(equalToConstant: Self.padding),

            bottomPaddingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomPaddingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomPaddingView.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomPaddingView.heightAnchor.constraint(equalToConstant: Self.padding),
        ])
        updatePaddingColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        var size = terminal.intrinsicContentSize
        if size.width >= 0 {
            size.width += Self.padding * 2
        }
        if size.height >= 0 {
            size.height += Self.padding
        }
        return size
    }

    func updatePaddingColor() {
        let color = terminal.nativeBackgroundColor.cgColor
        leftPaddingView.layer?.backgroundColor = color
        rightPaddingView.layer?.backgroundColor = color
        bottomPaddingView.layer?.backgroundColor = color
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
        controller.attach(to: nsView.terminal)
        nsView.updatePaddingColor()
    }

    static func dismantleNSView(_ nsView: TerminalSessionContainerView, coordinator: ()) {
        guard let controller = (nsView.terminal as? AppTerminalView)?.sessionController,
              let window = nsView.window else { return }
        TerminalSessionRegistry.shared.unregister(controller: controller, from: window)
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
