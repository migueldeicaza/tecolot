//
//  AppTerminalView.swift
//  Tecolot
//

import AppKit
import Foundation
import os
import SwiftTerm
import TecolotSessionHost

enum TerminalClearAction {
    /// Clears the active screen and normal-buffer history without sending data
    /// to the process. The escape sequence also moves the terminal cursor home.
    static func perform(on terminal: LocalProcessTerminalView) {
        terminal.feed(text: "\u{1b}[H\u{1b}[2J")
        terminal.clearScrollback()
    }
}

/// Stores a main-actor callback behind a stable object reference.
///
/// Do not store the function directly in the generic lock. A generic `inout`
/// read can write a new reabstraction thunk back to the stored function. Each
/// read can then add a thunk and create an unbounded call and release chain.
nonisolated final class LockedMainActorCallback<Input: Sendable>: Sendable {
    private final class Callback: Sendable {
        let body: @MainActor @Sendable (Input) -> Void

        init(_ body: @escaping @MainActor @Sendable (Input) -> Void) {
            self.body = body
        }
    }

    private let callback = OSAllocatedUnfairLock<Callback?>(initialState: nil)

    func replace(with body: (@MainActor @Sendable (Input) -> Void)?) {
        let next = body.map(Callback.init)
        callback.withLock {
            $0 = next
        }
    }

    var current: (@MainActor @Sendable (Input) -> Void)? {
        callback.withLock {
            $0
        }?.body
    }
}

private final class TerminalSessionEventDelivery: Sendable {
    private enum Event: Sendable {
        case bell
        case output
        case reset
    }

    private let handler = LockedMainActorCallback<Event>()
    private let lastOutputNotification = OSAllocatedUnfairLock(initialState: Date.distantPast)

    @MainActor
    func setController(_ controller: TerminalSessionController?) {
        handler.replace { [weak controller] event in
            switch event {
            case .bell:
                controller?.noteBell()
            case .output:
                controller?.noteOutputActivity()
            case .reset:
                controller?.programStatusDidReset()
            }
        }
    }

    nonisolated func sendBell() {
        guard let handler = handler.current else {
            return
        }
        Task { @MainActor in
            handler(.bell)
        }
    }

    nonisolated func sendReset() {
        guard let handler = handler.current else {
            return
        }
        Task { @MainActor in
            handler(.reset)
        }
    }

    nonisolated func sendOutput() {
        let shouldNotify = lastOutputNotification.withLock { lastNotification in
            let now = Date()
            guard now.timeIntervalSince(lastNotification) > 0.25 else {
                return false
            }
            lastNotification = now
            return true
        }
        guard shouldNotify, let handler = handler.current else {
            return
        }
        Task { @MainActor in
            handler(.output)
        }
    }
}

final class AppTerminalView: LocalProcessTerminalView, TerminalContextMenuActions {
    weak var sessionController: TerminalSessionController? {
        didSet {
            eventDelivery.setController(sessionController)
            setProcessOutputHandler { [eventDelivery] in
                eventDelivery.sendOutput()
            }
        }
    }

    nonisolated let programStatusTracker = ProgramStatusTracker()
    nonisolated private let eventDelivery = TerminalSessionEventDelivery()

    nonisolated override func showCursor(source: Terminal) {
        programStatusTracker.initializeBuffer(source)
        super.showCursor(source: source)
    }

