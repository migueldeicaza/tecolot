import Testing
@testable import TecolotWire

struct ProgramStatusWireTests {
    @Test func roundTripAndOptionalCompatibility() throws {
        let record = WireProgramStatus(
            id: "agent/build",
            state: .blocked,
            kind: "permission",
            progress: 40,
            app: "claude-code",
            title: "Build",
            message: "Run tests?",
            reportTime: 12345
        )
        var message = ProgramStatusMessage(records: [record], resetSerial: 2, progress: WireProgress(state: 1, progress: 40))
        message.outputSerial = 123
        message.progressReportTime = 456
        var stream = EnvelopeStreamDecoder()
        stream.append(EnvelopeCodec.encode(message))
        stream.append(EnvelopeCodec.encode(PingMessage(nonce: 77)))
        let firstEnvelope = try stream.next()
        let envelope = try #require(firstEnvelope)
        #expect(!envelope.flags.contains(.required)) // a v1 reader may skip this whole message
        let decoded = try envelope.decode(ProgramStatusMessage.self)
        #expect(decoded.records == [record] && decoded.uses7501 && decoded.resetSerial == 2)
        #expect(decoded.progress?.progress == 40 && decoded.outputSerial == 123 && decoded.progressReportTime == 456)
        let next = try stream.next()
        #expect(try next?.decode(PingMessage.self).nonce == 77)
        var clear = EnvelopeStreamDecoder()
        clear.append(EnvelopeCodec.encode(ClearProgramStatusMessage(records: [record])))
        let clearEnvelope = try clear.next()
        #expect(try clearEnvelope?.decode(ClearProgramStatusMessage.self).records == [record])
        #expect(SessionProtocol.version == 1 && SessionProtocol.minimumVersion == 1)
    }
    @Test func boundedRecordCount() throws {
        var writer = WireWriter()
        writer.bool(true)
        writer.u64(0)
        writer.varint(257)
        var reader = WireReader(writer.bytes)
        #expect(throws: WireError.self) { try ProgramStatusMessage(from: &reader) }
    }
    @Test func zeroFrameRateRoundTrip() throws {
        var writer = WireWriter()
        SetFrameRateMessage(0).encode(to: &writer)
        var reader = WireReader(writer.bytes)
        #expect(try SetFrameRateMessage(from: &reader).maximumFramesPerSecond == 0)
    }
}
