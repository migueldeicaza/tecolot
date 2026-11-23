/// OSC 7501 snapshots travel independently of rendering and frame credits.
/// New message kinds are optional under protocol v1; older peers ignore them.
public struct ProgramStatusMessage: WireMessage {
    /// The optional envelope kind, sent only after capability negotiation.
    public static let kind = MessageKind.programStatus
    /// The bounded record snapshot, or the exact versions to clear in a clear request.
    public var records: [WireProgramStatus]
    /// Whether native program reports have superseded legacy progress since the last reset.
    public var uses7501: Bool
    /// Changes at RIS so clients can clear their presentation and resume the legacy fallback.
    public var resetSerial: UInt64
    /// The most recent legacy progress report, independent of native records.
    public var progress: WireProgress?
    /// An optional trailing output version; old senders omit it and old readers ignore it.
    public var outputSerial: UInt64 = 0
    /// The legacy report version used for seen completion clearing; old senders omit it.
    public var progressReportTime: UInt64 = 0

    /// Builds an optional status snapshot without consuming frame credits.
    public init(
        records: [WireProgramStatus], uses7501: Bool = true, resetSerial: UInt64 = 0,
        progress: WireProgress? = nil
    ) {
        self.records = records
        self.uses7501 = uses7501
        self.resetSerial = resetSerial
        self.progress = progress
    }
    /// Decodes bounded fields and optional trailing extensions for protocol-v1 compatibility.
    public init(from reader: inout WireReader) throws(WireError) {
        uses7501 = try reader.bool()
        resetSerial = try reader.u64()
        records = try reader.array(limit: 256) { reader throws(WireError) in
            try WireProgramStatus(from: &reader)
        }
        progress = try reader.bool() ? WireProgress(from: &reader) : nil
        outputSerial = reader.isAtEnd ? 0 : try reader.u64()
        progressReportTime = reader.isAtEnd ? 0 : try reader.u64()
    }
    /// Encodes this optional message or record; message delivery is capability gated.
    public func encode(to writer: inout WireWriter) {
        writer.bool(uses7501)
        writer.u64(resetSerial)
        writer.array(records) {
            $1.encode(to: &$0)
        }
        writer.bool(progress != nil)
        progress?.encode(to: &writer)
        writer.u64(outputSerial)
        writer.u64(progressReportTime)
    }
}

/// The protocol states understood by this peer; unknown native states are skipped by the host.
public enum ProgramStatusState: String, CaseIterable, Sendable, Codable {
    case idle, working, done, error, blocked
    /// Orders program states for pane-to-tab reduction.
    public var priority: Int {
        switch self {
        case .idle:
            0
        case .working:
            1
        case .done:
            2
        case .error:
            3
        case .blocked:
            4
        }
    }
    /// Whether the report survives shell prompts and process exit.
    public var isCompletion: Bool {
        self == .done || self == .error
    }
}

/// Report time is assigned by the emulator host and stays stable over reattach.
public struct WireProgramStatus: Equatable, Sendable {
    /// The validated hierarchical protocol id; the empty string identifies the root.
    public var id: String
    /// The state understood by this protocol peer.
    public var state: ProgramStatusState
    /// The optional blocked reason used for glyphs and accessible announcements.
    public var kind: String?
    /// An optional determinate percentage from zero through one hundred.
    public var progress: Int?
    /// An optional application identity, inherited from ancestors by the host.
    public var app: String?
    /// The optional short program title, bounded during decoding.
    public var title: String?
    /// The optional display message, bounded during decoding and sanitized before presentation.
    public var message: String?
    /// A monotonic host-assigned report version, stable across client reattachment.
    public var reportTime: UInt64

