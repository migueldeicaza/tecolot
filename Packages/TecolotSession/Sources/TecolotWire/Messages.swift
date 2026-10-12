//
// Messages.swift
// TecolotWire
//
// The session protocol messages. Each message lists its fields in wire order.
// To extend a message, append a field at the end and decode it only when
// `reader.isAtEnd` is false, so that older peers keep working.
//

/// The protocol version range that this build speaks.
public enum SessionProtocol {
    public static let version: UInt32 = 1
    public static let minimumVersion: UInt32 = 1
}

/// Optional features that a peer advertises in `Hello` / `HelloReply`.
public struct SessionCapabilities: OptionSet, Hashable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let search = SessionCapabilities(rawValue: 1 << 0)
    public static let images = SessionCapabilities(rawValue: 1 << 1)
    public static let compression = SessionCapabilities(rawValue: 1 << 2)
    /// The helper handles `Reset`.
    public static let reset = SessionCapabilities(rawValue: 1 << 3)
    /// The helper handles `FindPrompt`.
    public static let prompts = SessionCapabilities(rawValue: 1 << 4)
    /// The helper sends the paragraph rows that bidi layout needs and the
    /// paragraph row limit.
    public static let bidi = SessionCapabilities(rawValue: 1 << 5)

    /// What this build of the helper handles.
    public static let helper: SessionCapabilities = [.search, .reset, .prompts, .images, .bidi]
}

public enum WireBuffer: UInt8, Hashable, Sendable {
    case normal = 0
    case alternate = 1
}

/// A color with SwiftTerm's 16-bit channels.
public struct WireRGB: Hashable, Sendable {
    public var red: UInt16
    public var green: UInt16
    public var blue: UInt16

    public init(red: UInt16, green: UInt16, blue: UInt16) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public struct WireCursor: Hashable, Sendable {
    public var line: UInt64
    public var column: Int
    public var visible: Bool
    public var blink: Bool
    /// SwiftTerm `CursorStyle` case index: 0 blinkBlock, 1 steadyBlock,
    /// 2 blinkUnderline, 3 steadyUnderline, 4 blinkBar, 5 steadyBar.
    public var style: UInt8

    public init(line: UInt64, column: Int, visible: Bool, blink: Bool, style: UInt8) {
        self.line = line
        self.column = column
        self.visible = visible
        self.blink = blink
        self.style = style
    }
}

/// A row version that the client already has.
public struct WireKnownVersion: Hashable, Sendable {
    public var line: UInt64
    public var version: UInt64

    public init(line: UInt64, version: UInt64) {
        self.line = line
        self.version = version
    }
}

/// A run of consecutive lines.
public struct WireLineRange: Hashable, Sendable {
    public var start: UInt64
    public var count: Int

    public init(start: UInt64, count: Int) {
        self.start = start
        self.count = count
    }

    public var lines: Range<UInt64> { start ..< start + UInt64(count) }
}

// MARK: - Shared field helpers

extension WireWriter {
    public mutating func rgb(_ value: WireRGB) {
        u16(value.red)
        u16(value.green)
        u16(value.blue)
    }

    public mutating func array<T>(_ items: [T], _ body: (inout WireWriter, T) -> Void) {
        varint(items.count)
        for item in items { body(&self, item) }
    }

    mutating func knownVersions(_ items: [WireKnownVersion]) {
        array(items) { writer, item in
            writer.varint(item.line)
            writer.u64(item.version)
        }
    }

    mutating func lineRanges(_ items: [WireLineRange]) {
        array(items) { writer, item in
            writer.varint(item.start)
            writer.varint(item.count)
        }
    }
}

extension WireReader {
    public mutating func rgb() throws(WireError) -> WireRGB {
        WireRGB(red: try u16(), green: try u16(), blue: try u16())
    }

    public mutating func array<T>(limit: Int = 1 << 20,
                                  _ body: (inout WireReader) throws(WireError) -> T) throws(WireError) -> [T] {
        let count = try count(limit: limit)
        var items: [T] = []
        items.reserveCapacity(Swift.min(count, 4096))
        for _ in 0 ..< count { items.append(try body(&self)) }
        return items
    }

    mutating func knownVersions() throws(WireError) -> [WireKnownVersion] {
        try array { reader throws(WireError) in
            WireKnownVersion(line: try reader.varint(), version: try reader.u64())
        }
    }

    mutating func lineRanges() throws(WireError) -> [WireLineRange] {
        try array { reader throws(WireError) in
            WireLineRange(start: try reader.varint(), count: try reader.count())
        }
    }

    mutating func buffer() throws(WireError) -> WireBuffer {
        let raw = try u8()
        guard let buffer = WireBuffer(rawValue: raw) else { throw .invalidValue("buffer \(raw)") }
        return buffer
    }
}

// MARK: - Handshake

public struct HelloMessage: WireMessage, Hashable {
    public static let kind = MessageKind.hello
    public var minimumVersion: UInt32
    public var maximumVersion: UInt32
    public var build: String
    public var capabilities: SessionCapabilities
    public var maximumMessageSize: Int
    /// Rows the client keeps above and below its viewport (the retention margin M).
    public var retainMargin: Int
    public var clientName: String

    public init(minimumVersion: UInt32 = SessionProtocol.minimumVersion,
                maximumVersion: UInt32 = SessionProtocol.version,
                build: String, capabilities: SessionCapabilities = [],
                maximumMessageSize: Int = 32 * 1024 * 1024, retainMargin: Int = 256,
                clientName: String) {
        self.minimumVersion = minimumVersion
        self.maximumVersion = maximumVersion
        self.build = build
        self.capabilities = capabilities
        self.maximumMessageSize = maximumMessageSize
        self.retainMargin = retainMargin
        self.clientName = clientName
    }

    public init(from reader: inout WireReader) throws(WireError) {
        minimumVersion = try reader.varint32()
        maximumVersion = try reader.varint32()
        build = try reader.string()
        capabilities = SessionCapabilities(rawValue: try reader.u64())
        maximumMessageSize = try reader.count(limit: Int(Int32.max))
        retainMargin = try reader.count(limit: 1 << 20)
        clientName = try reader.string()
    }

