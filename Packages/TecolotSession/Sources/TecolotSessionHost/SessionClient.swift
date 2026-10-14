//
// SessionClient.swift
// TecolotSessionHost
//
// The helper's state for one connected client. Every member is confined to
// the session queue.
//

import Dispatch
import TecolotTransport
import TecolotWire

/// `@unchecked Sendable`: every member is used only on the session queue.
final class SessionClient: @unchecked Sendable {
    let channel: MessageChannel
    var negotiatedVersion: UInt32?
    var retainMargin = 256
    var attached = false
    var size = WireGridSize(columns: 80, rows: 24)
    var maximumFramesPerSecond = 60
    var viewer = false
    var focused = false
    /// Device pixels per point, in hundredths; 0 when the client did not say.
    var scale = 0
    var lastInput: DispatchTime = .init(uptimeNanoseconds: 0)

    // Viewport.
    var follow = true
    var anchor: Int64 = 0

    // What the client has: absolute line to row version, for one buffer and epoch.
    var rowVersions: [Int64: UInt64] = [:]
    var rowsBuffer: WireBuffer = .normal
    var rowsEpoch: UInt64 = .max
    var sentLinks = Set<UInt32>()

    // Flow control.
    static let maximumCredits = 2
    static let byteBudget = 4 * 1024 * 1024
    var credits = SessionClient.maximumCredits
    var inFlight: [(sequence: UInt64, bytes: Int)] = []
    var bytesInFlight: Int { inFlight.reduce(0) { $0 + $1.bytes } }
    var nextFrameAt: DispatchTime = .init(uptimeNanoseconds: 0)
    var boostUntil: DispatchTime = .init(uptimeNanoseconds: 0)
    var sequence: UInt64 = 0

    // What the client has seen.
    var needsFrame = true
    var seenFeed: UInt64 = .max
    var seenLatched: UInt64 = .max
    var seenTitle: UInt64 = 0
    var seenIconTitle: UInt64 = 0
    var seenDirectory: UInt64 = 0
    var seenColors: UInt64 = 0
    var seenProgress: UInt64 = 0
    var seenReverse: Bool?
    var lastCursor: WireCursor?
    var lastModes: WireModes?
    var lastGeometry: Geometry?
    var lastKitty: WireKittyState?
    var sentParagraphRows: Int?

    // Bulk requests, in arrival order.
    var bulk: [BulkRequest] = []

    struct Geometry: Equatable {
        var buffer: WireBuffer
        var epoch: UInt64
        var first: Int64
        var end: Int64
        var viewTop: Int64
        var columns: Int
        var rows: Int
    }

    enum BulkRequest {
        case fetch(FetchRowsMessage, requestID: UInt64?, next: Int64, end: Int64)
    }

    init(channel: MessageChannel) {
        self.channel = channel
    }

    /// Clears the row record when the client's view moves to another buffer or epoch.
    func resetRowsIfNeeded(buffer: WireBuffer, epoch: UInt64) {
        if rowsBuffer != buffer || rowsEpoch != epoch {
            rowVersions.removeAll(keepingCapacity: true)
            rowsBuffer = buffer
            rowsEpoch = epoch
        }
    }

    /// Forgets rows outside the retention window `[top - M, top + rows + M)`.
    func pruneRows(viewTop: Int64, rows: Int) {
        let low = viewTop - Int64(retainMargin)
        let high = viewTop + Int64(rows + retainMargin)
        if rowVersions.count > rows + 2 * retainMargin {
            rowVersions = rowVersions.filter { $0.key >= low && $0.key < high }
        }
    }
}