    /// Builds one versioned report for transport independently of rendering.
    public init(
        id: String = "", state: ProgramStatusState, kind: String? = nil, progress: Int? = nil,
        app: String? = nil, title: String? = nil, message: String? = nil, reportTime: UInt64 = 0
    ) {
        self.id = id
        self.state = state
        self.kind = kind
        self.progress = progress
        self.app = app
        self.title = title
        self.message = message
        self.reportTime = reportTime
    }
    /// Decodes bounded fields and optional trailing extensions for protocol-v1 compatibility.
    public init(from reader: inout WireReader) throws(WireError) {
        id = try reader.string(limit: 128)
        guard let state = ProgramStatusState(rawValue: try reader.string(limit: 16)) else {
            throw .invalidValue("program status state")
        }
        self.state = state
        kind = try reader.bool() ? reader.string(limit: 16) : nil
        let value = try reader.u8()
        progress = value <= 100 ? Int(value) : nil
        app = try reader.bool() ? reader.string(limit: 32) : nil
        title = try reader.bool() ? reader.string(limit: 192) : nil
        message = try reader.bool() ? reader.string(limit: 2048) : nil
        reportTime = try reader.u64()
        guard
            (kind?.utf8.count ?? 0) <= 16, (app?.utf8.count ?? 0) <= 32,
            (title?.utf8.count ?? 0) <= 192, (message?.utf8.count ?? 0) <= 2048
        else {
            throw .invalidValue("program status text length")
        }
    }
    /// Encodes this optional message or record; message delivery is capability gated.
    public func encode(to writer: inout WireWriter) {
        writer.string(id)
        writer.string(state.rawValue)
        writer.optionalString(kind)
        writer.u8(progress.map {
            UInt8(clamping: $0)
        } ?? 255)
        writer.optionalString(app)
        writer.optionalString(title)
        writer.optionalString(message)
        writer.u64(reportTime)
    }
}

/// Removing seen completions is conditional on report time: an intervening
/// report must not be deleted by a delayed keystroke from a client.
/// Sent only to programStatus-capable helpers; older helpers ignore the unknown kind.
public struct ClearProgramStatusMessage: WireMessage {
    /// The optional envelope kind, sent only after capability negotiation.
    public static let kind = MessageKind.clearProgramStatus
    /// The bounded record snapshot, or the exact versions to clear in a clear request.
    public var records: [WireProgramStatus]
    /// Builds a version-conditional clear request for seen completions.
    public init(records: [WireProgramStatus]) {
        self.records = records
    }
    /// Decodes bounded fields and optional trailing extensions for protocol-v1 compatibility.
    public init(from reader: inout WireReader) throws(WireError) {
        records = try reader.array(limit: 256) { reader throws(WireError) in
            try WireProgramStatus(from: &reader)
        }
    }
    /// Encodes this optional message or record; message delivery is capability gated.
    public func encode(to writer: inout WireWriter) {
        writer.array(records) {
            $1.encode(to: &$0)
        }
    }
}

/// Zero suspends frames, leaving event delivery and attachment intact.
/// Sent only to statusOnly-capable helpers; older helpers ignore the unknown kind.
public struct SetFrameRateMessage: WireMessage {
    /// The optional envelope kind, sent only after capability negotiation.
    public static let kind = MessageKind.setFrameRate
    /// Zero suspends frames while status and notification events continue.
    public var maximumFramesPerSecond: Int
    /// Builds a frame-rate change without replacing the current attachment.
    public init(_ value: Int) {
        maximumFramesPerSecond = value
    }
    /// Decodes bounded fields and optional trailing extensions for protocol-v1 compatibility.
    public init(from reader: inout WireReader) throws(WireError) {
        maximumFramesPerSecond = try reader.count(limit: 240)
    }
    /// Encodes this optional message or record; message delivery is capability gated.
    public func encode(to writer: inout WireWriter) {
        writer.varint(maximumFramesPerSecond)
    }
}

/// How often a client needs `SessionInfoMessage` reports.
public enum InfoReportMode: UInt8, Sendable, Hashable {
    /// No reports. The helper does not poll for this client.
    case off = 0
    /// Reports every five seconds, for the busy check and the Sessions window.
    case background = 1
    /// Reports every second, for visible tab icons and pane headers.
    case live = 2
}

/// Tells the helper how often this client needs `SessionInfoMessage`.
/// When all attached clients send `off`, the helper stops its poll.
/// Sent only to infoReports-capable helpers; older helpers ignore the unknown kind.
public struct SetInfoReportsMessage: WireMessage, Hashable {
    /// The optional envelope kind, sent only after capability negotiation.
    public static let kind = MessageKind.setInfoReports
    /// The report rate that this client needs.
    public var mode: InfoReportMode
    /// Builds a request to change the report rate.
    public init(mode: InfoReportMode) {
        self.mode = mode
    }
    /// Decodes the mode. An unknown mode from a newer client is `live`.
    public init(from reader: inout WireReader) throws(WireError) {
        mode = InfoReportMode(rawValue: try reader.u8()) ?? .live
    }
    /// Encodes the mode.
    public func encode(to writer: inout WireWriter) {
        writer.u8(mode.rawValue)
    }
}