    public func encode(to writer: inout WireWriter) {
        writer.varint(minimumVersion)
        writer.varint(maximumVersion)
        writer.string(build)
        writer.u64(capabilities.rawValue)
        writer.varint(maximumMessageSize)
        writer.varint(retainMargin)
        writer.string(clientName)
    }
}

public struct HelloReplyMessage: WireMessage, Hashable {
    public static let kind = MessageKind.helloReply
    public var version: UInt32
    public var build: String
    public var capabilities: SessionCapabilities
    public var sessionID: String
    public var maximumMessageSize: Int

    public init(version: UInt32, build: String, capabilities: SessionCapabilities,
                sessionID: String, maximumMessageSize: Int = 32 * 1024 * 1024) {
        self.version = version
        self.build = build
        self.capabilities = capabilities
        self.sessionID = sessionID
        self.maximumMessageSize = maximumMessageSize
    }

    public init(from reader: inout WireReader) throws(WireError) {
        version = try reader.varint32()
        build = try reader.string()
        capabilities = SessionCapabilities(rawValue: try reader.u64())
        sessionID = try reader.string()
        maximumMessageSize = try reader.count(limit: Int(Int32.max))
    }

    public func encode(to writer: inout WireWriter) {
        writer.varint(version)
        writer.string(build)
        writer.u64(capabilities.rawValue)
        writer.string(sessionID)
        writer.varint(maximumMessageSize)
    }
}

// MARK: - Attachment and viewport

/// Grid size plus the cell size in device-independent pixels.
public struct WireGridSize: Hashable, Sendable {
    public var columns: Int
    public var rows: Int
    public var cellWidth: Int
    public var cellHeight: Int

    public init(columns: Int, rows: Int, cellWidth: Int = 0, cellHeight: Int = 0) {
        self.columns = columns
        self.rows = rows
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
    }

    func encode(to writer: inout WireWriter) {
        writer.varint(columns)
        writer.varint(rows)
        writer.varint(cellWidth)
        writer.varint(cellHeight)
    }

    init(from reader: inout WireReader) throws(WireError) {
        columns = try reader.count(limit: 65_535)
        rows = try reader.count(limit: 65_535)
        cellWidth = try reader.count(limit: 65_535)
        cellHeight = try reader.count(limit: 65_535)
    }
}

public struct AttachMessage: WireMessage, Hashable {
    public static let kind = MessageKind.attach
    public var size: WireGridSize
    public var maximumFramesPerSecond: Int
    /// A viewer never becomes the size owner.
    public var viewer: Bool
    public var focused: Bool
    /// Device pixels per point, in hundredths (200 on a Retina display);
    /// 0 when unknown. Image sizes that a program gives in pixels are points.
    public var scale: Int

    public init(size: WireGridSize, maximumFramesPerSecond: Int = 60, viewer: Bool = false, focused: Bool = true,
                scale: Int = 0) {
        self.size = size
        self.maximumFramesPerSecond = maximumFramesPerSecond
        self.viewer = viewer
        self.focused = focused
        self.scale = scale
    }

    public init(from reader: inout WireReader) throws(WireError) {
        size = try WireGridSize(from: &reader)
        maximumFramesPerSecond = try reader.count(limit: 1000)
        viewer = try reader.bool()
        focused = try reader.bool()
        scale = reader.isAtEnd ? 0 : try reader.count(limit: 10_000)
    }

    public func encode(to writer: inout WireWriter) {
        size.encode(to: &writer)
        writer.varint(maximumFramesPerSecond)
        writer.bool(viewer)
        writer.bool(focused)
        writer.varint(scale)
    }
}

public struct DetachMessage: WireMessage, Hashable {
    public static let kind = MessageKind.detach
    public init() {}
    public init(from reader: inout WireReader) throws(WireError) {}
    public func encode(to writer: inout WireWriter) {}
}

public struct ResizeMessage: WireMessage, Hashable {
    public static let kind = MessageKind.resize
    public var size: WireGridSize
    /// As in `AttachMessage.scale`.
    public var scale: Int

    public init(size: WireGridSize, scale: Int = 0) {
        self.size = size
        self.scale = scale
    }

    public init(from reader: inout WireReader) throws(WireError) {
        size = try WireGridSize(from: &reader)
        scale = reader.isAtEnd ? 0 : try reader.count(limit: 10_000)
    }

    public func encode(to writer: inout WireWriter) {
        size.encode(to: &writer)
        writer.varint(scale)
    }
}

public struct SetViewportMessage: WireMessage, Hashable {
    public static let kind = MessageKind.setViewport
    public var buffer: WireBuffer
    /// True to follow the live screen; `top` is then ignored.
    public var follow: Bool
    public var top: UInt64
    public var known: [WireKnownVersion]

    public init(buffer: WireBuffer, follow: Bool, top: UInt64 = 0, known: [WireKnownVersion] = []) {
        self.buffer = buffer
        self.follow = follow
        self.top = top
        self.known = known
    }

    public init(from reader: inout WireReader) throws(WireError) {
        buffer = try reader.buffer()
        follow = try reader.bool()
        top = try reader.varint()
        known = try reader.knownVersions()
    }

    public func encode(to writer: inout WireWriter) {
        writer.u8(buffer.rawValue)
        writer.bool(follow)
        writer.varint(top)
        writer.knownVersions(known)
    }
}

public struct FrameAckMessage: WireMessage, Hashable {
    public static let kind = MessageKind.frameAck
    public var sequence: UInt64

    public init(sequence: UInt64) { self.sequence = sequence }
    public init(from reader: inout WireReader) throws(WireError) { sequence = try reader.varint() }
    public func encode(to writer: inout WireWriter) { writer.varint(sequence) }
}

public struct FetchRowsMessage: WireMessage, Hashable {
    public static let kind = MessageKind.fetchRows
    public var buffer: WireBuffer
    public var epoch: UInt64
    public var start: UInt64
    public var count: Int
    public var known: [WireKnownVersion]

    public init(buffer: WireBuffer, epoch: UInt64, start: UInt64, count: Int, known: [WireKnownVersion] = []) {
        self.buffer = buffer
        self.epoch = epoch
        self.start = start
        self.count = count
        self.known = known
    }

    public init(from reader: inout WireReader) throws(WireError) {
        buffer = try reader.buffer()
        epoch = try reader.varint()
        start = try reader.varint()
        count = try reader.count(limit: 1 << 20)
        known = try reader.knownVersions()
    }

