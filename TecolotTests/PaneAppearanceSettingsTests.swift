import AppKit
import Testing
@testable import Tecolot

@MainActor
struct PaneAppearanceSettingsTests {
    @Test func missingValuesUseRexDefaultsAndFollowTheCurrentAccent() throws {
        let name = "PaneAppearance-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let value = GlobalAppearanceSettings(defaults: defaults)
        #expect(value.highlightActivePane)
        #expect(value.paneHighlightColor == nil)
        #expect(value.resolvedActivePaneColor(accent: .red) == .red)
        #expect(value.resolvedActivePaneColor(accent: .green) == .green)
        #expect(value.activePaneColor == .controlAccentColor)
        #expect(defaults.dictionaryRepresentation()[GlobalAppearanceSettings.paneHighlightColorKey] == nil)
    }

    @Test func customSRGBAndAlphaRoundTripAndResetWithoutChangingExistingKeys() throws {
        let name = "PaneAppearance-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let existing: [String: Any] = ["terminalPadding": "wide", "paneStyle": "compact", "paneCardsEnabled": false, "paneCardsBackdrop": "gradient"]
        for (key, value) in existing {
            defaults.set(value, forKey: key)
        }
        let color = try #require(GlobalAppearanceSettings.HighlightColor(color: NSColor(srgbRed: 0.2, green: 0.4, blue: 0.7, alpha: 0.35)))
        defaults.set(color.encoded, forKey: GlobalAppearanceSettings.paneHighlightColorKey)
        defaults.set(false, forKey: GlobalAppearanceSettings.highlightActivePaneKey)
        let value = GlobalAppearanceSettings(defaults: defaults)
        #expect(value.paneHighlightColor == color)
        #expect(!value.highlightActivePane)
        #expect(abs(value.activePaneColor.alphaComponent - 0.35) < 0.00001)
        #expect(value.resolvedActivePaneColor(accent: .yellow) == color.color)
        #expect(value.terminalPadding == .wide && value.paneStyle == .compact)
        #expect(!value.paneCardsEnabled && value.paneCardsBackdrop == .gradient)
        defaults.set("", forKey: GlobalAppearanceSettings.paneHighlightColorKey)
        let reset = GlobalAppearanceSettings(defaults: defaults)
        #expect(reset.paneHighlightColor == nil)
        #expect(reset.resolvedActivePaneColor(accent: .magenta) == .magenta)
        #expect(!reset.highlightActivePane)
        for (key, value) in existing {
            #expect(NSDictionary(dictionary: [key: defaults.object(forKey: key) as Any]).isEqual(to: [key: value]))
        }
    }

    @Test func damagedColorFallsBackToAccent() {
        for value in ["", "broken", "{}", "{\"red\":2,\"green\":0,\"blue\":0,\"alpha\":1}", "{\"red\":0,\"green\":0,\"blue\":0,\"alpha\":-1}"] {
            #expect(GlobalAppearanceSettings.HighlightColor.decode(value) == nil)
        }
    }

    @Test func highlightOffKeepsOnlyNeutralEdgesAndContrastRemainsVisible() {
        func focus(_ highlight: Bool, contrast: Bool = false, alpha: CGFloat = 0.4, style: GlobalAppearanceSettings.PaneStyle = .comfortable) -> PaneFocusAppearance {
            PaneFocusAppearance(
                enabled: true,
                focused: true,
                showsHeader: true,
                style: style,
                highlight: highlight,
                color: NSColor.red.withAlphaComponent(alpha),
                foreground: .white,
                background: .black,
                highContrast: contrast
            )
        }
        let on = focus(true)
        #expect(on.lineWidth == 2)
        #expect(on.stroke == NSColor.red.withAlphaComponent(0.4))
        #expect(on.shadow == NSColor.red)
        #expect(abs(on.shadowOpacity - 0.072) < 0.00001)
        let off = focus(false)
        #expect(off.lineWidth == 1)
        #expect(off.stroke == NSColor.white.withAlphaComponent(0.1))
        #expect(off.shadow == NSColor.black)
        #expect(off.shadowOpacity == 0.08)
        #expect(focus(false, contrast: true).lineWidth == 2)
        #expect(focus(false, contrast: true).stroke.alphaComponent == 0.8)
        #expect(focus(true, contrast: true, alpha: 0).stroke.alphaComponent == 0.8)
        #expect(focus(false, style: .compact).header == NSColor.black)
        #expect(focus(true, style: .compact).header != NSColor.black)
    }

