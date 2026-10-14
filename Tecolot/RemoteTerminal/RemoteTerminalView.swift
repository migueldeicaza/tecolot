//
//  RemoteTerminalView.swift
//  Tecolot
//
//  The view of a persistent pane. It draws with SwiftTerm's
//  TerminalRenderView and runs no terminal emulator: tecolot-sessiond owns
//  the terminal, and the view sends it keys, text, mouse reports and pastes.
//
//  Keys go to the helper as W3C key events with the bytes that SwiftTerm's
//  keyboard router made for them and the modes that it used. The helper
//  sends these bytes while the terminal has these modes, and encodes the key
//  with the modes of now otherwise, so a mode change can never race a key.
//  Typed text goes as text, which the helper encodes with its modes too.
//

import AppKit
import SwiftTerm
import TecolotSessionClient
import TecolotWire

final class RemoteTerminalView: TerminalRenderView, NSTextInputClient, NSMenuItemValidation, TerminalKeyboardHost {
    private(set) var session: RemoteSession
    let source: RemoteFrameSource
    weak var sessionController: TerminalSessionController?

    var optionAsMetaKey = true
    var backspaceSendsControlH = false
    var remoteDestination: String?
    var remoteInputEnabled = true {
        didSet {
            guard remoteInputEnabled != oldValue else { return }
            inputShade.isHidden = remoteInputEnabled
            if !remoteInputEnabled {
                markedText = nil
                keyboardRouter.markedTextChanged(composing: false)
                keyboardRouter.focusLost()
                pressedButton = nil
            }
        }
    }
    private let inputShade = RemoteInputShade(frame: .zero)
    /// Profile key bindings and Command shortcuts run first; see the controller.
    var shouldSendCommandKeyToTerminal: ((NSEvent) -> Bool)?

    private var markedText: NSAttributedString?
    private var wheelRemainder: CGFloat = 0
    private let scroller = NSScroller(frame: .zero)
    private var scrollerFadeGeneration = 0
    private var scrollerUpdatePending = false
    private var selectionAnchor: Position?
    private var selectionHead: Position?
    private var pressedButton: TerminalMouseButton?