    public func encode(to writer: inout WireWriter) {
        writer.u8(buffer.rawValue)
        writer.varint(epoch)
        writer.varint(start)
        writer.varint(count)
        writer.knownVersions(known)
    }
}

// MARK: - Input

/// A key event with W3C `KeyboardEvent` names, encoded by the helper with
/// `Terminal.sendHostKey`.
public struct KeyMessage: WireMessage, Hashable {
    public static let kind = MessageKind.key
    public var key: String
    public var code: String
    /// Kitty modifier bits: shift 1, alt 2, ctrl 4, super 8, hyper 16, meta 32, caps 64, num 128.
    public var modifiers: UInt32
    /// 1 press, 2 repeat, 3 release.
    public var eventType: UInt32
    public var text: String?
    public var shiftedKey: UInt32
    public var baseLayoutKey: UInt32

    public init(key: String, code: String, modifiers: UInt32 = 0, eventType: UInt32 = 1,
                text: String? = nil, shiftedKey: UInt32 = 0, baseLayoutKey: UInt32 = 0) {
        self.key = key
        self.code = code
        self.modifiers = modifiers
        self.eventType = eventType
        self.text = text
        self.shiftedKey = shiftedKey
        self.baseLayoutKey = baseLayoutKey
    }

    public init(from reader: inout WireReader) throws(WireError) {
        key = try reader.string(limit: 256)
        code = try reader.string(limit: 256)
        modifiers = try reader.varint32()
        eventType = try reader.varint32()
        text = try reader.optionalString()
        shiftedKey = try reader.varint32()
        baseLayoutKey = try reader.varint32()
    }

    public func encode(to writer: inout WireWriter) {
        writer.string(key)
        writer.string(code)
        writer.varint(modifiers)
        writer.varint(eventType)
        writer.optionalString(text)
        writer.varint(shiftedKey)
        writer.varint(baseLayoutKey)
    }
}

/// Committed typing text (for example from an input method).
public struct TextMessage: WireMessage, Hashable {
    public static let kind = MessageKind.text
    public var text: String

    public init(text: String) { self.text = text }
    public init(from reader: inout WireReader) throws(WireError) { text = try reader.string() }
    public func encode(to writer: inout WireWriter) { writer.string(text) }
}

/// Literal bytes for the program, sent as user input.
public struct InputMessage: WireMessage, Hashable {
    public static let kind = MessageKind.input
    public var bytes: [UInt8]

    public init(bytes: [UInt8]) { self.bytes = bytes }
    public init(from reader: inout WireReader) throws(WireError) { bytes = try reader.blob() }
    public func encode(to writer: inout WireWriter) { writer.blob(bytes) }
}

public struct MouseMessage: WireMessage, Hashable {
    public static let kind = MessageKind.mouse
    /// SwiftTerm `TerminalMouseAction` raw value.
    public var action: UInt8
    /// SwiftTerm `TerminalMouseButton` raw value.
    public var button: UInt8
    /// Shift 1, Alt 2, Control 4.
    public var modifiers: UInt8
    public var column: Int
    public var row: Int
    public var pixelX: Int
    public var pixelY: Int

    public init(action: UInt8, button: UInt8, modifiers: UInt8, column: Int, row: Int, pixelX: Int, pixelY: Int) {
        self.action = action
        self.button = button
        self.modifiers = modifiers
        self.column = column
        self.row = row
        self.pixelX = pixelX
        self.pixelY = pixelY
    }

    public init(from reader: inout WireReader) throws(WireError) {
        action = try reader.u8()
        button = try reader.u8()
        modifiers = try reader.u8()
        column = try reader.count(limit: 65_535)
        row = try reader.count(limit: 65_535)
        pixelX = try reader.count(limit: 1 << 24)
        pixelY = try reader.count(limit: 1 << 24)
    }

    public func encode(to writer: inout WireWriter) {
        writer.u8(action)
        writer.u8(button)
        writer.u8(modifiers)
        writer.varint(column)
        writer.varint(row)
        writer.varint(pixelX)
        writer.varint(pixelY)
    }
}

public struct PasteMessage: WireMessage, Hashable {
    public static let kind = MessageKind.paste
    public var text: String
    public var allowUnsafe: Bool

    public init(text: String, allowUnsafe: Bool = false) {
        self.text = text
        self.allowUnsafe = allowUnsafe
    }

    public init(from reader: inout WireReader) throws(WireError) {
        text = try reader.string()
        allowUnsafe = try reader.bool()
    }

    public func encode(to writer: inout WireWriter) {
        writer.string(text)
        writer.bool(allowUnsafe)
    }
}

public struct PasteApproveMessage: WireMessage, Hashable {
    public static let kind = MessageKind.pasteApprove
    public var token: UInt64
    public var approved: Bool

    public init(token: UInt64, approved: Bool) {
        self.token = token
        self.approved = approved
    }

    public init(from reader: inout WireReader) throws(WireError) {
        token = try reader.varint()
        approved = try reader.bool()
    }

    public func encode(to writer: inout WireWriter) {
        writer.varint(token)
        writer.bool(approved)
    }
}

public struct FocusMessage: WireMessage, Hashable {
    public static let kind = MessageKind.focus
    public var focused: Bool

    public init(focused: Bool) { self.focused = focused }
    public init(from reader: inout WireReader) throws(WireError) { focused = try reader.bool() }
    public func encode(to writer: inout WireWriter) { writer.bool(focused) }
}

// MARK: - Queries and replies

public struct GetTextMessage: WireMessage, Hashable {
    public static let kind = MessageKind.getText
    public var buffer: WireBuffer
    public var startLine: UInt64
    public var startColumn: Int
    /// Inclusive end position.
    public var endLine: UInt64
    public var endColumn: Int

    public init(buffer: WireBuffer, startLine: UInt64, startColumn: Int, endLine: UInt64, endColumn: Int) {
        self.buffer = buffer
        self.startLine = startLine
        self.startColumn = startColumn
        self.endLine = endLine
        self.endColumn = endColumn
    }

    public init(from reader: inout WireReader) throws(WireError) {
        buffer = try reader.buffer()
        startLine = try reader.varint()
        startColumn = try reader.count(limit: 65_535)
        endLine = try reader.varint()
        endColumn = try reader.count(limit: 65_535)
    }

