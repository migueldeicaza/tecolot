// Control messages for channel 0. JSON fields contain launch or record bytes.
// Fields follow the same append-only rule as session messages.

public struct LinkHelloMessage: WireMessage, Hashable {
    public static let kind = MessageKind.linkHello
    public var minimumVersion: UInt32
    public var maximumVersion: UInt32
    public var build: String
    public var clientName: String
    public var receiveWindow: UInt64

    public init(minimumVersion: UInt32 = LinkProtocol.minimumVersion,
                maximumVersion: UInt32 = LinkProtocol.version, build: String, clientName: String,
                receiveWindow: UInt64) {
        self.minimumVersion = minimumVersion
        self.maximumVersion = maximumVersion
        self.build = build
        self.clientName = clientName
        self.receiveWindow = receiveWindow
    }

    public init(from reader: inout WireReader) throws(WireError) {
        minimumVersion = try reader.u32()
        maximumVersion = try reader.u32()
        build = try reader.string()
        clientName = try reader.string()
        receiveWindow = try reader.varint()
    }

    public func encode(to writer: inout WireWriter) {
        writer.u32(minimumVersion)
        writer.u32(maximumVersion)
        writer.string(build)
        writer.string(clientName)
        writer.varint(receiveWindow)
    }
}

public struct ListSessionsMessage: WireMessage, Hashable {
    public static let kind = MessageKind.listSessions

    public init() {
    }

    public init(from reader: inout WireReader) throws(WireError) {
    }

    public func encode(to writer: inout WireWriter) {
    }
}

public struct CreateSessionMessage: WireMessage, Hashable {
    public static let kind = MessageKind.createSession
    public var json: [UInt8]

    public init(json: [UInt8]) {
        self.json = json
    }

    public init(from reader: inout WireReader) throws(WireError) {
        json = try reader.blob()
    }

    public func encode(to writer: inout WireWriter) {
        writer.blob(json)
    }
}

public struct TerminateSessionMessage: WireMessage, Hashable {
    public static let kind = MessageKind.terminateSession
    public var id: String
    public var signal: Int32

    public init(id: String, signal: Int32) {
        self.id = id
        self.signal = signal
    }

    public init(from reader: inout WireReader) throws(WireError) {
        id = try reader.string()
        let rawSignal = try reader.svarint()
        guard let value = Int32(exactly: rawSignal) else { throw .invalidValue("signal \(rawSignal)") }
        signal = value
    }

    public func encode(to writer: inout WireWriter) {
        writer.string(id)
        writer.svarint(Int64(signal))
    }
}

public struct OpenChannelMessage: WireMessage, Hashable {
    public static let kind = MessageKind.openChannel
    public var channel: UInt64
    public var sessionID: String
    public var receiveWindow: UInt64

    public init(channel: UInt64, sessionID: String, receiveWindow: UInt64) {
        self.channel = channel
        self.sessionID = sessionID
        self.receiveWindow = receiveWindow
    }

    public init(from reader: inout WireReader) throws(WireError) {
        channel = try reader.varint()
        sessionID = try reader.string()
        receiveWindow = try reader.varint()
    }

    public func encode(to writer: inout WireWriter) {
        writer.varint(channel)
        writer.string(sessionID)
        writer.varint(receiveWindow)
    }
}

public struct CloseChannelMessage: WireMessage, Hashable {
    public static let kind = MessageKind.closeChannel
    public var channel: UInt64

    public init(channel: UInt64) {
        self.channel = channel
    }

    public init(from reader: inout WireReader) throws(WireError) {
        channel = try reader.varint()
    }

    public func encode(to writer: inout WireWriter) {
        writer.varint(channel)
    }
}

public struct ChannelWindowMessage: WireMessage, Hashable {
    public static let kind = MessageKind.channelWindow
    public var channel: UInt64
    public var increment: UInt64

    public init(channel: UInt64, increment: UInt64) {
        self.channel = channel
        self.increment = increment
    }

    public init(from reader: inout WireReader) throws(WireError) {
        channel = try reader.varint()
        increment = try reader.varint()
    }

    public func encode(to writer: inout WireWriter) {
        writer.varint(channel)
        writer.varint(increment)
    }
}

public struct LinkAckMessage: WireMessage, Hashable {
    public static let kind = MessageKind.linkAck
    public var received: UInt64

    public init(received: UInt64) {
        self.received = received
    }

    public init(from reader: inout WireReader) throws(WireError) {
        received = try reader.u64()
    }

    public func encode(to writer: inout WireWriter) {
        writer.u64(received)
    }
}

