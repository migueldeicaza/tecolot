import AppKit
import SwiftTerm
import Testing
@testable import Tecolot

@MainActor
struct TerminalPaneCardTests {
    @Test(arguments: ["iTerm2 Solarized Light", "Terminal Basic Dark"])
    func titleExpandsAfterResizeAndHeaderTracksFocus(themeName: String) async throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let first = try #require(workspace.focusedController)
        workspace.split(first, direction: .down)
        let second = try #require(workspace.focusedController)
        let document = TerminalDocument()
        let host = TerminalPaneHostView(workspace: workspace, document: document)
        host.frame = NSRect(x: 0, y: 0, width: 1500, height: 800)
        let settings = GlobalAppearanceSettings(paneCardsEnabled: true, paneCardsBackdrop: .gradient)
        host.synchronize(revision: workspace.revision, document: document, settings: settings)
        let terminal = try #require(first.terminal)
        var profile = TerminalProfile(name: "Title Width Test")
        profile.titleOverride = nil
        profile.titleComponents = [.activeTitle]
        profile.setThemeName(themeName, isDark: false)
        profile.setThemeName(themeName, isDark: true)
        first.applyProfile(profile)
        first.applyThemeOverride(themeName)
        let text = "Terminal session with a complete title"
        first.setTerminalTitle(source: terminal, title: text)
        first.hostCurrentDirectoryUpdate(source: terminal, directory: "file://localhost/tmp/pane-one")
        for _ in 0..<30 {
            if first.panePresentation.title == text { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(first.panePresentation.title == text)
        host.layoutSubtreeIfNeeded()
        let split = try #require(host.subviews.compactMap { $0 as? NSSplitView }.first)
        let card = try #require(split.arrangedSubviews.compactMap { $0 as? TerminalPaneCardView }.first { $0.controller === first })
        card.refreshAppearance()
        card.frame.size.width = 140
        card.needsLayout = true
        card.layoutSubtreeIfNeeded()
        card.frame.size.width = 1400
        card.needsLayout = true
        card.layoutSubtreeIfNeeded()
        let surface = try #require(card.subviews.first)
        let labels = surface.subviews.flatMap { $0.subviews }.compactMap { $0 as? NSTextField }
        let title = try #require(labels.first { $0.stringValue == text })
        let directory = try #require(labels.first { $0.stringValue == "/tmp/pane-one" })
        let font = try #require(title.font)
        let fullTextWidth = (text as NSString).size(withAttributes: [.font: font]).width
        #expect(title.frame.width >= fullTextWidth + 4)
        #expect(directory.frame.minX == title.frame.maxX + 8)
        #expect(!directory.isHidden)

        let header = try #require(title.superview)
        let inactiveColor = try #require(header.layer?.backgroundColor)
        #expect(inactiveColor == terminal.nativeBackgroundColor.cgColor)
        workspace.markFocused(first)
        card.refreshAppearance()
        let focusedColor = try #require(header.layer?.backgroundColor)
        #expect(focusedColor != inactiveColor)
        workspace.markFocused(second)
        card.refreshAppearance()
        #expect(header.layer?.backgroundColor == inactiveColor)
    }

    @Test func focusedTabIconUpdatesWhenCommandIdentityIsCleared() throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let controller = try #require(workspace.focusedController)
        let document = TerminalDocument()
        let host = TerminalPaneHostView(workspace: workspace, document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.synchronize(revision: workspace.revision, document: document)
        window.title = "Command title"
        controller.updatePaneExecutablePath("/opt/bin/bun")
        let accessory = try #require(window.tab.accessoryView)
        let title = try #require(window.tab.attributedTitle)
        #expect(title.string == "\u{fffc}  Command title")
        let attachment = try #require(title.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        let image = try #require(attachment.image)
        #expect(image.size.width == 30)
        #expect(image.size.height == 26)
        #expect(accessory.subviews.compactMap { $0 as? NSImageView }.isEmpty)
        controller.updatePaneExecutablePath(nil)
        let clearedTitle = try #require(window.tab.attributedTitle)
        let clearedAttachment = try #require(clearedTitle.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        #expect(clearedAttachment.image?.tiffRepresentation != image.tiffRepresentation)
        #expect(accessory.intrinsicContentSize.height == 20)
    }

    @Test func tabStackTracksInactiveCommandsFocusAndPaneCount() throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let first = try #require(workspace.focusedController)
        workspace.split(first, direction: .right)
        let second = try #require(workspace.focusedController)
        let document = TerminalDocument()
        let host = TerminalPaneHostView(workspace: workspace, document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.synchronize(revision: workspace.revision, document: document)
        second.updatePaneExecutablePath("/opt/bin/git")

        func tabImage() throws -> NSImage {
            let title = try #require(window.tab.attributedTitle)
            let attachment = try #require(title.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
            return try #require(attachment.image)
        }

        let before = try tabImage()
        #expect(before.size.width == 36)
        first.updatePaneExecutablePath("/opt/bin/bun")
        let after = try tabImage()
        #expect(before.tiffRepresentation != after.tiffRepresentation)
        workspace.markFocused(first)
        TerminalSplitZoomTitlebar.configure(window, workspace: workspace)
        #expect(try tabImage().tiffRepresentation != after.tiffRepresentation)

        workspace.split(first, direction: .down)
        TerminalSplitZoomTitlebar.configure(window, workspace: workspace)
        #expect(try tabImage().size.width == 42)
        let third = try #require(workspace.focusedController)
        workspace.split(third, direction: .right)
        TerminalSplitZoomTitlebar.configure(window, workspace: workspace)
        #expect(try tabImage().size.width == 42)
        for controller in workspace.controllers where controller !== first {
            workspace.close(controller)
        }
        TerminalSplitZoomTitlebar.configure(window, workspace: workspace)
        #expect(try tabImage().size.width == 30)
    }

    @Test(arguments: ["iTerm2 Solarized Light", "Terminal Basic Dark"])
    func nestedCardsRenderWithThemeColors(themeName: String) async throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let first = try #require(workspace.focusedController)
        workspace.split(first, direction: .right)
        let second = try #require(workspace.focusedController)
        workspace.split(first, direction: .down)
        let third = try #require(workspace.focusedController)
        workspace.markFocused(first)
        let document = TerminalDocument()
        let host = TerminalPaneHostView(workspace: workspace, document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        host.synchronize(revision: workspace.revision, document: document)
        for (controller, label, path) in [(first, "Stress-test Snake demo", "/opt/bin/codex"),
                                          (second, "Node", "/opt/bin/node"),
                                          (third, "Git Changes", "/opt/bin/git")] {
            var profile = TerminalProfile(name: "Card Preview")
            profile.fontSize = 13
            profile.backgroundOpacity = 1
            profile.titleOverride = nil
            profile.titleComponents = [.activeTitle]
            profile.setThemeName(themeName, isDark: false)
            profile.setThemeName(themeName, isDark: true)
            controller.applyProfile(profile)
            controller.applyThemeOverride(themeName)
            let terminal = try #require(controller.terminal)
            try terminal.setUseMetal(false)
            controller.setTerminalTitle(source: terminal, title: label)
            controller.hostCurrentDirectoryUpdate(source: terminal, directory: "file://localhost/tmp/rex-snake")
            controller.updatePaneExecutablePath(path)
            terminal.feed(text: "\u{1b}[32m$\u{1b}[0m tecolot\r\nPane title bars and theme colors\r\n\u{1b}[36mReady.\u{1b}[0m\r\n")
        }
        for _ in 0..<30 {
            if first.panePresentation.title.contains("Stress-test") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        host.refreshAppearance()
        host.layoutSubtreeIfNeeded()
        for controller in workspace.controllers {
            let terminal = try #require(controller.terminal)
            #expect(terminal.bounds.width > 100)
            #expect(terminal.bounds.height > 100)
        }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(Array(png), named: "pane-cards-\(themeName).png")
    }

    @Test func appearanceToggleKeepsViewsFocusAndDividerFraction() throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let first = try #require(workspace.focusedController)
        workspace.split(first, direction: .right)
        let second = try #require(workspace.focusedController)
        let document = TerminalDocument()
        let host = TerminalPaneHostView(workspace: workspace, document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        let enabled = GlobalAppearanceSettings(paneCardsEnabled: true, paneCardsBackdrop: .gradient)
        host.synchronize(revision: workspace.revision, document: document, settings: enabled)
        host.layoutSubtreeIfNeeded()
        let split = try #require(host.subviews.compactMap { $0 as? NSSplitView }.first)
        let firstCard = try #require(split.arrangedSubviews[0] as? TerminalPaneCardView)
        let firstTerminal = try #require(first.terminal)
        let secondTerminal = try #require(second.terminal)
        split.setPosition(250, ofDividerAt: 0)
        split.adjustSubviews()
        host.layoutSubtreeIfNeeded()
        let fraction = split.arrangedSubviews[0].frame.width / (split.bounds.width - split.dividerThickness)
        window.makeFirstResponder(secondTerminal)

        host.synchronize(revision: workspace.revision, document: document,
                         settings: .init(paneCardsEnabled: false, paneCardsBackdrop: .gradient))
        host.layoutSubtreeIfNeeded()
        #expect(split.arrangedSubviews[0] === firstCard)
        #expect(first.terminal === firstTerminal)
        #expect(second.terminal === secondTerminal)
        #expect(window.firstResponder === secondTerminal)
        #expect(split.dividerThickness == 1)
        #expect(abs(firstCard.content.frame.height - firstCard.bounds.height) < 0.5)
        #expect(abs(firstTerminal.frame.minX - 2) < 0.5)
        #expect(abs(firstTerminal.frame.minY - 2) < 0.5)
        let disabledFraction = split.arrangedSubviews[0].frame.width / (split.bounds.width - split.dividerThickness)
        #expect(abs(disabledFraction - fraction) < 0.02)

        host.synchronize(revision: workspace.revision, document: document, settings: enabled)
        host.layoutSubtreeIfNeeded()
        #expect(split.dividerThickness == 12)
        #expect(abs(firstCard.bounds.height - firstCard.content.frame.height - 32) < 0.5)
        #expect(firstCard.content.terminal.superview === firstCard.content)
        // Cards use the padding setting too. The default is two points.
        #expect(firstTerminal.frame == firstCard.content.bounds.insetBy(dx: 2, dy: 2))
        #expect(window.firstResponder === secondTerminal)
    }

    @Test(arguments: [true, false])
    func paddingSettingInsetsTheTerminal(cards: Bool) throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let first = try #require(workspace.focusedController)
        workspace.split(first, direction: .right)
        let document = TerminalDocument()
        let host = TerminalPaneHostView(workspace: workspace, document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        for padding in GlobalAppearanceSettings.TerminalPadding.allCases {
            host.synchronize(revision: workspace.revision, document: document,
                             settings: .init(paneCardsEnabled: cards, paneCardsBackdrop: .gradient,
                                             terminalPadding: padding))
            host.layoutSubtreeIfNeeded()
            let terminal = try #require(first.terminal)
            #expect(host.cardsEnabled == cards)
            let container = try #require(terminal.superview as? TerminalSessionContainerView)
            let side = padding.points
            let top = padding.topPoints(cardsEnabled: cards)
            #expect(container.padding == side)
            #expect(container.topPadding == top)
            #expect(terminal.frame == NSRect(x: side, y: side, width: container.bounds.width - side * 2,
                                             height: container.bounds.height - top - side))
        }
    }

