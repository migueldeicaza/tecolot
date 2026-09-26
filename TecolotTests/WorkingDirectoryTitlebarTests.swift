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
        #expect(menu.items.compactMap { $0.representedObject as? URL }.map(\.path)
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

    @Test func installsOneAccessoryAndHidesDocumentTitle() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.toolbar = NSToolbar(identifier: "WorkingDirectoryTitlebarTests")
        window.toolbarStyle = .unifiedCompact
        TerminalWorkingDirectoryTitlebar.configure(
            window, path: "/tmp", title: "Terminal", hasActivity: false,
            enableProxyIcon: true
        )
        TerminalWorkingDirectoryTitlebar.configure(
            window, path: "/Users", title: "Terminal", hasActivity: false,
            enableProxyIcon: true
        )

        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAccessoryViewControllers.count == 1)
        let control = try #require(
            window.titlebarAccessoryViewControllers.first?.view as? WorkingDirectoryTitlebarControl
        )
        #expect(control.path == "/Users")
        #expect(!control.mouseDownCanMoveWindow)
        TerminalWorkingDirectoryTitlebar.configure(
            window, path: "/Users", title: "Terminal", hasActivity: false,
            enableProxyIcon: false
        )
        #expect(control.path == nil)
        #expect(control.mouseDownCanMoveWindow)
        let stack = try #require(control.subviews.first as? NSStackView)
        let label = try #require(stack.arrangedSubviews.last as? NSTextField)
        #expect(label.stringValue == "Terminal")
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
        #expect(control.menu(for: event) == nil)
        TerminalWorkingDirectoryTitlebar.configure(
            window, path: "/Users", title: "Terminal", hasActivity: false,
            enableProxyIcon: true
        )
        #expect(control.path == "/Users")
        #expect(!control.mouseDownCanMoveWindow)
        #expect(control.menu(for: event) != nil)

        let themeController = TerminalSessionController(startsProcess: false)
        TerminalThemeTitlebar.configure(
            window,
            controller: themeController,
            profiles: SettingsPreviewData.profiles,
            themes: SettingsPreviewData.themes,
            themeIndex: SettingsPreviewData.themeIndex
        )
        #expect(window.titlebarAccessoryViewControllers.count == 2)
        let themeAccessory = try #require(window.titlebarAccessoryViewControllers.first {
            $0.layoutAttribute == .right
        })
        let themeControl = try #require(themeAccessory.view as? ThemeTitlebarControl)
        TerminalThemeTitlebar.configure(
            window,
            controller: themeController,
            profiles: SettingsPreviewData.profiles,
            themes: SettingsPreviewData.themes,
            themeIndex: SettingsPreviewData.themeIndex
        )
        #expect(window.titlebarAccessoryViewControllers.count == 2)

        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        control.layoutSubtreeIfNeeded()
        themeControl.layoutSubtreeIfNeeded()
        let closeButton = try #require(window.standardWindowButton(.closeButton))
        let themeButton = try #require(themeControl.subviews.first as? NSButton)
        let buttonCenter = NSPoint(x: closeButton.bounds.midX, y: closeButton.bounds.midY)
        let stackCenter = NSPoint(x: stack.bounds.midX, y: stack.bounds.midY)
        let themeCenter = NSPoint(x: themeButton.bounds.midX, y: themeButton.bounds.midY)
        #expect(abs(closeButton.convert(buttonCenter, to: control).y
                    - stack.convert(stackCenter, to: control).y) < 1)
        #expect(abs(closeButton.convert(buttonCenter, to: themeControl).y
                    - themeButton.convert(themeCenter, to: themeControl).y) < 1)
        #expect(themeControl.convert(themeControl.bounds, to: nil).maxX
                > window.frame.width - 70)
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
}
