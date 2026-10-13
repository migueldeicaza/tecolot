//
//  RemoteTerminalView.swift
//  Tecolot
//
//  The view of a persistent pane. It draws with SwiftTerm's
//  TerminalRenderView and runs no terminal emulator: tecolot-sessiond owns
//  the terminal, and the view sends it keys, text, mouse reports and pastes.
//
//  Keys go to the helper as W3C key events, and the helper encodes them with
//  the terminal's current modes, so a mode change can never race a key.
//

import AppKit
import SwiftTerm
import TecolotSessionClient
import TecolotWire

final class RemoteTerminalView: TerminalRenderView, NSTextInputClient, NSMenuItemValidation {
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

    private struct SpecialKey {
        let key: String
        let code: String
    }

    private static let specialKeys: [UInt16: SpecialKey] = [
        123: SpecialKey(key: "ArrowLeft", code: "ArrowLeft"),
        124: SpecialKey(key: "ArrowRight", code: "ArrowRight"),
        125: SpecialKey(key: "ArrowDown", code: "ArrowDown"),
        126: SpecialKey(key: "ArrowUp", code: "ArrowUp"),
        115: SpecialKey(key: "Home", code: "Home"),
        119: SpecialKey(key: "End", code: "End"),
        116: SpecialKey(key: "PageUp", code: "PageUp"),
        121: SpecialKey(key: "PageDown", code: "PageDown"),
        117: SpecialKey(key: "Delete", code: "Delete"),
        114: SpecialKey(key: "Insert", code: "Insert"),
        53: SpecialKey(key: "Escape", code: "Escape"),
        36: SpecialKey(key: "Enter", code: "Enter"),
        76: SpecialKey(key: "Enter", code: "NumpadEnter"),
        48: SpecialKey(key: "Tab", code: "Tab"),
        51: SpecialKey(key: "Backspace", code: "Backspace"),
        122: SpecialKey(key: "F1", code: "F1"), 120: SpecialKey(key: "F2", code: "F2"),
        99: SpecialKey(key: "F3", code: "F3"), 118: SpecialKey(key: "F4", code: "F4"),
        96: SpecialKey(key: "F5", code: "F5"), 97: SpecialKey(key: "F6", code: "F6"),
        98: SpecialKey(key: "F7", code: "F7"), 100: SpecialKey(key: "F8", code: "F8"),
        101: SpecialKey(key: "F9", code: "F9"), 109: SpecialKey(key: "F10", code: "F10"),
        103: SpecialKey(key: "F11", code: "F11"), 111: SpecialKey(key: "F12", code: "F12"),
        105: SpecialKey(key: "F13", code: "F13"), 107: SpecialKey(key: "F14", code: "F14"),
        113: SpecialKey(key: "F15", code: "F15"), 106: SpecialKey(key: "F16", code: "F16"),
        64: SpecialKey(key: "F17", code: "F17"), 79: SpecialKey(key: "F18", code: "F18"),
        80: SpecialKey(key: "F19", code: "F19"), 90: SpecialKey(key: "F20", code: "F20"),
    ]

    /// Kitty modifier bits: shift 1, alt 2, control 4, super 8, caps lock 64.
    private func modifierBits(_ flags: NSEvent.ModifierFlags, includeOption: Bool = true) -> UInt32 {
        var bits: UInt32 = 0
        if flags.contains(.shift) { bits |= 1 }
        if includeOption && flags.contains(.option) { bits |= 2 }
        if flags.contains(.control) { bits |= 4 }
        if flags.contains(.command) { bits |= 8 }
        if flags.contains(.capsLock) { bits |= 64 }
        return bits
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.contains(.command),
              session.state.kittyKeyboardFlags != 0, shouldSendCommandKeyToTerminal?(event) == true else {
            return super.performKeyEquivalent(with: event)
        }
        sendKey(for: event, key: event.charactersIgnoringModifiers ?? "", code: Self.code(for: event))
        return true
    }