    @Test func paddingRaisesTheMinimumPaneSize() throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let first = try #require(workspace.focusedController)
        workspace.split(first, direction: .right)
        let document = TerminalDocument()
        let host = TerminalPaneHostView(workspace: workspace, document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        func minimum(_ padding: GlobalAppearanceSettings.TerminalPadding) throws -> CGFloat {
            host.synchronize(revision: workspace.revision, document: document,
                             settings: .init(paneCardsEnabled: false, paneCardsBackdrop: .gradient,
                                             terminalPadding: padding))
            host.layoutSubtreeIfNeeded()
            let split = try #require(host.subviews.compactMap { $0 as? NSSplitView }.first)
            return host.splitView(split, constrainMinCoordinate: 0, ofSubviewAt: 0)
        }
        let off = try minimum(.off)
        let spacious = try minimum(.spacious)
        // The first pane is one cell plus the padding on its two sides.
        #expect(abs(spacious - off - 24) < 0.5)
    }

    @Test func largePaddingCanTurnOffCardsInASmallWindow() throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let first = try #require(workspace.focusedController)
        workspace.split(first, direction: .down)
        let document = TerminalDocument()
        let host = TerminalPaneHostView(workspace: workspace, document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        host.synchronize(revision: workspace.revision, document: document,
                         settings: .init(terminalPadding: .off))
        host.layoutSubtreeIfNeeded()
        let terminal = try #require(first.terminal)
        let cell = terminal.bounds.height / CGFloat(terminal.terminalDimensions.rows)
        // Three spaces, two title bars and two rows, with 8 points to spare.
        // Spacious padding needs 2 x 24 more points, so the cards do not fit.
        let height = GlobalAppearanceSettings.cardSpacing * 3 + GlobalAppearanceSettings.cardTitlebarHeight * 2
            + cell * 2 + 8
        window.setContentSize(NSSize(width: 800, height: height.rounded(.up)))
        host.layoutSubtreeIfNeeded()
        #expect(host.cardsEnabled)

        host.synchronize(revision: workspace.revision, document: document,
                         settings: .init(terminalPadding: .spacious))
        host.layoutSubtreeIfNeeded()
        #expect(!host.cardsEnabled)
    }

