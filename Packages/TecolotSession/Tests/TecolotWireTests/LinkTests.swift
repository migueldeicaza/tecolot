import Testing
@testable import TecolotWire

struct LinkTests {
    static let samples: [any WireMessage] = [
        LinkHelloMessage(build: "build", clientName: "client", receiveWindow: 262_144),
        ListSessionsMessage(),
        CreateSessionMessage(json: Array("{\"command\":\"echo hi\"}".utf8)),
        TerminateSessionMessage(id: "abc", signal: -15),
        OpenChannelMessage(channel: UInt64.max, sessionID: "session", receiveWindow: 65_536),
        CloseChannelMessage(channel: 128),
        ChannelWindowMessage(channel: 1, increment: UInt64.max),
        LinkAckMessage(received: UInt64.max),
        HelperInfoMessage(build: "build", os: "Linux", arch: "aarch64", machineID: "machine",
                          hostName: "host", runtimeDirectory: "/tmp/tecolot-1000", home: "/home/user",
                          shell: "/bin/sh", receiveWindow: 262_144),
        SessionListMessage(json: Array("[]".utf8)),
        SessionCreatedMessage(json: Array("{}".utf8)),
        ChannelOpenedMessage(channel: 2, receiveWindow: 262_144),
        DirectoryDoneMessage(),
    ]

    @Test func messagesRoundTripAndRejectTruncatedFields() throws {
        for sample in Self.samples { try check(sample) }
    }

    private func check<M: WireMessage>(_ message: M) throws {
        var original = WireWriter()
        message.encode(to: &original)
        let control = LinkFrame(channel: 0, payload: EnvelopeCodec.encode(message, requestID: 7))
        var decoder = LinkFrameStreamDecoder()
        decoder.append(try LinkFrameCodec.encode(control))
        let frame = try #require(try decoder.next())
        #expect(frame == control)
        var envelopes = EnvelopeStreamDecoder()
        envelopes.append(frame.payload)
        let envelope = try #require(try envelopes.next())
        #expect(envelope.kind == M.kind)
        #expect(envelope.requestID == 7)
        let result = try envelope.decode(M.self)
        var encoded = WireWriter()
        result.encode(to: &encoded)
        #expect(encoded.bytes == original.bytes)
        for count in 0 ..< original.count {
            var reader = WireReader(Array(original.bytes.prefix(count)))
            #expect(throws: (any Error).self) { try M(from: &reader) }
        }
        var withTrailing = original
        withTrailing.string("future field")
        var reader = WireReader(withTrailing.bytes)
        var known = WireWriter()
        try M(from: &reader).encode(to: &known)
        #expect(known.bytes == original.bytes)
    }

    @Test func framesUseLittleEndianLengthAndSupportEverySplit() throws {
        let frames = [
            LinkFrame(channel: 0, payload: EnvelopeCodec.encode(PingMessage(nonce: 1))),
            LinkFrame(channel: 1, payload: [1]),
            LinkFrame(channel: UInt64.max, payload: Array(repeating: 7, count: 16_384)),
        ]
        var stream: [UInt8] = []
        for frame in frames { stream += try LinkFrameCodec.encode(frame) }
        let small = try LinkFrameCodec.encode(frames[1])
        #expect(small == [2, 0, 0, 0, 1, 1])
        for chunkSize in [1, 2, 3, 7, 16_384, stream.count] {
            var decoder = LinkFrameStreamDecoder()
            var decoded: [LinkFrame] = []
            for start in stride(from: 0, to: stream.count, by: chunkSize) {
                decoder.append(stream[start ..< min(start + chunkSize, stream.count)])
                while let frame = try decoder.next() { decoded.append(frame) }
            }
            #expect(decoded == frames)
            #expect(decoder.pendingByteCount == 0)
        }
        for frame in [frames[0], LinkFrame(channel: UInt64.max, payload: Array(repeating: 9, count: 512))] {
            let bytes = try LinkFrameCodec.encode(frame)
            for split in 0 ... bytes.count {
                var decoder = LinkFrameStreamDecoder()
                decoder.append(bytes.prefix(split))
                if split < bytes.count {
                    #expect(try decoder.next() == nil)
                    #expect(decoder.pendingByteCount == split)
                }
                decoder.append(bytes.dropFirst(split))
                #expect(try decoder.next() == frame)
            }
        }
    }

