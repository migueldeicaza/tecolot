import AppKit

/// Draws a pane fan or vertical deck in focus order, with the front card last.
@MainActor
enum TerminalTabIconStack {
    private static let cache = NSCache<NSString, NSImage>()

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
        // Unknown programs share a neutral tile, but keep the resolver's own
        // icon (including enclosing app icons), so cache them by path too.
        let identities = zip(entries, paths).map { entry, path in
            entry.id == ProgramGlyphCatalog.terminal.id ? "terminal:\(path ?? "")" : entry.id
        }
        let pie = showsProgress
        let key = "\(identities)-\(colored)-\(dark)-\(scale)-\(pie)-\(vertical)" as NSString
        if let image = cache.object(forKey: key) {
            return image
        }
        let glyphs = zip(entries, paths).map { entry, path in
            entry.id == ProgramGlyphCatalog.terminal.id
                ? TerminalAppIconResolver.shared.icon(forExecutablePath: path)
                : TerminalAppIconResolver.shared.tabGlyph(for: entry.id)
        }
        let size = NSSize(width: entries.isEmpty ? 0 : (vertical ? 24 : 24 + CGFloat(entries.count - 1) * 6), height: 24)
        let image = NSImage(size: size, flipped: true) { _ in
            for index in entries.indices.reversed() {
                let entry = entries[index]
                let isColored = colored[index]
                let background = ProgramGlyphCatalog.color(isColored ? entry.background : ProgramGlyphCatalog.grayBackground)
                let foreground = ProgramGlyphCatalog.color(isColored ? entry.foreground : ProgramGlyphCatalog.grayForeground)
                NSGraphicsContext.saveGraphicsState()
                let transform = NSAffineTransform()
                transform.translateX(by: 12 + (vertical ? 0 : CGFloat(index) * 6), yBy: 12 + (vertical ? CGFloat(entries.count - 1) * 1.5 - CGFloat(index) * 3 : 0))
                if !vertical && index == 0 && entries.count > 1 {
                    transform.rotate(byDegrees: -3.6)
                }
                transform.concat()
                let height = vertical ? CGFloat(16.5) : max(8, 18 - CGFloat(index) * 1.5)
                let width = vertical ? 20.5 - CGFloat(index) * 3 : 22
                let rect = NSRect(x: -width / 2, y: -height / 2, width: width, height: height)
                // Center the stroke inside the measured 22 × 18 outer frame.
                let tile = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 4.5, yRadius: 4.5)
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
                shadow.shadowBlurRadius = 1.5
                shadow.shadowOffset = NSSize(width: 0, height: -0.5)
                shadow.set()
                background.setFill()
                tile.fill()
                NSGraphicsContext.restoreGraphicsState()
                NSGradient(
                    starting: background.blended(withFraction: 0.12, of: .white) ?? background,
                    ending: background.blended(withFraction: 0.08, of: .black) ?? background
                )?.draw(in: tile, angle: 90)
                NSColor.white.withAlphaComponent(0.9).setStroke()
                tile.lineWidth = 1.5
                tile.stroke()
                let glyph = glyphs[index].copy() as! NSImage
                // All glyphs, including the two bundled brands, use the tile's
                // foreground in grayscale mode, without creating new artwork.
                let glyphRect = NSRect(x: -6, y: -5.4, width: 12, height: 10.8)
                let tinted = isColored && !glyph.isTemplate ? glyph : NSImage(size: glyph.size, flipped: false) { bounds in
                    glyph.draw(in: bounds)
                    foreground.setFill()
                    bounds.fill(using: .sourceIn)
                    return true
                }
                if !(index == 0 && pie) {
                    tinted.draw(
                        in: glyphRect,
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 1,
                        respectFlipped: true,
                        hints: nil
                    )
                }
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
        cache.countLimit = 256
        cache.setObject(image, forKey: key)
        return image
    }
}
