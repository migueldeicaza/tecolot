//
// SessionHost.swift
// TecolotSessionHost
//
// Owns one terminal session: the PTY, the child process and a headless
// SwiftTerm `Terminal`. Clients attach over message channels and receive
// frames that hold only the rows that changed in their viewport.
//
// Threads and locks:
// - The PTY delivery queue feeds the terminal under `terminal.terminalLock`.
//   Terminal delegate callbacks run there, with the lock held; they only
//   record state in `events` and signal the tick source.
// - The session queue (`queue`) owns all client state, the line table and
//   the numbering. It takes the terminal lock to read rows and to encode
//   input. Client channels deliver their messages on this queue.
// - Lock order: terminal lock, then the events lock.
//

import Foundation
import Synchronization
import SwiftTerm
import TecolotTransport
import TecolotWire
import TecolotSessionDirectory
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// State that terminal callbacks record for the session queue.
struct HostEvents {
    enum Edge {
        case bell
        case clipboardCopy([UInt8])
        case clipboardRead(UInt64, String)
        case exited(Int32?)
    }

    var latched: UInt64 = 0
    var title = ""
    var titleVersion: UInt64 = 0
    var iconTitle = ""
    var iconTitleVersion: UInt64 = 0
    var directory = ""
    var directoryVersion: UInt64 = 0
    var colorsVersion: UInt64 = 0
    var paletteOverrides = Set<UInt8>()
    var cursorVisible = true
    var reverseVideo = false
    var reverseVideoProbe = false
    var edges: [Edge] = []
    var droppedBells = 0
    var nextClipboardRequest: UInt64 = 1
    var hasAttachedClients = false
    var cellSize: (width: Int, height: Int)?
    /// The size owner's device pixels per point.
    var scale: Double = 2
    var windowSize = (columns: 80, rows: 24, cellWidth: 0, cellHeight: 0)

    mutating func bumpLatched() { latched &+= 1 }
}

/// Points in the life of a keystroke, for latency measurements.
public enum SessionTraceEvent: Sendable {
    /// Input from a client went to the terminal.
    case input
    /// The terminal parsed one batch of output.
    case fed(ArraySlice<UInt8>)
    /// A frame left for a client. It shows the first `feed` parsed batches.
    case frameSent(sequence: UInt64, feed: UInt64)
    /// A client has a frame to get but no credit (frames await acks).
    case waitingForCredit
    /// A client has a frame to get but its frame-rate slot is not open.
    case waitingForSlot
    /// Bytes that the terminal wrote to the child (encoded keys, replies).
    case childInput(ArraySlice<UInt8>)
}

public final class SessionHost: @unchecked Sendable {
    /// Development only (tecolot-latency): set before `start()`. Called on
    /// the thread where the event happens.
    public var trace: (@Sendable (SessionTraceEvent) -> Void)?

    public let id: String
    public let build: String
    public let launch: SessionLaunch
    public let queue: DispatchQueue
    let ptyQueue: DispatchQueue
    let rasterImages = RasterImageTable()
    private let kittyImages = KittyImageTable()

    public private(set) var terminal: Terminal!
    private(set) var process: LocalProcess!

    let events = Mutex(HostEvents())
    let feedSequence = Atomic<UInt64>(0)
    private let terminationRequested = Atomic<Bool>(false)

    /// True after a client or the owner asked the session to end.
    public var wasTerminationRequested: Bool { terminationRequested.load(ordering: .relaxed) }

    // Session queue state.
    private var clients: [ObjectIdentifier: SessionClient] = [:]
    private let lineTable = LineTable()
    private var lineEncoder = LineEncoder()
    private let links = LinkTable()
    private var normalNumbering = BufferNumbering()
    private var alternateNumbering = BufferNumbering()
    private var wasAlternate = false
    private var normalResizedDuringAlternate = false
    private var forceDiscontinuity = false
    private var sizeOwner: SessionClient?
    private var tickSource: DispatchSourceUserDataOr!
    private var frameTimer: DispatchSourceTimer?
    private var frameTimerDeadline: DispatchTime?
    private var infoTimer: DispatchSourceTimer?
    private var lastSessionInfo: SessionInfoMessage?
    private var pendingPastes: [UInt64: String] = [:]
    private var nextPasteToken: UInt64 = 1
    private var clipboardReaders: [UInt64: SessionClient] = [:]
    private var started = false
    private var notifiedTitleVersion: UInt64 = 0
    private var notifiedDirectoryVersion: UInt64 = 0

    /// The exit status once the child process ended.
    public private(set) var exitStatus: Int32??

    /// Called on the session queue when the child process ended.
    public var onExit: ((Int32?) -> Void)?
    /// Called on the session queue when the last client detached.
    public var onIdle: (() -> Void)?
    /// Called on the session queue with the number of attached clients when it changes.
    public var onAttachmentChange: ((Int) -> Void)?
    /// Called on the session queue when the foreground process or the child state changes.
    public var onSessionInfo: ((SessionInfoMessage) -> Void)?
    /// Called on the session queue when the grid size changes.
    public var onGridChange: ((_ columns: Int, _ rows: Int) -> Void)?
    /// Called on the session queue when the title or directory changed.
    public var onMetadataChange: ((_ title: String, _ directory: String) -> Void)?

    public init(id: String, launch: SessionLaunch, build: String = "dev") {
        self.id = id
        self.launch = launch
        self.build = build
        queue = DispatchQueue(label: "tecolot.session.\(id)", qos: .userInitiated)
        ptyQueue = DispatchQueue(label: "tecolot.session.\(id).pty", qos: .userInitiated)

        var options = TerminalOptions.default
        options.cols = max(2, launch.columns)
        options.rows = max(2, launch.rows)
        options.scrollback = max(0, launch.scrollback)
        options.termName = launch.termName
        options.cursorStyle = WireMapping.cursorStyle(launch.cursorStyle)
        options.featureReport = launch.featureReport
        if let limit = launch.kittyGraphicsStorageLimit {
            options.kittyGraphics = KittyGraphicsConfiguration(
                storageLimitBytesPerScreen: limit,
                localMediaPolicy: .init(rawValue: launch.kittyGraphicsLocalMedia ?? 0))
        }
        events.withLock {
            $0.windowSize = (options.cols, options.rows, launch.cellWidth, launch.cellHeight)
            if launch.cellWidth > 0 { $0.cellSize = (launch.cellWidth, launch.cellHeight) }
        }
        terminal = Terminal(delegate: self, options: options)
        process = LocalProcess(delegate: self, dispatchQueue: ptyQueue, directDelivery: false)

        let source = DispatchSource.makeUserDataOrSource(queue: queue)
        source.setEventHandler { [weak self] in self?.tick() }
        tickSource = source
        source.activate()
    }

    public struct LaunchError: Error, CustomStringConvertible {
        public let description: String
    }

