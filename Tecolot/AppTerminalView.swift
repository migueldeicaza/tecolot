//
//  AppTerminalView.swift
//  Tecolot
//

import AppKit
import Foundation
import os
import SwiftTerm

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
        callback.withLock { $0 = next }
    }

    var current: (@MainActor @Sendable (Input) -> Void)? {
        callback.withLock { $0 }?.body
    }
}

private final class TerminalSessionEventDelivery: Sendable {
    private enum Event: Sendable {
        case bell
        case output
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
            }
        }
    }

    nonisolated func sendBell() {
        guard let handler = handler.current else { return }
        Task { @MainActor in
            handler(.bell)
        }
    }

    nonisolated func sendOutput() {
        let shouldNotify = lastOutputNotification.withLock { lastNotification in
            let now = Date()
            guard now.timeIntervalSince(lastNotification) > 0.25 else { return false }
            lastNotification = now
            return true
        }
        guard shouldNotify, let handler = handler.current else { return }
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

    nonisolated private let eventDelivery = TerminalSessionEventDelivery()
    var fileDropShellResolver = TerminalShellResolver()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSourceOperationMask.contains(.copy),
              TerminalFileDrop.hasFileURLs(in: sender.draggingPasteboard) else { return [] }
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        draggingEntered(sender) == .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard sender.draggingSourceOperationMask.contains(.copy) else { return false }
        return insertDroppedFiles(from: sender.draggingPasteboard)
    }

    @discardableResult
    func insertDroppedFiles(from pasteboard: NSPasteboard) -> Bool {
        guard TerminalFileDrop.hasFileURLs(in: pasteboard) else { return false }
        let dialect = fileDropShellResolver.dialect(for: process?.childfd)
        guard let text = TerminalFileDrop.text(from: pasteboard, dialect: dialect) else { return false }
        if window?.makeFirstResponder(self) == true {
            sessionController?.didBecomeFocused()
        }
        // Paste semantics let applications recognize dropped image paths and
        // apply bracketed-paste framing when the application has enabled it.
        pasteText(text)
        return true
    }

    nonisolated override func bell(source: Terminal) {
        super.bell(source: source)
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
        guard event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)),
              !isReportingMouseEvents else { return nil }
        // Auto Fill uses the active text input client.
        focusTerminal()
        return makeContextMenu()
    }

    func makeContextMenu(pasteboard: NSPasteboard = .general) -> NSMenu {
        TerminalContextMenu.make(target: self, hasSelection: getSelection()?.isEmpty == false,
                                 pasteboard: pasteboard)
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
        guard let controller = sessionController else { return }
        controller.workspace?.split(controller, direction: direction)
    }

    @objc func resetTerminal(_ sender: Any?) {
        resetToInitialState()
    }

    private func focusTerminal() {
        if window?.firstResponder !== self,
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
    static func make(target: NSResponder & TerminalContextMenuActions, hasSelection: Bool,
                     pasteboard: NSPasteboard) -> NSMenu {
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