    init(session: RemoteSession, font: NSFont) {
        self.session = session
        source = RemoteFrameSource(session: session)
        super.init(frame: .zero, font: font)
        frameSource = source
        onGridSizeChange = { [weak self] columns, rows in
            self?.sendGridSize(columns: columns, rows: rows)
        }
        observe(session)
        scroller.scrollerStyle = .overlay
        scroller.knobStyle = .light
        scroller.controlSize = .regular
        scroller.target = self
        scroller.action = #selector(scrollerMoved(_:))
        scroller.alphaValue = 0
        scroller.isEnabled = false
        addSubview(inputShade)
        inputShade.wantsLayer = true
        inputShade.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        inputShade.autoresizingMask = [.width, .height]
        inputShade.frame = bounds
        inputShade.isHidden = true
        addSubview(scroller)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        hasFocus = true
        session.setFocus(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        hasFocus = false
        session.setFocus(false)
        // Releases can be lost while another view has the keys.
        keyboardRouter.focusLost()
        return true
    }

    /// The grid size with the cell size in device pixels.
    var wireGridSize: WireGridSize {
        let grid = gridSize
        let scale = window?.backingScaleFactor ?? 2
        return WireGridSize(columns: grid.columns, rows: grid.rows,
                            cellWidth: Int((cellSize.width * scale).rounded()),
                            cellHeight: Int((cellSize.height * scale).rounded()))
    }

    /// Device pixels per point, in hundredths, for the helper's image sizes.
    var displayScale: Int {
        Int(((window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2) * 100).rounded())
    }

    private func sendGridSize(columns: Int, rows: Int) {
        guard columns > 1, rows > 1 else { return }
        session.resize(wireGridSize, scale: displayScale)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        source.displayScale = CGFloat(displayScale) / 100
        registerForDraggedTypes([.fileURL])
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        source.displayScale = CGFloat(displayScale) / 100
        let grid = gridSize
        sendGridSize(columns: grid.columns, rows: grid.rows)
    }

    private func observe(_ session: RemoteSession) {
        session.onChange = { [weak self] change in
            self?.requestRedraw()
            DispatchQueue.main.async { [weak self] in self?.sessionController?.refreshRemoteConnectionDisplay() }
            if !change.isDisjoint(with: [.geometry, .viewport, .buffer]) {
                DispatchQueue.main.async { self?.scheduleScrollerUpdate() }
            }
        }
    }

    /// Shows the frames of `newSession` instead of the current session, for
    /// example after a reconnect. The caller wires `onEvent` and starts it.
    func replaceSession(_ newSession: RemoteSession) {
        session.onChange = nil
        session.onEvent = nil
        session.close()
        session = newSession
        source.session = newSession
        observe(newSession)
        hideBanner()
        requestRedraw()
    }

    // MARK: Find

    private var findBar: RemoteFindBar?
    /// The last match, as (start, end) positions; the next search starts after it.
    private var lastMatch: (start: Position, end: Position)?
    /// Where the find started. A changed query searches again from here, so
    /// that typing refines the match instead of moving past it.
    private var searchOrigin: (line: Int64, column: Int)?
    /// Results of older searches (the user typed on) are dropped.
    private var searchGeneration = 0
    /// The text of the find bar's status, for tests.
    var findStatus: String?
    /// Shares the query with other apps. Tests use a private pasteboard.
    var findPasteboard = NSPasteboard(name: .find)

    func performFind(_ action: NSTextFinder.Action) {
        switch action {
        case .showFindInterface:
            showFindBar()
        case .nextMatch:
            if findBar == nil { showFindBar() } else { search(backward: false) }
        case .previousMatch:
            if findBar == nil { showFindBar() } else { search(backward: true) }
        case .hideFindInterface:
            hideFindBar()
        default:
            break
        }
    }

    private func showFindBar() {
        let bar = findBar ?? makeFindBar()
        searchOrigin = nil
        bar.focus()
        // Like local panes: start with the selection, else the find pasteboard.
        selectedText { [weak self, weak bar] selected in
            guard let self, let bar, self.findBar === bar else { return }
            let initial = selected.flatMap { $0.isEmpty || $0.contains("\n") ? nil : $0 }
                ?? findPasteboard.string(forType: .string)
            if let initial, !initial.isEmpty, bar.query != initial {
                bar.query = initial
                bar.focus()
                self.searchFromOrigin()
            }
        }
    }

    private func makeFindBar() -> RemoteFindBar {
        let bar = RemoteFindBar()
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            bar.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
        ])
        bar.onQueryChange = { [weak self] in self?.searchFromOrigin() }
        bar.onSearch = { [weak self] backward in self?.search(backward: backward) }
        bar.onClose = { [weak self] in self?.hideFindBar() }
        findBar = bar
        return bar
    }

    private func hideFindBar() {
        findBar?.removeFromSuperview()
        findBar = nil
        searchOrigin = nil
        searchGeneration += 1
        window?.makeFirstResponder(self)
    }

    /// Searches the bar's query again from where the find started.
    private func searchFromOrigin() {
        guard let bar = findBar else { return }
        guard !bar.query.isEmpty else {
            searchGeneration += 1
            clearSelection()
            setFindStatus("")
            return
        }
        search(backward: false, fromOrigin: true)
    }

    /// Finds `query` after (or before) the last match. Without a match, a
    /// forward search starts at the top of the view and a backward search at
    /// its bottom.
    func search(query: String? = nil, backward: Bool, caseSensitive: Bool? = nil,
                regularExpression: Bool? = nil, wholeWord: Bool? = nil) {
        search(query: query, backward: backward, caseSensitive: caseSensitive,
               regularExpression: regularExpression, wholeWord: wholeWord, fromOrigin: false)
    }

    private func search(query: String? = nil, backward: Bool, caseSensitive: Bool? = nil,
                        regularExpression: Bool? = nil, wholeWord: Bool? = nil, fromOrigin: Bool) {
        let text = query ?? findBar?.query ?? findPasteboard.string(forType: .string) ?? ""
        guard !text.isEmpty else { return }
        if query == nil {
            // Like other Mac apps, share the query through the find pasteboard.
            let finder = findPasteboard
            if finder.string(forType: .string) != text {
                finder.clearContents()
                finder.setString(text, forType: .string)
            }
        }
        var options: SessionSearchOptions = []
        if caseSensitive ?? findBar?.caseSensitive ?? false { options.insert(.caseSensitive) }
        if regularExpression ?? findBar?.regularExpression ?? false { options.insert(.regularExpression) }
        if wholeWord ?? findBar?.wholeWord ?? false { options.insert(.wholeWord) }
        if backward { options.insert(.backward) }
        let state = session.state
        let start: (line: Int64, column: Int)
        if let lastMatch, !fromOrigin {
            start = (Int64(lastMatch.start.row), lastMatch.start.col)
        } else {
            // Just before the first visible cell, so a match at the top is found.
            let origin = searchOrigin ?? (backward ? (state.displayTop + Int64(state.rows), 0) : (state.displayTop, -1))
            searchOrigin = origin
            start = origin
        }
        searchGeneration += 1
        let generation = searchGeneration
        session.search(text, options: options, from: (start.line, max(0, start.column))) { result in
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.searchGeneration else { return }
                self.showSearchResult(result)
            }
        }
    }

    private func setFindStatus(_ text: String) {
        findStatus = text
        findBar?.setStatus(text)
    }

    private func showSearchResult(_ result: SearchResultMessage?) {
        guard let result, result.found else {
            setFindStatus(result?.problem.isEmpty == false ? result!.problem : "Not found")
            // The highlight of an older match no longer applies.
            if lastMatch != nil { clearSelection() }
            return
        }
        setFindStatus("")
        let start = Position(col: result.column, row: Int(result.line))
        let end = Position(col: result.endColumn, row: Int(result.endLine))
        lastMatch = (start, end)
        selectionAnchor = start
        selectionHead = end
        updateSelection()
        let state = session.state
        let line = Int64(result.line)
        if line < state.displayTop || line >= state.displayTop + Int64(state.rows) {
            session.scroll(toTop: line - Int64(state.rows / 2))
        }
    }

    // MARK: Prompts

    /// Scrolls so that the nearest shell prompt above (or below) the top row
    /// is the top row, like local panes do.
    func scrollToPrompt(upward: Bool) {
        let state = session.state
        guard state.buffer == .normal else { return }
        session.findPrompt(from: state.displayTop, upward: upward) { line in
            DispatchQueue.main.async { [weak self] in
                guard let self, let line else { return }
                self.session.scroll(toTop: line)
                self.flashScroller()
            }
        }
    }

    // MARK: Banner

    private var banner: RemoteSessionBanner?

    /// The text of the banner that is shown, if any.
    var bannerText: String? { banner?.text }

    func showBanner(_ text: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        showBanner(text, actionTitle: actionTitle, action: action,
                   secondaryActionTitle: nil, secondaryAction: nil)
    }

    func showBanner(_ text: String, actionTitle: String?, action: (() -> Void)?,
                    secondaryActionTitle: String?, secondaryAction: (() -> Void)?) {
        let banner = self.banner ?? RemoteSessionBanner()
        if self.banner == nil {
            banner.translatesAutoresizingMaskIntoConstraints = false
            addSubview(banner)
            NSLayoutConstraint.activate([
                banner.centerXAnchor.constraint(equalTo: centerXAnchor),
                banner.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
                banner.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -16),
            ])
            self.banner = banner
        }
        banner.configure(text: text, actionTitle: actionTitle, action: action,
                         secondaryActionTitle: secondaryActionTitle, secondaryAction: secondaryAction)
    }

    func hideBanner() {
        banner?.removeFromSuperview()
        banner = nil
    }

    // MARK: File drops

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard remoteDestination != nil, sender.draggingSourceOperationMask.contains(.copy),
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
        guard draggingEntered(sender) == .copy else { return false }
        let alert = NSAlert()
        alert.messageText = "Files cannot be dropped into a remote session."
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
        return false
    }

    // MARK: Scroll bar

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutScroller()
    }

    private func layoutScroller() {
        let width = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
        scroller.frame = NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
    }

    private func scheduleScrollerUpdate() {
        guard !scrollerUpdatePending else { return }
        scrollerUpdatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            scrollerUpdatePending = false
            updateScroller()
        }
    }

    /// Mirrors the helper's line range: the knob is the viewport.
    private func updateScroller() {
        let state = session.state
        let total = state.endLine - state.firstLine
        let rows = Int64(state.rows)
        let scrollable = state.buffer == .normal && total > rows
        scroller.isEnabled = scrollable
        guard scrollable else {
            scroller.alphaValue = 0
            return
        }
        scroller.knobProportion = CGFloat(rows) / CGFloat(total)
        scroller.doubleValue = Double(state.displayTop - state.firstLine) / Double(total - rows)
        if state.follow {
            fadeScroller()
        } else {
            scroller.alphaValue = 1
        }
    }

    /// Shows the scroll bar for a moment while the view follows the live screen.
    private func flashScroller() {
        guard scroller.isEnabled else { return }
        scroller.alphaValue = 1
        fadeScroller()
    }

    private func fadeScroller() {
        scrollerFadeGeneration += 1
        let generation = scrollerFadeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, generation == scrollerFadeGeneration, session.state.follow else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                self.scroller.animator().alphaValue = 0
            }
        }
    }

    @objc private func scrollerMoved(_ sender: NSScroller) {
        let state = session.state
        let rows = max(1, state.rows - 1)
        switch sender.hitPart {
        case .decrementPage: session.scroll(by: -rows)
        case .incrementPage: session.scroll(by: rows)
        case .decrementLine: session.scroll(by: -1)
        case .incrementLine: session.scroll(by: 1)
        case .knob, .knobSlot:
            let total = state.endLine - state.firstLine - Int64(state.rows)
            session.scroll(toTop: state.firstLine + Int64((sender.doubleValue * Double(max(0, total))).rounded()))
        default: break
        }
        scheduleScrollerUpdate()
    }

    // MARK: Keyboard

    /// SwiftTerm's keyboard router makes the same decisions as in a local
    /// pane, so a key reaches the program as the same bytes (KeyParityTests).
    private lazy var keyboardRouter = TerminalKeyboardRouter(host: self)

    /// The input modes that the router read last: the modes of the bytes
    /// that it sends next.
    private var routerInputModes: UInt32 = 0
    /// True while the router reports a modifier key (kitty "report all
    /// keys"). A modifier key does not end the selection or leave the
    /// scrollback, so that Command-C copies the selection.
    private var routesModifierKey = false

    var keyboardModes: TerminalKeyboardModes {
        routerInputModes = session.state.inputModes
        return TerminalKeyboardModes(hostInputModes: routerInputModes)
    }

    /// True when the program asked for swapped arrows and the cursor's
    /// paragraph is drawn right to left, as `TerminalView` decides.
    var swapsHorizontalArrowKeys: Bool {
        let state = session.state
        guard state.bidiArrowKeySwap, let cursor = state.cursor else { return false }
        return baseDirection(row: Int(Int64(cursor.line) - state.displayTop)) == .rightToLeft
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        (remoteInputEnabled && keyboardRouter.performKeyEquivalent(event)) || super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard remoteInputEnabled else {
            if event.modifierFlags.contains(.command) { super.keyDown(with: event) }
            return
        }
        keyboardRouter.keyDown(event)
    }

    override func keyUp(with event: NSEvent) {
        if remoteInputEnabled { keyboardRouter.keyUp(event) }
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        if remoteInputEnabled {
            routesModifierKey = true
            keyboardRouter.flagsChanged(event)
            routesModifierKey = false
        }
        super.flagsChanged(with: event)
    }

    override func doCommand(by selector: Selector) {
        guard remoteInputEnabled else { return }
        keyboardRouter.doCommand(selector)
    }

    /// The controller hides the pointer while the user types, when the
    /// profile asks for it.
    func keyboardRouterKeyDown(_ event: NSEvent) {
        guard remoteInputEnabled else { return }
        clearSelection()
    }

    func keyboardRouter(send event: TerminalKeyEvent, bytes: [UInt8]) {
        guard remoteInputEnabled else { return }
        // Releases and modifier keys keep the selection (as in a local
        // pane) and the scroll position.
        if event.eventType != 3 && !routesModifierKey {
            followAfterInput()
        }
        if event.isText, let text = event.text {
            session.send(text: text)
        } else if session.state.helperCapabilities.contains(.keyBytes), bytes.count <= KeyMessage.bytesLimit {
            let fields = event.hostKey
            session.send(key: KeyMessage(key: fields.key, code: fields.code, modifiers: event.modifiers,
                                         eventType: event.eventType, text: event.text,
                                         shiftedKey: event.shiftedKey, baseLayoutKey: event.baseLayoutKey,
                                         composing: event.composing,
                                         backspaceSendsControlH: event.backspaceSendsControlH,
                                         bytes: bytes, modes: routerInputModes))
        } else {
            // A helper from an older build ignores the options of a key
            // (Backspace would send DEL): send the bytes themselves.
            session.send(bytes: bytes)
        }
        resetCaretBlink()
    }

    func keyboardRouter(send bytes: [UInt8]) {
        guard remoteInputEnabled else { return }
        followAfterInput()
        session.send(bytes: bytes)
        resetCaretBlink()
    }

    /// The helper encodes typed text with the terminal's modes of now.
    func keyboardRouter(sendText text: String) {
        guard remoteInputEnabled else { return }
        followAfterInput()
        session.send(text: text)
        resetCaretBlink()
    }

    /// As `TerminalView.pageUp()`: the alternate screen gets the key, the
    /// normal screen scrolls one page.
    func keyboardRouterScrollPage(up: Bool) {
        guard remoteInputEnabled else { return }
        let state = session.state
        if state.buffer == .alternate {
            keyboardRouter(send: up ? EscapeSequences.cmdPageUp : EscapeSequences.cmdPageDown)
            return
        }
        session.scroll(by: (up ? -1 : 1) * max(1, state.rows))
        flashScroller()
    }

    private func followAfterInput() {
        clearSelection()
        if !session.state.follow { session.followLive() }
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard remoteInputEnabled else { return }
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = nil
        guard !text.isEmpty else {
            keyboardRouter.markedTextChanged(composing: false)
            return
        }
        // A commit ends the preedit; the router clears it.
        keyboardRouter.insertText(text)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard remoteInputEnabled else { return }
        if let attributed = string as? NSAttributedString {
            markedText = attributed.length == 0 ? nil : attributed
        } else if let plain = string as? String {
            markedText = plain.isEmpty ? nil : NSAttributedString(string: plain)
        } else {
            markedText = nil
        }
        keyboardRouter.markedTextChanged(composing: markedText != nil)
    }

    func unmarkText() {
        markedText = nil
        keyboardRouter.markedTextChanged(composing: false)
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func markedRange() -> NSRange {
        markedText.map { NSRange(location: 0, length: $0.length) } ?? NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool { markedText != nil }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        markedText
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(caretFrame, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    // MARK: Mouse

    private func mouseCell(_ event: NSEvent) -> (column: Int, row: Int, pixelX: Int, pixelY: Int) {
        let point = convert(event.locationInWindow, from: nil)
        let cell = cell(at: point)
        let state = session.state
        let scale = window?.backingScaleFactor ?? 1
        let row = min(cell.row, max(0, state.rows - 1))
        // In bidi rows the clicked (visual) column shows another logical column.
        let column = logicalColumn(forVisualColumn: min(cell.column, max(0, state.columns - 1)), row: row)
        return (column, row, Int(max(0, point.x) * scale), Int(max(0, bounds.height - point.y) * scale))
    }

    /// Mouse events go to the program when it asked for them, the view
    /// follows the live screen, and Shift is not held.
    private func reportsMouse(_ event: NSEvent) -> Bool {
        let state = session.state
        return remoteInputEnabled && state.mouseReporting && state.follow && !event.modifierFlags.contains(.shift)
    }

    private func sendMouse(_ action: TerminalMouseAction, _ button: TerminalMouseButton, _ event: NSEvent) {
        guard remoteInputEnabled else { return }
        let cell = mouseCell(event)
        let flags = event.modifierFlags
        var modifiers: UInt8 = 0
        if flags.contains(.shift) { modifiers |= 1 }
        if flags.contains(.option) { modifiers |= 2 }
        if flags.contains(.control) { modifiers |= 4 }
        session.send(mouse: MouseMessage(action: UInt8(action.rawValue), button: UInt8(button.rawValue),
                                         modifiers: modifiers, column: cell.column, row: cell.row,
                                         pixelX: cell.pixelX, pixelY: cell.pixelY))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if reportsMouse(event) {
            pressedButton = .left
            sendMouse(.press, .left, event)
            return
        }
        let cell = mouseCell(event)
        let line = Int(session.state.displayTop) + cell.row
        switch event.clickCount {
        case 2:
            selectWord(line: line, column: cell.column)
        case 3:
            selectionAnchor = Position(col: 0, row: line)
            selectionHead = Position(col: max(0, session.state.columns - 1), row: line)
            updateSelection()
        default:
            selectionAnchor = Position(col: cell.column, row: line)
            selectionHead = nil
            updateSelection()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if pressedButton != nil {
            sendMouse(.move, .left, event)
            return
        }
        guard selectionAnchor != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        if point.y > bounds.height { session.scroll(by: -1) }
        if point.y < 0 { session.scroll(by: 1) }
        let cell = mouseCell(event)
        selectionHead = Position(col: cell.column, row: Int(session.state.displayTop) + cell.row)
        updateSelection()
    }

    override func mouseUp(with event: NSEvent) {
        if pressedButton != nil {
            pressedButton = nil
            sendMouse(.release, .left, event)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let state = session.state
        // Any-event tracking (mode 1003) reports motion without a button.
        if state.pointerModes & 0x7 == 4 && state.follow {
            sendMouse(.move, .none, event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let state = session.state
        var delta = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas { delta /= max(1, cellSize.height) }
        wheelRemainder += delta
        let lines = Int(wheelRemainder)
        guard lines != 0 else { return }
        wheelRemainder -= CGFloat(lines)
        if reportsMouse(event) {
            for _ in 0 ..< min(abs(lines), 10) {
                sendMouse(.wheel, lines > 0 ? .wheelUp : .wheelDown, event)
            }
        } else if state.buffer == .alternate {
            if remoteInputEnabled && state.alternateScroll {
                let key = lines > 0 ? "ArrowUp" : "ArrowDown"
                for _ in 0 ..< min(abs(lines), 10) {
                    session.send(key: KeyMessage(key: key, code: key))
                }
            }
        } else {
            session.scroll(by: -lines)
            flashScroller()
        }
    }

    // MARK: Selection and clipboard

    var selectionActive: Bool { selectionAnchor != nil && selectionHead != nil }

    private func clearSelection() {
        lastMatch = nil
        guard selectionAnchor != nil else { return }
        selectionAnchor = nil
        selectionHead = nil
        updateSelection()
    }

    private func updateSelection() {
        if let range = orderedSelection {
            // The view keeps inclusive positions (copy reads them); the
            // renderer, like SelectionService, stops before `end`.
            source.selection = TerminalExternalSelection(
                start: range.start, end: Position(col: range.end.col + 1, row: range.end.row))
        } else {
            source.selection = nil
        }
        requestRedraw()
    }

    private func selectWord(line: Int, column: Int) {
        let cells: [WireCell]? = session.withState { _, cache in cache[Int64(line)]?.cells }
        guard let cells, column < cells.count else { return }
        func isWord(_ cell: WireCell) -> Bool {
            switch cell.content {
            case .ascii(let byte):
                let scalar = UnicodeScalar(byte)
                return CharacterSet.alphanumerics.contains(scalar) || "_-./~".unicodeScalars.contains(scalar)
            case .grapheme: return true
            case .spacer: return true
            case .null: return false
            }
        }
        guard isWord(cells[column]) else { return }
        var start = column
        var end = column
        while start > 0 && isWord(cells[start - 1]) { start -= 1 }
        while end + 1 < cells.count && isWord(cells[end + 1]) { end += 1 }
        selectionAnchor = Position(col: start, row: line)
        selectionHead = Position(col: end, row: line)
        updateSelection()
    }

    /// The selected range, start first.
    private var orderedSelection: (start: Position, end: Position)? {
        guard let anchor = selectionAnchor, let head = selectionHead else { return nil }
        return Position.compare(anchor, head) == .before ? (anchor, head) : (head, anchor)
    }

    @objc func copy(_ sender: Any?) {
        selectedText { text in
            if let text { Self.setPasteboard(text) }
        }
    }

    /// The selected text, from the cache when every row is cached, otherwise
    /// from the helper. Calls `completion` on the main thread.
    func selectedText(_ completion: @escaping @MainActor (String?) -> Void) {
        guard let range = orderedSelection else {
            completion(nil)
            return
        }
        let start = (line: Int64(range.start.row), column: range.start.col)
        let end = (line: Int64(range.end.row), column: range.end.col)
        if let text = session.withState({ _, cache in cache.text(from: start, to: end) }) {
            completion(text)
            return
        }
        session.text(from: start, to: end) { text in
            DispatchQueue.main.async { completion(text) }
        }
    }

    /// The text of the whole buffer (scrollback and screen), from the helper.
    func bufferText(_ completion: @escaping @MainActor (String) -> Void) {
        let state = session.state
        let last = max(state.firstLine, state.endLine - 1)
        session.text(from: (state.firstLine, 0), to: (last, max(0, state.columns - 1))) { text in
            DispatchQueue.main.async { completion((text ?? "") + "\n") }
        }
    }

    private static func setPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard remoteInputEnabled else { return }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        keyboardRouter.textWillBePasted()
        followAfterInput()
        session.paste(text) { [weak self] result in
            guard result.status == .needsApproval else { return }
            DispatchQueue.main.async { self?.confirmUnsafePaste(token: result.token) }
        }
    }

    private func confirmUnsafePaste(token: UInt64) {
        guard remoteInputEnabled else { return }
        let alert = NSAlert()
        alert.messageText = "Paste text that contains control characters?"
        alert.informativeText = "The text has characters that a program can treat as commands."
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        let approve: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, remoteInputEnabled else { return }
            session.approvePaste(token: token, approved: response == .alertFirstButtonReturn)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: approve)
        } else {
            approve(alert.runModal())
        }
    }

    override func selectAll(_ sender: Any?) {
        let state = session.state
        selectionAnchor = Position(col: 0, row: Int(state.firstLine))
        selectionHead = Position(col: max(0, state.columns - 1), row: Int(max(state.firstLine, state.endLine - 1)))
        updateSelection()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)): return selectionActive
        case #selector(paste(_:)): return remoteInputEnabled && NSPasteboard.general.string(forType: .string) != nil
        default: return true
        }
    }
}

extension RemoteTerminalView: TerminalSurface {
    var gridDimensions: (cols: Int, rows: Int) {
        let grid = gridSize
        return (grid.columns, grid.rows)
    }
}

private final class RemoteInputShade: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
