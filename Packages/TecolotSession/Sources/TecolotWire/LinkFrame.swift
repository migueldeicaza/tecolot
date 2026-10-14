// Each link frame is [u32 length][varint channel][payload].
// Channel 0 holds one complete session envelope. Other channels hold bytes.

public enum LinkProtocol {
    public static let version: UInt32 = 1
    public static let minimumVersion: UInt32 = 1
}

public struct LinkFrame: Hashable, Sendable {
    public var channel: UInt64
    public var payload: [UInt8]

    public init(channel: UInt64, payload: [UInt8]) {
        self.channel = channel
        self.payload = payload
    }
}

public enum LinkFrameCodec {
    public static let lengthFieldSize = 4
    public static let maximumDataSize = 16_384
    public static let maximumFrameSize = 32 * 1024 * 1024

    public static func append(_ frame: LinkFrame, to output: inout WireWriter) throws(WireError) {
        try validate(frame)
        var body = WireWriter(capacity: frame.payload.count + 10)
        body.varint(frame.channel)
        body.raw(frame.payload)
        guard body.count <= maximumFrameSize else { throw .lengthTooLarge(body.count) }
        output.u32(UInt32(body.count))
        output.raw(body.bytes)
    }

    public static func encode(_ frame: LinkFrame) throws(WireError) -> [UInt8] {
        var writer = WireWriter(capacity: frame.payload.count + 14)
        try append(frame, to: &writer)
        return writer.bytes
    }

    static func validate(_ frame: LinkFrame) throws(WireError) {
        if frame.channel == 0 {
            // The control payload includes the envelope's own length field.
            var decoder = EnvelopeStreamDecoder(maximumMessageSize: maximumFrameSize)
            decoder.append(frame.payload)
            guard try decoder.next() != nil else { throw .truncated }
            guard decoder.pendingByteCount == 0 else { throw .invalidValue("multiple control envelopes") }
        } else {
            guard !frame.payload.isEmpty else { throw .invalidValue("empty data frame") }
            guard frame.payload.count <= maximumDataSize else { throw .lengthTooLarge(frame.payload.count) }
        }
    }
}

/// Keeps partial bytes until a complete link frame is available.
public struct LinkFrameStreamDecoder: Sendable {
    public let maximumFrameSize: Int
    private var buffer: [UInt8] = []
    private var start = 0

    public init(maximumFrameSize: Int = LinkFrameCodec.maximumFrameSize) {
        precondition(maximumFrameSize >= 0)
        self.maximumFrameSize = maximumFrameSize
    }

    public var pendingByteCount: Int { buffer.count - start }

    public mutating func append<C: Collection>(_ bytes: C) where C.Element == UInt8 {
        if start > 0 && start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
        }
        buffer.append(contentsOf: bytes)
    }

    public mutating func next() throws(WireError) -> LinkFrame? {
        let available = pendingByteCount
        guard available >= LinkFrameCodec.lengthFieldSize else {
            compact()
            return nil
        }
        var reader = WireReader(buffer, range: start ..< buffer.count)
        let length = Int(try reader.u32())
        guard length <= maximumFrameSize else { throw .lengthTooLarge(length) }
        guard length > 0 else { throw .invalidValue("link frame length 0") }
        let bodyStart = start + LinkFrameCodec.lengthFieldSize
        let bodyEnd = bodyStart + length
        var body = WireReader(buffer, range: bodyStart ..< min(bodyEnd, buffer.count))
        let channel: UInt64
        do {
            channel = try body.varint()
        } catch .truncated where buffer.count < bodyEnd {
            compact()
            return nil
        }
        if channel != 0 {
            guard length <= LinkFrameCodec.maximumDataSize + 16 else { throw .lengthTooLarge(length) }
            let payloadSize = length - (body.offset - bodyStart)
            guard payloadSize <= LinkFrameCodec.maximumDataSize else { throw .lengthTooLarge(payloadSize) }
            guard payloadSize > 0 else { throw .invalidValue("empty data frame") }
        }
        guard buffer.count >= bodyEnd else {
            compact()
            return nil
        }
        let frame = LinkFrame(channel: channel, payload: Array(buffer[body.offset ..< bodyEnd]))
        try LinkFrameCodec.validate(frame)
        start = bodyEnd
        return frame
    }

    private mutating func compact() {
        if start > 0 && start * 2 >= buffer.count {
            buffer.removeSubrange(0 ..< start)
            start = 0
        }
    }
}