    /// Resolves `launch.executable` like execvp: a path with a slash must be
    /// executable; a bare name is searched in the launch PATH.
    static func resolveExecutable(_ launch: SessionLaunch) -> String? {
        let executable = launch.executable
        if executable.contains("/") {
            return access(executable, X_OK) == 0 ? executable : nil
        }
        let path = launch.environment.first { $0.hasPrefix("PATH=") }.map { String($0.dropFirst(5)) }
            ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = "\(directory)/\(executable)"
            if access(candidate, X_OK) == 0 { return candidate }
        }
        return nil
    }

    /// Starts the child process.
    public func start() throws {
        guard Self.resolveExecutable(launch) != nil else {
            throw LaunchError(description: "cannot run \(launch.executable)")
        }
        queue.async { self.updateInfoTimer() }
        let theme = launch.theme
        terminal.terminalLock.withLock {
            if let theme { applyThemeLocked(theme) }
            if launch.cellWidth > 0 {
                terminal.updatePixelGeometry(cellWidth: launch.cellWidth, cellHeight: launch.cellHeight)
            }
        }
        let result = process.startProcessChecked(executable: launch.executable, args: launch.arguments,
                                                 environment: launch.environment, execName: launch.argv0,
                                                 currentDirectory: launch.workingDirectory)
        if case .failure(let error) = result {
            throw error
        }
        queue.async { self.started = true }
    }

    /// Sends a signal to the child process. A second call after the child
    /// ignored the first one escalates to SIGKILL.
    public func terminate(signal: Int32 = SIGHUP) {
        terminationRequested.store(true, ordering: .relaxed)
        let pid = process.shellPid
        guard pid > 0, process.running else { return }
        kill(pid, signal)
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, process.running else { return }
            kill(pid, SIGKILL)
        }
    }

    /// Wakes the tick handler. Safe from any thread.
    func signal() {
        tickSource.or(data: 1)
    }

    // MARK: - Clients

    /// Takes ownership of a connected socket and serves one client on it.
    public func accept(socket fd: Int32) {
        accept(channel: MessageChannel(socket: fd, queue: queue))
    }

    /// Serves one client on `channel`. The channel must use `queue`.
    public func accept(channel: MessageChannel) {
        precondition(channel.queue === queue, "client channels must use the session queue")
        let client = SessionClient(channel: channel)
        channel.onMessage = { [weak self, weak client] envelope in
            guard let self, let client else { return }
            handle(envelope, from: client)
        }
        channel.onDrained = { [weak self, weak client] in
            guard let self, let client else { return }
            pumpBulk(client)
        }
        channel.onClose = { [weak self, weak client] _ in
            guard let self, let client else { return }
            remove(client)
        }
        queue.async {
            self.clients[ObjectIdentifier(client)] = client
            channel.start()
        }
    }

    private func remove(_ client: SessionClient) {
        dispatchPrecondition(condition: .onQueue(queue))
        clients[ObjectIdentifier(client)] = nil
        if client.attached {
            client.attached = false
            attachmentChanged()
        }
    }

    private var attachedClients: [SessionClient] {
        clients.values.filter(\.attached)
    }

    private func attachmentChanged() {
        let attached = attachedClients
        events.withLock { $0.hasAttachedClients = !attached.isEmpty }
        if let owner = sizeOwner, !owner.attached { sizeOwner = nil }
        if sizeOwner == nil, let next = attached.first(where: { !$0.viewer }) {
            sizeOwner = next
            applySize(next.size)
        }
        updateFocus()
        updateInfoTimer()
        onAttachmentChange?(attached.count)
        if attached.isEmpty { onIdle?() }
    }

    // MARK: - Messages

    private func handle(_ envelope: Envelope, from client: SessionClient) {
        dispatchPrecondition(condition: .onQueue(queue))
        do {
            switch envelope.kind {
            case .hello:
                try handleHello(envelope.decode(HelloMessage.self), from: client, requestID: envelope.requestID)
                return
            case .ping:
                let ping = try envelope.decode(PingMessage.self)
                client.channel.send(PongMessage(nonce: ping.nonce), requestID: envelope.requestID)
                return
            default:
                break
            }
            guard client.negotiatedVersion != nil else {
                fail(client, .badRequest, envelope, "hello required")
                return
            }
            switch envelope.kind {
            case .attach: handleAttach(try envelope.decode(AttachMessage.self), from: client)
            case .detach:
                if client.attached {
                    client.attached = false
                    attachmentChanged()
                }
            case .resize: handleResize(try envelope.decode(ResizeMessage.self), from: client)
            case .setViewport: handleViewport(try envelope.decode(SetViewportMessage.self), from: client)
            case .frameAck: handleAck(try envelope.decode(FrameAckMessage.self), from: client)
            case .fetchRows: handleFetch(try envelope.decode(FetchRowsMessage.self), from: client,
                                         requestID: envelope.requestID)
            case .key: handleKey(try envelope.decode(KeyMessage.self), from: client)
            case .text:
                let text = try envelope.decode(TextMessage.self).text
                noteInput(from: client)
                terminal.terminalLock.withLock { _ = terminal.sendHostText(text) }
                trace?(.input)
            case .input:
                let bytes = try envelope.decode(InputMessage.self).bytes
                noteInput(from: client)
                terminal.terminalLock.withLock { terminal.sendUserInput(bytes[...]) }
                trace?(.input)
            case .mouse: handleMouse(try envelope.decode(MouseMessage.self), from: client)
            case .paste: handlePaste(try envelope.decode(PasteMessage.self), from: client,
                                     requestID: envelope.requestID)
            case .pasteApprove:
                let approval = try envelope.decode(PasteApproveMessage.self)
                if let text = pendingPastes.removeValue(forKey: approval.token), approval.approved {
                    noteInput(from: client)
                    terminal.terminalLock.withLock { _ = terminal.sendHostTextPaste(text, allowUnsafe: true) }
                }
            case .focus:
                client.focused = try envelope.decode(FocusMessage.self).focused
                updateFocus()
            case .getText: handleGetText(try envelope.decode(GetTextMessage.self), from: client,
                                         requestID: envelope.requestID)
            case .clipboardReply: handleClipboardReply(try envelope.decode(ClipboardReplyMessage.self))
            case .setTheme: handleTheme(try envelope.decode(SetThemeMessage.self))
            case .terminate: terminate(signal: try envelope.decode(TerminateMessage.self).signal)
            case .reset: handleReset(try envelope.decode(ResetMessage.self).action)
            case .search: handleSearch(try envelope.decode(SearchMessage.self), from: client,
                                       requestID: envelope.requestID)
            case .findPrompt: handleFindPrompt(try envelope.decode(FindPromptMessage.self), from: client,
                                               requestID: envelope.requestID)
            case .fetchImage: handleFetchImage(try envelope.decode(FetchImageMessage.self), from: client,
                                               requestID: envelope.requestID)
            default:
                if envelope.flags.contains(.required) {
                    fail(client, .unsupported, envelope, "unsupported message")
                }
            }
        } catch {
            fail(client, .badRequest, envelope, "\(error)")
        }
    }

    private func fail(_ client: SessionClient, _ code: SessionErrorCode, _ envelope: Envelope, _ message: String) {
        client.channel.send(ErrorMessage(code: code, failedKind: envelope.kind, message: message),
                            requestID: envelope.requestID)
    }

    private func handleHello(_ hello: HelloMessage, from client: SessionClient, requestID: UInt64?) {
        let version = min(hello.maximumVersion, SessionProtocol.version)
        guard version >= hello.minimumVersion, version >= SessionProtocol.minimumVersion else {
            client.channel.send(ErrorMessage(code: .versionMismatch, failedKind: .hello,
                                             message: "helper speaks \(SessionProtocol.minimumVersion)...\(SessionProtocol.version)"),
                                requestID: requestID)
            client.channel.closeWhenDrained()
            return
        }
        client.negotiatedVersion = version
        client.retainMargin = max(0, min(hello.retainMargin, 4096))
        client.channel.send(HelloReplyMessage(version: version, build: build, capabilities: .helper,
                                              sessionID: id), requestID: requestID)
    }

    private func handleAttach(_ attach: AttachMessage, from client: SessionClient) {
        client.size = attach.size
        client.scale = attach.scale
        client.maximumFramesPerSecond = max(1, min(attach.maximumFramesPerSecond, 240))
        client.viewer = attach.viewer
        client.focused = attach.focused
        client.follow = true
        client.attached = true
        client.needsFrame = true
        client.credits = SessionClient.maximumCredits
        client.inFlight.removeAll()
        client.rowVersions.removeAll()
        client.rowsEpoch = .max
        client.sentLinks.removeAll()
        client.lastCursor = nil
        client.lastModes = nil
        client.lastGeometry = nil
        client.seenTitle = 0
        client.seenIconTitle = 0
        client.seenDirectory = 0
        client.seenColors = 0
        client.seenReverse = nil
        client.lastKitty = nil
        client.sentParagraphRows = nil
        if !attach.viewer {
            // The newest interactive client takes the size.
            sizeOwner = client
            client.lastInput = .now()
        }
        attachmentChanged()
        if sizeOwner === client { applySize(client.size) }
        // Replay the exit status for late clients.
        if let status = exitStatus {
            client.channel.send(ProcessExitedMessage(exitCode: status))
        }
        signal()
    }

    private func handleResize(_ resize: ResizeMessage, from client: SessionClient) {
        client.size = resize.size
        if resize.scale > 0 { client.scale = resize.scale }
        if sizeOwner === client { applySize(resize.size) }
        client.needsFrame = true
        signal()
    }

    private func handleViewport(_ message: SetViewportMessage, from client: SessionClient) {
        client.follow = message.follow
        client.anchor = Int64(clamping: message.top)
        if !message.known.isEmpty && message.buffer == client.rowsBuffer {
            for known in message.known {
                client.rowVersions[Int64(clamping: known.line)] = known.version
            }
        }
        client.needsFrame = true
        signal()
    }

    private func handleAck(_ ack: FrameAckMessage, from client: SessionClient) {
        if let index = client.inFlight.firstIndex(where: { $0.sequence == ack.sequence }) {
            client.inFlight.removeSubrange(0 ... index)
        }
        client.credits = SessionClient.maximumCredits - client.inFlight.count
        signal()
    }

    /// Records input from `client`: it gets an input boost and, unless it is
    /// a viewer, becomes the size owner when the current owner is quiet.
    private func noteInput(from client: SessionClient) {
        let now = DispatchTime.now()
        client.boostUntil = now + .milliseconds(100)
        client.lastInput = now
        guard !client.viewer, sizeOwner !== client else { return }
        let ownerQuiet = sizeOwner.map { now.uptimeNanoseconds - $0.lastInput.uptimeNanoseconds > 250_000_000 } ?? true
        if ownerQuiet {
            sizeOwner = client
            applySize(client.size)
        }
    }

    private func handleKey(_ key: KeyMessage, from client: SessionClient) {
        noteInput(from: client)
        terminal.terminalLock.withLock {
            let result = terminal.sendHostKey(key: key.key, code: key.code, modifiers: key.modifiers,
                                              eventType: key.eventType, text: key.text,
                                              shiftedKey: key.shiftedKey, baseLayoutKey: key.baseLayoutKey)
            if result == 0, let text = key.text, !text.isEmpty, key.eventType != 3 {
                _ = terminal.sendHostText(text)
            }
        }
    }

    private func handleMouse(_ mouse: MouseMessage, from client: SessionClient) {
        guard let action = TerminalMouseAction(rawValue: UInt32(mouse.action)),
              let button = TerminalMouseButton(rawValue: UInt32(mouse.button)) else { return }
        if action != .move { noteInput(from: client) }
        terminal.terminalLock.withLock {
            _ = terminal.sendHostMouse(action: action, button: button, modifiers: UInt32(mouse.modifiers),
                                       col: mouse.column, row: mouse.row,
                                       pixelX: mouse.pixelX, pixelY: mouse.pixelY)
        }
    }

    private func handlePaste(_ paste: PasteMessage, from client: SessionClient, requestID: UInt64?) {
        noteInput(from: client)
        let sent = terminal.terminalLock.withLock {
            terminal.sendHostTextPaste(paste.text, allowUnsafe: paste.allowUnsafe)
        }
        if sent {
            client.channel.send(PasteResultMessage(status: .sent), requestID: requestID)
        } else {
            let token = nextPasteToken
            nextPasteToken &+= 1
            pendingPastes[token] = paste.text
            if pendingPastes.count > 8, let oldest = pendingPastes.keys.min() {
                pendingPastes[oldest] = nil
            }
            client.channel.send(PasteResultMessage(status: .needsApproval, token: token), requestID: requestID)
        }
    }

    private func updateFocus() {
        let focused = attachedClients.contains { $0.focused }
        terminal.terminalLock.withLock { terminal.setTerminalFocus(focused) }
    }

    private func handleTheme(_ theme: SetThemeMessage) {
        let sessionTheme = SessionTheme(palette: theme.palette.prefix(16).map(WireRGBCodable.init),
                                        foreground: WireRGBCodable(theme.foreground),
                                        background: WireRGBCodable(theme.background),
                                        cursor: theme.cursor.map(WireRGBCodable.init))
        terminal.terminalLock.withLock { applyThemeLocked(sessionTheme) }
        signal()
    }

    private func applyThemeLocked(_ theme: SessionTheme) {
        if theme.palette.count == 16 {
            terminal.installPalette(colors: theme.palette.map { WireMapping.color($0.wire) })
        }
        terminal.foregroundColor = WireMapping.color(theme.foreground.wire)
        terminal.backgroundColor = WireMapping.color(theme.background.wire)
        terminal.cursorColor = theme.cursor.map { WireMapping.color($0.wire) }
        events.withLock {
            $0.colorsVersion &+= 1
            $0.bumpLatched()
        }
    }

    private func handleClipboardReply(_ reply: ClipboardReplyMessage) {
        guard clipboardReaders.removeValue(forKey: reply.request) != nil else { return }
        let selection = pendingClipboardSelections.removeValue(forKey: reply.request) ?? "c"
        terminal.terminalLock.withLock {
            terminal.completeClipboardRead(selection: selection, content: reply.allowed ? reply.data : [])
        }
    }

    private var pendingClipboardSelections: [UInt64: String] = [:]

    private var searchIndex = SearchIndex()

    /// Searches the whole buffer. The index is rebuilt only after new output,
    /// in chunks so that the parser is never held up for long.
    private func handleSearch(_ request: SearchMessage, from client: SessionClient, requestID: UInt64?) {
        let feed = feedSequence.load(ordering: .acquiring)
        let (live, needsBuild) = terminal.terminalLock.withLock { () -> (LiveState, Bool) in
            let live = updateNumberingLocked()
            let stale = searchIndex.feed != feed || searchIndex.epoch != live.epoch ||
                searchIndex.buffer != live.buffer || searchIndex.columns != live.columns
            return (live, stale)
        }
        guard request.buffer == live.buffer else {
            client.channel.send(SearchResultMessage(found: false), requestID: requestID)
            return
        }
        if needsBuild {
            searchIndex.reset(feed: feed, epoch: live.epoch, buffer: live.buffer, columns: live.columns)
            var ring = 0
            while true {
                let done = terminal.terminalLock.withLock { () -> Bool in
                    let current = updateNumberingLocked()
                    let end = min(current.lineCount, ring + 2000)
                    guard ring < end else { return true }
                    searchIndex.append(terminal: terminal, ringIndices: ring ..< end) { index in
                        current.numbering.line(ringIndex: index, trimmed: current.trimmed)
                    }
                    ring = end
                    return false
                }
                if done { break }
            }
            searchIndex.finish()
        }
        client.channel.send(searchIndex.search(request), requestID: requestID)
    }

    /// Finds the nearest prompt row (OSC 133) above or below a line. The scan
    /// takes the lock for one chunk of rows at a time and follows absolute
    /// line numbers, so output between chunks does not lose its place.
    private func handleFindPrompt(_ request: FindPromptMessage, from client: SessionClient, requestID: UInt64?) {
        let chunk = 4096
        var line = Int64(clamping: request.line)
        var epoch: UInt64?
        var found: Int64?
        var done = false
        while !done {
            terminal.terminalLock.withLock {
                let live = updateNumberingLocked()
                guard !live.alternate, live.buffer == request.buffer, epoch == nil || epoch == live.epoch else {
                    done = true
                    return
                }
                epoch = live.epoch
                let ring = live.numbering.ringIndex(line: line, trimmed: live.trimmed)
                let start = Int(clamping: request.upward ? ring - 1 : max(ring + 1, 0))
                let rows = request.upward
                    ? Array(stride(from: min(start, live.lineCount - 1), through: max(0, start - chunk + 1), by: -1))
                    : Array(start ..< max(start, min(live.lineCount, start + chunk)))
                guard let last = rows.last else {
                    done = true
                    return
                }
                if let row = rows.first(where: { terminal.semanticRowKind(at: $0) == .initial }) {
                    found = live.numbering.line(ringIndex: row, trimmed: live.trimmed)
                    done = true
                    return
                }
                line = live.numbering.line(ringIndex: last, trimmed: live.trimmed)
                done = request.upward ? last == 0 : last == live.lineCount - 1
            }
        }
        client.channel.send(PromptResultMessage(found: found != nil, line: UInt64(max(0, found ?? 0))),
                            requestID: requestID)
    }

    private func handleReset(_ action: ResetAction) {
        terminal.terminalLock.withLock {
            switch action {
            case .soft:
                terminal.softReset()
            case .hard:
                terminal.resetToInitialState()
            case .clearScrollback:
                terminal.clearScrollback()
            case .clearToStart:
                terminal.feed(buffer: Array("\u{1b}[H\u{1b}[2J".utf8)[...])
                terminal.clearScrollback()
            }
            // The scrollback changed under the line numbers.
            forceDiscontinuity = true
        }
        for client in attachedClients { client.needsFrame = true }
        signal()
    }

    // MARK: - Size

    /// Applies the size owner's grid. Column changes reflow the scrollback,
    /// so they start a new epoch.
    private func applySize(_ size: WireGridSize) {
        let columns = max(2, min(size.columns, 4096))
        let rows = max(2, min(size.rows, 2048))
        var changed = false
        terminal.terminalLock.withLock {
            if terminal.cols != columns || terminal.rows != rows {
                if terminal.cols != columns {
                    forceDiscontinuity = true
                    if terminal.isCurrentBufferAlternate { normalResizedDuringAlternate = true }
                }
                terminal.resize(cols: columns, rows: rows)
                changed = true
            }
            if size.cellWidth > 0 && size.cellHeight > 0 {
                terminal.updatePixelGeometry(cellWidth: size.cellWidth, cellHeight: size.cellHeight)
            }
        }
        let scale = sizeOwner?.scale ?? 0
        events.withLock {
            $0.windowSize = (columns, rows, size.cellWidth, size.cellHeight)
            if size.cellWidth > 0 { $0.cellSize = (size.cellWidth, size.cellHeight) }
            if scale > 0 { $0.scale = Double(scale) / 100 }
        }
        if changed {
            var window = makeWindowSize()
            process.updateWindowSize(&window)
            for client in attachedClients { client.needsFrame = true }
            signal()
            onGridChange?(columns, rows)
        }
    }

    private func makeWindowSize() -> winsize {
        let size = events.withLock { $0.windowSize }
        return winsize(ws_row: UInt16(clamping: size.rows), ws_col: UInt16(clamping: size.columns),
                       ws_xpixel: UInt16(clamping: size.columns * size.cellWidth),
                       ws_ypixel: UInt16(clamping: size.rows * size.cellHeight))
    }

    // MARK: - Frames

    private struct LiveState {
        var alternate: Bool
        var buffer: WireBuffer
        var columns: Int
        var rows: Int
        var scrollbackRows: Int
        var lineCount: Int
        var trimmed: Int
        var epoch: UInt64
        var numbering: BufferNumbering
    }

    private func tick() {
        dispatchPrecondition(condition: .onQueue(queue))
        drainEdges()
        notifyMetadataIfNeeded()
        if events.withLock({ $0.reverseVideoProbe }) { probeReverseVideo() }

        let now = DispatchTime.now()
        let feed = feedSequence.load(ordering: .acquiring)
        let latched = events.withLock { $0.latched }
        var candidates: [SessionClient] = []
        var earliest: DispatchTime?
        for client in attachedClients {
            let pending = client.needsFrame || client.seenFeed != feed || client.seenLatched != latched
            guard pending else { continue }
            guard client.credits > 0, client.bytesInFlight < SessionClient.byteBudget else {
                trace?(.waitingForCredit)
                continue
            }
            if now < client.nextFrameAt && now >= client.boostUntil {
                trace?(.waitingForSlot)
                earliest = min(earliest ?? client.nextFrameAt, client.nextFrameAt)
                continue
            }
            candidates.append(client)
        }
        if let earliest { armFrameTimer(earliest) }
        guard !candidates.isEmpty else { return }

        var outgoing: [(SessionClient, FrameMessage, DefineLinksMessage?)] = []
        terminal.terminalLock.withLock {
            guard !terminal.synchronizedOutputActive else { return }
            let live = updateNumberingLocked()
            let snapshot = events.withLock { $0 }
            let kitty = terminal.kittyGraphicsRenderSnapshot()
            for client in candidates {
                client.seenFeed = feed
                client.seenLatched = latched
                if let frame = buildFrameLocked(for: client, live: live, events: snapshot, kitty: kitty) {
                    outgoing.append(frame)
                }
                client.needsFrame = false
            }
        }
        lineTable.trim()
        kittyImages.prune(keeping: Set(attachedClients.flatMap { $0.lastKitty?.images.map(\.imageID) ?? [] }))

        for (client, frame, linkDefinitions) in outgoing {
            if let linkDefinitions { client.channel.send(linkDefinitions) }
            let bytes = EnvelopeCodec.encode(frame)
            client.channel.sendEncoded(bytes)
            client.inFlight.append((frame.sequence, bytes.count))
            client.credits -= 1
            client.nextFrameAt = now + .nanoseconds(1_000_000_000 / client.maximumFramesPerSecond)
            client.channel.flushPending()
            trace?(.frameSent(sequence: frame.sequence, feed: feed))
        }
    }

    /// Reads the live buffer state and updates the numbering. Hold the lock.
    private func updateNumberingLocked() -> LiveState {
        let alternate = terminal.isCurrentBufferAlternate
        let buffer = terminal.buffer
        let rows = terminal.rows
        // The helper never scrolls the terminal's own viewport, so
        // `yDisp` equals the top of the live screen.
        let scrollbackRows = buffer.yDisp
        let lineCount = scrollbackRows + rows
        var force = forceDiscontinuity
        forceDiscontinuity = false
        if alternate != wasAlternate {
            if alternate {
                force = true
            } else if normalResizedDuringAlternate {
                // SwiftTerm reflows the normal buffer when the alternate screen ends.
                force = true
                normalResizedDuringAlternate = false
            }
            wasAlternate = alternate
        }
        if alternate {
            alternateNumbering.update(terminal: terminal, buffer: buffer, lineCount: lineCount,
                                      scrollbackRows: 0, force: force)
        } else {
            normalNumbering.update(terminal: terminal, buffer: buffer, lineCount: lineCount,
                                   scrollbackRows: scrollbackRows, force: force)
        }
        let numbering = alternate ? alternateNumbering : normalNumbering
        return LiveState(alternate: alternate, buffer: alternate ? .alternate : .normal,
                         columns: terminal.cols, rows: rows, scrollbackRows: scrollbackRows,
                         lineCount: lineCount, trimmed: buffer.totalLinesTrimmed,
                         epoch: numbering.epoch, numbering: numbering)
    }

    private func buildFrameLocked(for client: SessionClient, live: LiveState, events: HostEvents,
                                  kitty: KittyGraphicsRenderSnapshot) -> (SessionClient, FrameMessage, DefineLinksMessage?)? {
        let numbering = live.numbering
        let first = numbering.line(ringIndex: 0, trimmed: live.trimmed)
        let end = numbering.line(ringIndex: live.lineCount, trimmed: live.trimmed)
        let liveTop = numbering.line(ringIndex: live.scrollbackRows, trimmed: live.trimmed)
        let viewTop: Int64
        if client.follow || live.alternate {
            viewTop = liveTop
        } else {
            viewTop = max(first, min(client.anchor, max(first, end - Int64(live.rows))))
        }
        client.resetRowsIfNeeded(buffer: live.buffer, epoch: live.epoch)

        var changed: [WireRowRecord] = []
        var newLinks: [UInt32: String] = [:]
        /// Encodes the row at `ring` and adds it when the client lacks this
        /// version. Returns whether the row may need bidi layout.
        @discardableResult
        func sendRow(ring: Int) -> Bool {
            guard ring >= 0, ring < live.lineCount, let line = terminal.bufferLine(atRow: ring) else { return false }
            let lineNumber = numbering.line(ringIndex: ring, trimmed: live.trimmed)
            let entry = lineTable.row(for: line, ringIndex: ring, columns: live.columns,
                                      terminal: terminal, links: links, encoder: &lineEncoder)
            if client.rowVersions[lineNumber] != entry.version {
                client.rowVersions[lineNumber] = entry.version
                changed.append(WireRowRecord(line: UInt64(lineNumber), version: entry.version,
                                             payload: entry.payload))
                for link in entry.links where !client.sentLinks.contains(link) {
                    client.sentLinks.insert(link)
                    newLinks[link] = links.value(for: link)
                }
            }
            return (entry.payload.first ?? 0) & RowFlags.rightToLeft.rawValue != 0
        }
        let topRing = Int(clamping: numbering.ringIndex(line: viewTop, trimmed: live.trimmed))
        var visibleRightToLeft = false
        for offset in 0 ..< live.rows where sendRow(ring: topRing + offset) {
            visibleRightToLeft = true
        }
        sendParagraphContextLocked(topRing: topRing, live: live, retainMargin: client.retainMargin,
                                   visibleRightToLeft: visibleRightToLeft, sendRow: sendRow)
        client.pruneRows(viewTop: viewTop, rows: live.rows)

        let buffer = terminal.buffer
        let cursorRing = live.scrollbackRows + buffer.y
        let cursorLine = numbering.line(ringIndex: cursorRing, trimmed: live.trimmed)
        let style = terminal.options.cursorStyle
        let cursor = WireCursor(line: UInt64(max(0, cursorLine)), column: min(buffer.x, live.columns - 1),
                                visible: events.cursorVisible, blink: WireMapping.cursorBlinks(style),
                                style: WireMapping.cursorStyle(style))
        // Bit 16: swap the arrow keys in right-to-left paragraphs (DECSET 1243).
        let modes = WireModes(input: terminal.hostInputModes | (terminal.bidiArrowKeySwap ? 1 << 16 : 0),
                              pointer: terminal.hostPointerModes)
        let geometry = SessionClient.Geometry(buffer: live.buffer, epoch: live.epoch, first: first, end: end,
                                              viewTop: viewTop, columns: live.columns, rows: live.rows)

        var frame = FrameMessage(sequence: client.sequence + 1, snapshotSequence: feedSequence.load(ordering: .relaxed),
                                 buffer: live.buffer, epoch: live.epoch, firstLine: UInt64(max(0, first)),
                                 endLine: UInt64(max(0, end)), viewTop: UInt64(max(0, viewTop)),
                                 columns: live.columns, rows: live.rows, cursor: cursor,
                                 changedRows: changed)
        var meaningful = !changed.isEmpty || client.lastGeometry != geometry || client.lastCursor != cursor
        if client.lastModes != modes {
            frame.modes = modes
            meaningful = true
        }
        if client.seenTitle != events.titleVersion {
            frame.title = events.title
            client.seenTitle = events.titleVersion
            meaningful = true
        }
        if client.seenIconTitle != events.iconTitleVersion {
            frame.iconTitle = events.iconTitle
            client.seenIconTitle = events.iconTitleVersion
            meaningful = true
        }
        if client.seenDirectory != events.directoryVersion {
            frame.directory = events.directory
            client.seenDirectory = events.directoryVersion
            meaningful = true
        }
        if client.seenColors != events.colorsVersion {
            var overrides: [UInt8: WireRGB] = [:]
            for index in events.paletteOverrides {
                if let color = terminal.paletteColor(index: Int(index)) {
                    overrides[index] = WireMapping.rgb(color)
                }
            }
            frame.colors = WireColorState(foreground: WireMapping.rgb(terminal.foregroundColor),
                                          background: WireMapping.rgb(terminal.backgroundColor),
                                          cursor: terminal.cursorColor.map(WireMapping.rgb),
                                          paletteOverrides: overrides)
            client.seenColors = events.colorsVersion
            meaningful = true
        }
        if client.seenReverse != events.reverseVideo {
            frame.reverseVideo = events.reverseVideo
            client.seenReverse = events.reverseVideo
            meaningful = true
        }
        let paragraphRows = terminal.options.maximumBidiParagraphRows
        if client.sentParagraphRows != paragraphRows {
            frame.maximumBidiParagraphRows = paragraphRows
            client.sentParagraphRows = paragraphRows
            meaningful = true
        }
        let kittyState = kittyStateLocked(kitty, live: live, viewTop: viewTop)
        if client.lastKitty != kittyState {
            frame.kitty = kittyState
            client.lastKitty = kittyState
            meaningful = true
        }
        guard meaningful || client.needsFrame else { return nil }
        client.sequence += 1
        client.lastCursor = cursor
        client.lastModes = modes
        client.lastGeometry = geometry
        let definitions = newLinks.isEmpty ? nil : DefineLinksMessage(links: newLinks)
        return (client, frame, definitions)
    }

    /// Adds the rows outside the view that belong to the soft-wrapped
    /// paragraphs of the first and last visible rows, when bidi layout may
    /// need them: the client lays out each paragraph as a whole.
    private func sendParagraphContextLocked(topRing: Int, live: LiveState, retainMargin: Int,
                                            visibleRightToLeft: Bool, sendRow: (Int) -> Bool) {
        let limit = min(max(1, terminal.options.maximumBidiParagraphRows), max(1, retainMargin))
        var above: [Int] = []
        var ring = topRing
        while above.count < limit, ring > 0, terminal.bufferLine(atRow: ring)?.isWrapped == true {
            ring -= 1
            above.append(ring)
        }
        var below: [Int] = []
        ring = topRing + live.rows
        while below.count < limit, ring < live.lineCount, terminal.bufferLine(atRow: ring)?.isWrapped == true {
            below.append(ring)
            ring += 1
        }
        guard !above.isEmpty || !below.isEmpty else { return }
        // Rows that need no bidi layout are drawn the same without them.
        func needsContext(_ rings: [Int], start: Int?) -> Bool {
            if let start, let state = terminal.bufferLine(atRow: start)?.bidiState,
               state.supportMode == .implicit, state.fallbackDirection == .rightToLeft {
                return true
            }
            if visibleRightToLeft { return true }
            return rings.contains { ring in
                guard let line = terminal.bufferLine(atRow: ring) else { return false }
                return lineEncoder.mayNeedBidi(line, columns: live.columns)
            }
        }
        if !above.isEmpty && needsContext(above, start: above.last) {
            for ring in above { sendRow(ring) }
        }
        if !below.isEmpty && needsContext(below, start: nil) {
            for ring in below { sendRow(ring) }
        }
    }

    /// The Kitty placements that touch the client's rows, with absolute
    /// lines, plus every virtual placement, and the images they use.
    private func kittyStateLocked(_ kitty: KittyGraphicsRenderSnapshot, live: LiveState,
                                  viewTop: Int64) -> WireKittyState {
        var placements: [WireKittyPlacement] = []
        var used = Set<UInt32>()
        let bottom = viewTop + Int64(live.rows)
        for placement in kitty.placements {
            let geometry = placement.geometry
            // Rows are relative to the live screen (the helper never scrolls).
            let line = live.numbering.line(ringIndex: live.scrollbackRows + geometry.row, trimmed: live.trimmed)
            if !placement.isVirtual {
                guard line < bottom, line + Int64(max(1, geometry.rows)) > viewTop else { continue }
            }
            used.insert(placement.imageId)
            let source = placement.visibleSource
            placements.append(WireKittyPlacement(
                token: placement.token, placementID: placement.placementId, kittyID: placement.imageId,
                sourceX: source.x, sourceY: source.y, sourceWidth: source.width, sourceHeight: source.height,
                line: placement.isVirtual ? 0 : line, column: geometry.column,
                columns: geometry.columns, rows: geometry.rows,
                pixelOffsetX: placement.pixelOffsetX, pixelOffsetY: placement.pixelOffsetY,
                zIndex: placement.zIndex, isVirtual: placement.isVirtual,
                insertionOrder: placement.insertionOrder))
        }
        var images: [WireKittyImage] = []
        for kittyID in used.sorted() {
            guard let image = kitty.imagesById[kittyID] else { continue }
            images.append(WireKittyImage(kittyID: kittyID, imageNumber: image.imageNumber,
                                         imageID: kittyImages.wireID(for: image, alternate: live.alternate),
                                         width: image.width, height: image.height))
        }
        return WireKittyState(generation: placements.isEmpty ? 0 : kitty.storageGeneration,
                              images: images, placements: placements)
    }

    /// Sends the pixels of an image in chunks on the bulk queue, so that
    /// frames go first.
    private func handleFetchImage(_ request: FetchImageMessage, from client: SessionClient, requestID: UInt64?) {
        var pixels: KittyImageTable.Pixels?
        if request.imageID < 1 << 32 {
            if let image = rasterImages.image(UInt32(request.imageID)) {
                pixels = terminal.terminalLock.withLock {
                    image.rgba.isEmpty ? nil : KittyImageTable.Pixels(width: image.width, height: image.height,
                                                                       rgba: image.rgba)
                }
            }
        } else {
            pixels = kittyImages.pixels[request.imageID]
        }
        guard let pixels, pixels.rgba.count == pixels.width * pixels.height * 4 else {
            client.channel.send(ImageDataMessage(imageID: request.imageID, width: 0, height: 0),
                                priority: .bulk, requestID: requestID)
            return
        }
        let chunk = 1 << 20
        var offset = 0
        repeat {
            let end = min(pixels.rgba.count, offset + chunk)
            client.channel.send(ImageDataMessage(imageID: request.imageID, width: pixels.width, height: pixels.height,
                                                 offset: offset, bytes: Array(pixels.rgba[offset ..< end])),
                                priority: .bulk, requestID: requestID)
            offset = end
        } while offset < pixels.rgba.count
    }

    private func armFrameTimer(_ deadline: DispatchTime) {
        if let current = frameTimerDeadline, current <= deadline, frameTimer != nil { return }
        frameTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: deadline, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            frameTimer?.cancel()
            frameTimer = nil
            frameTimerDeadline = nil
            tick()
        }
        frameTimer = timer
        frameTimerDeadline = deadline
        timer.resume()
    }

    /// Reverse video (DECSCNM) has no public getter; the portable snapshot carries it.
    private func probeReverseVideo() {
        let snapshot = terminal.makeRenderSnapshot(scope: .dirty)
        events.withLock {
            $0.reverseVideoProbe = false
            if $0.reverseVideo != snapshot.reverseVideo {
                $0.reverseVideo = snapshot.reverseVideo
                $0.bumpLatched()
            }
        }
    }

    // MARK: - Edge events

    private func drainEdges() {
        let edges: [HostEvents.Edge] = events.withLock { state in
            defer { state.edges.removeAll(keepingCapacity: true) }
            return state.edges
        }
        guard !edges.isEmpty else { return }
        let attached = attachedClients
        for edge in edges {
            switch edge {
            case .bell:
                for client in attached { client.channel.send(BellMessage()) }
            case .clipboardCopy(let data):
                for client in attached { client.channel.send(ClipboardCopyMessage(data: data)) }
            case .clipboardRead(let request, let selection):
                let reader = sizeOwner ?? attached.first
                if let reader {
                    clipboardReaders[request] = reader
                    pendingClipboardSelections[request] = selection
                    reader.channel.send(ClipboardReadRequestMessage(request: request, selection: selection))
                } else {
                    terminal.terminalLock.withLock {
                        terminal.completeClipboardRead(selection: selection, content: [])
                    }
                }
            case .exited(let code):
                exitStatus = .some(code)
                for client in clients.values where client.negotiatedVersion != nil {
                    client.channel.send(ProcessExitedMessage(exitCode: code))
                }
                updateInfoTimer()
                onExit?(code)
            }
        }
    }

    /// Reports title and directory changes to the owner (for session metadata).
    private func notifyMetadataIfNeeded() {
        let state = events.withLock { ($0.titleVersion, $0.directoryVersion, $0.title, $0.directory) }
        guard state.0 != notifiedTitleVersion || state.1 != notifiedDirectoryVersion else { return }
        notifiedTitleVersion = state.0
        notifiedDirectoryVersion = state.1
        onMetadataChange?(state.2, state.3)
    }

    // MARK: - Bulk requests

    private func handleFetch(_ fetch: FetchRowsMessage, from client: SessionClient, requestID: UInt64?) {
        let start = Int64(clamping: fetch.start)
        let count = max(0, min(fetch.count, 100_000))
        client.bulk.append(.fetch(fetch, requestID: requestID, next: start, end: start + Int64(count)))
        pumpBulk(client)
    }

    /// Sends the next chunk of the oldest bulk request when the channel is idle.
    private func pumpBulk(_ client: SessionClient) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard client.channel.queuedBytes == 0, let request = client.bulk.first else { return }
        switch request {
        case .fetch(let fetch, let requestID, let next, let end):
            let (message, reached) = buildRowsChunk(fetch, from: next, to: end)
            if reached >= end {
                client.bulk.removeFirst()
            } else {
                client.bulk[0] = .fetch(fetch, requestID: requestID, next: reached, end: end)
            }
            client.channel.send(message, priority: .bulk, requestID: requestID)
        }
    }

    /// Encodes rows for a fetch, holding the lock for a bounded time.
    private func buildRowsChunk(_ fetch: FetchRowsMessage, from start: Int64, to end: Int64) -> (RowsMessage, Int64) {
        let known = Dictionary(fetch.known.map { (Int64(clamping: $0.line), $0.version) },
                               uniquingKeysWith: { first, _ in first })
        let budgetBytes = 64 * 1024
        let deadline = DispatchTime.now() + .milliseconds(2)
        var records: [WireRowRecord] = []
        var confirmed: [WireLineRange] = []
        var unavailable: [WireLineRange] = []
        var reached = start
        var epoch: UInt64 = 0
        var buffer = WireBuffer.normal
        terminal.terminalLock.withLock {
            let live = updateNumberingLocked()
            epoch = live.epoch
            buffer = live.buffer
            guard fetch.buffer == live.buffer else {
                unavailable.append(WireLineRange(start: UInt64(max(0, start)), count: Int(end - start)))
                reached = end
                return
            }
            let first = live.numbering.line(ringIndex: 0, trimmed: live.trimmed)
            let lineEnd = live.numbering.line(ringIndex: live.lineCount, trimmed: live.trimmed)
            var bytes = 0
            var lineNumber = start
            while lineNumber < end {
                if lineNumber < first || lineNumber >= lineEnd {
                    let stop = lineNumber < first ? min(first, end) : end
                    Self.appendRange(&unavailable, lineNumber, stop)
                    lineNumber = stop
                    continue
                }
                let ring = live.numbering.ringIndex(line: lineNumber, trimmed: live.trimmed)
                guard let line = terminal.bufferLine(atRow: Int(ring)) else {
                    Self.appendRange(&unavailable, lineNumber, lineNumber + 1)
                    lineNumber += 1
                    continue
                }
                let entry = lineTable.row(for: line, ringIndex: Int(ring), columns: live.columns,
                                          terminal: terminal, links: links, encoder: &lineEncoder)
                if known[lineNumber] == entry.version {
                    Self.appendRange(&confirmed, lineNumber, lineNumber + 1)
                } else {
                    records.append(WireRowRecord(line: UInt64(lineNumber), version: entry.version,
                                                 payload: entry.payload))
                    bytes += entry.payload.count + 12
                }
                lineNumber += 1
                if bytes >= budgetBytes || (lineNumber & 63 == 0 && DispatchTime.now() >= deadline) {
                    break
                }
            }
            reached = lineNumber
        }
        lineTable.trim()
        let message = RowsMessage(snapshotSequence: feedSequence.load(ordering: .relaxed), buffer: buffer,
                                  epoch: epoch, final: reached >= end, records: records,
                                  confirmed: confirmed, unavailable: unavailable)
        return (message, reached)
    }

    private static func appendRange(_ ranges: inout [WireLineRange], _ start: Int64, _ end: Int64) {
        guard end > start else { return }
        if let last = ranges.last, Int64(last.start) + Int64(last.count) == start {
            ranges[ranges.count - 1].count += Int(end - start)
        } else {
            ranges.append(WireLineRange(start: UInt64(max(0, start)), count: Int(end - start)))
        }
    }

    private func handleGetText(_ request: GetTextMessage, from client: SessionClient, requestID: UInt64?) {
        let text: String = terminal.terminalLock.withLock {
            let live = updateNumberingLocked()
            guard request.buffer == live.buffer else { return "" }
            let first = live.numbering.line(ringIndex: 0, trimmed: live.trimmed)
            let lastLine = live.numbering.line(ringIndex: live.lineCount - 1, trimmed: live.trimmed)
            let startLine = max(first, min(Int64(clamping: request.startLine), lastLine))
            let endLine = max(first, min(Int64(clamping: request.endLine), lastLine))
            guard startLine <= endLine else { return "" }
            let startRing = Int(live.numbering.ringIndex(line: startLine, trimmed: live.trimmed))
            let endRing = Int(live.numbering.ringIndex(line: endLine, trimmed: live.trimmed))
            return terminal.getText(start: Position(col: request.startColumn, row: startRing),
                                    end: Position(col: request.endColumn + 1, row: endRing))
        }
        client.channel.send(TextResultMessage(text: text), priority: .bulk, requestID: requestID)
    }

    // MARK: - Session information

    /// Polls the foreground process: every second while a client is attached,
    /// every five seconds otherwise (for the session records).
    private func updateInfoTimer() {
        let interval = attachedClients.isEmpty ? 5 : 1
        guard exitStatus == nil else {
            infoTimer?.cancel()
            infoTimer = nil
            return
        }
        guard interval != infoTimerInterval || infoTimer == nil else { return }
        infoTimer?.cancel()
        infoTimerInterval = interval
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(interval), leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.publishSessionInfo() }
        infoTimer = timer
        timer.resume()
        // A newly attached client receives the current information.
        lastSessionInfo = nil
    }

    private var infoTimerInterval = 0

    private func publishSessionInfo() {
        let pid = process.shellPid
        let info = SessionInfoMessage(shellPID: pid,
                                      shellName: (launch.executable as NSString).lastPathComponent,
                                      foreground: ProcessInspector.foreground(ptyDescriptor: process.childfd),
                                      hasChildren: ProcessInspector.hasChildren(pid))
        guard info != lastSessionInfo else { return }
        lastSessionInfo = info
        for client in attachedClients { client.channel.send(info) }
        onSessionInfo?(info)
    }

    /// The process ID of the shell, or 0 before it starts.
    public var shellPID: Int32 { process.shellPid }

    /// The current grid size.
    public var gridSize: (columns: Int, rows: Int) {
        terminal.terminalLock.withLock { (terminal.cols, terminal.rows) }
    }

    /// The current session information (computed now). For tests and `list`.
    public func currentInfo() -> SessionInfoMessage {
        let pid = process.shellPid
        return SessionInfoMessage(shellPID: pid,
                                  shellName: (launch.executable as NSString).lastPathComponent,
                                  foreground: ProcessInspector.foreground(ptyDescriptor: process.childfd),
                                  hasChildren: ProcessInspector.hasChildren(pid))
    }
}