    public func encode(to writer: inout WireWriter) {
        writer.u8(buffer.rawValue)
        writer.varint(startLine)
        writer.varint(startColumn)
        writer.varint(endLine)
        writer.varint(endColumn)
    }
}

public struct TextResultMessage: WireMessage, Hashable {
    public static let kind = MessageKind.textResult
    public var text: String

    public init(text: String) { self.text = text }
    public init(from reader: inout WireReader) throws(WireError) { text = try reader.string() }
    public func encode(to writer: inout WireWriter) { writer.string(text) }
}

public struct ClipboardReplyMessage: WireMessage, Hashable {
    public static let kind = MessageKind.clipboardReply
    public var request: UInt64
    public var allowed: Bool
    public var data: [UInt8]

    public init(request: UInt64, allowed: Bool, data: [UInt8] = []) {
        self.request = request
        self.allowed = allowed
        self.data = data
    }

    public init(from reader: inout WireReader) throws(WireError) {
        request = try reader.varint()
        allowed = try reader.bool()
        data = try reader.blob()
    }

    public func encode(to writer: inout WireWriter) {
        writer.varint(request)
        writer.bool(allowed)
        writer.blob(data)
    }
}

public struct SetThemeMessage: WireMessage, Hashable {
    public static let kind = MessageKind.setTheme
    /// The first 16 or all 256 palette entries.
    public var palette: [WireRGB]
    public var foreground: WireRGB
    public var background: WireRGB
    public var cursor: WireRGB?

    public init(palette: [WireRGB], foreground: WireRGB, background: WireRGB, cursor: WireRGB? = nil) {
        self.palette = palette
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
    }

    public init(from reader: inout WireReader) throws(WireError) {
        palette = try reader.array(limit: 256) { reader throws(WireError) in try reader.rgb() }
        foreground = try reader.rgb()
        background = try reader.rgb()
        cursor = try reader.bool() ? try reader.rgb() : nil
    }

    public func encode(to writer: inout WireWriter) {
        writer.array(palette) { writer, color in writer.rgb(color) }
        writer.rgb(foreground)
        writer.rgb(background)
        writer.bool(cursor != nil)
        if let cursor { writer.rgb(cursor) }
    }
}

public struct PingMessage: WireMessage, Hashable {
    public static let kind = MessageKind.ping
    public var nonce: UInt64

    public init(nonce: UInt64) { self.nonce = nonce }
    public init(from reader: inout WireReader) throws(WireError) { nonce = try reader.u64() }
    public func encode(to writer: inout WireWriter) { writer.u64(nonce) }
}

public struct PongMessage: WireMessage, Hashable {
    public static let kind = MessageKind.pong
    public var nonce: UInt64

    public init(nonce: UInt64) { self.nonce = nonce }
    public init(from reader: inout WireReader) throws(WireError) { nonce = try reader.u64() }
    public func encode(to writer: inout WireWriter) { writer.u64(nonce) }
}

/// Ends the session: the helper sends `signal` to the shell's process group.
public struct TerminateMessage: WireMessage, Hashable {
    public static let kind = MessageKind.terminate
    public var signal: Int32

    public init(signal: Int32 = 1) { self.signal = signal }
    public init(from reader: inout WireReader) throws(WireError) {
        signal = Int32(clamping: try reader.svarint())
    }
    public func encode(to writer: inout WireWriter) { writer.svarint(Int64(signal)) }
}

public enum ResetAction: UInt8, Hashable, Sendable {
    /// DECSTR.
    case soft = 0
    /// RIS: the terminal returns to its initial state.
    case hard = 1
    /// Removes the scrollback of the normal screen.
    case clearScrollback = 2
    /// Clears the screen and the scrollback and moves the cursor home,
    /// without sending anything to the program (Tecolot's Clear to Start).
    case clearToStart = 3
}

public struct ResetMessage: WireMessage, Hashable {
    public static let kind = MessageKind.reset
    public var action: ResetAction

    public init(action: ResetAction) { self.action = action }

    public init(from reader: inout WireReader) throws(WireError) {
        let raw = try reader.u8()
        guard let action = ResetAction(rawValue: raw) else { throw .invalidValue("reset action \(raw)") }
        self.action = action
    }

    public func encode(to writer: inout WireWriter) { writer.u8(action.rawValue) }
}

public struct SessionSearchOptions: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let caseSensitive = SessionSearchOptions(rawValue: 1)
    public static let regularExpression = SessionSearchOptions(rawValue: 2)
    public static let wholeWord = SessionSearchOptions(rawValue: 4)
    /// Search toward older lines.
    public static let backward = SessionSearchOptions(rawValue: 8)
}

/// Finds the next match after (or, backward, before) a position. The search
/// wraps around the buffer.
public struct SearchMessage: WireMessage, Hashable {
    public static let kind = MessageKind.search
    public var query: String
    public var options: SessionSearchOptions
    public var buffer: WireBuffer
    public var startLine: UInt64
    public var startColumn: Int

    public init(query: String, options: SessionSearchOptions, buffer: WireBuffer, startLine: UInt64, startColumn: Int) {
        self.query = query
        self.options = options
        self.buffer = buffer
        self.startLine = startLine
        self.startColumn = startColumn
    }

    public init(from reader: inout WireReader) throws(WireError) {
        query = try reader.string(limit: 1 << 16)
        options = SessionSearchOptions(rawValue: try reader.u8())
        buffer = try reader.buffer()
        startLine = try reader.varint()
        startColumn = try reader.count(limit: 65_535)
    }

    public func encode(to writer: inout WireWriter) {
        writer.string(query)
        writer.u8(options.rawValue)
        writer.u8(buffer.rawValue)
        writer.varint(startLine)
        writer.varint(startColumn)
    }
}

/// A match: from (line, column) to (endLine, endColumn), inclusive.
public struct SearchResultMessage: WireMessage, Hashable {
    public static let kind = MessageKind.searchResult
    public var found: Bool
    public var line: UInt64
    public var column: Int
    public var endLine: UInt64
    public var endColumn: Int
    /// A message for the user, for example an invalid regular expression.
    public var problem: String

    public init(found: Bool, line: UInt64 = 0, column: Int = 0, endLine: UInt64 = 0, endColumn: Int = 0,
                problem: String = "") {
        self.found = found
        self.line = line
        self.column = column
        self.endLine = endLine
        self.endColumn = endColumn
        self.problem = problem
    }

