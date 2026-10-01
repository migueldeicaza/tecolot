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

final class AppTerminalView: LocalProcessTerminalView {
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
        let menu = NSMenu()
        // AppKit adds system menu items, including Auto Fill.
        menu.allowsContextMenuPlugIns = true
        if let selection = getSelection(), !selection.isEmpty {
            menu.addItem(contextMenuItem("Copy", action: #selector(copy(_:))))
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            menu.addItem(contextMenuItem("Paste", action: #selector(paste(_:))))
        }
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        menu.addItem(contextMenuItem("Split Right", action: #selector(splitRight(_:))))
        menu.addItem(contextMenuItem("Split Left", action: #selector(splitLeft(_:))))
        menu.addItem(contextMenuItem("Split Down", action: #selector(splitDown(_:))))
        menu.addItem(contextMenuItem("Split Up", action: #selector(splitUp(_:))))
        menu.addItem(.separator())
        menu.addItem(contextMenuItem("Reset Terminal", action: #selector(resetTerminal(_:))))
        return menu
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

    private func contextMenuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func splitRight(_ sender: Any?) {
        split(in: .right)
    }

    @objc private func splitLeft(_ sender: Any?) {
        split(in: .left)
    }

    @objc private func splitDown(_ sender: Any?) {
        split(in: .down)
    }

    @objc private func splitUp(_ sender: Any?) {
        split(in: .up)
    }

    private func split(in direction: TerminalPaneDirection) {
        guard let controller = sessionController else { return }
        controller.workspace?.split(controller, direction: direction)
    }

    @objc private func resetTerminal(_ sender: Any?) {
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
