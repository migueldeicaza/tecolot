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
        let document = TerminalDocument(content: "")
        let host = TerminalPaneHostView(workspace: workspace, document: document)
        host.frame = NSRect(x: 0, y: 0, width: 1500, height: 800)
        let settings = GlobalAppearanceSettings(paneCardsEnabled: true, paneCardsBackdrop: .gradient)
        host.synchronize(revision: workspace.revision, document: document, settings: settings)
        let terminal = try #require(first.terminal)
        var profile = TerminalProfile(name: "Title Width Test")
        profile.titleOverride = nil
        profile.titleComponents = [.activeTitle]
        profile.themeName = themeName
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
        let document = TerminalDocument(content: "")
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
        let document = TerminalDocument(content: "")
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
        let document = TerminalDocument(content: "")
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
            profile.themeName = themeName
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
        let document = TerminalDocument(content: "")
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
        #expect(firstTerminal.frame == firstCard.content.bounds)
        #expect(window.firstResponder === secondTerminal)
    }

    @Test func inactivePaneReceivesItsOwnTitleAndDirectory() async throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let first = try #require(workspace.focusedController)
        workspace.split(first, direction: .right)
        let second = try #require(workspace.focusedController)
        let document = TerminalDocument(content: "")
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
        let document = TerminalDocument(content: "")
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
        let document = TerminalDocument(content: "")
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
        let document = TerminalDocument(content: "")
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
        let document = TerminalDocument(content: "")
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
        let document = TerminalDocument(content: "")
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
}
