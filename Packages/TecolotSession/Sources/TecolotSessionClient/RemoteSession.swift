//
// RemoteSession.swift
// TecolotSessionClient
//
// The client side of one session connection. It keeps the latest state and
// a row cache, acknowledges frames, keeps the viewport and fetches
// scrollback rows ahead of the user.
//
// The state and cache are behind one lock: the connection queue writes them,
// and the view reads them with `withState` when it draws a frame.
//

import Dispatch
import Foundation
import Synchronization
import TecolotTransport
import TecolotWire

public struct RemoteSessionState: Sendable {
    public var connected = false
    public var sessionID = ""
    public var helperBuild = ""
    /// What the helper handles; an older helper lacks newer features.
    public var helperCapabilities: SessionCapabilities = []
    public var buffer: WireBuffer = .normal
    public var epoch: UInt64 = 0
    /// The oldest line the helper has.
    public var firstLine: Int64 = 0
    /// One past the newest line.
    public var endLine: Int64 = 0
    public var columns = 80
    public var rows = 24
    public var cursor: WireCursor?
    public var inputModes: UInt32 = 0
    public var pointerModes: UInt32 = 0
    public var title = ""
    public var iconTitle = ""
    public var directory = ""
    public var colors: WireColorState?
    public var reverseVideo = false
    /// Set once the child process ended; the inner value is its exit code.
    public var exitStatus: Int32??
    public var info: SessionInfoMessage?
    public var links: [UInt32: String] = [:]
    public var lastFrameSequence: UInt64 = 0
    /// The terminal's `maximumBidiParagraphRows`.
    public var maximumBidiParagraphRows = 500
    /// The Kitty graphics that touch the view's rows.
    public var kitty: WireKittyState?

    /// True while the view follows the live screen.
    public var follow = true
    /// The first visible line when the view does not follow the live screen.
    public var anchor: Int64 = 0

    /// The first line of the live screen.
    public var liveTop: Int64 { max(firstLine, endLine - Int64(rows)) }

    /// The first line that the view shows.
    public var displayTop: Int64 {
        follow || buffer == .alternate ? liveTop : max(firstLine, min(anchor, liveTop))
    }

    /// True when the program asked for mouse reports (`hostPointerModes` tracking bits).
    public var mouseReporting: Bool { pointerModes & 0x7 != 0 }
    public var alternateScroll: Bool { pointerModes & (1 << 7) != 0 }
    public var applicationCursor: Bool { inputModes & 1 != 0 }
    public var bracketedPaste: Bool { inputModes & 4 != 0 }
    public var kittyKeyboardFlags: UInt32 { (inputModes >> 8) & 0x1f }
    /// Swap the arrow keys in right-to-left paragraphs (DECSET 1243).
    public var bidiArrowKeySwap: Bool { inputModes & (1 << 16) != 0 }
}

public enum RemoteSessionEvent: Sendable {
    case title(String)
    case iconTitle(String)
    case directory(String)
    case bell
    case clipboardCopy([UInt8])
    case clipboardReadRequest(request: UInt64, selection: String)
    case exited(Int32?)
    case info(SessionInfoMessage)
    case error(ErrorMessage)
    case closed(String?)
}

public struct RemoteSessionChange: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let rows = RemoteSessionChange(rawValue: 1 << 0)
    public static let geometry = RemoteSessionChange(rawValue: 1 << 1)
    public static let cursor = RemoteSessionChange(rawValue: 1 << 2)
    public static let modes = RemoteSessionChange(rawValue: 1 << 3)
    public static let colors = RemoteSessionChange(rawValue: 1 << 4)
    public static let viewport = RemoteSessionChange(rawValue: 1 << 5)
    public static let buffer = RemoteSessionChange(rawValue: 1 << 6)
    /// Image pixels arrived, or the Kitty state changed.
    public static let images = RemoteSessionChange(rawValue: 1 << 7)
}

public final class RemoteSession: @unchecked Sendable {
    public let queue: DispatchQueue
    private let channel: MessageChannel
    private let clientName: String
    private let build: String
    private let maximumFramesPerSecond: Int
    private let inner = Mutex(Inner())