// MARK: - Terminal callbacks (terminal lock held)

extension SessionHost: TerminalDelegate {
    public func send(source: Terminal, data: ArraySlice<UInt8>) {
        trace?(.childInput(data))
        process.send(data: data)
    }

    public func setTerminalTitle(source: Terminal, title: String) {
        events.withLock {
            $0.title = title
            $0.titleVersion &+= 1
            $0.bumpLatched()
        }
        signal()
    }

    public func setTerminalIconTitle(source: Terminal, title: String) {
        events.withLock {
            $0.iconTitle = title
            $0.iconTitleVersion &+= 1
            $0.bumpLatched()
        }
        signal()
    }

    public func hostCurrentDirectoryUpdated(source: Terminal) {
        let directory = source.hostCurrentDirectory ?? ""
        events.withLock {
            $0.directory = directory
            $0.directoryVersion &+= 1
            $0.bumpLatched()
        }
        signal()
    }

    public func bell(source: Terminal) {
        events.withLock { state in
            let pending = state.edges.reduce(0) { count, edge in
                if case .bell = edge { return count + 1 }
                return count
            }
            if pending < 4 { state.edges.append(.bell) } else { state.droppedBells += 1 }
        }
        signal()
    }

    public func clipboardCopy(source: Terminal, content: TerminalData) {
        let bytes = [UInt8](content)
        events.withLock { $0.edges.append(.clipboardCopy(bytes)) }
        signal()
    }

