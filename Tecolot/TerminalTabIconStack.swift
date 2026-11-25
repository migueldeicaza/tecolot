import AppKit
import CoreImage

/// Draws a pane fan or vertical deck in focus order, with the front card last.
@MainActor
enum TerminalTabIconStack {
    private static let cache = NSCache<NSString, NSImage>()
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    nonisolated static func paneIDs(creationOrder: [UUID], focusHistory: [UUID], liveIDs: [UUID], limit: Int) -> [UUID] {
        let live = Set(liveIDs)
        var seen = Set<UUID>()
        return (focusHistory + creationOrder + liveIDs).filter {
            live.contains($0) && seen.insert($0).inserted
        }
        .prefix(max(0, min(5, limit))).map {
            $0
        }
    }

    static func image(
        workspace: TerminalPaneWorkspace,
        preferences: TabStripPreferences = TabStripPreferences(),
        selected: Bool = true,
        appearance: NSAppearance? = nil,
        scale: CGFloat = 2,
        showsProgress: Bool = false,
        vertical: Bool = false
    ) -> NSImage {
        let panes = workspace.controllers
        let ids = paneIDs(
            creationOrder: workspace.creationOrder,
            focusHistory: workspace.focusHistory,
            liveIDs: panes.map(\.id),
            limit: vertical ? min(3, preferences.iconCount) : preferences.iconCount
        )
        let paths = ids.compactMap { id in
            panes.first {
                $0.id == id
            }
        }.map {
            $0.programStatus.tabStatus.app ?? $0.panePresentation.executablePath
        }
        let entries = paths.map {
            ProgramGlyphCatalog.entry(forExecutablePath: $0)
        }
        let dark = appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let colored = entries.indices.map {
            preferences.colorsTile(selected: selected, index: $0)
        }
        let identities = zip(entries, paths).map { entry, path in
            entry.id == ProgramGlyphCatalog.terminal.id ? "terminal:\(path ?? "")" : entry.id
        }
        let effectiveScale = max(1, scale.rounded(.up))
        let pie = showsProgress
        let key = "\(identities)-\(colored)-\(dark)-\(effectiveScale)-\(pie)-\(vertical)" as NSString
        if let image = cache.object(forKey: key) {
            return image
        }
        let resolvedGlyphs: [TerminalAppIconResolver.TabGlyph] = zip(entries, paths).map { entry, path in
            entry.id == ProgramGlyphCatalog.terminal.id
                ? TerminalAppIconResolver.shared.resolvedTabIcon(forExecutablePath: path)
                : TerminalAppIconResolver.shared.resolvedTabGlyph(for: entry.id)
        }
        let size = NSSize(
            width: entries.isEmpty ? 0 : (vertical ? 24 : 24 + CGFloat(entries.count - 1) * 6),
            height: 24
        )
        let image = renderBitmap(size: size, scale: effectiveScale) { ctx in
            ctx.interpolationQuality = .high
            for index in entries.indices.reversed() {
                let entry = entries[index]
                let isColored = colored[index]
                let resolved = resolvedGlyphs[index]
                let background = ProgramGlyphCatalog.color(isColored ? entry.background : ProgramGlyphCatalog.grayBackground)
                let foreground = ProgramGlyphCatalog.color(isColored ? entry.foreground : ProgramGlyphCatalog.grayForeground)

                NSGraphicsContext.saveGraphicsState()
                let centerX: CGFloat = 12 + (vertical ? 0 : CGFloat(index) * 6)
                let centerY: CGFloat = 12 + (vertical ? CGFloat(entries.count - 1) * 1.25 - CGFloat(index) * 2.5 : 0)
                let transform = NSAffineTransform()
                transform.translateX(by: centerX, yBy: centerY)
                if !vertical && index == 0 && entries.count > 1 {
                    transform.rotate(byDegrees: -3.6)
                }
                transform.concat()

                let width: CGFloat = vertical ? max(11, 19 - CGFloat(index) * 2.5) : 20
                let height: CGFloat = vertical ? 15.5 : max(9, 16.5 - CGFloat(index) * 1.8)
                let outerRect = NSRect(x: -width / 2, y: -height / 2, width: width, height: height)
                let outerRadius: CGFloat = 4.25
                let outerPath = NSBezierPath(roundedRect: outerRect, xRadius: outerRadius, yRadius: outerRadius)

                // Layer 1: Drop shadow cast from the full outer white frame so
                // front cards separate cleanly from rear cards even when identical.
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.36 : 0.24)
                shadow.shadowBlurRadius = 1.8
                shadow.shadowOffset = NSSize(width: vertical ? 0 : 0.4, height: -0.9)
                shadow.set()
                NSColor.white.setFill()
                outerPath.fill()
                NSGraphicsContext.restoreGraphicsState()

                // Subtle outer hairline so pure white frames stay sharp on white selected capsules.
                NSColor.black.withAlphaComponent(dark ? 0.28 : 0.11).setStroke()
                outerPath.lineWidth = 0.5
                outerPath.stroke()

                // Layer 2: Clipped colored interior with vertical gradient and top specular gloss.
                let borderWidth: CGFloat = 1.25
                let interiorRect = outerRect.insetBy(dx: borderWidth, dy: borderWidth)
                let interiorRadius = max(2, outerRadius - borderWidth * 0.85)
                let interiorPath = NSBezierPath(roundedRect: interiorRect, xRadius: interiorRadius, yRadius: interiorRadius)

                NSGraphicsContext.saveGraphicsState()
                interiorPath.addClip()

                if !(index == 0 && pie) && resolved.isAppIcon {
                    drawAppIcon(resolved.image, in: interiorRect, grayscale: !isColored)
                } else {
                    let topColor = background.blended(withFraction: 0.14, of: .white) ?? background
                    let bottomColor = background.blended(withFraction: 0.10, of: .black) ?? background
                    NSGradient(starting: topColor, ending: bottomColor)?.draw(in: interiorRect, angle: 90)

                    // Curved top specular highlight matching Rex's glossy tile polish.
                    let glossRect = NSRect(
                        x: interiorRect.minX,
                        y: interiorRect.minY,
                        width: interiorRect.width,
                        height: interiorRect.height * 0.42
                    )
                    NSGradient(
                        starting: NSColor.white.withAlphaComponent(0.22),
                        ending: NSColor.white.withAlphaComponent(0)
                    )?.draw(in: glossRect, angle: 90)

                    if !(index == 0 && pie) {
                        if entry.id == ProgramGlyphCatalog.terminal.id && !resolved.isAppIcon {
                            drawTerminalPromptGlyph(in: interiorRect, color: foreground)
                        } else {
                            drawGlyph(
                                resolved.image,
                                in: interiorRect,
                                tint: foreground,
                                preserveOriginalColor: isColored && !resolved.image.isTemplate,
                                scale: effectiveScale
                            )
                        }
                    }
                }

                // Crisp top inner bevel sheen.
                NSColor.white.withAlphaComponent(0.24).setStroke()
                let innerRim = NSBezierPath(
                    roundedRect: interiorRect.insetBy(dx: 0.25, dy: 0.25),
                    xRadius: max(1.5, interiorRadius - 0.25),
                    yRadius: max(1.5, interiorRadius - 0.25)
                )
                innerRim.lineWidth = 0.5
                innerRim.stroke()

                NSGraphicsContext.restoreGraphicsState()
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        cache.countLimit = 256
        cache.setObject(image, forKey: key)
        return image
    }

    /// Renders directly into a backing-scale CGContext so rotated multi-pane stacks
    /// never go through deferred double-resampling.
    private static func renderBitmap(
        size: NSSize,
        scale: CGFloat,
        draw: (CGContext) -> Void
    ) -> NSImage {
        guard size.width > 0, size.height > 0 else {
            return NSImage(size: size)
        }
        let pixelWidth = max(1, Int(ceil(size.width * scale)))
        let pixelHeight = max(1, Int(ceil(size.height * scale)))
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let cg = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
            return NSImage(size: size)
        }
        cg.translateBy(x: 0, y: CGFloat(pixelHeight))
        cg.scaleBy(x: scale, y: -scale)
        let flippedContext = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = flippedContext
        draw(cg)
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = cg.makeImage() else {
            return NSImage(size: size)
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = size
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    /// Draws a bare `>_` prompt vector inside the tile (no box-in-a-box frame).
    private static func drawTerminalPromptGlyph(in rect: NSRect, color: NSColor) {
        let unit = min(rect.width, rect.height)
        let strokeWidth = max(1.3, unit * 0.115)
        let chevronLeft = rect.midX - unit * 0.34
        let chevronRight = rect.midX - unit * 0.04
        let chevronHalfH = unit * 0.22
        let chevronCenterY = rect.midY - unit * 0.02

        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: chevronLeft, y: chevronCenterY - chevronHalfH))
        chevron.line(to: NSPoint(x: chevronRight, y: chevronCenterY))
        chevron.line(to: NSPoint(x: chevronLeft, y: chevronCenterY + chevronHalfH))
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        chevron.lineWidth = strokeWidth

        let underscore = NSBezierPath()
        let underY = rect.midY + unit * 0.21
        underscore.move(to: NSPoint(x: rect.midX + unit * 0.04, y: underY))
        underscore.line(to: NSPoint(x: rect.midX + unit * 0.36, y: underY))
        underscore.lineCapStyle = .round
        underscore.lineWidth = strokeWidth

        color.setStroke()
        chevron.stroke()
        underscore.stroke()
    }