    /// Called on `queue` after a frame or rows changed the state.
    public var onChange: (@Sendable (RemoteSessionChange) -> Void)?
    /// Called on `queue` for events.
    public var onEvent: (@Sendable (RemoteSessionEvent) -> Void)?

    // Queue-confined.
    private var nextRequest: UInt64 = 1
    private var textRequests: [UInt64: @Sendable (String?) -> Void] = [:]
    private var pasteRequests: [UInt64: @Sendable (PasteResultMessage) -> Void] = [:]
    private var searchRequests: [UInt64: @Sendable (SearchResultMessage?) -> Void] = [:]
    private var promptRequests: [UInt64: @Sendable (Int64?) -> Void] = [:]
    private var pendingFetches: [Int64: UInt64] = [:]
    /// Image fetches by request ID, and the images being assembled.
    private var imageRequests: [UInt64: UInt64] = [:]
    private var partialImages: [UInt64: PartialImage] = [:]
    private var closed = false

    /// Rows fetched ahead of a scroll, per side, in screens.
    public var prefetchScreens = 2
    static let fetchChunk: Int64 = 128
    static let maximumFetchesInFlight = 4

    struct Inner {
        var state = RemoteSessionState()
        var cache = RowCache()
        var images = RemoteImageStore()
    }

    /// A session over a connected socket (or any read/write descriptor pair).
    public init(readFD: Int32, writeFD: Int32, clientName: String, build: String,
                maximumFramesPerSecond: Int = 120) {
        queue = DispatchQueue(label: "tecolot.remote-session", qos: .userInitiated)
        channel = MessageChannel(readFD: readFD, writeFD: writeFD, queue: queue)
        self.clientName = clientName
        self.build = build
        self.maximumFramesPerSecond = maximumFramesPerSecond
    }

    public convenience init(socket fd: Int32, clientName: String, build: String,
                            maximumFramesPerSecond: Int = 120) {
        self.init(readFD: fd, writeFD: fd, clientName: clientName, build: build,
                  maximumFramesPerSecond: maximumFramesPerSecond)
    }

    /// Says hello and attaches with the view's grid size.
    /// `scale` is the display's device pixels per point, in hundredths.
    public func start(size: WireGridSize, focused: Bool, viewer: Bool = false, scale: Int = 0) {
        channel.onMessage = { [weak self] envelope in self?.handle(envelope) }
        channel.onClose = { [weak self] error in self?.channelClosed(error) }
        channel.onDrained = nil
        channel.start()
        channel.send(HelloMessage(build: build, clientName: clientName))
        channel.send(AttachMessage(size: size, maximumFramesPerSecond: maximumFramesPerSecond,
                                   viewer: viewer, focused: focused, scale: scale))
    }

    /// Reads the state and the cache under the lock. Keep `body` short, and do
    /// not call other methods of the session in it: the lock is not
    /// recursive, and taking it again ends the process. Use `withFrameState`
    /// to read image pixels too.
    public func withState<R>(_ body: (RemoteSessionState, RowCache) -> R) -> R {
        inner.withLock { body($0.state, $0.cache) }
    }

    /// Like `withState`, and `body` can also look up image pixels (calling
    /// `image(_:)` inside `withState` would take the lock twice).
    public func withFrameState<R>(_ body: (RemoteSessionState, RowCache, (UInt64) -> RemoteImage?) -> R) -> R {
        inner.withLock { inner in
            body(inner.state, inner.cache) { inner.images.image($0) }
        }
    }

    public var state: RemoteSessionState { inner.withLock { $0.state } }

    // MARK: Input

    public func send(key: KeyMessage) { channel.send(key) }
    public func send(text: String) { channel.send(TextMessage(text: text)) }
    public func send(bytes: [UInt8]) { channel.send(InputMessage(bytes: bytes)) }
    public func send(mouse: MouseMessage) { channel.send(mouse) }
    public func setFocus(_ focused: Bool) { channel.send(FocusMessage(focused: focused)) }
    public func resize(_ size: WireGridSize, scale: Int = 0) { channel.send(ResizeMessage(size: size, scale: scale)) }
    public func setTheme(_ theme: SetThemeMessage) { channel.send(theme) }
    public func terminate(signal: Int32 = 1) { channel.send(TerminateMessage(signal: signal)) }
    public func reset(_ action: ResetAction) { channel.send(ResetMessage(action: action), flags: .required) }