    public func clipboardReadRequest(source: Terminal, selection: String) -> Bool {
        let accepted = events.withLock { state -> Bool in
            guard state.hasAttachedClients else { return false }
            let request = state.nextClipboardRequest
            state.nextClipboardRequest &+= 1
            state.edges.append(.clipboardRead(request, selection))
            return true
        }
        if accepted { signal() }
        return accepted
    }

    public func colorChanged(source: Terminal, idx: Int?) {
        events.withLock {
            if let idx {
                if idx >= 0 && idx < 256 { $0.paletteOverrides.insert(UInt8(idx)) }
            } else {
                $0.reverseVideoProbe = true
            }
            $0.colorsVersion &+= 1
            $0.bumpLatched()
        }
        signal()
    }

    public func setForegroundColor(source: Terminal, color: Color) { colorsChanged() }
    public func setBackgroundColor(source: Terminal, color: Color) { colorsChanged() }
    public func setCursorColor(source: Terminal, color: Color?) { colorsChanged() }

    private func colorsChanged() {
        events.withLock {
            $0.colorsVersion &+= 1
            $0.bumpLatched()
        }
        signal()
    }

    public func showCursor(source: Terminal) {
        events.withLock {
            $0.cursorVisible = true
            $0.bumpLatched()
        }
        signal()
    }

