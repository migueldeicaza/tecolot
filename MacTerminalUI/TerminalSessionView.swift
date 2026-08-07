//
//  TerminalSessionView.swift
//  MacTerminalUI
//
//  Created by Miguel de Icaza on 8/5/25.
//

import AppKit
import Darwin
import Observation
import SwiftTerm
import SwiftUI
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
        // SwiftUI owns window sizing; we only need the PTY resize handled by SwiftTerm.
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        postedTitle = title
        updateWindowTitle()
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        postedDirectory = directory
        updateWindowTitle()
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        terminal?.window?.close()
        if let exitCode = exitCode {
            print("Process terminated with code: \(exitCode)")
        } else {
            print("Process vanished")
        }
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
        terminal.font = NSFont.monospacedSystemFont(ofSize: size + 1, weight: .regular)
    }

    func smallerFont() {
        guard let terminal else { return }
        let size = terminal.font.pointSize
        guard size > 5 else { return }
        terminal.font = NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular)
    }

    func defaultFontSize() {
        guard let terminal else { return }
        terminal.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
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
        terminal.caretColor = .systemGreen
        terminal.getTerminal().setCursorStyle(.steadyBlock)
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
        TerminalSessionRegistry.shared.register(controller: self, for: window)
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

        terminal.feed(text: "Welcome to SwiftTerm")
        let shell = getShell()
        let shellIdiom = "-" + NSString(string: shell).lastPathComponent
        FileManager.default.changeCurrentDirectoryPath(FileManager.default.homeDirectoryForCurrentUser.path)
        terminal.startProcess(executable: shell, execName: shellIdiom)
        terminal.sizeChanged(source: terminal.getTerminal())
    }

    private func updateWindowTitle() {
        guard let terminal else { return }
        let newTitle: String
        if let dir = postedDirectory, let uri = URL(string: dir) {
            newTitle = postedTitle.isEmpty ? uri.path : "\(postedTitle) - \(uri.path)"
        } else {
            newTitle = postedTitle
        }
        DispatchQueue.main.async {
            guard let window = terminal.window else { return }
            let document = window.windowController?.document as? NSDocument
            let documentName = document?.displayName ?? ""
            let effectiveTitle = newTitle.isEmpty ? documentName : newTitle
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

    private func getShell() -> String {
        let bufsize = sysconf(_SC_GETPW_R_SIZE_MAX)
        guard bufsize != -1 else { return "/bin/bash" }

        let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: bufsize)
        defer { buffer.deallocate() }
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>? = nil

        if getpwuid_r(getuid(), &pwd, buffer, bufsize, &result) != 0 || result == nil {
            return "/bin/bash"
        }
        return String(cString: pwd.pw_shell)
    }
}

struct TerminalSessionView: NSViewRepresentable {
    var controller: TerminalSessionController

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = LocalProcessTerminalView(frame: .zero)
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