    public func replyClipboard(request: UInt64, data: [UInt8]?) {
        channel.send(ClipboardReplyMessage(request: request, allowed: data != nil, data: data ?? []))
    }

    /// Pastes text. The helper applies bracketed paste; text with control
    /// bytes comes back as `.needsApproval` with a token for `approvePaste`.
    public func paste(_ text: String, completion: (@Sendable (PasteResultMessage) -> Void)? = nil) {
        queue.async { [self] in
            let request = nextRequestID()
            if let completion { pasteRequests[request] = completion }
            channel.send(PasteMessage(text: text), requestID: request)
        }
    }

    public func approvePaste(token: UInt64, approved: Bool) {
        channel.send(PasteApproveMessage(token: token, approved: approved))
    }

    /// The text between two positions (inclusive), read by the helper.
    public func text(from start: (line: Int64, column: Int), to end: (line: Int64, column: Int),
                     completion: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            let request = nextRequestID()
            textRequests[request] = completion
            let buffer = inner.withLock { $0.state.buffer }
            channel.send(GetTextMessage(buffer: buffer, startLine: UInt64(max(0, start.line)),
                                        startColumn: start.column, endLine: UInt64(max(0, end.line)),
                                        endColumn: end.column), flags: .required, requestID: request)
        }
    }

    /// Finds the next match after (or, with `.backward`, before) a position.
    /// The helper searches the whole buffer and wraps around.
    public func search(_ query: String, options: SessionSearchOptions, from start: (line: Int64, column: Int),
                       completion: @escaping @Sendable (SearchResultMessage?) -> Void) {
        queue.async { [self] in
            let request = nextRequestID()
            searchRequests[request] = completion
            let buffer = inner.withLock { $0.state.buffer }
            channel.send(SearchMessage(query: query, options: options, buffer: buffer,
                                       startLine: UInt64(max(0, start.line)), startColumn: max(0, start.column)),
                         flags: .required, requestID: request)
        }
    }

    /// Finds the nearest shell prompt above (or below) `line`; the
    /// completion gets its line, or nil.
    public func findPrompt(from line: Int64, upward: Bool, completion: @escaping @Sendable (Int64?) -> Void) {
        queue.async { [self] in
            let request = nextRequestID()
            promptRequests[request] = completion
            let buffer = inner.withLock { $0.state.buffer }
            channel.send(FindPromptMessage(buffer: buffer, line: UInt64(max(0, line)), upward: upward),
                         flags: .required, requestID: request)
        }
    }

    // MARK: Images

    /// The pixels of an image, when the session has them. Takes the session
    /// lock: inside `withState` or `withFrameState`, use the lookup that
    /// `withFrameState` passes instead.
    public func image(_ id: UInt64) -> RemoteImage? {
        inner.withLock { $0.images.image(id) }
    }

    /// Fetches the images that the session does not have yet. `onChange`
    /// reports `.images` when they arrive. Safe from any thread.
    public func requestImages(_ ids: [UInt64]) {
        guard !ids.isEmpty else { return }
        queue.async { [self] in requestImagesOnQueue(ids) }
    }

    private func requestImagesOnQueue(_ ids: [UInt64]) {
        dispatchPrecondition(condition: .onQueue(queue))
        let missing = inner.withLock { inner -> [UInt64] in
            guard inner.state.helperCapabilities.contains(.images) else { return [] }
            return ids.filter { !inner.images.contains($0) }
        }
        let inFlight = Set(imageRequests.values)
        for id in Set(missing) where !inFlight.contains(id) {
            let request = nextRequestID()
            imageRequests[request] = id
            channel.send(FetchImageMessage(imageID: id), flags: .required, requestID: request)
        }
    }

    private func receive(_ data: ImageDataMessage, request: UInt64?) {
        guard let request, imageRequests[request] == data.imageID else { return }
        guard data.width > 0, data.height > 0 else {
            imageRequests[request] = nil
            partialImages[data.imageID] = nil
            inner.withLock { $0.images.markUnavailable(data.imageID) }
            return
        }
        var partial = partialImages[data.imageID]
            ?? PartialImage(width: data.width, height: data.height,
                            rgba: [UInt8](repeating: 0, count: data.totalBytes), received: 0)
        guard partial.width == data.width, partial.height == data.height,
              data.offset >= 0, data.offset + data.bytes.count <= partial.rgba.count else { return }
        partial.rgba.replaceSubrange(data.offset ..< data.offset + data.bytes.count, with: data.bytes)
        partial.received += data.bytes.count
        guard partial.received >= partial.rgba.count else {
            partialImages[data.imageID] = partial
            return
        }
        partialImages[data.imageID] = nil
        imageRequests[request] = nil
        let image = RemoteImage(id: data.imageID, width: data.width, height: data.height, rgba: partial.rgba)
        inner.withLock { $0.images.insert(image) }
        onChange?(.images)
    }

    /// The images that the rows at `lines` use. Call with the lock held.
    private static func imageIDs(in inner: Inner, lines: [Int64]) -> [UInt64] {
        var ids: [UInt64] = []
        for line in lines {
            if let row = inner.cache[line] {
                ids.append(contentsOf: row.header.images.map(\.imageID))
            }
        }
        return ids
    }

    public func detach() {
        channel.send(DetachMessage())
        channel.closeWhenDrained()
    }

    public func close() {
        channel.close()
    }

    // MARK: Viewport

    /// Scrolls by `lines` (negative is up). Returns the new top line.
    @discardableResult
    public func scroll(by lines: Int) -> Int64 {
        let top = inner.withLock { inner -> Int64 in
            let state = inner.state
            return state.displayTop + Int64(lines)
        }
        return scroll(toTop: top)
    }

    /// Shows `line` at the top; reaching the live screen follows it again.
    @discardableResult
    public func scroll(toTop line: Int64) -> Int64 {
        let (top, follow, buffer, known) = inner.withLock { inner -> (Int64, Bool, WireBuffer, [WireKnownVersion]) in
            let liveTop = inner.state.liveTop
            let top = max(inner.state.firstLine, min(line, liveTop))
            let follow = top >= liveTop || inner.state.buffer == .alternate
            inner.state.follow = follow
            inner.state.anchor = top
            let known = inner.cache.knownVersions(in: top ..< top + Int64(inner.state.rows))
            return (top, follow, inner.state.buffer, known)
        }
        channel.send(SetViewportMessage(buffer: buffer, follow: follow, top: UInt64(max(0, top)), known: known))
        queue.async { [self] in
            prefetch()
            onChange?(.viewport)
        }
        return top
    }

    /// Follows the live screen again.
    public func followLive() {
        let buffer = inner.withLock { inner -> WireBuffer in
            inner.state.follow = true
            return inner.state.buffer
        }
        channel.send(SetViewportMessage(buffer: buffer, follow: true))
        queue.async { [self] in onChange?(.viewport) }
    }

    // MARK: Messages

    private func nextRequestID() -> UInt64 {
        defer { nextRequest &+= 1 }
        return nextRequest
    }

    private func handle(_ envelope: Envelope) {
        do {
            switch envelope.kind {
            case .helloReply:
                let reply = try envelope.decode(HelloReplyMessage.self)
                inner.withLock {
                    $0.state.connected = true
                    $0.state.sessionID = reply.sessionID
                    $0.state.helperBuild = reply.build
                    $0.state.helperCapabilities = reply.capabilities
                }
            case .frame:
                try apply(envelope.decode(FrameMessage.self))
            case .rows:
                try apply(envelope.decode(RowsMessage.self), request: envelope.requestID)
            case .defineLinks:
                let links = try envelope.decode(DefineLinksMessage.self).links
                inner.withLock { $0.state.links.merge(links) { $1 } }
            case .bell:
                onEvent?(.bell)
            case .clipboardCopy:
                onEvent?(.clipboardCopy(try envelope.decode(ClipboardCopyMessage.self).data))
            case .clipboardReadRequest:
                let request = try envelope.decode(ClipboardReadRequestMessage.self)
                onEvent?(.clipboardReadRequest(request: request.request, selection: request.selection))
            case .processExited:
                let code = try envelope.decode(ProcessExitedMessage.self).exitCode
                inner.withLock { $0.state.exitStatus = .some(code) }
                onEvent?(.exited(code))
            case .sessionInfo:
                let info = try envelope.decode(SessionInfoMessage.self)
                inner.withLock { $0.state.info = info }
                onEvent?(.info(info))
            case .textResult:
                let text = try envelope.decode(TextResultMessage.self).text
                if let request = envelope.requestID { textRequests.removeValue(forKey: request)?(text) }
            case .searchResult:
                let result = try envelope.decode(SearchResultMessage.self)
                if let request = envelope.requestID { searchRequests.removeValue(forKey: request)?(result) }
            case .imageData:
                receive(try envelope.decode(ImageDataMessage.self), request: envelope.requestID)
            case .promptResult:
                let result = try envelope.decode(PromptResultMessage.self)
                if let request = envelope.requestID {
                    promptRequests.removeValue(forKey: request)?(result.found ? Int64(clamping: result.line) : nil)
                }
            case .pasteResult:
                let result = try envelope.decode(PasteResultMessage.self)
                if let request = envelope.requestID { pasteRequests.removeValue(forKey: request)?(result) }
            case .error:
                let error = try envelope.decode(ErrorMessage.self)
                if let request = envelope.requestID {
                    textRequests.removeValue(forKey: request)?(nil)
                    // Say why, so that Find does not just report no match.
                    let problem = error.code == .unsupported
                        ? "Needs a newer session helper" : error.message
                    searchRequests.removeValue(forKey: request)?(SearchResultMessage(found: false, problem: problem))
                    promptRequests.removeValue(forKey: request)?(nil)
                    pasteRequests[request] = nil
                    if let image = imageRequests.removeValue(forKey: request) {
                        partialImages[image] = nil
                        inner.withLock { $0.images.markUnavailable(image) }
                    }
                }
                onEvent?(.error(error))
            default:
                break
            }
        } catch {
            onEvent?(.error(ErrorMessage(code: .badRequest, failedKind: envelope.kind, message: "\(error)")))
        }
    }

    private func apply(_ frame: FrameMessage) throws {
        var change: RemoteSessionChange = []
        var events: [RemoteSessionEvent] = []
        var neededImages: [UInt64] = []
        try inner.withLock { inner in
            var state = inner.state
            if frame.buffer != state.buffer {
                change.insert(.buffer)
                state.follow = true
            }
            inner.cache.select(buffer: frame.buffer, epoch: frame.epoch)
            let first = Int64(clamping: frame.firstLine)
            if first != state.firstLine || frame.epoch != state.epoch {
                inner.cache.dropLines(before: first)
            }
            if !frame.changedRows.isEmpty {
                let lines = try inner.cache.store(frame.changedRows)
                change.insert(.rows)
                neededImages = Self.imageIDs(in: inner, lines: lines)
            }
            if let paragraphRows = frame.maximumBidiParagraphRows, paragraphRows != state.maximumBidiParagraphRows {
                state.maximumBidiParagraphRows = paragraphRows
                change.insert(.rows)
            }
            if let kitty = frame.kitty {
                state.kitty = kitty.placements.isEmpty ? nil : kitty
                change.insert(.images)
                neededImages += kitty.images.map(\.imageID)
            }
            let geometryChanged = state.firstLine != first || state.endLine != Int64(clamping: frame.endLine) ||
                state.columns != frame.columns || state.rows != frame.rows || state.epoch != frame.epoch
            if geometryChanged { change.insert(.geometry) }
            state.buffer = frame.buffer
            state.epoch = frame.epoch
            state.firstLine = first
            state.endLine = Int64(clamping: frame.endLine)
            state.columns = frame.columns
            state.rows = frame.rows
            if state.cursor != frame.cursor {
                state.cursor = frame.cursor
                change.insert(.cursor)
            }
            if let modes = frame.modes {
                state.inputModes = modes.input
                state.pointerModes = modes.pointer
                change.insert(.modes)
            }
            if let title = frame.title {
                state.title = title
                events.append(.title(title))
            }
            if let iconTitle = frame.iconTitle {
                state.iconTitle = iconTitle
                events.append(.iconTitle(iconTitle))
            }
            if let directory = frame.directory {
                state.directory = directory
                events.append(.directory(directory))
            }
            if let colors = frame.colors {
                state.colors = colors
                change.insert(.colors)
            }
            if let reverse = frame.reverseVideo {
                state.reverseVideo = reverse
                change.insert(.colors)
            }
            state.lastFrameSequence = frame.sequence
            inner.state = state
            let top = state.displayTop
            let margin = Int64(state.rows * (prefetchScreens + 1))
            inner.cache.evict(keeping: top - margin ..< top + Int64(state.rows) + margin)
        }
        // The helper holds the next frame until this ack returns its credit.
        channel.send(FrameAckMessage(sequence: frame.sequence))
        channel.flushPending()
        if !neededImages.isEmpty { requestImagesOnQueue(neededImages) }
        for event in events { onEvent?(event) }
        if change.contains(.buffer) || change.contains(.geometry) { prefetch() }
        if !change.isEmpty { onChange?(change) }
    }

    private func apply(_ rows: RowsMessage, request: UInt64?) throws {
        var changed = false
        var neededImages: [UInt64] = []
        try inner.withLock { inner in
            guard rows.buffer == inner.cache.buffer else { return }
            let first = inner.state.firstLine
            let records = rows.records.filter { Int64(clamping: $0.line) >= first }
            let lines = try inner.cache.store(records)
            changed = !lines.isEmpty
            neededImages = Self.imageIDs(in: inner, lines: lines)
        }
        if !neededImages.isEmpty { requestImagesOnQueue(neededImages) }
        if rows.final, let request {
            pendingFetches = pendingFetches.filter { $0.value != request }
        }
        if changed { onChange?(.rows) }
        if rows.final { prefetch() }
    }

    /// Requests missing rows around the viewport, in aligned chunks.
    private func prefetch() {
        dispatchPrecondition(condition: .onQueue(queue))
        let plan = inner.withLock { inner -> (WireBuffer, UInt64, [Int64: [WireKnownVersion]]) in
            let state = inner.state
            guard state.buffer == .normal, state.endLine > state.firstLine else { return (state.buffer, 0, [:]) }
            let rows = Int64(state.rows)
            let top = state.displayTop
            let low = max(state.firstLine, top - rows * Int64(prefetchScreens))
            let high = min(state.endLine, top + rows + rows * Int64(prefetchScreens))
            guard low < high else { return (state.buffer, state.epoch, [:]) }
            var chunks: [Int64: [WireKnownVersion]] = [:]
            for range in inner.cache.missing(in: low ..< high) {
                var chunk = (range.lowerBound / Self.fetchChunk) * Self.fetchChunk
                while chunk < range.upperBound {
                    if chunks[chunk] == nil && pendingFetches[chunk] == nil {
                        let span = max(state.firstLine, chunk) ..< min(state.endLine, chunk + Self.fetchChunk)
                        chunks[chunk] = inner.cache.knownVersions(in: span)
                    }
                    chunk += Self.fetchChunk
                }
            }
            return (state.buffer, state.epoch, chunks)
        }
        let (buffer, epoch, chunks) = plan
        for (chunk, known) in chunks.sorted(by: { $0.key < $1.key }) {
            guard pendingFetches.count < Self.maximumFetchesInFlight else { break }
            let request = nextRequestID()
            pendingFetches[chunk] = request
            let start = max(0, chunk)
            channel.send(FetchRowsMessage(buffer: buffer, epoch: epoch, start: UInt64(start),
                                          count: Int(chunk + Self.fetchChunk - start), known: known),
                         requestID: request)
        }
    }

    private func channelClosed(_ error: Error?) {
        closed = true
        inner.withLock { $0.state.connected = false }
        for (_, completion) in textRequests { completion(nil) }
        textRequests.removeAll()
        for (_, completion) in searchRequests { completion(nil) }
        searchRequests.removeAll()
        for (_, completion) in promptRequests { completion(nil) }
        promptRequests.removeAll()
        pasteRequests.removeAll()
        onEvent?(.closed(error.map { "\($0)" }))
    }
}