    @Test func frameLimitsAndControlEnvelopeAreChecked() throws {
        #expect(throws: WireError.lengthTooLarge(16_385)) {
            try LinkFrameCodec.encode(LinkFrame(channel: 1, payload: Array(repeating: 0, count: 16_385)))
        }
        #expect(throws: WireError.invalidValue("empty data frame")) {
            try LinkFrameCodec.encode(LinkFrame(channel: 1, payload: []))
        }
        #expect(throws: WireError.truncated) { try LinkFrameCodec.encode(LinkFrame(channel: 0, payload: [])) }
        let message = EnvelopeCodec.encode(PingMessage(nonce: 1))
        #expect(throws: WireError.invalidValue("multiple control envelopes")) {
            try LinkFrameCodec.encode(LinkFrame(channel: 0, payload: message + message))
        }
        var oversized = LinkFrameStreamDecoder(maximumFrameSize: 16)
        oversized.append([17, 0, 0, 0])
        #expect(throws: WireError.lengthTooLarge(17)) { try oversized.next() }
        var oversizedData = LinkFrameStreamDecoder()
        oversizedData.append([17, 64, 0, 0, 1])
        #expect(throws: WireError.lengthTooLarge(16_401)) { try oversizedData.next() }
        var empty = LinkFrameStreamDecoder()
        empty.append([0, 0, 0, 0])
        #expect(throws: WireError.invalidValue("link frame length 0")) { try empty.next() }
        var malformed = LinkFrameStreamDecoder()
        malformed.append([11, 0, 0, 0] + Array(repeating: 0xff, count: 11))
        #expect(throws: WireError.malformedVarint) { try malformed.next() }
        var truncatedChannel = LinkFrameStreamDecoder()
        truncatedChannel.append([1, 0, 0, 0, 0x80])
        #expect(throws: WireError.truncated) { try truncatedChannel.next() }
        var truncatedControl = LinkFrameStreamDecoder()
        truncatedControl.append([2, 0, 0, 0, 0, 0])
        #expect(throws: WireError.truncated) { try truncatedControl.next() }
    }

    @Test func messagesAndFramesAcceptGarbageWithoutCrashing() {
        var random = SplitMix64(seed: 0x11_00_55)
        for _ in 0 ..< 1000 {
            let bytes = (0 ..< Int(random.next() % 80)).map { _ in UInt8(truncatingIfNeeded: random.next()) }
            for sample in Self.samples { decodeGarbage(sample, bytes: bytes) }
            var frames = LinkFrameStreamDecoder()
            frames.append(bytes)
            while let _ = try? frames.next() {}
            var invalidVarint = LinkFrameStreamDecoder()
            invalidVarint.append([10, 0, 0, 0] + Array(repeating: 0xff, count: 10))
            #expect(throws: WireError.malformedVarint) { try invalidVarint.next() }
            let declared = UInt32(LinkFrameCodec.maximumFrameSize) + UInt32(random.next() % 1024) + 1
            var header = WireWriter()
            header.u32(declared)
            var invalidLength = LinkFrameStreamDecoder()
            invalidLength.append(header.bytes)
            #expect(throws: WireError.lengthTooLarge(Int(declared))) { try invalidLength.next() }
            var field = WireWriter()
            LinkAckMessage(received: random.next()).encode(to: &field)
            var truncated = WireReader(Array(field.bytes.prefix(Int(random.next() % UInt64(field.count)))))
            #expect(throws: WireError.truncated) { try LinkAckMessage(from: &truncated) }
        }
    }

    private func decodeGarbage<M: WireMessage>(_ message: M, bytes: [UInt8]) {
        var reader = WireReader(bytes)
        _ = try? M(from: &reader)
    }

    @Test func messageKindValuesAreStable() {
        #expect(Self.samples.map { type(of: $0).kind.rawValue } ==
                [128, 129, 130, 131, 132, 133, 134, 135, 192, 193, 194, 195, 196])
        #expect(LinkProtocol.version == 1)
        #expect(LinkProtocol.minimumVersion == 1)
    }

    @Test func helloClientInstanceIsOptionalForOlderPeers() throws {
        let current = HelloMessage(build: "build", clientName: "client", clientInstance: "pane-id")
        var writer = WireWriter()
        current.encode(to: &writer)
        var reader = WireReader(writer.bytes)
        #expect(try HelloMessage(from: &reader) == current)
        var field = WireWriter()
        field.string(current.clientInstance)
        var old = WireReader(Array(writer.bytes.dropLast(field.count)))
        #expect(try HelloMessage(from: &old).clientInstance == "")
        var incomplete = WireReader(Array(writer.bytes.dropLast()))
        #expect(throws: WireError.truncated) { try HelloMessage(from: &incomplete) }
    }
}
