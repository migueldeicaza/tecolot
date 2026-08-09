import AppKit
import Foundation
import Testing
@testable import Tecolot

struct AppearancePreferencesTests {
    @Test
    func preferenceEnumsUseStableValues() {
        #expect(InterfaceAppearance.system.rawValue == "system")
        #expect(InterfaceAppearance.light.rawValue == "light")
        #expect(InterfaceAppearance.dark.rawValue == "dark")
        #expect(MacTitlebarStyle.native.rawValue == "native")
        #expect(MacTitlebarStyle.blended.rawValue == "blended")
        #expect(MacTitlebarStyle.liquidGlass.rawValue == "liquid-glass")
    }

    @Test
    func invalidPreferencesUseDefaults() throws {
        let suiteName = "AppearancePreferencesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("unknown", forKey: AppearancePreferences.interfaceAppearanceKey)
        defaults.set("unknown", forKey: AppearancePreferences.macosTitlebarStyleKey)

        #expect(InterfaceAppearance.load(from: defaults) == .system)
        #expect(MacTitlebarStyle.load(from: defaults) == .native)
    }

    @Test
    func liquidGlassFallsBackBeforeMacOS26() {
        let macOS15 = OperatingSystemVersion(majorVersion: 15, minorVersion: 5, patchVersion: 0)
        let macOS26 = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)

        #expect(MacTitlebarStyle.liquidGlass.resolved(for: macOS15) == .blended)
        #expect(MacTitlebarStyle.liquidGlass.resolved(for: macOS26) == .liquidGlass)
        #expect(MacTitlebarStyle.native.resolved(for: macOS15) == .native)
    }

    @Test @MainActor
    func focusedBottomPaneDoesNotControlTitlebar() {
        let workspace = TerminalPaneWorkspace()
        let bottom = workspace.focusedController!

        workspace.split(bottom, orientation: .horizontal)
        let top = workspace.focusedController!
        #expect(workspace.titlebarController === top)

        workspace.markFocused(bottom)
        #expect(workspace.titlebarController === top)
    }

    @Test @MainActor
    func focusedTopPaneControlsTitlebarAcrossVerticalSplit() {
        let workspace = TerminalPaneWorkspace()
        let original = workspace.focusedController!

        workspace.split(original, orientation: .vertical)
        let right = workspace.focusedController!
        #expect(workspace.titlebarController === right)

        workspace.markFocused(original)
        #expect(workspace.titlebarController === original)
    }

    @Test @MainActor
    func macOS27FindsTabBarInSeparateHostWindow() {
        let documentWindow = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 500),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let hostWindow = MacOS27TabHostWindow(
            contentRect: NSRect(x: 100, y: 560, width: 800, height: 40),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let hostContentView = NSView(frame: hostWindow.contentLayoutRect)
        let tabBarView = MacOS27TabBarView(frame: hostContentView.bounds)
        hostContentView.addSubview(tabBarView)
        hostWindow.contentView = hostContentView

        let macOS26 = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        let macOS27 = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
        let hostClassName = String(describing: type(of: hostWindow))
        let tabBarClassName = String(describing: type(of: tabBarView))

        let oldResult = WindowChromeViewLookup.tabBarView(
            for: documentWindow,
            operatingSystemVersion: macOS26,
            applicationWindows: [hostWindow],
            tabHostClassName: hostClassName,
            tabBarClassName: tabBarClassName
        )
        let newResult = WindowChromeViewLookup.tabBarView(
            for: documentWindow,
            operatingSystemVersion: macOS27,
            applicationWindows: [hostWindow],
            tabHostClassName: hostClassName,
            tabBarClassName: tabBarClassName
        )

        #expect(oldResult == nil)
        #expect(newResult === tabBarView)
    }
}

@MainActor
private final class MacOS27TabHostWindow: NSWindow {}

@MainActor
private final class MacOS27TabBarView: NSView {}
