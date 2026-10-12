//
// WireCodec.swift
// TecolotWire
//
// The primitive codec for the session protocol. Both ends of the protocol
// ship from this repository, so the format is a hand-written little-endian
// binary encoding instead of a self-describing format such as CBOR or JSON.
//
// Rules that keep old and new peers compatible:
// - Fields are only appended at the end of a payload.
// - Decoders ignore bytes that remain after the fields they know.
// - Optional trailing fields use `WireReader.isAtEnd` to detect absence.
//

/// An error raised while decoding untrusted wire data.
public enum WireError: Error, Equatable, Sendable {
    /// The input ended before a complete value.
    case truncated
    /// A variable-length integer used more than ten bytes or overflowed.
    case malformedVarint
    /// A length prefix exceeded the allowed limit.
    case lengthTooLarge(Int)
    /// A string was not valid UTF-8.
    case invalidUTF8
    /// A value was outside the range that the field allows.
    case invalidValue(String)
}

/// Appends wire values to a growable byte buffer.
public struct WireWriter: Sendable {
    public private(set) var bytes: [UInt8]

    public init(capacity: Int = 64) {
        bytes = []
        bytes.reserveCapacity(capacity)
    }

    public var count: Int { bytes.count }

    @inline(__always)
    public mutating func u8(_ value: UInt8) {
        bytes.append(value)
    }

    public mutating func bool(_ value: Bool) {
        bytes.append(value ? 1 : 0)
    }

    public mutating func u16(_ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    public mutating func u32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    public mutating func u64(_ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    /// Writes an unsigned LEB128 integer.
    @inline(__always)
    public mutating func varint(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            bytes.append(UInt8(truncatingIfNeeded: value) | 0x80)
            value >>= 7
        }
        bytes.append(UInt8(value))
    }

    @inline(__always)
    public mutating func varint(_ value: Int) {
        precondition(value >= 0, "varint requires a non-negative value")
        varint(UInt64(value))
    }

    public mutating func varint(_ value: UInt32) {
        varint(UInt64(value))
    }

    /// Writes a signed integer as a zigzag LEB128 integer.
    public mutating func svarint(_ value: Int64) {
        varint(UInt64(bitPattern: (value << 1) ^ (value >> 63)))
    }

    /// Writes a length-prefixed byte sequence.
    public mutating func blob<C: Collection>(_ value: C) where C.Element == UInt8 {
        varint(value.count)
        bytes.append(contentsOf: value)
    }

    /// Writes a length-prefixed UTF-8 string.
    public mutating func string(_ value: String) {
        var value = value
        value.withUTF8 { blob($0) }
    }

    public mutating func optionalString(_ value: String?) {
        if let value {
            bool(true)
            string(value)
        } else {
            bool(false)
        }
    }

    /// Appends bytes without a length prefix.
    public mutating func raw<C: Collection>(_ value: C) where C.Element == UInt8 {
        bytes.append(contentsOf: value)
    }

    /// Writes a length-prefixed nested payload that `body` produces.
    public mutating func nested(_ body: (inout WireWriter) -> Void) {
        var inner = WireWriter()
        body(&inner)
        blob(inner.bytes)
    }

    public mutating func removeAll(keepingCapacity: Bool = true) {
        bytes.removeAll(keepingCapacity: keepingCapacity)
    }

    public mutating func truncate(to count: Int) {
        bytes.removeSubrange(count...)
    }

    /// Overwrites four bytes at `offset` with `value` (little-endian).
    /// Sets bits in a byte that was already written.
    public mutating func setBits(_ bits: UInt8, at offset: Int) {
        bytes[offset] |= bits
    }

    public mutating func patchU32(_ value: UInt32, at offset: Int) {
        for index in 0 ..< 4 {
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> UInt32(index * 8))
        }
    }
}

/// Reads wire values from a byte buffer. Every read checks bounds and throws
/// on malformed input; a bad message must never crash the reader.
public struct WireReader: Sendable {
    public let bytes: [UInt8]
    public private(set) var offset: Int
    public let end: Int

