//
// Envelope.swift
// TecolotWire
//
// Every message on a session stream has this layout:
//
//     [u32 length][varint kind][u8 flags][varint requestID, if flagged] payload
//
// `length` counts the bytes after the length field. The session protocol has
// no channel field: the bridge wraps whole messages when it multiplexes.
//

/// Identifies a message type. Values are never reused.
public struct MessageKind: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public var description: String { "kind(\(rawValue))" }

    // Client to helper.
    public static let hello = MessageKind(rawValue: 1)
    public static let attach = MessageKind(rawValue: 2)
    public static let detach = MessageKind(rawValue: 3)
    public static let resize = MessageKind(rawValue: 4)
    public static let setViewport = MessageKind(rawValue: 5)
    public static let frameAck = MessageKind(rawValue: 6)
    public static let fetchRows = MessageKind(rawValue: 7)
    public static let key = MessageKind(rawValue: 8)
    public static let text = MessageKind(rawValue: 9)
    public static let input = MessageKind(rawValue: 10)
    public static let mouse = MessageKind(rawValue: 11)
    public static let paste = MessageKind(rawValue: 12)
    public static let pasteApprove = MessageKind(rawValue: 13)
    public static let focus = MessageKind(rawValue: 14)
    public static let getText = MessageKind(rawValue: 15)
    public static let clipboardReply = MessageKind(rawValue: 16)
    public static let setTheme = MessageKind(rawValue: 17)
    public static let ping = MessageKind(rawValue: 18)
    public static let terminate = MessageKind(rawValue: 19)
    public static let reset = MessageKind(rawValue: 20)
    public static let search = MessageKind(rawValue: 21)
    public static let findPrompt = MessageKind(rawValue: 22)
    public static let fetchImage = MessageKind(rawValue: 23)

    // Link directory messages.
    public static let linkHello = MessageKind(rawValue: 128)
    public static let listSessions = MessageKind(rawValue: 129)
    public static let createSession = MessageKind(rawValue: 130)
    public static let terminateSession = MessageKind(rawValue: 131)
    public static let openChannel = MessageKind(rawValue: 132)
    public static let closeChannel = MessageKind(rawValue: 133)
    public static let channelWindow = MessageKind(rawValue: 134)
    public static let linkAck = MessageKind(rawValue: 135)
    public static let helperInfo = MessageKind(rawValue: 192)
    public static let sessionList = MessageKind(rawValue: 193)
    public static let sessionCreated = MessageKind(rawValue: 194)
    public static let channelOpened = MessageKind(rawValue: 195)
    public static let directoryDone = MessageKind(rawValue: 196)

    // Helper to client.
    public static let helloReply = MessageKind(rawValue: 64)
    public static let frame = MessageKind(rawValue: 65)
    public static let rows = MessageKind(rawValue: 66)
    public static let defineLinks = MessageKind(rawValue: 67)
    public static let bell = MessageKind(rawValue: 68)
    public static let clipboardCopy = MessageKind(rawValue: 69)
    public static let clipboardReadRequest = MessageKind(rawValue: 70)
    public static let processExited = MessageKind(rawValue: 71)
    public static let pasteResult = MessageKind(rawValue: 72)
    public static let textResult = MessageKind(rawValue: 73)
    public static let sessionInfo = MessageKind(rawValue: 74)
    public static let error = MessageKind(rawValue: 75)
    public static let pong = MessageKind(rawValue: 76)
    public static let searchResult = MessageKind(rawValue: 77)
    public static let promptResult = MessageKind(rawValue: 78)
    public static let imageData = MessageKind(rawValue: 79)
    public static let notification = MessageKind(rawValue: 80)
}

/// Per-message flags.
public struct EnvelopeFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// The receiver must answer `ErrorMessage(.unsupported)` when it does not
    /// know the kind, instead of ignoring the message.
    public static let required = EnvelopeFlags(rawValue: 1)
    /// A request identifier follows the flags.
    public static let hasRequestID = EnvelopeFlags(rawValue: 2)
    /// The payload is compressed (reserved; negotiated by capability).
    public static let compressed = EnvelopeFlags(rawValue: 4)
    /// More chunks follow for the same request identifier.
    public static let more = EnvelopeFlags(rawValue: 8)
}

/// A decoded message envelope. `payload` is a reader over the payload bytes.
public struct Envelope: Sendable {
    public let kind: MessageKind
    public let flags: EnvelopeFlags
    public let requestID: UInt64?
    public let payload: WireReader

