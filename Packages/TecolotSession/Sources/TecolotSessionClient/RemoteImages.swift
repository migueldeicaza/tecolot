//
// RemoteImages.swift
// TecolotSessionClient
//
// The pixels of the images that rows (Sixel and iTerm2 slices) and the
// Kitty state refer to. The session fetches missing images from the helper
// and keeps the most recently used ones within a byte budget.
//

import TecolotWire

/// The pixels of one image: straight RGBA, top row first.
public struct RemoteImage: Sendable {
    public let id: UInt64
    public let width: Int
    public let height: Int
    public let rgba: [UInt8]

    public init(id: UInt64, width: Int, height: Int, rgba: [UInt8]) {
        self.id = id
        self.width = width
        self.height = height
        self.rgba = rgba
    }
}

/// Images by ID, least recently used first out.
struct RemoteImageStore {
    private var images: [UInt64: (image: RemoteImage, lastUse: UInt64)] = [:]
    private var clock: UInt64 = 0
    private(set) var bytes = 0
    var budget = 256 * 1024 * 1024
    /// Images that the helper no longer has.
    private(set) var unavailable = Set<UInt64>()

    func contains(_ id: UInt64) -> Bool { images[id] != nil || unavailable.contains(id) }

    mutating func image(_ id: UInt64) -> RemoteImage? {
        guard var entry = images[id] else { return nil }
        clock += 1
        entry.lastUse = clock
        images[id] = entry
        return entry.image
    }

    mutating func insert(_ image: RemoteImage) {
        clock += 1
        if let old = images[image.id] { bytes -= old.image.rgba.count }
        images[image.id] = (image, clock)
        bytes += image.rgba.count
        guard bytes > budget else { return }
        // Drop the least recently used images, never the one just added.
        for (id, entry) in images.sorted(by: { $0.value.lastUse < $1.value.lastUse }) where id != image.id {
            images[id] = nil
            bytes -= entry.image.rgba.count
            if bytes <= budget { break }
        }
    }

    mutating func markUnavailable(_ id: UInt64) {
        if unavailable.count > 4096 { unavailable.removeAll() }
        unavailable.insert(id)
    }

    mutating func removeAll() {
        images.removeAll()
        unavailable.removeAll()
        bytes = 0
    }
}

/// An image whose chunks are arriving. Queue-confined.
struct PartialImage {
    var width: Int
    var height: Int
    var rgba: [UInt8]
    var received: Int
}