    /// The largest length prefix that a single field may declare.
    public static let defaultMaximumLength = 64 * 1024 * 1024

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
        offset = 0
        end = bytes.count
    }

    public init(_ bytes: [UInt8], range: Range<Int>) {
        precondition(range.lowerBound >= 0 && range.upperBound <= bytes.count)
        self.bytes = bytes
        offset = range.lowerBound
        end = range.upperBound
    }

    public var remaining: Int { end - offset }
    public var isAtEnd: Bool { offset >= end }

    @inline(__always)
    public mutating func u8() throws(WireError) -> UInt8 {
        guard offset < end else { throw .truncated }
        let value = bytes[offset]
        offset += 1
        return value
    }

    public mutating func bool() throws(WireError) -> Bool {
        switch try u8() {
        case 0: return false
        case 1: return true
        case let other: throw .invalidValue("bool \(other)")
        }
    }

    public mutating func u16() throws(WireError) -> UInt16 {
        guard remaining >= 2 else { throw .truncated }
        let value = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
        offset += 2
        return value
    }

    public mutating func u32() throws(WireError) -> UInt32 {
        guard remaining >= 4 else { throw .truncated }
        var value: UInt32 = 0
        for index in 0 ..< 4 {
            value |= UInt32(bytes[offset + index]) << UInt32(index * 8)
        }
        offset += 4
        return value
    }

    public mutating func u64() throws(WireError) -> UInt64 {
        guard remaining >= 8 else { throw .truncated }
        var value: UInt64 = 0
        for index in 0 ..< 8 {
            value |= UInt64(bytes[offset + index]) << UInt64(index * 8)
        }
        offset += 8
        return value
    }

    /// Reads an unsigned LEB128 integer of at most ten bytes.
    @inline(__always)
    public mutating func varint() throws(WireError) -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard offset < end else { throw .truncated }
            let byte = bytes[offset]
            offset += 1
            if shift == 63 && byte > 1 { throw .malformedVarint }
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { throw .malformedVarint }
        }
    }

    /// Reads a varint that must fit in a non-negative `Int` no larger than `limit`.
    public mutating func count(limit: Int = WireReader.defaultMaximumLength) throws(WireError) -> Int {
        let value = try varint()
        guard value <= UInt64(limit) else { throw .lengthTooLarge(Int(clamping: value)) }
        return Int(value)
    }

    public mutating func varint32() throws(WireError) -> UInt32 {
        let value = try varint()
        guard value <= UInt64(UInt32.max) else { throw .invalidValue("u32 varint \(value)") }
        return UInt32(value)
    }

    public mutating func svarint() throws(WireError) -> Int64 {
        let raw = try varint()
        return Int64(bitPattern: (raw >> 1) ^ (0 &- (raw & 1)))
    }

    /// Reads a length prefix and returns the range of the bytes it covers.
    public mutating func blobRange(limit: Int = WireReader.defaultMaximumLength) throws(WireError) -> Range<Int> {
        let length = try count(limit: limit)
        guard length <= remaining else { throw .truncated }
        let range = offset ..< offset + length
        offset += length
        return range
    }

    public mutating func blob(limit: Int = WireReader.defaultMaximumLength) throws(WireError) -> [UInt8] {
        let range = try blobRange(limit: limit)
        return Array(bytes[range])
    }

    public mutating func string(limit: Int = WireReader.defaultMaximumLength) throws(WireError) -> String {
        let range = try blobRange(limit: limit)
        guard let value = String(validating: bytes[range], as: UTF8.self) else {
            throw .invalidUTF8
        }
        return value
    }

    public mutating func optionalString() throws(WireError) -> String? {
        try bool() ? try string() : nil
    }

    /// Returns a reader limited to a length-prefixed nested payload and skips it.
    public mutating func nested() throws(WireError) -> WireReader {
        let range = try blobRange()
        return WireReader(bytes, range: range)
    }

    public mutating func skip(_ count: Int) throws(WireError) {
        guard count >= 0, count <= remaining else { throw .truncated }
        offset += count
    }
}