    public init(from reader: inout WireReader) throws(WireError) {
        found = try reader.bool()
        line = try reader.varint()
        column = try reader.count(limit: 65_535)
        endLine = try reader.varint()
        endColumn = try reader.count(limit: 65_535)
        problem = try reader.string(limit: 4096)
    }

    public func encode(to writer: inout WireWriter) {
        writer.bool(found)
        writer.varint(line)
        writer.varint(column)
        writer.varint(endLine)
        writer.varint(endColumn)
        writer.string(problem)
    }
}

/// Finds the nearest shell prompt (a row that OSC 133 marks as the start of
/// a prompt) above or below a line. The line itself is not a candidate.
public struct FindPromptMessage: WireMessage, Hashable {
    public static let kind = MessageKind.findPrompt
    public var buffer: WireBuffer
    public var line: UInt64
    public var upward: Bool

    public init(buffer: WireBuffer, line: UInt64, upward: Bool) {
        self.buffer = buffer
        self.line = line
        self.upward = upward
    }

    public init(from reader: inout WireReader) throws(WireError) {
        buffer = try reader.buffer()
        line = try reader.varint()
        upward = try reader.bool()
    }

    public func encode(to writer: inout WireWriter) {
        writer.u8(buffer.rawValue)
        writer.varint(line)
        writer.bool(upward)
    }
}

/// The answer to `FindPrompt`: the line of the prompt, if there is one.
public struct PromptResultMessage: WireMessage, Hashable {
    public static let kind = MessageKind.promptResult
    public var found: Bool
    public var line: UInt64

    public init(found: Bool, line: UInt64 = 0) {
        self.found = found
        self.line = line
    }

    public init(from reader: inout WireReader) throws(WireError) {
        found = try reader.bool()
        line = try reader.varint()
    }

    public func encode(to writer: inout WireWriter) {
        writer.bool(found)
        writer.varint(line)
    }
}

// MARK: - Frames and rows

/// Latched terminal values. A frame carries only the values that changed.
public struct WireModes: Hashable, Sendable {
    /// `Terminal.hostInputModes`.
    public var input: UInt32
    /// `Terminal.hostPointerModes`.
    public var pointer: UInt32

    public init(input: UInt32, pointer: UInt32) {
        self.input = input
        self.pointer = pointer
    }
}

public struct WireColorState: Hashable, Sendable {
    public var foreground: WireRGB
    public var background: WireRGB
    public var cursor: WireRGB?
    /// Palette entries that a program changed (OSC 4), as (index, color).
    public var paletteOverrides: [UInt8: WireRGB]

    public init(foreground: WireRGB, background: WireRGB, cursor: WireRGB?, paletteOverrides: [UInt8: WireRGB]) {
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.paletteOverrides = paletteOverrides
    }
}

public struct FrameMessage: WireMessage, Hashable {
    public static let kind = MessageKind.frame

    struct Sections: OptionSet {
        let rawValue: UInt32
        static let modes = Sections(rawValue: 1 << 0)
        static let title = Sections(rawValue: 1 << 1)
        static let iconTitle = Sections(rawValue: 1 << 2)
        static let directory = Sections(rawValue: 1 << 3)
        static let colors = Sections(rawValue: 1 << 4)
        static let reverseVideo = Sections(rawValue: 1 << 5)
    }

    public var sequence: UInt64
    /// The helper's feed counter when it built the frame.
    public var snapshotSequence: UInt64
    public var buffer: WireBuffer
    public var epoch: UInt64
    /// The oldest line that the helper still has.
    public var firstLine: UInt64
    /// One past the newest line.
    public var endLine: UInt64
    /// The first line of the client's viewport.
    public var viewTop: UInt64
    public var columns: Int
    public var rows: Int
    public var cursor: WireCursor

    public var modes: WireModes?
    public var title: String?
    public var iconTitle: String?
    /// OSC 7 value; an empty string clears it.
    public var directory: String?
    public var colors: WireColorState?
    public var reverseVideo: Bool?

    /// Rows whose version differs from what the client has. Besides the
    /// visible rows, these can be rows just outside them that the client
    /// needs for the bidi layout of a wrapped paragraph.
    public var changedRows: [WireRowRecord]

    // Extensions: after the rows, so that older decoders ignore them.

    /// The terminal's `maximumBidiParagraphRows`; nil when unchanged.
    public var maximumBidiParagraphRows: Int?
    /// The Kitty graphics that touch the client's rows; nil when unchanged.
    public var kitty: WireKittyState?

    struct Extensions: OptionSet {
        let rawValue: UInt32
        static let bidi = Extensions(rawValue: 1 << 0)
        static let kitty = Extensions(rawValue: 1 << 1)
    }

    public init(sequence: UInt64, snapshotSequence: UInt64, buffer: WireBuffer, epoch: UInt64,
                firstLine: UInt64, endLine: UInt64, viewTop: UInt64, columns: Int, rows: Int,
                cursor: WireCursor, modes: WireModes? = nil, title: String? = nil,
                iconTitle: String? = nil, directory: String? = nil, colors: WireColorState? = nil,
                reverseVideo: Bool? = nil, changedRows: [WireRowRecord] = [],
                maximumBidiParagraphRows: Int? = nil, kitty: WireKittyState? = nil) {
        self.sequence = sequence
        self.snapshotSequence = snapshotSequence
        self.buffer = buffer
        self.epoch = epoch
        self.firstLine = firstLine
        self.endLine = endLine
        self.viewTop = viewTop
        self.columns = columns
        self.rows = rows
        self.cursor = cursor
        self.modes = modes
        self.title = title
        self.iconTitle = iconTitle
        self.directory = directory
        self.colors = colors
        self.reverseVideo = reverseVideo
        self.changedRows = changedRows
        self.maximumBidiParagraphRows = maximumBidiParagraphRows
        self.kitty = kitty
    }