    public func hideCursor(source: Terminal) {
        events.withLock {
            $0.cursorVisible = false
            $0.bumpLatched()
        }
        signal()
    }

    public func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        events.withLock { $0.bumpLatched() }
        signal()
    }

    public func bufferActivated(source: Terminal) {
        signal()
    }

    public func synchronizedOutputChanged(source: Terminal, active: Bool) {
        if !active { signal() }
    }

    public func isProcessTrusted(source: Terminal) -> Bool { true }

    public func cellSizeInPixels(source: Terminal) -> (width: Int, height: Int)? {
        events.withLock { $0.cellSize }
    }

    public func terminalControlBytesForPaste(source: Terminal) -> Set<UInt8> {
        process.terminalControlBytesForPaste() ?? TerminalPasteControls.approximateTerminalControlBytes
    }

    public func mouseModeChanged(source: Terminal) {}
    public func sizeChanged(source: Terminal) {}
}

// MARK: - Process callbacks (PTY delivery queue)

extension SessionHost: LocalProcessDelegate {
    public func dataReceived(slice: ArraySlice<UInt8>) {
        terminal.terminalLock.withLock {
            terminal.feed(buffer: slice)
        }
        feedSequence.add(1, ordering: .releasing)
        trace?(.fed(slice))
        signal()
    }

    public func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        terminal.terminalLock.withLock { terminal.programStatusProcessExited() }
        events.withLock { $0.edges.append(.exited(exitCode)) }
        signal()
    }

    public func processFailedToStart(_ source: LocalProcess, error: LocalProcessError) {
        dataReceived(slice: Array("\r\nProcess launch failed: \(error)\r\n".utf8)[...])
        events.withLock { $0.edges.append(.exited(nil)) }
        signal()
    }

    public func getWindowSize() -> winsize {
        makeWindowSize()
    }
}