    /// Fits a monochrome or brand glyph aspect-preservingly inside the tile interior.
    private static func drawGlyph(
        _ glyph: NSImage,
        in interior: NSRect,
        tint: NSColor,
        preserveOriginalColor: Bool,
        scale: CGFloat
    ) {
        let maxW = interior.width * 0.70
        let maxH = interior.height * 0.64
        let sourceSize = glyph.size.width > 0 && glyph.size.height > 0 ? glyph.size : NSSize(width: 16, height: 16)
        let fit = min(maxW / sourceSize.width, maxH / sourceSize.height)
        let targetW = sourceSize.width * fit
        let targetH = sourceSize.height * fit
        let targetRect = NSRect(
            x: interior.midX - targetW / 2,
            y: interior.midY - targetH / 2,
            width: targetW,
            height: targetH
        )
        if preserveOriginalColor {
            glyph.draw(
                in: targetRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high.rawValue]
            )
            return
        }
        var proposed = NSRect(origin: .zero, size: NSSize(width: targetW * scale, height: targetH * scale))
        if
            let cgGlyph = glyph.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
            let cg = NSGraphicsContext.current?.cgContext {
            cg.saveGState()
            // Flip locally so CGContext.clip(to:mask:) draws upright inside our flipped context.
            cg.translateBy(x: targetRect.minX, y: targetRect.maxY)
            cg.scaleBy(x: 1, y: -1)
            let localRect = CGRect(origin: .zero, size: targetRect.size)
            cg.clip(to: localRect, mask: cgGlyph)
            cg.setFillColor(tint.cgColor)
            cg.fill(localRect)
            cg.restoreGState()
        } else {
            glyph.draw(
                in: targetRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high.rawValue]
            )
        }
    }

    /// Draws an installed macOS `.app` icon full-bleed inside the clipped tile interior,
    /// using CoreImage desaturation in grayscale mode so detail is preserved.
    private static func drawAppIcon(_ icon: NSImage, in interior: NSRect, grayscale: Bool) {
        // Slightly overscale to crop standard macOS .icns outer transparent margins.
        let side = max(interior.width, interior.height) * 1.16
        let drawRect = NSRect(
            x: interior.midX - side / 2,
            y: interior.midY - side / 2,
            width: side,
            height: side
        )
        if grayscale, let desaturated = desaturatedImage(icon, targetSide: side * 2) {
            desaturated.draw(
                in: drawRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 0.9,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high.rawValue]
            )
            return
        }
        icon.draw(
            in: drawRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high.rawValue]
        )
    }

    private static func desaturatedImage(_ image: NSImage, targetSide: CGFloat) -> NSImage? {
        var proposed = NSRect(origin: .zero, size: NSSize(width: targetSide, height: targetSide))
        guard let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            return nil
        }
        let ci = CIImage(cgImage: cg)
        guard let filter = CIFilter(name: "CIColorControls") else {
            return nil
        }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(0.0, forKey: kCIInputSaturationKey)
        filter.setValue(0.04, forKey: kCIInputBrightnessKey)
        guard
            let output = filter.outputImage,
            let rendered = ciContext.createCGImage(output, from: ci.extent) else {
            return nil
        }
        return NSImage(cgImage: rendered, size: image.size)
    }
}