    public init(from reader: inout WireReader) throws(WireError) {
        sequence = try reader.varint()
        snapshotSequence = try reader.varint()
        buffer = try reader.buffer()
        epoch = try reader.varint()
        firstLine = try reader.varint()
        endLine = try reader.varint()
        viewTop = try reader.varint()
        columns = try reader.count(limit: 65_535)
        rows = try reader.count(limit: 65_535)
        let cursorLine = try reader.varint()
        let cursorColumn = try reader.count(limit: 65_535)
        let cursorFlags = try reader.u8()
        let cursorStyle = try reader.u8()
        cursor = WireCursor(line: cursorLine, column: cursorColumn, visible: cursorFlags & 1 != 0,
                            blink: cursorFlags & 2 != 0, style: cursorStyle)
        let sections = Sections(rawValue: try reader.varint32())
        if sections.contains(.modes) {
            modes = WireModes(input: try reader.varint32(), pointer: try reader.varint32())
        }
        if sections.contains(.title) { title = try reader.string(limit: 1 << 16) }
        if sections.contains(.iconTitle) { iconTitle = try reader.string(limit: 1 << 16) }
        if sections.contains(.directory) { directory = try reader.string(limit: 1 << 16) }
        if sections.contains(.colors) {
            let foreground = try reader.rgb()
            let background = try reader.rgb()
            let cursor = try reader.bool() ? try reader.rgb() : nil
            var overrides: [UInt8: WireRGB] = [:]
            let count = try reader.count(limit: 256)
            for _ in 0 ..< count {
                let index = try reader.u8()
                overrides[index] = try reader.rgb()
            }
            colors = WireColorState(foreground: foreground, background: background,
                                    cursor: cursor, paletteOverrides: overrides)
        }
        if sections.contains(.reverseVideo) { reverseVideo = try reader.bool() }
        changedRows = try reader.array(limit: 65_535) { reader throws(WireError) in
            try WireRowRecord(from: &reader)
        }
        guard !reader.isAtEnd else { return }
        let extensions = Extensions(rawValue: try reader.varint32())
        if extensions.contains(.bidi) { maximumBidiParagraphRows = try reader.count(limit: 1 << 20) }
        if extensions.contains(.kitty) { kitty = try WireKittyState(from: &reader) }
    }

    public func encode(to writer: inout WireWriter) {
        writer.varint(sequence)
        writer.varint(snapshotSequence)
        writer.u8(buffer.rawValue)
        writer.varint(epoch)
        writer.varint(firstLine)
        writer.varint(endLine)
        writer.varint(viewTop)
        writer.varint(columns)
        writer.varint(rows)
        writer.varint(cursor.line)
        writer.varint(cursor.column)
        writer.u8((cursor.visible ? 1 : 0) | (cursor.blink ? 2 : 0))
        writer.u8(cursor.style)
        var sections: Sections = []
        if modes != nil { sections.insert(.modes) }
        if title != nil { sections.insert(.title) }
        if iconTitle != nil { sections.insert(.iconTitle) }
        if directory != nil { sections.insert(.directory) }
        if colors != nil { sections.insert(.colors) }
        if reverseVideo != nil { sections.insert(.reverseVideo) }
        writer.varint(sections.rawValue)
        if let modes {
            writer.varint(modes.input)
            writer.varint(modes.pointer)
        }
        if let title { writer.string(title) }
        if let iconTitle { writer.string(iconTitle) }
        if let directory { writer.string(directory) }
        if let colors {
            writer.rgb(colors.foreground)
            writer.rgb(colors.background)
            writer.bool(colors.cursor != nil)
            if let cursor = colors.cursor { writer.rgb(cursor) }
            writer.varint(colors.paletteOverrides.count)
            for (index, color) in colors.paletteOverrides.sorted(by: { $0.key < $1.key }) {
                writer.u8(index)
                writer.rgb(color)
            }
        }
        if let reverseVideo { writer.bool(reverseVideo) }
        writer.array(changedRows) { writer, row in row.encode(to: &writer) }
        var extensions: Extensions = []
        if maximumBidiParagraphRows != nil { extensions.insert(.bidi) }
        if kitty != nil { extensions.insert(.kitty) }
        guard !extensions.isEmpty else { return }
        writer.varint(extensions.rawValue)
        if let maximumBidiParagraphRows { writer.varint(maximumBidiParagraphRows) }
        if let kitty { kitty.encode(to: &writer) }
    }
}

// MARK: - Images

/// A Kitty image that placements use. Fetch its pixels with
/// `FetchImage(imageID)`; `imageID` changes whenever the pixels change.
public struct WireKittyImage: Hashable, Sendable {
    /// The image ID that the program chose (placeholders refer to it).
    public var kittyID: UInt32
    public var imageNumber: UInt32?
    public var imageID: UInt64
    public var width: Int
    public var height: Int

    public init(kittyID: UInt32, imageNumber: UInt32? = nil, imageID: UInt64, width: Int, height: Int) {
        self.kittyID = kittyID
        self.imageNumber = imageNumber
        self.imageID = imageID
        self.width = width
        self.height = height
    }
}

/// A Kitty placement, as `KittyGraphicsRenderPlacement` with an absolute
/// line instead of a row relative to the viewport. Virtual placements
/// (Unicode placeholders) have no line.
public struct WireKittyPlacement: Hashable, Sendable {
    public var token: UInt64
    public var placementID: UInt32
    public var kittyID: UInt32
    public var sourceX: Int
    public var sourceY: Int
    public var sourceWidth: Int
    public var sourceHeight: Int
    public var line: Int64
    public var column: Int
    public var columns: Int
    public var rows: Int
    public var pixelOffsetX: Int
    public var pixelOffsetY: Int
    public var zIndex: Int32
    public var isVirtual: Bool
    public var insertionOrder: UInt64

    public init(token: UInt64, placementID: UInt32, kittyID: UInt32, sourceX: Int, sourceY: Int,
                sourceWidth: Int, sourceHeight: Int, line: Int64, column: Int, columns: Int, rows: Int,
                pixelOffsetX: Int, pixelOffsetY: Int, zIndex: Int32, isVirtual: Bool, insertionOrder: UInt64) {
        self.token = token
        self.placementID = placementID
        self.kittyID = kittyID
        self.sourceX = sourceX
        self.sourceY = sourceY
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.line = line
        self.column = column
        self.columns = columns
        self.rows = rows
        self.pixelOffsetX = pixelOffsetX
        self.pixelOffsetY = pixelOffsetY
        self.zIndex = zIndex
        self.isVirtual = isVirtual
        self.insertionOrder = insertionOrder
    }
}

