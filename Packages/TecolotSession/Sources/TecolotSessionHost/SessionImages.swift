//
// SessionImages.swift
// TecolotSessionHost
//
// Inline images in the helper.
//
// Sixel and iTerm2 images become slices on buffer lines
// (`Terminal.insertRasterImage`), so they scroll and erase with the text,
// and they travel inside the row records. Kitty images stay in SwiftTerm's
// Kitty store; each frame carries the placements that touch the client's
// rows. Clients fetch the pixels by image ID (`FetchImage`).
//
// Image IDs on the wire: a raster image's own ID (below 2^32), or an ID from
// 2^32 up for each Kitty image content. IDs are never reused.
//

import Foundation
import SwiftTerm
import TecolotTransport
import TecolotWire
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

/// Sixel and iTerm2 images by ID. The buffer lines own the images; the table
/// only finds them again for `FetchImage`.
final class RasterImageTable: @unchecked Sendable {
    private struct WeakImage {
        weak var image: TerminalRasterImage?
    }

    private let lock = NSLock()
    private var next: UInt32 = 1
    private var images: [UInt32: WeakImage] = [:]

    func makeID() -> UInt32 {
        lock.withLock {
            let id = next
            next = next == UInt32.max ? 1 : next + 1
            return id
        }
    }

    func register(_ image: TerminalRasterImage) {
        lock.withLock {
            if images.count >= 256 && images.count.isMultiple(of: 64) {
                images = images.filter { $0.value.image != nil }
            }
            images[image.id] = WeakImage(image: image)
        }
    }

    func image(_ id: UInt32) -> TerminalRasterImage? {
        lock.withLock { images[id]?.image }
    }
}

/// Kitty image contents by wire ID. Session queue only.
///
/// The same pixels get the same wire ID, so an animation that loops reuses
/// the frames that the client already fetched.
final class KittyImageTable {
    private struct Key: Hashable {
        var alternate: Bool
        var kittyID: UInt32
        var contentGeneration: UInt64
    }

    private struct ContentKey: Hashable {
        var width: Int
        var height: Int
        var hash: UInt64
    }

    struct Pixels {
        var width: Int
        var height: Int
        var rgba: [UInt8]
    }

    private var ids: [Key: UInt64] = [:]
    private var contentIDs: [ContentKey: UInt64] = [:]
    private(set) var pixels: [UInt64: Pixels] = [:]
    private var next: UInt64 = 1 << 32

    /// The wire ID of an image's current content. Keeps its pixels (a shared
    /// copy of SwiftTerm's array) until `prune` drops them.
    func wireID(for image: KittyGraphicsRenderImage, alternate: Bool) -> UInt64 {
        let key = Key(alternate: alternate, kittyID: image.imageId, contentGeneration: image.contentGeneration)
        if let id = ids[key] { return id }
        let content = ContentKey(width: image.width, height: image.height, hash: WireHash.hash64(image.rgba))
        let id: UInt64
        if let known = contentIDs[content], pixels[known]?.rgba == image.rgba {
            id = known
        } else {
            id = next
            next += 1
            contentIDs[content] = id
            pixels[id] = Pixels(width: image.width, height: image.height, rgba: image.rgba)
        }
        ids[key] = id
        return id
    }

    /// Forgets the images that no client's last Kitty state uses. Keeps the
    /// most recent ones too, up to `retainedBytes`, so that the frames of a
    /// looping animation keep their IDs.
    func prune(keeping used: Set<UInt64>, retainedBytes: Int = 64 * 1024 * 1024) {
        var bytes = pixels.reduce(0) { $0 + $1.value.rgba.count }
        guard bytes > retainedBytes else { return }
        for id in pixels.keys.sorted() where !used.contains(id) {
            bytes -= pixels[id]?.rgba.count ?? 0
            pixels[id] = nil
            if bytes <= retainedBytes { break }
        }
        ids = ids.filter { pixels[$0.value] != nil }
        contentIDs = contentIDs.filter { pixels[$0.value] != nil }
    }
}

extension WireMapping {
    /// The scalars that make SwiftTerm's bidi layout look at a paragraph (the
    /// same ranges as `TerminalBidi.isRTLTrigger`, which only Apple
    /// platforms build).
    static func isRightToLeftTrigger(_ value: UInt32) -> Bool {
        if value < 0x0590 { return false }
        switch value {
        case 0x0590 ... 0x08FF, 0xFB1D ... 0xFDFF, 0xFE70 ... 0xFEFC, 0x10800 ... 0x10FFF,
             0x1E800 ... 0x1EFFF, 0x200F, 0x202B, 0x202E, 0x2067:
            return true
        default:
            return false
        }
    }
}

// MARK: - Images from the parser (terminal lock held)

extension SessionHost {
    /// The size owner's cell size in device pixels, and its device pixels per point.
    private func imageMetrics() -> (cellWidth: Int, cellHeight: Int, scale: Double) {
        events.withLock {
            let cell = $0.cellSize ?? (width: 16, height: 34)
            return (max(1, cell.width), max(1, cell.height), $0.scale)
        }
    }

    public func createImageFromBitmap(source: Terminal, bytes: inout [UInt8], width: Int, height: Int) {
        guard let image = TerminalRasterImage(id: rasterImages.makeID(), width: width, height: height,
                                              rgba: bytes) else { return }
        rasterImages.register(image)
        let metrics = imageMetrics()
        // As TerminalView does: an image wider than the terminal (in points)
        // takes the terminal's width.
        let terminalPoints = Double(source.cols * metrics.cellWidth) / metrics.scale
        source.insertRasterImage(image, cellWidth: metrics.cellWidth, cellHeight: metrics.cellHeight,
                                 width: Double(width) > terminalPoints ? .percent(100) : .auto,
                                 height: .auto, preserveAspectRatio: true)
    }

    public func createImage(source: Terminal, data: Data, width: ImageSizeRequest, height: ImageSizeRequest,
                            preserveAspectRatio: Bool) {
        #if canImport(ImageIO)
        guard let decoded = Self.decodeImage(data),
              let image = TerminalRasterImage(id: rasterImages.makeID(), width: decoded.width,
                                              height: decoded.height, rgba: decoded.rgba) else { return }
        rasterImages.register(image)
        let metrics = imageMetrics()
        // TerminalView reads pixel sizes as points.
        func devicePixels(_ request: ImageSizeRequest) -> ImageSizeRequest {
            if case .pixels(let value) = request { return .pixels(Int((Double(value) * metrics.scale).rounded())) }
            return request
        }
        source.insertRasterImage(image, cellWidth: metrics.cellWidth, cellHeight: metrics.cellHeight,
                                 width: devicePixels(width), height: devicePixels(height),
                                 preserveAspectRatio: preserveAspectRatio)
        #endif
    }

    #if canImport(ImageIO)
    /// Decodes PNG, JPEG, GIF and the other ImageIO formats to straight RGBA.
    static func decodeImage(_ data: Data) -> (width: Int, height: Int, rgba: [UInt8])? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width <= 16384, height <= 16384,
              width <= (64 * 1024 * 1024) / 4 / height else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // Core Graphics draws premultiplied; the wire carries straight alpha.
        var index = 0
        while index < rgba.count {
            let alpha = rgba[index + 3]
            if alpha != 0 && alpha != 255 {
                for channel in 0 ..< 3 {
                    rgba[index + channel] = UInt8(min(255, (Int(rgba[index + channel]) * 255 + Int(alpha) / 2) / Int(alpha)))
                }
            }
            index += 4
        }
        return (width, height, rgba)
    }
    #endif
}