    @Test func inactivePaneReceivesItsOwnTitleAndDirectory() async throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let first = try #require(workspace.focusedController)
        workspace.split(first, direction: .right)
        let second = try #require(workspace.focusedController)
        let document = TerminalDocument()
        let host = TerminalPaneHostView(workspace: workspace, document: document)
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        host.synchronize(revision: workspace.revision, document: document)
        let terminal = try #require(first.terminal)
        var profile = TerminalProfile(name: "Pane Title Test")
        profile.titleOverride = nil
        profile.titleComponents = [.activeTitle]
        first.applyProfile(profile)
        first.setTerminalTitle(source: terminal, title: "Independent title")
        first.hostCurrentDirectoryUpdate(source: terminal, directory: "file://localhost/tmp/pane-one")
        for _ in 0..<30 {
            if first.panePresentation.title.contains("Independent title") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(first.panePresentation.title.contains("Independent title"))
        #expect(first.panePresentation.directory == "/tmp/pane-one")
        #expect(!second.panePresentation.title.contains("Independent title"))
        #expect(workspace.focusedController === second)
    }

    @Test func paneControlsSelectTheirPaneBeforeSplitAndZoom() throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let first = try #require(workspace.focusedController)
        let document = TerminalDocument()
        let host = TerminalPaneHostView(workspace: workspace, document: document)
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        host.synchronize(revision: workspace.revision, document: document)
        let card = try #require(host.subviews.compactMap { $0 as? TerminalPaneCardView }.first)
        card.splitRight()
        #expect(workspace.paneCount == 2)
        #expect(workspace.focusedController !== first)
        card.toggleZoom()
        #expect(workspace.focusedController === first)
        #expect(workspace.zoomedControllerID == first.id)
        card.toggleZoom()
        #expect(workspace.zoomedControllerID == nil)
    }

    @Test func tabIconsFollowTheWindowSettings() throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let document = TerminalDocument()
        let host = TerminalPaneHostView(workspace: workspace, document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.synchronize(revision: workspace.revision, document: document,
                         settings: .init(paneCardsEnabled: false, paneCardsBackdrop: .gradient))
        TerminalSplitZoomTitlebar.configure(window, workspace: workspace)
        #expect(window.tab.attributedTitle == nil)
        host.synchronize(revision: workspace.revision, document: document, settings: GlobalAppearanceSettings())
        TerminalSplitZoomTitlebar.configure(window, workspace: workspace)
        #expect(window.tab.attributedTitle != nil)
    }

    @Test func splitAppliesCardMetricsOnlyToTheNewTree() throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let first = try #require(workspace.focusedController)
        let document = TerminalDocument()
        let host = TerminalPaneHostView(workspace: workspace, document: document)
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        host.synchronize(revision: workspace.revision, document: document)
        host.layoutSubtreeIfNeeded()
        let oldCard = try #require(host.subviews.compactMap { $0 as? TerminalPaneCardView }.first)
        #expect(!oldCard.cardsEnabled)

        workspace.split(first, direction: .right)
        host.synchronize(revision: workspace.revision, document: document)
        // The old card must not get the card metrics before the rebuild.
        // That layout would send one more size change to the terminal.
        #expect(!oldCard.cardsEnabled)
        #expect(oldCard.superview == nil)
        #expect(host.cardsEnabled)
        let split = try #require(host.subviews.compactMap { $0 as? NSSplitView }.first)
        #expect(split.arrangedSubviews.allSatisfy { ($0 as? TerminalPaneCardView)?.cardsEnabled == true })
    }

    @Test func smallWindowUsesTheCompactLayout() throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let first = try #require(workspace.focusedController)
        workspace.split(first, direction: .down)
        let document = TerminalDocument()
        let host = TerminalPaneHostView(workspace: workspace, document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        host.synchronize(revision: workspace.revision, document: document)
        host.layoutSubtreeIfNeeded()
        let split = try #require(host.subviews.compactMap { $0 as? NSSplitView }.first)
        let cards = split.arrangedSubviews.compactMap { $0 as? TerminalPaneCardView }
        #expect(host.cardsEnabled)
        #expect(split.dividerThickness == GlobalAppearanceSettings.cardSpacing)

        // Two title bars, three spaces and two rows need more than 100 points.
        window.setContentSize(NSSize(width: 800, height: 100))
        host.layoutSubtreeIfNeeded()
        #expect(host.bounds.height == 100)
        #expect(!host.cardsEnabled)
        #expect(split.dividerThickness == 1)
        #expect(cards.allSatisfy { !$0.cardsEnabled })
        #expect(split.frame == host.bounds)
        for card in cards {
            #expect(abs(card.content.frame.height - card.bounds.height) < 0.5)
        }

        window.setContentSize(NSSize(width: 800, height: 500))
        host.layoutSubtreeIfNeeded()
        #expect(host.cardsEnabled)
        #expect(split.dividerThickness == GlobalAppearanceSettings.cardSpacing)
        #expect(cards.allSatisfy { $0.cardsEnabled })
    }

    @Test func dividerIsFreeWhenPanesDoNotFit() throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let first = try #require(workspace.focusedController)
        workspace.split(first, direction: .right)
        let document = TerminalDocument()
        let host = TerminalPaneHostView(workspace: workspace, document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        host.synchronize(revision: workspace.revision, document: document)
        host.layoutSubtreeIfNeeded()
        let split = try #require(host.subviews.compactMap { $0 as? NSSplitView }.first)
        #expect(host.splitView(split, constrainMinCoordinate: 0, ofSubviewAt: 0) > 0)
        #expect(host.splitView(split, constrainMaxCoordinate: split.bounds.width, ofSubviewAt: 0)
            < split.bounds.width - split.dividerThickness)

        // The split view is now smaller than the two minimum pane widths.
        split.frame.size.width = 6
        let firstWidth = split.arrangedSubviews[0].frame.width
        #expect(host.splitView(split, constrainMinCoordinate: 1, ofSubviewAt: 0) == 1)
        #expect(host.splitView(split, constrainMaxCoordinate: 5, ofSubviewAt: 0) == 5)
        workspace.moveDivider(in: .right)
        #expect(split.arrangedSubviews[0].frame.width == firstWidth)
    }

    @Test func compactStyleKeepsTheTitleBarWithoutSpaceOrDecorations() throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let first = try #require(workspace.focusedController)
        workspace.split(first, direction: .right)
        let document = TerminalDocument()
        let host = TerminalPaneHostView(workspace: workspace, document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        // The desktop blur shows only when the backdrop is visible.
        host.synchronize(revision: workspace.revision, document: document,
                         settings: .init(paneCardsBackdrop: .desktopBlur, paneStyle: .compact))
        host.layoutSubtreeIfNeeded()
        let split = try #require(host.subviews.compactMap { $0 as? NSSplitView }.first)
        let cards = split.arrangedSubviews.compactMap { $0 as? TerminalPaneCardView }
        #expect(host.cardsEnabled)
        #expect(host.appliedPaneStyle == .compact)
        #expect(split.frame == host.bounds)
        #expect(split.dividerThickness == 1)
        #expect(!host.showsDesktopBlur)
        for card in cards {
            #expect(card.cardsEnabled)
            #expect(card.layer?.shadowOpacity == 0)
            let surface = try #require(card.subviews.first)
            #expect(surface.layer?.cornerRadius == 0)
            let header = try #require(surface.subviews.first { !($0 is TerminalSessionContainerView) })
            #expect(!header.isHidden)
            #expect(header.frame.height == GlobalAppearanceSettings.cardTitlebarHeight)
        }

        host.synchronize(revision: workspace.revision, document: document,
                         settings: .init(paneCardsBackdrop: .desktopBlur, paneStyle: .comfortable))
        host.layoutSubtreeIfNeeded()
        let spacing = GlobalAppearanceSettings.cardSpacing
        #expect(host.appliedPaneStyle == .comfortable)
        #expect(split.frame == host.bounds.insetBy(dx: spacing, dy: spacing))
        #expect(split.dividerThickness == spacing)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            #expect(host.showsDesktopBlur)
        }
        for card in cards {
            #expect(card.layer?.shadowOpacity ?? 0 > 0)
            #expect(card.subviews.first?.layer?.cornerRadius == 14)
        }
    }

    /// A window on the screen. The transitions run only in a visible window.
    /// macOS updates the occlusion state some time after the window shows.
    private func visibleWindow(for host: TerminalPaneHostView) async throws -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        for _ in 0..<40 where !window.occlusionState.contains(.visible) {
            try await Task.sleep(for: .milliseconds(50))
        }
        return window
    }

    @Test(.enabled(if: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion),
          arguments: [TerminalPaneDirection.right, .left, .down, .up])
    func newPaneGrowsFromTheEdgeOfItsSplit(direction: TerminalPaneDirection) async throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let first = try #require(workspace.focusedController)
        let document = TerminalDocument()
        let host = TerminalPaneHostView(workspace: workspace, document: document)
        let window = try await visibleWindow(for: host)
        defer { window.orderOut(nil) }
        host.synchronize(revision: workspace.revision, document: document)
        host.layoutSubtreeIfNeeded()
        try #require(host.transitionsAllowed)

        workspace.split(first, direction: direction)
        host.synchronize(revision: workspace.revision, document: document)
        #expect(workspace.pendingTransition == nil)
        #expect(host.isRunningTransition)
        let second = try #require(workspace.focusedController)
        let split = try #require(host.subviews.compactMap { $0 as? NSSplitView }.first)
        let card = try #require(split.arrangedSubviews.compactMap { $0 as? TerminalPaneCardView }
            .first { $0.controller === second })
        let layer = try #require(card.layer)
        // The animations start in the display pass, not in the layout pass.
        // The test calls viewWillDraw() in place of the display pass.
        #expect(layer.animation(forKey: "paneTransition.bounds") == nil)
        host.viewWillDraw()

        // The animation converts host rectangles through the layer tree.
        #expect(host.layerRect(card.convert(card.bounds, to: host), for: card) == layer.frame)
        let bounds = try #require(layer.animation(forKey: "paneTransition.bounds") as? CABasicAnimation)
        let start = try #require((bounds.fromValue as? NSValue)?.rectValue)
        let horizontal = direction == .left || direction == .right
        #expect(horizontal ? start.width == 0 : start.height == 0)
        #expect(layer.masksToBounds)

        // The divider starts at the outer edge of the new pane.
        let position = try #require(layer.animation(forKey: "paneTransition.position") as? CABasicAnimation)
        let from = try #require((position.fromValue as? NSValue)?.pointValue)
        let edge = TerminalPaneHostView.edgeRect(of: card.convert(card.bounds, to: host), at: direction)
        let expected = try #require(host.layerRect(edge, for: card))
        #expect(abs(from.x - (expected.minX + layer.anchorPoint.x * expected.width)) < 0.5)
        #expect(abs(from.y - (expected.minY + layer.anchorPoint.y * expected.height)) < 0.5)

        host.cancelTransition()
        #expect(!host.isRunningTransition)
        #expect(!layer.masksToBounds)
        #expect(!(layer.animationKeys() ?? []).contains { $0.hasPrefix("paneTransition") })
    }

    @Test(.enabled(if: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))
    func closedPaneShrinksToItsOuterEdge() async throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let first = try #require(workspace.focusedController)
        workspace.split(first, direction: .right)
        let second = try #require(workspace.focusedController)
        let document = TerminalDocument()
        let host = TerminalPaneHostView(workspace: workspace, document: document)
        let window = try await visibleWindow(for: host)
        defer { window.orderOut(nil) }
        host.synchronize(revision: workspace.revision, document: document)
        host.layoutSubtreeIfNeeded()
        try #require(host.transitionsAllowed)
        let split = try #require(host.subviews.compactMap { $0 as? NSSplitView }.first)
        let closed = try #require(split.arrangedSubviews.compactMap { $0 as? TerminalPaneCardView }
            .first { $0.controller === second })
        let oldFrame = closed.convert(closed.bounds, to: host)

        #expect(workspace.close(second))
        host.synchronize(revision: workspace.revision, document: document)
        host.viewWillDraw()
        #expect(host.isRunningTransition)
        // The card of the closed pane stays in the window, in an overlay
        // above the panes, and takes no clicks.
        let overlay = try #require(closed.superview as? TerminalTransitionOverlayView)
        #expect(overlay.superview === host)
        #expect(closed.window === window)
        #expect(closed.convert(closed.bounds, to: host) == oldFrame)
        let point = NSPoint(x: oldFrame.midX, y: oldFrame.midY)
        let hit = host.hitTest(host.convert(point, to: host.superview))
        #expect(hit == nil || !(hit!.isDescendant(of: closed)))
        let bounds = try #require(closed.layer?.animation(forKey: "paneTransition.bounds") as? CABasicAnimation)
        #expect((bounds.toValue as? NSValue)?.rectValue.width == 0)
        let position = try #require(closed.layer?.animation(forKey: "paneTransition.position") as? CABasicAnimation)
        // The second pane of a vertical split shrinks to its right edge.
        let end = try #require(host.layerRect(CGRect(x: oldFrame.maxX, y: oldFrame.minY, width: 0,
                                                     height: oldFrame.height), for: closed))
        #expect((position.toValue as? NSValue)?.pointValue.x == end.minX)

        // The pane that stays grows from its old frame.
        let survivor = try #require(host.subviews.compactMap { $0 as? TerminalPaneCardView }
            .first { $0.controller === first })
        #expect(survivor.layer?.animation(forKey: "paneTransition.bounds") != nil)

        // A second close of the same pane, for example when its process
        // exits, does nothing and does not stop the transition.
        #expect(!workspace.close(second))
        #expect(host.isRunningTransition)
        // A close request from the closed pane does not close the window.
        second.requestClose()
        #expect(window.isVisible)

        host.cancelTransition()
        #expect(closed.superview == nil)
        #expect(!host.isRunningTransition)
    }

    @Test func noTransitionInAWindowThatIsNotVisible() throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let first = try #require(workspace.focusedController)
        let document = TerminalDocument()
        let host = TerminalPaneHostView(workspace: workspace, document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.synchronize(revision: workspace.revision, document: document)
        #expect(!host.transitionsAllowed)
        workspace.split(first, direction: .right)
        host.synchronize(revision: workspace.revision, document: document)
        #expect(!host.isRunningTransition)
        let second = try #require(workspace.focusedController)
        #expect(workspace.close(second))
        #expect(workspace.pendingTransition == nil)
    }

    @Test func zoomedSplitDoesNotAnimate() throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let first = try #require(workspace.focusedController)
        workspace.split(first, direction: .right)
        workspace.toggleSplitZoom()
        let zoomed = try #require(workspace.focusedController)
        workspace.split(zoomed, direction: .down)
        #expect(workspace.pendingTransition == nil)
    }
}