/// The Kitty graphics of the active screen that touch the client's rows,
/// plus every virtual placement. Sent whole when anything in it changes.
public struct WireKittyState: Hashable, Sendable {
    /// Changes whenever the helper's Kitty storage changes.
    public var generation: UInt64
    public var images: [WireKittyImage]
    /// In drawing order (z-index, then insertion order).
    public var placements: [WireKittyPlacement]

    public init(generation: UInt64, images: [WireKittyImage] = [], placements: [WireKittyPlacement] = []) {
        self.generation = generation
        self.images = images
        self.placements = placements
    }

    init(from reader: inout WireReader) throws(WireError) {
        generation = try reader.varint()
        images = try reader.array(limit: 65_535) { reader throws(WireError) in
            let kittyID = try reader.varint32()
            let number = try reader.varint32()
            return WireKittyImage(kittyID: kittyID, imageNumber: number == 0 ? nil : number - 1,
                                  imageID: try reader.varint(), width: try reader.count(limit: 1 << 20),
                                  height: try reader.count(limit: 1 << 20))
        }
        placements = try reader.array(limit: 65_535) { reader throws(WireError) in
            WireKittyPlacement(
                token: try reader.varint(), placementID: try reader.varint32(), kittyID: try reader.varint32(),
                sourceX: try reader.count(limit: 1 << 20), sourceY: try reader.count(limit: 1 << 20),
                sourceWidth: try reader.count(limit: 1 << 20), sourceHeight: try reader.count(limit: 1 << 20),
                line: try reader.svarint(), column: Int(try reader.svarint()),
                columns: try reader.count(limit: 1 << 16), rows: try reader.count(limit: 1 << 16),
                pixelOffsetX: Int(try reader.svarint()), pixelOffsetY: Int(try reader.svarint()),
                zIndex: Int32(truncatingIfNeeded: try reader.svarint()), isVirtual: try reader.bool(),
                insertionOrder: try reader.varint())
        }
    }

    func encode(to writer: inout WireWriter) {
        writer.varint(generation)
        writer.array(images) { writer, image in
            writer.varint(image.kittyID)
            // 0 means none; numbers are stored plus one.
            writer.varint(image.imageNumber.map { UInt64($0) + 1 } ?? 0)
            writer.varint(image.imageID)
            writer.varint(image.width)
            writer.varint(image.height)
        }
        writer.array(placements) { writer, placement in
            writer.varint(placement.token)
            writer.varint(placement.placementID)
            writer.varint(placement.kittyID)
            writer.varint(placement.sourceX)
            writer.varint(placement.sourceY)
            writer.varint(placement.sourceWidth)
            writer.varint(placement.sourceHeight)
            writer.svarint(placement.line)
            writer.svarint(Int64(placement.column))
            writer.varint(placement.columns)
            writer.varint(placement.rows)
            writer.svarint(Int64(placement.pixelOffsetX))
            writer.svarint(Int64(placement.pixelOffsetY))
            writer.svarint(Int64(placement.zIndex))
            writer.bool(placement.isVirtual)
            writer.varint(placement.insertionOrder)
        }
    }
}

/// Asks for the pixels of an image (a row's image slice, or a Kitty image).
/// The reply is one or more `ImageData` chunks with the same request ID.
public struct FetchImageMessage: WireMessage, Hashable {
    public static let kind = MessageKind.fetchImage
    public var imageID: UInt64

    public init(imageID: UInt64) { self.imageID = imageID }
    public init(from reader: inout WireReader) throws(WireError) { imageID = try reader.varint() }
    public func encode(to writer: inout WireWriter) { writer.varint(imageID) }
}

/// Pixels of an image: straight (not premultiplied) RGBA, top row first,
/// `width * height * 4` bytes in total, sent in chunks at `offset`.
/// `width` 0 means that the helper no longer has the image.
public struct ImageDataMessage: WireMessage, Hashable {
    public static let kind = MessageKind.imageData
    public var imageID: UInt64
    public var width: Int
    public var height: Int
    public var offset: Int
    public var bytes: [UInt8]

    public init(imageID: UInt64, width: Int, height: Int, offset: Int = 0, bytes: [UInt8] = []) {
        self.imageID = imageID
        self.width = width
        self.height = height
        self.offset = offset
        self.bytes = bytes
    }

    public var totalBytes: Int { width * height * 4 }
    public var isLast: Bool { offset + bytes.count >= totalBytes }

    public init(from reader: inout WireReader) throws(WireError) {
        imageID = try reader.varint()
        width = try reader.count(limit: 1 << 16)
        height = try reader.count(limit: 1 << 16)
        offset = try reader.count(limit: Int(Int32.max))
        bytes = try reader.blob(limit: 32 * 1024 * 1024)
    }

    public func encode(to writer: inout WireWriter) {
        writer.varint(imageID)
        writer.varint(width)
        writer.varint(height)
        writer.varint(offset)
        writer.blob(bytes)
    }
}

/// A reply to `FetchRows`. Large replies come in several chunks; the last
/// chunk has `final` set.
public struct RowsMessage: WireMessage, Hashable {
    public static let kind = MessageKind.rows
    public var snapshotSequence: UInt64
    public var buffer: WireBuffer
    public var epoch: UInt64
    public var final: Bool
    /// Rows that the client did not have, or had with another version.
    public var records: [WireRowRecord]
    /// Rows that the client already has with the current version.
    public var confirmed: [WireLineRange]
    /// Rows that the helper no longer has (trimmed) or cannot read now.
    public var unavailable: [WireLineRange]

    public init(snapshotSequence: UInt64, buffer: WireBuffer, epoch: UInt64, final: Bool,
                records: [WireRowRecord] = [], confirmed: [WireLineRange] = [],
                unavailable: [WireLineRange] = []) {
        self.snapshotSequence = snapshotSequence
        self.buffer = buffer
        self.epoch = epoch
        self.final = final
        self.records = records
        self.confirmed = confirmed
        self.unavailable = unavailable
    }

    public init(from reader: inout WireReader) throws(WireError) {
        snapshotSequence = try reader.varint()
        buffer = try reader.buffer()
        epoch = try reader.varint()
        final = try reader.bool()
        records = try reader.array(limit: 1 << 20) { reader throws(WireError) in
            try WireRowRecord(from: &reader)
        }
        confirmed = try reader.lineRanges()
        unavailable = try reader.lineRanges()
    }

