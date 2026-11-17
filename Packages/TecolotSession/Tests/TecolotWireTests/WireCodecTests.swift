import Testing
@testable import TecolotWire

struct WireCodecTests {
    @Test func varintRoundTrip() throws {
        let values: [UInt64] = [0, 1, 127, 128, 255, 16_383, 16_384, 1 << 32, UInt64.max - 1, UInt64.max]
        var writer = WireWriter()
        for value in values { writer.varint(value) }
        var reader = WireReader(writer.bytes)
        for value in values { #expect(try reader.varint() == value) }
        #expect(reader.isAtEnd)
    }

    @Test func signedVarintRoundTrip() throws {
        let values: [Int64] = [0, -1, 1, -64, 63, Int64.min, Int64.max, -123_456_789]
        var writer = WireWriter()
        for value in values { writer.svarint(value) }
        var reader = WireReader(writer.bytes)
        for value in values { #expect(try reader.svarint() == value) }
    }

    @Test func malformedVarintThrows() {
        var reader = WireReader(Array(repeating: 0xff, count: 11))
        #expect(throws: WireError.malformedVarint) { try reader.varint() }
        var truncated = WireReader([0x80, 0x80])
        #expect(throws: WireError.truncated) { try truncated.varint() }
    }

    @Test func fixedWidthIntegers() throws {
        var writer = WireWriter()
        writer.u16(0xBEEF)
        writer.u32(0xDEAD_BEEF)
        writer.u64(0x0123_4567_89AB_CDEF)
        #expect(writer.bytes.prefix(2) == [0xEF, 0xBE])
        var reader = WireReader(writer.bytes)
        #expect(try reader.u16() == 0xBEEF)
        #expect(try reader.u32() == 0xDEAD_BEEF)
        #expect(try reader.u64() == 0x0123_4567_89AB_CDEF)
    }

    @Test func stringsAndBlobs() throws {
        var writer = WireWriter()
        writer.string("héllo 🦉")
        writer.optionalString(nil)
        writer.optionalString("x")
        writer.blob([1, 2, 3])
        var reader = WireReader(writer.bytes)
        #expect(try reader.string() == "héllo 🦉")
        #expect(try reader.optionalString() == nil)
        #expect(try reader.optionalString() == "x")
        #expect(try reader.blob() == [1, 2, 3])
    }

    @Test func invalidUTF8Throws() {
        var reader = WireReader([2, 0xC3, 0x28])
        #expect(throws: WireError.invalidUTF8) { try reader.string() }
    }

    @Test func lengthLimitIsEnforced() {
        var writer = WireWriter()
        writer.varint(UInt64(1000))
        var reader = WireReader(writer.bytes)
        #expect(throws: WireError.lengthTooLarge(1000)) { try reader.blob(limit: 10) }
    }

    @Test func nestedReaderStaysInsideItsRange() throws {
        var writer = WireWriter()
        writer.nested { inner in
            inner.varint(UInt64(7))
            inner.string("inside")
        }
        writer.string("after")
        var reader = WireReader(writer.bytes)
        var nested = try reader.nested()
        #expect(try nested.varint() == 7)
        #expect(try nested.string() == "inside")
        #expect(nested.isAtEnd)
        #expect(try reader.string() == "after")
    }

    @Test func hashIsStableAndSensitive() {
        let a: [UInt8] = Array("the quick brown fox".utf8)
        var b = a
        b[3] ^= 1
        #expect(WireHash.hash64(a) == WireHash.hash64(a))
        #expect(WireHash.hash64(a) != WireHash.hash64(b))
        #expect(WireHash.hash64([]) != WireHash.hash64([0]))
        // Lengths that exercise the 8-, 4- and 1-byte paths.
        var seen = Set<UInt64>()
        for length in 0 ..< 40 {
            seen.insert(WireHash.hash64(Array(repeating: 0, count: length)))
        }
        #expect(seen.count == 40)
    }
}

struct EnvelopeTests {
    @Test func streamDecoderReassemblesSplitMessages() throws {
        var stream: [UInt8] = []
        stream += EnvelopeCodec.encode(PingMessage(nonce: 42))
        stream += EnvelopeCodec.encode(TextMessage(text: "hello"), requestID: 9)
        stream += EnvelopeCodec.encode(FocusMessage(focused: true), flags: .required)

        for chunkSize in [1, 2, 3, 7, stream.count] {
            var decoder = EnvelopeStreamDecoder()
            var envelopes: [Envelope] = []
            var index = 0
            while index < stream.count {
                let end = min(index + chunkSize, stream.count)
                decoder.append(stream[index ..< end])
                while let envelope = try decoder.next() { envelopes.append(envelope) }
                index = end
            }
            #expect(envelopes.count == 3)
            #expect(envelopes[0].kind == .ping)
            #expect(try envelopes[0].decode(PingMessage.self).nonce == 42)
            #expect(envelopes[1].requestID == 9)
            #expect(try envelopes[1].decode(TextMessage.self).text == "hello")
            #expect(envelopes[2].flags.contains(.required))
            #expect(try envelopes[2].decode(FocusMessage.self).focused)
            #expect(decoder.pendingByteCount == 0)
        }
    }

    @Test func oversizedMessageIsRejected() {
        var decoder = EnvelopeStreamDecoder(maximumMessageSize: 16)
        decoder.append(EnvelopeCodec.encode(TextMessage(text: String(repeating: "x", count: 100))))
        #expect(throws: WireError.lengthTooLarge(103)) { try decoder.next() }
    }

    @Test func unknownTrailingFieldsAreIgnored() throws {
        // A newer peer appends a field; an older decoder must still read the message.
        var writer = WireWriter()
        FocusMessage(focused: true).encode(to: &writer)
        writer.string("a field from the future")
        var reader = WireReader(writer.bytes)
        #expect(try FocusMessage(from: &reader).focused)
    }
}