    nonisolated override func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        programStatusTracker.initializeBuffer(source)
        super.cursorStyleChanged(source: source, newStyle: newStyle)
    }

    nonisolated override func bufferActivated(source: Terminal) {
        super.bufferActivated(source: source)
        if programStatusTracker.bufferActivated(source) {
            eventDelivery.sendReset()
        }
    }
    var fileDropShellResolver = TerminalShellResolver()

    private var inputEchoMonitor: Task<Void, Never>?
    private lazy var hiddenInputIndicator: NSImageView = {
        let image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Input hidden")
        let indicator = NSImageView(image: image ?? NSImage())
        indicator.toolTip = "Input hidden"
        indicator.setAccessibilityLabel("Input hidden")
        indicator.contentTintColor = .labelColor
        indicator.wantsLayer = true
        indicator.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        indicator.layer?.cornerRadius = 5
        indicator.isHidden = true
        addSubview(indicator, positioned: .above, relativeTo: nil)
        return indicator
    }()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        sessionController?.surfaceDidMoveToWindow()
        registerForDraggedTypes([.fileURL])

        inputEchoMonitor?.cancel()
        inputEchoMonitor = nil
        hiddenInputIndicator.isHidden = true
        guard window != nil else { return }
        inputEchoMonitor = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                self?.updateHiddenInputIndicator()
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
            }
        }
    }

    private func updateHiddenInputIndicator() {
        guard hasHiddenLineInput,
              let viewport = terminalContentSnapshot(region: .viewport),
              viewport.capturedRange.contains(viewport.cursorRow) else {
            hiddenInputIndicator.isHidden = true
            return
        }

        // Metal draws its own cursor, so the AppKit caret frame's origin can be stale.
        let cell = caretFrame.size
        let row = viewport.cursorRow - viewport.capturedRange.lowerBound
        let caret = CGRect(
            x: CGFloat(viewport.cursorColumn) * cell.width,
            y: bounds.maxY - CGFloat(row + 1) * cell.height,
            width: cell.width, height: cell.height
        )
        guard !caret.isEmpty, bounds.intersects(caret) else {
            hiddenInputIndicator.isHidden = true
            return
        }

        let size = min(cell.height, 18)
        let gap: CGFloat = 3
        let right = caret.maxX + gap
        let left = caret.minX - gap - size
        let x = right + size <= bounds.maxX ? right : left
        guard x >= bounds.minX else {
            hiddenInputIndicator.isHidden = true
            return
        }

        hiddenInputIndicator.frame = CGRect(
            x: x, y: caret.midY - size / 2, width: size, height: size
        ).integral
        hiddenInputIndicator.isHidden = false
    }

    private var hasHiddenLineInput: Bool {
        guard let process,
              case let .success(descriptor?) = process.duplicatePrimaryDescriptor() else {
            return false
        }
        defer { close(descriptor) }
        var attributes = termios()
        guard tcgetattr(descriptor, &attributes) == 0 else { return false }
        let inputFlags = attributes.c_lflag
        return inputFlags & tcflag_t(ICANON) != 0 && inputFlags & tcflag_t(ECHO) == 0
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard
            sender.draggingSourceOperationMask.contains(.copy),
            TerminalFileDrop.hasFileURLs(in: sender.draggingPasteboard)
        else {
            return []
        }
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        draggingEntered(sender) == .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard sender.draggingSourceOperationMask.contains(.copy) else {
            return false
        }
        return insertDroppedFiles(from: sender.draggingPasteboard)
    }

    @discardableResult
    func insertDroppedFiles(from pasteboard: NSPasteboard) -> Bool {
        guard TerminalFileDrop.hasFileURLs(in: pasteboard) else {
            return false
        }
        let dialect = fileDropShellResolver.dialect(for: process?.childfd)
        guard let text = TerminalFileDrop.text(from: pasteboard, dialect: dialect) else {
            return false
        }
        if window?.makeFirstResponder(self) == true {
            sessionController?.didBecomeFocused()
        }
        // Paste semantics let applications recognize dropped image paths and
        // apply bracketed-paste framing when the application has enabled it.
        pasteText(text)
        return true
    }

    // SwiftTerm's sound delegate is public but not open, so calling super would
    // bypass the shared per-tab sound limit. The controller preserves its visual
    // bell using the app-wide preference while delivering sound once.
    nonisolated override func bell(source: Terminal) {
        programStatusTracker.initializeBuffer(source)
        eventDelivery.sendBell()
    }

    override func mouseDown(with event: NSEvent) {
        focusTerminal()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        focusTerminal()
        super.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard
            event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)),
            !isReportingMouseEvents
        else {
            return nil
        }
        // Auto Fill uses the active text input client.
        focusTerminal()
        return makeContextMenu()
    }

    func makeContextMenu(pasteboard: NSPasteboard = .general) -> NSMenu {
        TerminalContextMenu.make(
            target: self, hasSelection: getSelection()?.isEmpty == false,
            pasteboard: pasteboard
        )
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(splitRight(_:)), #selector(splitLeft(_:)),
             #selector(splitDown(_:)), #selector(splitUp(_:)):
            return sessionController?.workspace != nil
        case #selector(resetTerminal(_:)):
            return true
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    private var isReportingMouseEvents: Bool {
        allowMouseReporting && currentMouseMode != .off
    }

    @objc func splitRight(_ sender: Any?) {
        split(in: .right)
    }

    @objc func splitLeft(_ sender: Any?) {
        split(in: .left)
    }

    @objc func splitDown(_ sender: Any?) {
        split(in: .down)
    }

    @objc func splitUp(_ sender: Any?) {
        split(in: .up)
    }

    private func split(in direction: TerminalPaneDirection) {
        guard let controller = sessionController else {
            return
        }
        controller.workspace?.split(controller, direction: direction)
    }

    @objc func resetTerminal(_ sender: Any?) {
        resetToInitialState()
    }

    private func focusTerminal() {
        if
            window?.firstResponder !== self,
            window?.makeFirstResponder(self) == true {
            sessionController?.didBecomeFocused()
        }
    }

    /// Uses the current terminal-driver control bytes when SwiftTerm filters
    /// text before it sends a paste to the PTY.
    nonisolated override func terminalControlBytesForPaste(source: Terminal) -> Set<UInt8> {
        process?.terminalControlBytesForPaste()
            ?? TerminalPasteControls.approximateTerminalControlBytes
    }
}

/// The actions of the context menu of a terminal pane, local or persistent.
@MainActor @objc protocol TerminalContextMenuActions {
    func splitRight(_ sender: Any?)
    func splitLeft(_ sender: Any?)
    func splitDown(_ sender: Any?)
    func splitUp(_ sender: Any?)
    func resetTerminal(_ sender: Any?)
}

/// The context menu of a terminal pane: Copy and Paste when they apply,
/// the splits, and Reset Terminal.
enum TerminalContextMenu {
    @MainActor
    static func make(
        target: NSResponder & TerminalContextMenuActions, hasSelection: Bool,
        pasteboard: NSPasteboard
    ) -> NSMenu {
        let menu = NSMenu()
        // AppKit adds system menu items, including Auto Fill.
        menu.allowsContextMenuPlugIns = true
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            return item
        }
        if hasSelection {
            menu.addItem(item("Copy", #selector(NSText.copy(_:))))
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            menu.addItem(item("Paste", #selector(NSText.paste(_:))))
        }
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        menu.addItem(item("Split Right", #selector(TerminalContextMenuActions.splitRight(_:))))
        menu.addItem(item("Split Left", #selector(TerminalContextMenuActions.splitLeft(_:))))
        menu.addItem(item("Split Down", #selector(TerminalContextMenuActions.splitDown(_:))))
        menu.addItem(item("Split Up", #selector(TerminalContextMenuActions.splitUp(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Reset Terminal", #selector(TerminalContextMenuActions.resetTerminal(_:))))
        return menu
    }
}