    public func encode(to writer: inout WireWriter) {
        writer.varint(snapshotSequence)
        writer.u8(buffer.rawValue)
        writer.varint(epoch)
        writer.bool(final)
        writer.array(records) { writer, row in row.encode(to: &writer) }
        writer.lineRanges(confirmed)
        writer.lineRanges(unavailable)
    }
}

public struct DefineLinksMessage: WireMessage, Hashable {
    public static let kind = MessageKind.defineLinks
    /// Link identifier to the OSC 8 `params;URI` payload.
    public var links: [UInt32: String]

    public init(links: [UInt32: String]) { self.links = links }

    public init(from reader: inout WireReader) throws(WireError) {
        var links: [UInt32: String] = [:]
        let count = try reader.count(limit: 1 << 20)
        for _ in 0 ..< count {
            let id = try reader.varint32()
            links[id] = try reader.string(limit: 1 << 16)
        }
        self.links = links
    }

    public func encode(to writer: inout WireWriter) {
        writer.varint(links.count)
        for (id, value) in links.sorted(by: { $0.key < $1.key }) {
            writer.varint(id)
            writer.string(value)
        }
    }
}

// MARK: - Events

public struct BellMessage: WireMessage, Hashable {
    public static let kind = MessageKind.bell
    public init() {}
    public init(from reader: inout WireReader) throws(WireError) {}
    public func encode(to writer: inout WireWriter) {}
}

public struct ClipboardCopyMessage: WireMessage, Hashable {
    public static let kind = MessageKind.clipboardCopy
    public var data: [UInt8]

    public init(data: [UInt8]) { self.data = data }
    public init(from reader: inout WireReader) throws(WireError) { data = try reader.blob() }
    public func encode(to writer: inout WireWriter) { writer.blob(data) }
}

public struct ClipboardReadRequestMessage: WireMessage, Hashable {
    public static let kind = MessageKind.clipboardReadRequest
    public var request: UInt64
    public var selection: String

    public init(request: UInt64, selection: String) {
        self.request = request
        self.selection = selection
    }

    public init(from reader: inout WireReader) throws(WireError) {
        request = try reader.varint()
        selection = try reader.string(limit: 64)
    }

    public func encode(to writer: inout WireWriter) {
        writer.varint(request)
        writer.string(selection)
    }
}

public struct ProcessExitedMessage: WireMessage, Hashable {
    public static let kind = MessageKind.processExited
    /// Nil when the process ended by a signal or the status is unknown.
    public var exitCode: Int32?

    public init(exitCode: Int32?) { self.exitCode = exitCode }

    public init(from reader: inout WireReader) throws(WireError) {
        exitCode = try reader.bool() ? Int32(clamping: try reader.svarint()) : nil
    }

    public func encode(to writer: inout WireWriter) {
        writer.bool(exitCode != nil)
        if let exitCode { writer.svarint(Int64(exitCode)) }
    }
}

public enum PasteStatus: UInt8, Hashable, Sendable {
    case sent = 0
    /// The text has control bytes; the helper keeps it under `token`.
    case needsApproval = 1
    case rejected = 2
}

public struct PasteResultMessage: WireMessage, Hashable {
    public static let kind = MessageKind.pasteResult
    public var status: PasteStatus
    public var token: UInt64

    public init(status: PasteStatus, token: UInt64 = 0) {
        self.status = status
        self.token = token
    }

    public init(from reader: inout WireReader) throws(WireError) {
        let raw = try reader.u8()
        guard let status = PasteStatus(rawValue: raw) else { throw .invalidValue("paste status \(raw)") }
        self.status = status
        token = try reader.varint()
    }

    public func encode(to writer: inout WireWriter) {
        writer.u8(status.rawValue)
        writer.varint(token)
    }
}

public struct WireProcess: Hashable, Sendable {
    public var pid: Int32
    public var name: String
    public var path: String

    public init(pid: Int32, name: String, path: String) {
        self.pid = pid
        self.name = name
        self.path = path
    }
}

public struct SessionInfoMessage: WireMessage, Hashable {
    public static let kind = MessageKind.sessionInfo
    public var shellPID: Int32
    public var shellName: String
    public var foreground: WireProcess?
    public var hasChildren: Bool

    public init(shellPID: Int32, shellName: String, foreground: WireProcess?, hasChildren: Bool) {
        self.shellPID = shellPID
        self.shellName = shellName
        self.foreground = foreground
        self.hasChildren = hasChildren
    }

    public init(from reader: inout WireReader) throws(WireError) {
        shellPID = Int32(clamping: try reader.svarint())
        shellName = try reader.string(limit: 4096)
        if try reader.bool() {
            foreground = WireProcess(pid: Int32(clamping: try reader.svarint()),
                                     name: try reader.string(limit: 4096),
                                     path: try reader.string(limit: 4096))
        }
        hasChildren = try reader.bool()
    }

    public func encode(to writer: inout WireWriter) {
        writer.svarint(Int64(shellPID))
        writer.string(shellName)
        writer.bool(foreground != nil)
        if let foreground {
            writer.svarint(Int64(foreground.pid))
            writer.string(foreground.name)
            writer.string(foreground.path)
        }
        writer.bool(hasChildren)
    }
}

public enum SessionErrorCode: UInt32, Hashable, Sendable {
    case unknown = 0
    case unsupported = 1
    case badRequest = 2
    case unavailable = 3
    case internalError = 4
    case versionMismatch = 5
    case sessionEnded = 6
}

public struct ErrorMessage: WireMessage, Hashable {
    public static let kind = MessageKind.error
    public var code: SessionErrorCode
    /// The kind of the message that failed.
    public var failedKind: MessageKind
    public var message: String

    public init(code: SessionErrorCode, failedKind: MessageKind, message: String) {
        self.code = code
        self.failedKind = failedKind
        self.message = message
    }

    public init(from reader: inout WireReader) throws(WireError) {
        code = SessionErrorCode(rawValue: try reader.varint32()) ?? .unknown
        failedKind = MessageKind(rawValue: try reader.varint32())
        message = try reader.string(limit: 1 << 16)
    }

    public func encode(to writer: inout WireWriter) {
        writer.varint(code.rawValue)
        writer.varint(failedKind.rawValue)
        writer.string(message)
    }
}
