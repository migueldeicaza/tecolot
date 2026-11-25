import AppKit
import Testing
@testable import Tecolot

@MainActor
struct ChromeIconButtonTests {
    @Test func pointerAndPressTransitions() {
        var state = ChromeButtonHoverState()
        #expect(!state.highlighted)
        state.send(.enter)
        #expect(state.hovered && !state.pressed && state.highlighted)
        state.send(.press)
        #expect(state.hovered && state.pressed)
        state.send(.exit)
        #expect(!state.hovered && !state.pressed && !state.highlighted)
        state.send(.release)
        #expect(!state.highlighted)
        state.send(.enter)
        state.send(.press)
        state.send(.unavailable)
        #expect(state == ChromeButtonHoverState())
    }

    @Test func hideDisableAndRemovalClearHover() {
        let parent = NSView()
        let button = ChromeIconButton(frame: .zero)
        parent.addSubview(button)
        button.updateHover(.enter)
        button.highlight(true)
        #expect(button.hoverState.highlighted)
        button.isHidden = true
        #expect(button.hoverState == ChromeButtonHoverState())
        button.isHidden = false
        button.updateHover(.enter)
        button.isEnabled = false
        #expect(button.hoverState == ChromeButtonHoverState())
        button.isEnabled = true
        button.updateHover(.enter)
        button.removeFromSuperview()
        #expect(button.hoverState == ChromeButtonHoverState())
        parent.addSubview(button)
        button.updateHover(.enter)
        button.viewDidHide()
        #expect(button.hoverState == ChromeButtonHoverState())
    }

    @Test(arguments: [NSSize(width: 26, height: 26), NSSize(width: 29, height: 25), NSSize(width: 30, height: 28), NSSize(width: 35, height: 32), NSSize(width: 18, height: 16)])
    func highlightGeometryPreservesHitTarget(size: NSSize) {
        let bounds = NSRect(origin: NSPoint(x: 3, y: 5), size: size)
        for diameter: CGFloat in [22, 26, 32] {
            let rect = ChromeIconButton.highlightRect(in: bounds, diameter: diameter)
            #expect(rect.width == rect.height)
            #expect(rect.width == min(diameter, size.width, size.height))
            #expect(rect.midX == bounds.midX && rect.midY == bounds.midY)
            #expect(bounds.contains(rect))
        }
    }

    @Test func leavingErasesThePreviouslyPaintedHighlight() throws {
        let button = ChromeIconButton(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 26, pixelsHigh: 26, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        button.layoutSubtreeIfNeeded()
        button.updateHover(.enter)
        button.layer?.render(in: context.cgContext)
        #expect(try #require(bitmap.colorAt(x: 13, y: 13)).alphaComponent > 0)
        button.updateHover(.exit)
        context.cgContext.clear(button.bounds)
        button.layer?.render(in: context.cgContext)
        #expect(try #require(bitmap.colorAt(x: 13, y: 13)).alphaComponent == 0)
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func glyphIsVisibleAfterInitialLayout(appearance: NSAppearance.Name) throws {
        let button = ChromeIconButton(frame: .zero)
        button.appearance = NSAppearance(named: appearance)
        button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Pane")
        button.frame.size = NSSize(width: 26, height: 26)
        button.layoutSubtreeIfNeeded()
        let bitmap = try #require(button.bitmapImageRepForCachingDisplay(in: button.bounds))
        button.cacheDisplay(in: button.bounds, to: bitmap)
        let visible = (0..<bitmap.pixelsHigh).flatMap { y in
            (0..<bitmap.pixelsWide).compactMap { x -> NSColor? in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.1 else {
                    return nil
                }
                return color
            }
        }
        #expect(!visible.isEmpty)
        #expect(visible.contains {
            let brightness = ($0.redComponent + $0.greenComponent + $0.blueComponent) / 3
            return appearance == .aqua ? brightness < 0.75 : brightness > 0.5
        })
        let previous = bitmap.representation(using: .png, properties: [:])
        button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
        let updated = try #require(button.bitmapImageRepForCachingDisplay(in: button.bounds))
        button.cacheDisplay(in: button.bounds, to: updated)
        #expect(previous != updated.representation(using: .png, properties: [:]))
    }