    public init(kind: MessageKind, flags: EnvelopeFlags, requestID: UInt64?, payload: WireReader) {
        self.kind = kind
        self.flags = flags
        self.requestID = requestID
        self.payload = payload
    }

    /// Decodes the payload as `M`.
    public func decode<M: WireMessage>(_ type: M.Type) throws(WireError) -> M {
        var reader = payload
        return try M(from: &reader)
    }
}

/// A message type with a fixed kind and a hand-written codec.
public protocol WireMessage: Sendable {
    static var kind: MessageKind { get }
    init(from reader: inout WireReader) throws(WireError)
    func encode(to writer: inout WireWriter)
}

public enum EnvelopeCodec {
    /// Size of the length field that starts each message.
    public static let lengthFieldSize = 4

    /// Encodes `message` with its envelope and appends it to `output`.
    public static func append<M: WireMessage>(_ message: M,
                                              flags: EnvelopeFlags = [],
                                              requestID: UInt64? = nil,
                                              to output: inout WireWriter) {
        let lengthOffset = output.count
        output.u32(0)
        output.varint(UInt64(M.kind.rawValue))
        var flags = flags
        if requestID != nil { flags.insert(.hasRequestID) } else { flags.remove(.hasRequestID) }
        output.u8(flags.rawValue)
        if let requestID { output.varint(requestID) }
        message.encode(to: &output)
        let length = output.count - lengthOffset - lengthFieldSize
        output.patchU32(UInt32(length), at: lengthOffset)
    }

    /// Encodes `message` with its envelope into a new byte array.
    public static func encode<M: WireMessage>(_ message: M,
                                              flags: EnvelopeFlags = [],
                                              requestID: UInt64? = nil) -> [UInt8] {
        var writer = WireWriter()
        append(message, flags: flags, requestID: requestID, to: &writer)
        return writer.bytes
    }

    /// Decodes the envelope header of one complete message body (the bytes
    /// after the length field).
    public static func decodeBody(_ bytes: [UInt8], range: Range<Int>) throws(WireError) -> Envelope {
        var reader = WireReader(bytes, range: range)
        let kind = try reader.varint32()
        let flags = EnvelopeFlags(rawValue: try reader.u8())
        var requestID: UInt64?
        if flags.contains(.hasRequestID) {
            requestID = try reader.varint()
        }
        return Envelope(kind: MessageKind(rawValue: kind), flags: flags,
                        requestID: requestID, payload: reader)
    }
}

/// Splits a byte stream into complete messages.
///
/// The decoder copies each complete message body out of its internal buffer,
/// so the returned envelopes stay valid after more data arrives.
public struct EnvelopeStreamDecoder: Sendable {
    public let maximumMessageSize: Int
    private var buffer: [UInt8] = []
    private var start = 0

    public init(maximumMessageSize: Int = 32 * 1024 * 1024) {
        self.maximumMessageSize = maximumMessageSize
    }

    /// The number of buffered bytes that do not form a complete message yet.
    public var pendingByteCount: Int { buffer.count - start }

    public mutating func append<C: Collection>(_ bytes: C) where C.Element == UInt8 {
        if start > 0 && start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
        }
        buffer.append(contentsOf: bytes)
    }

    /// Returns the next complete message, or nil when more bytes are needed.
    public mutating func next() throws(WireError) -> Envelope? {
        let available = buffer.count - start
        guard available >= EnvelopeCodec.lengthFieldSize else {
            compact()
            return nil
        }
        var length = 0
        for index in 0 ..< 4 {
            length |= Int(buffer[start + index]) << (index * 8)
        }
        guard length <= maximumMessageSize else { throw .lengthTooLarge(length) }
        guard length >= 2 else { throw .invalidValue("envelope length \(length)") }
        guard available >= EnvelopeCodec.lengthFieldSize + length else {
            compact()
            return nil
        }
        let bodyStart = start + EnvelopeCodec.lengthFieldSize
        let body = Array(buffer[bodyStart ..< bodyStart + length])
        start = bodyStart + length
        return try EnvelopeCodec.decodeBody(body, range: 0 ..< body.count)
    }

    private mutating func compact() {
        if start > 0 && start * 2 >= buffer.count {
            buffer.removeSubrange(0 ..< start)
            start = 0
        }
    }
}
