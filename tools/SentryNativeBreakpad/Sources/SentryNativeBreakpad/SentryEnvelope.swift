import Foundation

/// A strict reader for the Sentry envelope format.
///
/// The format is a JSON header line, then items. Each item is a JSON header
/// line and a payload. When an item header has a `length`, the payload has
/// exactly that many bytes. Otherwise the payload ends at the next newline.
/// The reader rejects a file that ends inside an item, so a partial file is
/// not valid.
///
/// The reader does not copy the data. It reads only the header lines and
/// skips payloads that have a `length`, so a memory-mapped minidump is not
/// read into memory.
public struct SentryEnvelope: Sendable {
    public struct Item: Sendable {
        public let type: String
        public let header: [String: any Sendable]
        /// The payload byte range, as indices into the data that was parsed.
        public let payloadRange: Range<Data.Index>
    }

    public enum ParseError: Error, Equatable, Sendable {
        case missingHeader
        case invalidHeader
        case invalidItemHeader
        case truncatedPayload
        case missingNewline
    }

    /// A header line longer than this is not valid.
    public static let maximumHeaderLength = 64 * 1024

    public let header: [String: any Sendable]
    public let items: [Item]

    /// The event ID from the envelope header, in lowercase without dashes.
    public var eventID: String? {
        guard let raw = header["event_id"] as? String else { return nil }
        return Self.normalizedEventID(raw)
    }

    public var containsEvent: Bool {
        items.contains { $0.type == "event" }
    }

    public init(data: Data) throws {
        var offset = data.startIndex

        guard let headerEnd = Self.headerLineEnd(in: data, from: offset) else {
            throw ParseError.missingHeader
        }
        guard let header = Self.jsonObject(data[offset..<headerEnd]) else {
            throw ParseError.invalidHeader
        }
        self.header = header
        offset = headerEnd + 1

        var items: [Item] = []
        while offset < data.endIndex {
            // Tolerate blank lines between items.
            if data[offset] == 0x0A {
                offset += 1
                continue
            }
            guard let itemHeaderEnd = Self.headerLineEnd(in: data, from: offset),
                  let itemHeader = Self.jsonObject(data[offset..<itemHeaderEnd]),
                  let type = itemHeader["type"] as? String else {
                throw ParseError.invalidItemHeader
            }
            offset = itemHeaderEnd + 1

            let payloadRange: Range<Data.Index>
            if let length = itemHeader["length"] as? Int {
                guard length >= 0, length <= data.endIndex - offset else {
                    throw ParseError.truncatedPayload
                }
                payloadRange = offset..<(offset + length)
                offset += length
                if offset < data.endIndex {
                    guard data[offset] == 0x0A else { throw ParseError.missingNewline }
                    offset += 1
                }
            } else {
                let end = data[offset...].firstIndex(of: 0x0A) ?? data.endIndex
                payloadRange = offset..<end
                offset = end + 1
            }
            items.append(Item(type: type, header: itemHeader, payloadRange: payloadRange))
        }
        self.items = items
    }

    /// Returns a 32 character lowercase hexadecimal ID, or nil.
    public static func normalizedEventID(_ raw: String) -> String? {
        let id = raw.replacingOccurrences(of: "-", with: "").lowercased()
        guard id.count == 32, id.allSatisfy(\.isHexDigit), id != String(repeating: "0", count: 32) else {
            return nil
        }
        return id
    }

    /// Finds the newline that ends a header line. Searches no further than
    /// `maximumHeaderLength`, so damaged data is not scanned to its end.
    private static func headerLineEnd(in data: Data, from offset: Data.Index) -> Data.Index? {
        guard offset < data.endIndex else { return nil }
        let limit = min(data.endIndex, offset + maximumHeaderLength + 1)
        return data[offset..<limit].firstIndex(of: 0x0A)
    }

    private static func jsonObject(_ bytes: Data) -> [String: any Sendable]? {
        guard !bytes.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(bytes)),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary.compactMapValues { value -> (any Sendable)? in
            switch value {
            case let number as NSNumber:
                // Keep integer lengths as Int.
                if CFNumberIsFloatType(number) { return number.doubleValue }
                return number.intValue
            case let string as String:
                return string
            default:
                return nil
            }
        }
    }
}