    // The decisions below follow SwiftTerm's TerminalView.keyDown, so that a
    // key reaches the program as the same bytes in a persistent pane as in a
    // local one (KeyParityTests). The helper encodes the keys.
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        guard remoteInputEnabled else { return }
        NSCursor.setHiddenUntilMouseMoves(true)
        if markedText != nil {
            interpretKeyEvents([event])
            return
        }
        let state = session.state
        let kitty = state.kittyKeyboardFlags != 0
        // Function, navigation and keypad keys. Option counts as Alt only when
        // it is the Meta key; without the kitty protocol, a non-Meta Option
        // leaves these keys to the input system.
        if let special = Self.functionalKey(for: event), kitty || !flags.contains(.option) || optionAsMetaKey {
            let modifiers = modifierBits(flags, includeOption: optionAsMetaKey)
            if !kitty, special.key == "PageUp" || special.key == "PageDown",
               modifiers & 0x7 == 0, !state.applicationCursor {
                session.scroll(by: (special.key == "PageUp" ? -1 : 1) * max(1, state.rows - 1))
                flashScroller()
                return
            }
            if special.key == "Backspace" && backspaceSendsControlH && modifiers == 0 {
                sendBytes([0x08])
                return
            }
            var key = special.key
            if (key == "ArrowLeft" || key == "ArrowRight") && swapsArrowKeys(state) {
                // DECSET 1243: in a right-to-left paragraph the arrows follow the text.
                key = key == "ArrowLeft" ? "ArrowRight" : "ArrowLeft"
            }
            sendKey(KeyMessage(key: key, code: key == special.key ? special.code : key, modifiers: modifiers,
                               eventType: event.isARepeat ? 2 : 1, text: special.text))
            return
        }
        if kitty {
            if flags.contains(.control) || (optionAsMetaKey && flags.contains(.option)) {
                sendTextKey(event, text: nil)
            } else if let characters = event.characters, !characters.isEmpty {
                sendTextKey(event, text: characters)
            } else {
                interpretKeyEvents([event])
            }
            return
        }
        if optionAsMetaKey && flags.contains(.option) {
            if let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
                sendBytes([0x1b] + Array(characters.utf8))
            }
            return
        }
        if flags.contains(.control) {
            if event.keyCode == 49 {
                // Control-Space is NUL, whatever AppKit reports for it.
                sendBytes([0])
                return
            }
            if let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
                sendKey(KeyMessage(key: characters.lowercased(), code: Self.code(for: event),
                                   modifiers: modifierBits(flags, includeOption: optionAsMetaKey),
                                   eventType: event.isARepeat ? 2 : 1,
                                   baseLayoutKey: Self.baseLayoutKeys[event.keyCode]?.value ?? 0))
            }
            return
        }
        interpretKeyEvents([event])
    }

    /// A text key as TerminalView's kitty text event describes it: the
    /// unshifted key, the shifted key, and the key at that position on a US
    /// layout.
    private func sendTextKey(_ event: NSEvent, text: String?) {
        let flags = event.modifierFlags
        let hasControl = flags.contains(.control)
        let isControlSpace = hasControl && event.keyCode == 49
        // With Control, charactersIgnoringModifiers keeps Control's translation.
        let reported = hasControl
            ? (event.characters(byApplyingModifiers: [])?.unicodeScalars.first
                ?? event.charactersIgnoringModifiers?.unicodeScalars.first)
            : event.charactersIgnoringModifiers?.unicodeScalars.first
        guard let scalar = isControlSpace ? " " : reported else { return }
        let base = String(scalar).lowercased()
        var shifted: UInt32 = 0
        if flags.contains(.shift) && !isControlSpace {
            let characters = hasControl ? (event.characters(byApplyingModifiers: [.shift]) ?? event.characters)
                                        : event.characters
            shifted = characters?.unicodeScalars.first?.value ?? 0
        }
        let layout = Self.baseLayoutKeys[event.keyCode]
        let baseLayoutKey = layout.map { String($0) == base ? 0 : $0.value } ?? 0
        sendKey(KeyMessage(key: base, code: Self.code(for: event),
                           modifiers: modifierBits(flags, includeOption: optionAsMetaKey),
                           eventType: event.isARepeat ? 2 : 1, text: text, shiftedKey: shifted,
                           baseLayoutKey: baseLayoutKey))
    }

    /// Navigation, function and keypad keys, with their W3C key and code.
    private static func functionalKey(for event: NSEvent) -> (key: String, code: String, text: String?)? {
        if let special = specialKeys[event.keyCode] { return (special.key, special.code, nil) }
        if let code = keypadCodes[event.keyCode] {
            let text = event.characters ?? event.charactersIgnoringModifiers ?? ""
            return (text, code, text.isEmpty ? nil : text)
        }
        return nil
    }

    /// Keypad key codes and their W3C codes (Enter is in `specialKeys`).
    private static let keypadCodes: [UInt16: String] = [
        82: "Numpad0", 83: "Numpad1", 84: "Numpad2", 85: "Numpad3", 86: "Numpad4",
        87: "Numpad5", 88: "Numpad6", 89: "Numpad7", 91: "Numpad8", 92: "Numpad9",
        65: "NumpadDecimal", 75: "NumpadDivide", 67: "NumpadMultiply", 78: "NumpadSubtract",
        69: "NumpadAdd", 81: "NumpadEqual",
    ]

    /// The character at each key position on a US layout (TerminalView's map).
    private static let baseLayoutKeys: [UInt16: UnicodeScalar] = {
        let layout: [(UInt16, Character)] = [
            (0, "a"), (1, "s"), (2, "d"), (3, "f"), (4, "h"), (5, "g"), (6, "z"), (7, "x"), (8, "c"),
            (9, "v"), (11, "b"), (12, "q"), (13, "w"), (14, "e"), (15, "r"), (16, "y"), (17, "t"),
            (18, "1"), (19, "2"), (20, "3"), (21, "4"), (22, "6"), (23, "5"), (24, "="), (25, "9"),
            (26, "7"), (27, "-"), (28, "8"), (29, "0"), (30, "]"), (31, "o"), (32, "u"), (33, "["),
            (34, "i"), (35, "p"), (37, "l"), (38, "j"), (39, "'"), (40, "k"), (41, ";"), (42, "\\"),
            (43, ","), (44, "/"), (45, "n"), (46, "m"), (47, "."), (49, " "), (50, "`"),
        ]
        var map: [UInt16: UnicodeScalar] = [:]
        for (code, character) in layout { map[code] = character.unicodeScalars.first }
        return map
    }()

    override func keyUp(with event: NSEvent) {
        // Release events matter only to programs that asked for them (kitty flag 2).
        guard remoteInputEnabled, session.state.kittyKeyboardFlags & 2 != 0 else { return }
        let key = Self.specialKeys[event.keyCode]?.key ?? event.charactersIgnoringModifiers ?? ""
        let code = Self.specialKeys[event.keyCode]?.code ?? Self.code(for: event)
        session.send(key: KeyMessage(key: key, code: code, modifiers: modifierBits(event.modifierFlags),
                                     eventType: 3))
    }

    /// True when the program asked for swapped arrows and the cursor's
    /// paragraph is drawn right to left, as `TerminalView` decides.
    private func swapsArrowKeys(_ state: RemoteSessionState) -> Bool {
        guard state.bidiArrowKeySwap, let cursor = state.cursor else { return false }
        return baseDirection(row: Int(Int64(cursor.line) - state.displayTop)) == .rightToLeft
    }

    private func sendKey(for event: NSEvent, key: String, code: String, text: String? = nil) {
        sendKey(KeyMessage(key: key, code: code, modifiers: modifierBits(event.modifierFlags),
                           eventType: event.isARepeat ? 2 : 1, text: text))
    }

    private func sendKey(_ message: KeyMessage) {
        guard remoteInputEnabled else { return }
        followAfterInput()
        session.send(key: message)
        resetCaretBlink()
    }

    private func sendBytes(_ bytes: [UInt8]) {
        guard remoteInputEnabled else { return }
        followAfterInput()
        session.send(bytes: bytes)
        resetCaretBlink()
    }

    private func followAfterInput() {
        clearSelection()
        if !session.state.follow { session.followLive() }
    }

    /// The W3C `code` for a character key on a US layout.
    private static func code(for event: NSEvent) -> String {
        guard let character = event.charactersIgnoringModifiers?.uppercased().first else { return "" }
        if character.isLetter, character.isASCII { return "Key\(character)" }
        if character.isNumber, character.isASCII { return "Digit\(character)" }
        return ""
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard remoteInputEnabled else { return }
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = nil
        guard !text.isEmpty else { return }
        followAfterInput()
        session.send(text: text)
        resetCaretBlink()
    }

    override func doCommand(by selector: Selector) {
        guard remoteInputEnabled else { return }
        switch selector {
        case #selector(insertNewline(_:)): session.send(key: KeyMessage(key: "Enter", code: "Enter"))
        case #selector(insertTab(_:)): session.send(key: KeyMessage(key: "Tab", code: "Tab"))
        case #selector(insertBacktab(_:)): session.send(key: KeyMessage(key: "Tab", code: "Tab", modifiers: 1))
        case #selector(deleteBackward(_:)): session.send(key: KeyMessage(key: "Backspace", code: "Backspace"))
        case #selector(cancelOperation(_:)): session.send(key: KeyMessage(key: "Escape", code: "Escape"))
        default: break
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard remoteInputEnabled else { return }
        if let attributed = string as? NSAttributedString {
            markedText = attributed.length == 0 ? nil : attributed
        } else if let plain = string as? String {
            markedText = plain.isEmpty ? nil : NSAttributedString(string: plain)
        }
    }

    func unmarkText() {
        markedText = nil
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
