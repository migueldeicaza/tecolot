//
//  AppTerminalView.swift
//  Tecolot
//

import AppKit
import Darwin
import Foundation
import os
import SwiftTerm
import TecolotSessionHost

enum TerminalClearAction {
    /// Clears the active screen and normal-buffer history without sending data
    /// to the process. The escape sequence also moves the terminal cursor home.
    static func perform(on terminal: TerminalView) {
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

private nonisolated final class LockedVoidCallback: Sendable {
    private final class Callback: Sendable {
        let body: @Sendable () -> Void

        init(_ body: @escaping @Sendable () -> Void) {
            self.body = body
        }
    }

    private let callback = OSAllocatedUnfairLock<Callback?>(initialState: nil)

    func replace(with body: (@Sendable () -> Void)?) {
        let next = body.map(Callback.init)
        callback.withLock {
            $0 = next
        }
    }

    func call() {
        callback.withLock { $0 }?.body()
    }
}

private nonisolated final class TerminalSessionEventDelivery: Sendable {
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

/// Process delegate for `AppTerminalView`, mirroring SwiftTerm's
/// `LocalProcessTerminalViewDelegate` while backing the view with
/// `HotReloadableLocalProcess`.
@MainActor
protocol AppTerminalViewDelegate: AnyObject {
    func sizeChanged(source: AppTerminalView, newCols: Int, newRows: Int)
    func setTerminalTitle(source: AppTerminalView, title: String)
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?)
    func processTerminated(source: TerminalView, exitCode: Int32?)
    func processFailedToStart(source: TerminalView, error: LocalProcessError)
    func programStatusChanged(source: TerminalView, records: [TerminalProgramStatus])
    func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities
    func kittyClipboardAvailableMimeTypes(
        source: TerminalView,
        location: KittyClipboardLocation
    ) -> [String]?
    func kittyClipboardRead(
        source: TerminalView,
        location: KittyClipboardLocation,
        mimeType: String
    ) -> KittyClipboardReadResult?
    func kittyClipboardWrite(
        source: TerminalView,
        location: KittyClipboardLocation,
        content: KittyClipboardWriteContent
    ) -> KittyClipboardWriteResult
    func kittyClipboardRequestPermission(
        source: TerminalView,
        request: KittyClipboardPermissionRequest
    ) -> KittyClipboardPermissionResult
}

extension AppTerminalViewDelegate {
    func programStatusChanged(source: TerminalView, records: [TerminalProgramStatus]) {}
    func processFailedToStart(source: TerminalView, error: LocalProcessError) {}
    func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities { [] }
    func kittyClipboardAvailableMimeTypes(
        source: TerminalView,
        location: KittyClipboardLocation
    ) -> [String]? { nil }
    func kittyClipboardRead(
        source: TerminalView,
        location: KittyClipboardLocation,
        mimeType: String
    ) -> KittyClipboardReadResult? { nil }
    func kittyClipboardWrite(
        source: TerminalView,
        location: KittyClipboardLocation,
        content: KittyClipboardWriteContent
    ) -> KittyClipboardWriteResult { .unsupported }
    func kittyClipboardRequestPermission(
        source: TerminalView,
        request: KittyClipboardPermissionRequest
    ) -> KittyClipboardPermissionResult { .deny }
}

private nonisolated final class AppTerminalProcessAdapter: HotReloadableLocalProcessDelegate, Sendable {
    private let feedSender: TerminalFeedSender
    private let outputHandler: LockedVoidCallback
    private let windowSize = OSAllocatedUnfairLock(initialState: winsize())
    private let failureHandler: @MainActor @Sendable (LocalProcessError) -> Void
    private let terminationHandler: @MainActor @Sendable (Int32?) -> Void

    init(
        feedSender: TerminalFeedSender,
        outputHandler: LockedVoidCallback,
        failureHandler: @escaping @MainActor @Sendable (LocalProcessError) -> Void,
        terminationHandler: @escaping @MainActor @Sendable (Int32?) -> Void
    ) {
        self.feedSender = feedSender
        self.outputHandler = outputHandler
        self.failureHandler = failureHandler
        self.terminationHandler = terminationHandler
    }

    func updateWindowSize(_ value: winsize) {
        windowSize.withLock { $0 = value }
    }

    func currentWindowSize() -> winsize {
        windowSize.withLock { $0 }
    }

    func hotReloadProcess(_ source: HotReloadableLocalProcess, didReceiveData bytes: [UInt8]) {
        feedSender.feed(byteArray: bytes[...])
        outputHandler.call()
    }

    func hotReloadProcess(_ source: HotReloadableLocalProcess, didTerminateWithExitCode exitCode: Int32?) {
        let handler = terminationHandler
        Task { @MainActor in
            handler(exitCode)
        }
    }

    func hotReloadProcess(_ source: HotReloadableLocalProcess, didFailToStart error: LocalProcessError) {
        let handler = failureHandler
        Task { @MainActor in
            handler(error)
        }
    }
}

final class AppTerminalView: TerminalView, TerminalViewDelegate, TerminalContextMenuActions {
    private(set) var process: HotReloadableLocalProcess!
    private var processAdapter: AppTerminalProcessAdapter!
    nonisolated private let processOutputHandler = LockedVoidCallback()

    weak var processDelegate: (any AppTerminalViewDelegate)? {
        didSet {
            refreshKittyClipboardCapabilities()
        }
    }

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
    var fileDropShellResolver = TerminalShellResolver()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLocalProcess()
    }

    override init(frame: CGRect, font: NSFont? = nil, options: TerminalOptions) {
        super.init(frame: frame, font: font, options: options)
        setupLocalProcess()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLocalProcess()
    }

    private func setupLocalProcess() {
        terminalDelegate = self
        resolvesLinksAgainstShellDirectory = true
        let adapter = AppTerminalProcessAdapter(
            feedSender: feedSender,
            outputHandler: processOutputHandler,
            failureHandler: { [weak self] error in
                guard let self else { return }
                self.feed(text: "\r\nProcess launch failed: \(error)\r\n")
                self.processDelegate?.processFailedToStart(source: self, error: error)
            },
            terminationHandler: { [weak self] exitCode in
                guard let self else { return }
                self.programStatusProcessExited()
                self.processDelegate?.processTerminated(source: self, exitCode: exitCode)
            }
        )
        processAdapter = adapter
        process = HotReloadableLocalProcess(delegate: adapter, deliveryQueue: .main)
        adapter.updateWindowSize(getWindowSize())
    }

    func setProcessOutputHandler(_ handler: (@Sendable () -> Void)?) {
        processOutputHandler.replace(with: handler)
    }

    func startProcess(
        executable: String = "/bin/bash",
        args: [String] = [],
        environment: [String]? = nil,
        execName: String? = nil,
        currentDirectory: String? = nil
    ) {
        let size = getWindowSize()
        processAdapter.updateWindowSize(size)
        _ = process.startProcess(
            executable: executable,
            args: args,
            environment: environment,
            execName: execName,
            currentDirectory: currentDirectory,
            windowSize: size
        )
    }

    /// Attaches an already-running shell whose PTY master FD arrived over
    /// `SCM_RIGHTS` during an in-place hot reload.
    func attachAdoptedProcess(
        fd: Int32,
        shellPid: pid_t,
        startTime: ProcessStartTime?,
        sendSigwinch: Bool = true
    ) {
        let size = getWindowSize()
        processAdapter.updateWindowSize(size)
        _ = process.attachAdopted(
            fd: fd,
            shellPid: shellPid,
            startTime: startTime,
            windowSize: size,
            sendSigwinch: sendSigwinch
        )
    }

    func pauseForHandoff() -> HotReloadProcessPauseSnapshot? {
        process.pauseForHandoff()
    }

    func resumeAfterAbortedHandoff() {
        process.resumeAfterAbortedHandoff()
    }

    func commitHandoff() {
        process.commitHandoff()
    }

    func terminate() {
        process.terminate()
    }

    func setHostLogging(directory: String?) {
        process.setHostLogging(directory: directory)
    }

    func getWindowSize() -> winsize {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let dimensions = terminalDimensions
        let pxW = Int(max(0, bounds.width) * scale)
        let pxH = Int(max(0, bounds.height) * scale)
        return winsize(
            ws_row: UInt16(clamping: max(0, dimensions.rows)),
            ws_col: UInt16(clamping: max(0, dimensions.cols)),
            ws_xpixel: UInt16(clamping: pxW),
            ws_ypixel: UInt16(clamping: pxH)
        )
    }

    private func syncProcessWindowSizeIfNeeded() {
        guard let processAdapter, let process else {
            return
        }
        var size = getWindowSize()
        let previous = processAdapter.currentWindowSize()
        guard
            size.ws_row != previous.ws_row || size.ws_col != previous.ws_col
            || size.ws_xpixel != previous.ws_xpixel || size.ws_ypixel != previous.ws_ypixel
        else {
            return
        }
        processAdapter.updateWindowSize(size)
        _ = process.updateWindowSize(&size)
    }

    // MARK: - TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        syncProcessWindowSizeIfNeeded()
        processDelegate?.sizeChanged(source: self, newCols: newCols, newRows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        processDelegate?.setTerminalTitle(source: self, title: title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        processDelegate?.hostCurrentDirectoryUpdate(source: source, directory: directory)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        process.send(data: data)
    }

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        if let str = String(bytes: content, encoding: .utf8) {
            let pasteBoard = NSPasteboard.general
            pasteBoard.clearContents()
            pasteBoard.writeObjects([str as NSString])
        }
    }

    func clipboardRead(source: TerminalView) -> Data? {
        guard let str = NSPasteboard.general.string(forType: .string) else {
            return nil
        }
        return str.data(using: .utf8)
    }

    func programStatusChanged(source: TerminalView, records: [TerminalProgramStatus]) {
        processDelegate?.programStatusChanged(source: source, records: records)
    }

    func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities {
        processDelegate?.kittyClipboardCapabilities(source: source) ?? []
    }

    func kittyClipboardAvailableMimeTypes(
        source: TerminalView,
        location: KittyClipboardLocation
    ) -> [String]? {
        processDelegate?.kittyClipboardAvailableMimeTypes(source: source, location: location)
    }

    func kittyClipboardRead(
        source: TerminalView,
        location: KittyClipboardLocation,
        mimeType: String
    ) -> KittyClipboardReadResult? {
        processDelegate?.kittyClipboardRead(source: source, location: location, mimeType: mimeType)
    }

    func kittyClipboardWrite(
        source: TerminalView,
        location: KittyClipboardLocation,
        content: KittyClipboardWriteContent
    ) -> KittyClipboardWriteResult {
        processDelegate?.kittyClipboardWrite(source: source, location: location, content: content)
            ?? .unsupported
    }

    func kittyClipboardRequestPermission(
        source: TerminalView,
        request: KittyClipboardPermissionRequest
    ) -> KittyClipboardPermissionResult {
        processDelegate?.kittyClipboardRequestPermission(source: source, request: request) ?? .deny
    }

    // MARK: - Terminal overrides & UI hooks

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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            syncProcessWindowSizeIfNeeded()
        }
        sessionController?.surfaceDidMoveToWindow()
        registerForDraggedTypes([.fileURL])
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if window != nil {
            syncProcessWindowSizeIfNeeded()
        }
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