    @Test func unrelatedNativeTrackingEventsDoNotChangeHover() throws {
        let button = ChromeIconButton(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        button.updateTrackingAreas()
        let event = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        button.mouseEntered(with: event)
        #expect(!button.hoverState.highlighted)
        button.updateHover(.enter)
        button.mouseExited(with: event)
        #expect(button.hoverState.hovered)
    }

    @Test func resizingReplacesTrackingWithoutChangingTheHitTarget() {
        let button = ChromeIconButton(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        button.updateTrackingAreas()
        button.frame.size = NSSize(width: 30, height: 28)
        button.updateTrackingAreas()
        #expect(button.trackingAreas.count == 1)
        #expect(button.trackingAreas[0].options.contains(.inVisibleRect))
        #expect(button.trackingAreas[0].options.contains(.activeAlways))
        #expect(button.hitTest(NSPoint(x: 1, y: 1)) === button)
        #expect(button.frame.size == NSSize(width: 30, height: 28))
    }

    @Test func contrastIncreasesTheHighlightWithoutChangingGeometry() {
        for dark in [false, true] {
            let normal = ChromeIconButton.highlightColor(dark: dark, increasedContrast: false)
            let contrast = ChromeIconButton.highlightColor(dark: dark, increasedContrast: true)
            #expect(contrast.alphaComponent > normal.alphaComponent)
        }
        let button = ChromeIconButton(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        button.setAccessibilityLabel("Split Right")
        #expect(button.accessibilityLabel() == "Split Right")
        #expect(button.frame.size == NSSize(width: 26, height: 26))
        #expect(button.contentTintColor == .secondaryLabelColor)
    }

    @Test func convenienceInitAppliesTreatmentImmediatelyWithoutHover() throws {
        let pane = ChromeIconButton(treatment: .pane)
        let window = ChromeIconButton(treatment: .window)
        let toolbar = ChromeIconButton(treatment: .toolbar)

        let paneGlyph = try #require(pane.subviews.first as? NSImageView)
        let windowGlyph = try #require(window.subviews.first as? NSImageView)
        let toolbarGlyph = try #require(toolbar.subviews.first as? NSImageView)

        #expect(paneGlyph.alphaValue < 1)
        #expect(windowGlyph.alphaValue == 1)
        #expect(toolbarGlyph.alphaValue == 1)
        #expect(windowGlyph.symbolConfiguration == ChromeIconButton.symbolConfiguration(for: .window))
        #expect(toolbarGlyph.symbolConfiguration == ChromeIconButton.symbolConfiguration(for: .toolbar))
    }

    @Test func selectionSurfaceAnimatesGlassSublayerWithBoundsChange() {
        let surface = TabSelectionSurfaceView(frame: NSRect(x: 0, y: 0, width: 120, height: 32))
        surface.move(to: NSRect(x: 10, y: 0, width: 120, height: 32), animated: false)
        surface.move(to: NSRect(x: 140, y: 0, width: 220, height: 32), animated: true)
        #expect(surface.layer?.animation(forKey: "position") != nil)
        #expect(surface.layer?.animation(forKey: "bounds") != nil)
        if #available(macOS 26.0, *), let glass = surface.subviews.first {
            #expect(glass.layer?.animation(forKey: "transform.scale.x") != nil)
            #expect(glass.layer?.animation(forKey: "transform.scale.y") != nil)
            surface.move(to: NSRect(x: 140, y: 0, width: 220, height: 32), animated: false)
            #expect(glass.layer?.animation(forKey: "transform.scale.x") == nil)
        }
    }

    @Test func groupButtonHoverResetsAndDrawsBehindContent() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        window.contentView = container
        let button = GroupButton(frame: NSRect(x: 10, y: 10, width: 120, height: 36))
        button.cell = GroupSelectorCell()
        button.isBordered = false
        button.title = "Work"
        let insideScreenPoint = window.convertPoint(toScreen: NSPoint(x: 50, y: 28))
        let outsideScreenPoint = window.convertPoint(toScreen: NSPoint(x: 190, y: 28))
        button.pointerLocation = { outsideScreenPoint }
        container.addSubview(button)
        button.updateTrackingAreas()

        // Hover is drawn inside draw(_:) before super.draw(_:), never via an overlay sublayer.
        #expect((button.layer?.sublayers ?? []).isEmpty)

        // Unrelated tracking events do not toggle hover.
        let enter = try #require(NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        ))
        button.mouseEntered(with: enter)
        #expect(!button.hovered)

        // Turning hover on renders the highlight pill and lifecycle calls clear it.
        button.setHovered(true)
        #expect(button.hovered)
        let hoveredBitmap = try #require(button.bitmapImageRepForCachingDisplay(in: button.bounds))
        button.cacheDisplay(in: button.bounds, to: hoveredBitmap)
        let pillSampleX = hoveredBitmap.pixelsWide - max(8, hoveredBitmap.pixelsWide / 10)
        let pillSampleY = hoveredBitmap.pixelsHigh / 2
        #expect(try #require(hoveredBitmap.colorAt(x: pillSampleX, y: pillSampleY)).alphaComponent > 0)

        button.contextMenu = { NSMenu() }
        let click = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        #expect(button.menu(for: click) != nil)
        #expect(!button.hovered)
        let clearedBitmap = try #require(button.bitmapImageRepForCachingDisplay(in: button.bounds))
        button.cacheDisplay(in: button.bounds, to: clearedBitmap)
        #expect(try #require(clearedBitmap.colorAt(x: pillSampleX, y: pillSampleY)).alphaComponent == 0)

        button.setHovered(true)
        #expect(button.hovered)
        button.viewDidHide()
        #expect(!button.hovered)

        button.setHovered(true)
        #expect(button.hovered)
        button.isHidden = true
        #expect(!button.hovered)

        // Unhiding under a stationary pointer resyncs hover back on.
        button.pointerLocation = { insideScreenPoint }
        button.isHidden = false
        #expect(button.hovered)

        // Disabling clears hover; re-enabling under the pointer restores it.
        button.isEnabled = false
        #expect(!button.hovered)
        button.isEnabled = true
        #expect(button.hovered)

        // Moving outside and resyncing via updateTrackingAreas / removal clears hover.
        button.pointerLocation = { outsideScreenPoint }
        button.updateTrackingAreas()
        #expect(!button.hovered)

        button.setHovered(true)
        #expect(button.hovered)
        button.removeFromSuperview()
        #expect(!button.hovered)
    }
}
