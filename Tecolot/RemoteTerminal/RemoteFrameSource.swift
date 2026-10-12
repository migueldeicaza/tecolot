//
//  RemoteFrameSource.swift
//  Tecolot
//
//  Turns the rows that a RemoteSession caches (wire cells) into SwiftTerm
//  lines for TerminalRenderView. Only rows whose content changed are
//  converted again, and only when the view draws a frame.
//
//  Images: the slices that rows carry (Sixel, iTerm2) become cropped images,
//  and the Kitty state becomes a KittyGraphicsRenderSnapshot. Pixels that the
//  session does not have yet are requested; the frame draws without them.
//

import AppKit
import Foundation
import SwiftTerm
import TecolotSessionClient
import TecolotWire

final class RemoteFrameSource: TerminalExternalFrameSource {
    var session: RemoteSession {
        didSet {
            converted.removeAll()
            paletteCache = nil
        }
    }
    /// The selection to draw, in absolute line numbers.
    var selection: TerminalExternalSelection?
    /// The 16 theme colors and the default colors, for the 256-color palette.
    var theme: (ansi: [Color], foreground: Color, background: Color)? {
        didSet { paletteCache = nil }
    }

    /// Device pixels per point of the view's display; image slices are sized
    /// in device pixels.
    var displayScale: CGFloat = 2 {
        didSet { if displayScale != oldValue { slices.removeAll() } }
    }

    private var store = TerminalRowStore()
    private var converted: [Int64: (stamp: UInt64, line: BufferLine)] = [:]
    /// The lines that the last frame looked up, kept converted.
    private var usedLines = Set<Int64>()
    private var fullImages: [UInt64: CGImage] = [:]
    private var slices: [WireRowImage: TerminalExternalImage] = [:]
    private var attributes: [WireAttribute: Attribute] = [:]
    private var paletteCache: (overrides: [UInt8: WireRGB], palette: [Color])?

    init(session: RemoteSession) {
        self.session = session
    }

    func withFrame(_ body: (TerminalExternalFrame, TerminalRowStore, (Int) -> BufferLine?) -> Void) {
        var missingImages: [UInt64] = []
        session.withFrameState { state, cache, imageLookup in
            if store.isNearCapacity {
                store = TerminalRowStore()
                converted.removeAll()
                attributes.removeAll()
            }
            let top = state.displayTop
            let rows = state.rows
            // Keep the conversions that the last frame used (the visible rows
            // and the bidi paragraphs around them).
            if converted.count > max(usedLines.count, rows) * 2 {
                converted = converted.filter { usedLines.contains($0.key) }
            }
            usedLines.removeAll(keepingCapacity: true)
            let cursor = state.cursor
            var frame = TerminalExternalFrame(
                columns: state.columns, rows: rows, topLine: Int(top),
                cursorLine: Int(cursor?.line ?? 0), cursorColumn: cursor?.column ?? 0,
                cursorVisible: cursor?.visible ?? false,
                cursorStyle: PersistentSessions.cursorStyle(cursor?.style ?? 0),
                isAlternateBuffer: state.buffer == .alternate,
                palette: palette(overrides: state.colors?.paletteOverrides ?? [:]),
                selection: selection)
            frame.maximumBidiParagraphRows = state.maximumBidiParagraphRows
            for line in top ..< top + Int64(rows) {
                guard let row = cache[line], !row.header.images.isEmpty else { continue }
                let images = row.header.images.compactMap { slice($0, lookup: imageLookup, missing: &missingImages) }
                if !images.isEmpty { frame.images[Int(line)] = images }
            }
            frame.kitty = kittySnapshot(state.kitty, top: top, lookup: imageLookup, missing: &missingImages)
            body(frame, store) { number in
                self.usedLines.insert(Int64(number))
                return self.line(Int64(number), cache: cache)
            }
        }
        if !missingImages.isEmpty { session.requestImages(missingImages) }
    }

    // MARK: Images

    /// The image of one row slice, cropped from the full image and sized in
    /// points. The same object comes back while the slice does not change.
    private func slice(_ slice: WireRowImage, lookup: (UInt64) -> RemoteImage?,
                       missing: inout [UInt64]) -> TerminalExternalImage? {
        if let cached = slices[slice] { return cached }
        guard let full = fullImage(slice.imageID, lookup: lookup, missing: &missing) else { return nil }
        let top = max(0, Int(slice.sourceY.rounded(.down)))
        let bottom = min(full.height, Int((slice.sourceY + slice.sourceHeight).rounded(.up)))
        guard bottom > top, let cropped = full.cropping(to: CGRect(x: 0, y: top, width: full.width, height: bottom - top))
        else { return nil }
        let size = NSSize(width: CGFloat(slice.width) / displayScale, height: CGFloat(slice.height) / displayScale)
        let image = TerminalExternalImage(image: NSImage(cgImage: cropped, size: size), column: slice.column,
                                          width: Int(size.width), height: Int(size.height.rounded()))
        if slices.count > 2048 { slices.removeAll() }
        slices[slice] = image
        return image
    }

    private func fullImage(_ id: UInt64, lookup: (UInt64) -> RemoteImage?, missing: inout [UInt64]) -> CGImage? {
        if let image = fullImages[id] { return image }
        guard let pixels = lookup(id) else {
            missing.append(id)
            return nil
        }
        guard let provider = CGDataProvider(data: Data(pixels.rgba) as CFData),
              let image = CGImage(width: pixels.width, height: pixels.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: pixels.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue |
                                                                     CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent) else { return nil }
        if fullImages.count > 256 { fullImages.removeAll() }
        fullImages[id] = image
        return image
    }