    @Test func panesPageIsAppWideAndFollowsTabs() throws {
        let pages = SettingsDestination.appPages
        let tabs = try #require(pages.firstIndex(of: .tabs))
        #expect(pages[tabs + 1] == .panes)
        #expect(pages == [.general, .tabs, .panes, .notifications, .data])
        #expect(SettingsDestination.profilePages == [.appearance, .window, .shell, .keyboardAndMouse, .terminal, .manageProfiles])
        #expect(Set(pages + SettingsDestination.profilePages) == Set(SettingsDestination.allCases))
        #expect(!SettingsDestination.panes.isProfileDriven)
        #expect(ProfileSettingsSection(destination: .panes) == nil)
    }

    @Test func onlyProfileEditingPagesAreProfileDriven() {
        let expected: Set<SettingsDestination> = [.appearance, .window, .shell, .keyboardAndMouse, .terminal]
        #expect(Set(SettingsDestination.allCases.filter(\.isProfileDriven)) == expected)
        for destination in SettingsDestination.allCases {
            #expect((ProfileSettingsSection(destination: destination) != nil) == expected.contains(destination))
        }
        #expect(ProfileSettingsSection(destination: .appearance) == .appearance)
        #expect(ProfileSettingsSection(destination: .window) == .window)
        #expect(ProfileSettingsSection(destination: .shell) == .shell)
        #expect(ProfileSettingsSection(destination: .keyboardAndMouse) == .keyboardAndMouse)
        #expect(ProfileSettingsSection(destination: .terminal) == .terminal)
    }

    @Test func tabIconCountClampsOnlyForSideTabs() {
        #expect(TabInterfaceSettingsView.displayedIconCount(stored: 5, tabsOnSide: true) == 3)
        #expect(TabInterfaceSettingsView.displayedIconCount(stored: 5, tabsOnSide: false) == 5)
        #expect(TabInterfaceSettingsView.displayedIconCount(stored: 2, tabsOnSide: true) == 2)
        #expect(TabInterfaceSettingsView.displayedIconCount(stored: 2, tabsOnSide: false) == 2)
    }

    @Test func aSinglePaneKeepsNeutralDecorationEvenWithHighlightEnabled() throws {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        let host = TerminalPaneHostView(workspace: workspace)
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        host.synchronize(revision: workspace.revision)
        host.layoutSubtreeIfNeeded()
        let single = try #require(host.visibleCards.first)
        #expect(single.outlineLayer.lineWidth == 1)
        #expect(single.outlineLayer.strokeColor != GlobalAppearanceSettings().activePaneColor.cgColor)
        workspace.split(try #require(workspace.focusedController), direction: .right)
        host.synchronize(revision: workspace.revision)
        let focused = try #require(host.visibleCards.first {
            $0.controller === workspace.focusedController
        })
        #expect(focused.outlineLayer.lineWidth == 2)
    }

    @Test func newPreferencesReachEveryWindowObserver() async throws {
        let name = "PaneAppearance-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = TerminalWindowPreferences(defaults: defaults)
        let second = TerminalWindowPreferences(defaults: defaults)
        let custom = try #require(GlobalAppearanceSettings.HighlightColor(color: .systemPink.withAlphaComponent(0.5)))
        defaults.set(custom.encoded, forKey: GlobalAppearanceSettings.paneHighlightColorKey)
        defaults.set(false, forKey: GlobalAppearanceSettings.highlightActivePaneKey)
        for _ in 0..<50 {
            if first.value.paneHighlightColor == custom && !first.value.highlightActivePane && second.value == first.value {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(first.value.paneHighlightColor == custom)
        #expect(!first.value.highlightActivePane)
        #expect(second.value == first.value)
    }

    @Test func previewUsesTheSameCustomOutlineAndToggleAsWindows() throws {
        var settings = GlobalAppearanceSettings()
        let color = try #require(GlobalAppearanceSettings.HighlightColor(color: .systemOrange.withAlphaComponent(0.5)))
        settings.paneHighlightColor = color
        let preview = PaneSettingsPreviewView(settings: settings)
        preview.frame = NSRect(x: 0, y: 0, width: 600, height: 180)
        preview.layoutSubtreeIfNeeded()
        let focused = try #require(preview.host.visibleCards.first {
            $0.controller === preview.host.workspace.focusedController
        })
        #expect(focused.outlineLayer.strokeColor == settings.activePaneColor.usingColorSpace(.sRGB)?.cgColor)
        #expect(focused.outlineLayer.lineWidth == 2)
        #expect(focused.outlineLayer.superlayer !== focused.layer)
        settings.highlightActivePane = false
        preview.host.synchronize(revision: preview.host.workspace.revision, settings: settings)
        #expect(focused.outlineLayer.lineWidth == 1)
        #expect(focused.outlineLayer.strokeColor != settings.activePaneColor.cgColor)
    }
}
