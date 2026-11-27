import AppKit
import Testing
@testable import Tecolot

@MainActor
struct WorkingDirectoryTitlebarTests {
    @Test func readsLocalOSC7Reports() async {
        #expect(TerminalWorkingDirectory.path(from: "file:///Users/miguel/My%20Project")
            == "/Users/miguel/My Project")
        await LocalHostNames.shared.load().value
        let host = ProcessInfo.processInfo.hostName
        #expect(TerminalWorkingDirectory.path(from: "kitty-shell-cwd://\(host)/Users/miguel/src")
            == "/Users/miguel/src")
    }

    @Test func ignoresReportsThatAreNotLocalDirectories() {
        #expect(TerminalWorkingDirectory.path(from: nil) == nil)
        #expect(TerminalWorkingDirectory.path(from: "https://example.com/tmp") == nil)
        #expect(TerminalWorkingDirectory.path(from: "file://other-machine.invalid/tmp") == nil)
        #expect(TerminalWorkingDirectory.path(from: "kitty-shell-cwd://localhost") == nil)
    }

    @Test func listsEachParentThroughTheRoot() {
        #expect(TerminalWorkingDirectory.ancestors(of: "/Users/miguel/src").map(\.path)
            == ["/Users/miguel/src", "/Users/miguel", "/Users", "/"])
        #expect(TerminalWorkingDirectory.ancestors(of: "/").map(\.path) == ["/"])
    }

    @Test func titlebarControlOwnsTheDragAndAncestorMenu() throws {
        let control = WorkingDirectoryTitlebarControl()
        control.configure(path: "/Users/miguel/src", title: "Ignored", hasActivity: false)
        control.frame = NSRect(origin: .zero, size: control.intrinsicContentSize)

        #expect(!control.mouseDownCanMoveWindow)
        #expect(control.hitTest(NSPoint(x: 5, y: 12)) === control)
        #expect(control.hitTest(NSPoint(x: 40, y: 12)) === control)
        #expect(control.pasteboardItem(for: "/Users/miguel/src").string(forType: .string)
            == "/Users/miguel/src")

        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let menu = try #require(control.menu(for: event))
        #expect(menu.items.compactMap {
            $0.representedObject as? URL
        }.map(\.path)
            == ["/Users/miguel/src", "/Users/miguel", "/Users", "/"])
    }

    @Test func dragOffersTextAndAFileURLThatTheTerminalAccepts() {
        let path = "/Users/miguel/My Project"
        let item = WorkingDirectoryTitlebarControl().pasteboardItem(for: path)
        #expect(item.string(forType: .string) == path)
        #expect(item.string(forType: .fileURL)
            == URL(fileURLWithPath: path, isDirectory: true).absoluteString)

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(pasteboard.writeObjects([item]))
        #expect(TerminalFileDrop.hasFileURLs(in: pasteboard))
        #expect(TerminalFileDrop.text(from: pasteboard, dialect: .zsh)
            == "'/Users/miguel/My Project' ")
    }

    @Test func showsActivityBetweenFolderAndPathWithoutChangingDragText() throws {
        let path = "/Users/miguel/src"
        let control = WorkingDirectoryTitlebarControl()
        control.configure(path: path, title: "● Terminal", hasActivity: true)
        let stack = try #require(control.subviews.first as? NSStackView)
        let label = try #require(stack.arrangedSubviews.last as? NSTextField)
        #expect(label.stringValue == "● Terminal | \(path)")
        #expect(control.accessibilityLabel() == "Activity. Terminal. Working directory: \(path)")
        #expect(control.isAccessibilityElement())
        #expect((control.accessibilityValue() as? String)?.contains(path) == true)
        #expect(control.pasteboardItem(for: path).string(forType: .string) == path)

        control.configure(path: path, title: "Terminal", hasActivity: false)
        #expect(label.stringValue == "Terminal | \(path)")
        #expect(control.accessibilityLabel() == "Terminal. Working directory: \(path)")

        control.configure(path: path, title: "● Terminal", hasActivity: false)
        #expect(label.stringValue == "Terminal | \(path)")

        control.configure(path: nil, title: "● Terminal", hasActivity: true)
        #expect(label.stringValue == "● Terminal")
    }

    @Test func doesNotShowThePathTwiceWhenTheTitleHasIt() throws {
        let path = "/Users/miguel/src"
        let control = WorkingDirectoryTitlebarControl()
        let stack = try #require(control.subviews.first as? NSStackView)
        let label = try #require(stack.arrangedSubviews.last as? NSTextField)

        control.configure(path: path, title: "● vim — /Users/miguel/src/ — Default", hasActivity: true)
        #expect(label.stringValue == "● vim — Default | \(path)")
        #expect(control.accessibilityLabel() == "Activity. vim — Default. Working directory: \(path)")

        control.configure(path: path, title: path, hasActivity: false)
        #expect(label.stringValue == path)

        control.configure(path: path, title: "vim — /Users/miguel", hasActivity: false)
        #expect(label.stringValue == "vim — /Users/miguel | \(path)")

        control.configure(path: nil, title: "vim — \(path)", hasActivity: false)
        #expect(label.stringValue == "vim — \(path)")
    }

    @Test func controlsAreHostedInTheStripWithoutTitlebarAccessories() throws {
        let manager = TerminalWindowManager(registry: TerminalSessionRegistry())
        let group = TerminalTabGroup(name: "gentle-folio", tabs: [TerminalTab(startsProcesses: false)])
        let controller = TerminalWindowController(group: group, manager: manager)
        let window = try #require(controller.window)
        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAccessoryViewControllers.isEmpty)
        #expect(window.tabbingMode == .disallowed)
        #expect(controller.tabBar.subviews.contains {
            $0 is ThemeTitlebarControl
        })
        #expect(controller.tabBar.groupButton.title.isEmpty)
        #expect(controller.tabBar.groupButton.accessibilityValue() as? String == group.name)
    }

    @Test func themeButtonTogglesTheExistingPickerState() throws {
        let control = ThemeTitlebarControl()
        let controller = TerminalSessionController(startsProcess: false)
        control.configure(
            controller: controller,
            profiles: SettingsPreviewData.profiles,
            themes: SettingsPreviewData.themes,
            themeIndex: SettingsPreviewData.themeIndex
        )
        let button = try #require(control.subviews.first as? NSButton)
        button.performClick(nil)
        #expect(controller.showThemePicker)
        button.performClick(nil)
        #expect(!controller.showThemePicker)
    }

    @Test func hiddenThemeControlsDoNotStealOrOpenPopovers() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let content = try #require(window.contentView)
        let visibleControl = ThemeTitlebarControl()
        visibleControl.frame = NSRect(x: 20, y: 20, width: 35, height: 32)
        let hiddenContainer = NSView(frame: NSRect(x: 80, y: 20, width: 60, height: 40))
        hiddenContainer.isHidden = true
        let hiddenControl = ThemeTitlebarControl()
        hiddenControl.frame = NSRect(x: 0, y: 0, width: 35, height: 32)
        hiddenContainer.addSubview(hiddenControl)
        content.addSubview(visibleControl)
        content.addSubview(hiddenContainer)
        content.layoutSubtreeIfNeeded()
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
        }

        let pane = TerminalSessionController(startsProcess: false)
        visibleControl.configure(
            controller: pane,
            profiles: SettingsPreviewData.profiles,
            themes: SettingsPreviewData.themes,
            themeIndex: SettingsPreviewData.themeIndex
        )
        hiddenControl.configure(
            controller: pane,
            profiles: SettingsPreviewData.profiles,
            themes: SettingsPreviewData.themes,
            themeIndex: SettingsPreviewData.themeIndex
        )

        // Clicking the visible control presents its popover; configuring the
        // hidden sibling afterward must NOT open a competing popover or dismiss it.
        let visibleButton = try #require(visibleControl.subviews.first as? NSButton)
        visibleButton.performClick(nil)
        #expect(pane.showThemePicker)
        #expect(visibleControl.isPresentingPopover)

        hiddenControl.configure(
            controller: pane,
            profiles: SettingsPreviewData.profiles,
            themes: SettingsPreviewData.themes,
            themeIndex: SettingsPreviewData.themeIndex
        )
        #expect(!hiddenControl.isPresentingPopover)
        #expect(visibleControl.isPresentingPopover)
        #expect(pane.showThemePicker)

        // Switching visibility (e.g. Left sidebar → Top tabs) lets the newly
        // visible control present cleanly on click.
        visibleControl.isHidden = true
        hiddenContainer.isHidden = false
        visibleControl.configure(
            controller: pane,
            profiles: SettingsPreviewData.profiles,
            themes: SettingsPreviewData.themes,
            themeIndex: SettingsPreviewData.themeIndex
        )
        #expect(!visibleControl.isPresentingPopover)

        let newlyVisibleButton = try #require(hiddenControl.subviews.first as? NSButton)
        newlyVisibleButton.performClick(nil)
        #expect(pane.showThemePicker)
        #expect(hiddenControl.isPresentingPopover)
    }
}