public struct HelperInfoMessage: WireMessage, Hashable {
    public static let kind = MessageKind.helperInfo
    public var version: UInt32
    public var build: String
    public var os: String
    public var arch: String
    public var machineID: String
    public var hostName: String
    public var runtimeDirectory: String
    public var home: String
    public var shell: String
    public var receiveWindow: UInt64

    public init(version: UInt32 = LinkProtocol.version, build: String, os: String, arch: String,
                machineID: String, hostName: String, runtimeDirectory: String, home: String,
                shell: String, receiveWindow: UInt64) {
        self.version = version
        self.build = build
        self.os = os
        self.arch = arch
        self.machineID = machineID
        self.hostName = hostName
        self.runtimeDirectory = runtimeDirectory
        self.home = home
        self.shell = shell
        self.receiveWindow = receiveWindow
    }

    public init(from reader: inout WireReader) throws(WireError) {
        version = try reader.u32()
        build = try reader.string()
        os = try reader.string()
        arch = try reader.string()
        machineID = try reader.string()
        hostName = try reader.string()
        runtimeDirectory = try reader.string()
        home = try reader.string()
        shell = try reader.string()
        receiveWindow = try reader.varint()
    }

    public func encode(to writer: inout WireWriter) {
        writer.u32(version)
        writer.string(build)
        writer.string(os)
        writer.string(arch)
        writer.string(machineID)
        writer.string(hostName)
        writer.string(runtimeDirectory)
        writer.string(home)
        writer.string(shell)
        writer.varint(receiveWindow)
    }
}

public struct SessionListMessage: WireMessage, Hashable {
    public static let kind = MessageKind.sessionList
    public var json: [UInt8]

    public init(json: [UInt8]) {
        self.json = json
    }

    public init(from reader: inout WireReader) throws(WireError) {
        json = try reader.blob()
    }

    public func encode(to writer: inout WireWriter) {
        writer.blob(json)
    }
}

public struct SessionCreatedMessage: WireMessage, Hashable {
    public static let kind = MessageKind.sessionCreated
    public var json: [UInt8]

    public init(json: [UInt8]) {
        self.json = json
    }

    public init(from reader: inout WireReader) throws(WireError) {
        json = try reader.blob()
    }

    public func encode(to writer: inout WireWriter) {
        writer.blob(json)
    }
}

public struct ChannelOpenedMessage: WireMessage, Hashable {
    public static let kind = MessageKind.channelOpened
    public var channel: UInt64
    public var receiveWindow: UInt64

    public init(channel: UInt64, receiveWindow: UInt64) {
        self.channel = channel
        self.receiveWindow = receiveWindow
    }

    public init(from reader: inout WireReader) throws(WireError) {
        channel = try reader.varint()
        receiveWindow = try reader.varint()
    }

    public func encode(to writer: inout WireWriter) {
        writer.varint(channel)
        writer.varint(receiveWindow)
    }
}

public struct DirectoryDoneMessage: WireMessage, Hashable {
    public static let kind = MessageKind.directoryDone

    public init() {
    }

    public init(from reader: inout WireReader) throws(WireError) {
    }

    public func encode(to writer: inout WireWriter) {
    }
}

/// Asks for the durable states of the sessions that the system ended on
/// the host (spec-restoration.md section 6.4). An older bridge answers
/// with an `unsupported` error.
public struct ListEndedSessionsMessage: WireMessage, Hashable {
    public static let kind = MessageKind.listEndedSessions

    public init() {
    }

    public init(from reader: inout WireReader) throws(WireError) {
    }

    public func encode(to writer: inout WireWriter) {
    }
}

/// The reply to ListEndedSessions: a JSON array of durable states, without
/// their launch environment.
public struct EndedSessionListMessage: WireMessage, Hashable {
    public static let kind = MessageKind.endedSessionList
    public var json: [UInt8]

    public init(json: [UInt8]) {
        self.json = json
    }

    public init(from reader: inout WireReader) throws(WireError) {
        json = try reader.blob()
    }

    public func encode(to writer: inout WireWriter) {
        writer.blob(json)
    }
}

/// Deletes the durable state of an ended session. The reply is DirectoryDone.
public struct DeleteEndedSessionMessage: WireMessage, Hashable {
    public static let kind = MessageKind.deleteEndedSession
    public var id: String

    public init(id: String) {
        self.id = id
    }

    public init(from reader: inout WireReader) throws(WireError) {
        id = try reader.string()
    }

    public func encode(to writer: inout WireWriter) {
        writer.string(id)
    }
}

/// The bridge handshake values.
public typealias HelperInfo = HelperInfoMessage