    /// The Kitty state as the renderers take it: rows relative to `top`, and
    /// only the images whose pixels arrived.
    private func kittySnapshot(_ kitty: WireKittyState?, top: Int64, lookup: (UInt64) -> RemoteImage?,
                               missing: inout [UInt64]) -> KittyGraphicsRenderSnapshot? {
        guard let kitty else { return nil }
        var images: [UInt32: KittyGraphicsRenderImage] = [:]
        for image in kitty.images {
            guard let pixels = lookup(image.imageID) else {
                missing.append(image.imageID)
                continue
            }
            images[image.kittyID] = KittyGraphicsRenderImage(
                imageId: image.kittyID, imageNumber: image.imageNumber, width: pixels.width, height: pixels.height,
                rgba: pixels.rgba, contentGeneration: image.imageID)
        }
        let placements = kitty.placements.map { placement in
            KittyGraphicsRenderPlacement(
                token: placement.token, placementId: placement.placementID, imageId: placement.kittyID,
                visibleSource: KittyGraphicsPixelRect(x: placement.sourceX, y: placement.sourceY,
                                                      width: placement.sourceWidth, height: placement.sourceHeight),
                geometry: KittyGraphicsCellGeometry(column: placement.column,
                                                    row: placement.isVirtual ? 0 : Int(placement.line - top),
                                                    columns: placement.columns, rows: placement.rows),
                pixelOffsetX: placement.pixelOffsetX, pixelOffsetY: placement.pixelOffsetY,
                zIndex: placement.zIndex, isVirtual: placement.isVirtual, insertionOrder: placement.insertionOrder)
        }
        // Arriving pixels change what draws, so they change the generation.
        return KittyGraphicsRenderSnapshot(storageGeneration: kitty.generation &* 4099 &+ UInt64(images.count),
                                           imagesById: images, placements: placements)
    }

    private func line(_ number: Int64, cache: RowCache) -> BufferLine? {
        guard let row = cache[number] else { return nil }
        if let existing = converted[number], existing.stamp == row.stamp {
            return existing.line
        }
        let columns = max(1, row.header.columns)
        let line: BufferLine
        if let existing = converted[number]?.line, existing.count == columns {
            line = existing
            store.clear(line)
        } else {
            line = store.makeLine(columns: columns)
        }
        for (column, cell) in row.cells.enumerated() where column < columns {
            let attribute = attribute(for: cell.style.attribute)
            switch cell.content {
            case .null:
                if attribute != Attribute.empty {
                    store.setCell(line, column: column, text: nil, width: 1, attribute: attribute)
                }
            case .ascii(let byte):
                store.setCell(line, column: column, text: String(UnicodeScalar(byte)), width: 1,
                              attribute: attribute, isProtected: cell.style.isProtected)
            case .grapheme(let text, let width):
                store.setCell(line, column: column, text: text, width: Int(width),
                              attribute: attribute, isProtected: cell.style.isProtected)
            case .spacer:
                store.setCell(line, column: column, text: nil, width: 0, attribute: attribute)
            }
        }
        store.setLineState(line, isWrapped: row.header.isWrapped,
                           renderMode: Self.renderMode(row.header.renderMode),
                           bidiState: Self.bidiState(row.header.bidi))
        converted[number] = (row.stamp, line)
        return line
    }

    private func attribute(for wire: WireAttribute) -> Attribute {
        if let cached = attributes[wire] { return cached }
        let value = Attribute(foreground: Self.color(wire.foreground), background: Self.color(wire.background),
                              style: CharacterStyle(rawValue: wire.style),
                              underlineStyle: UnderlineStyle(rawValue: wire.underlineStyle) ?? .none,
                              underlineColor: wire.underlineColor.map(Self.color))
        if attributes.count > 4096 { attributes.removeAll() }
        attributes[wire] = value
        return value
    }

    private func palette(overrides: [UInt8: WireRGB]) -> [Color] {
        if let paletteCache, paletteCache.overrides == overrides { return paletteCache.palette }
        var palette = TerminalExternalFrame.makePalette(ansiColors: theme?.ansi, foreground: theme?.foreground,
                                                        background: theme?.background)
        for (index, color) in overrides where Int(index) < palette.count {
            palette[Int(index)] = Color(red: color.red, green: color.green, blue: color.blue)
        }
        paletteCache = (overrides, palette)
        return palette
    }

    static func color(_ wire: WireColor) -> Attribute.Color {
        switch wire {
        case .default: return .defaultColor
        case .defaultInverted: return .defaultInvertedColor
        case .ansi(let code): return .ansi256(code: code)
        case .rgb(let red, let green, let blue): return .trueColor(red: red, green: green, blue: blue)
        }
    }

    /// Unpacks the helper's `WireMapping.bidi` byte.
    static func bidiState(_ value: UInt8?) -> BidiPresentationState {
        guard let value else { return .default }
        var state = BidiPresentationState.default
        state.supportMode = value & 1 != 0 ? .explicit : .implicit
        state.autodetectDirection = value & 2 != 0
        state.fallbackDirection = value & 4 != 0 ? .rightToLeft : .leftToRight
        state.boxMirroring = value & 8 != 0
        return state
    }

    static func renderMode(_ value: UInt8) -> BufferLine.RenderLineMode {
        switch value {
        case 1: return .doubleWidth
        case 2: return .doubledTop
        case 3: return .doubledDown
        default: return .single
        }
    }
}
