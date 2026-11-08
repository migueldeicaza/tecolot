import AppKit
import Testing
@testable import Tecolot

struct GlobalAppearanceSettingsTests {
    @Test func defaultsEnableCardsAndGradient() {
        let settings = GlobalAppearanceSettings()
        #expect(settings.paneCardsEnabled)
        #expect(settings.paneCardsBackdrop == .gradient)
        // UserDefaults keeps these raw values.
        #expect(GlobalAppearanceSettings.Backdrop.allCases.map(\.rawValue) == ["gradient", "desktopBlur"])
        #expect(GlobalAppearanceSettings.Backdrop(rawValue: "invalid") == nil)
    }

    @Test func terminalPaddingDefaultsAndValues() {
        typealias Padding = GlobalAppearanceSettings.TerminalPadding
        #expect(GlobalAppearanceSettings().terminalPadding == .minimal)
        // UserDefaults keeps these raw values.
        #expect(Padding.allCases.map(\.rawValue) == ["none", "minimal", "wide", "spacious"])
        #expect(Padding.allCases.map(\.points) == [0, 2, 8, 12])
        #expect(Padding(rawValue: "invalid") == nil)
        #expect(Padding(rawValue: "none") == .off)
    }

    @MainActor
    @Test func paneStyleDefaultsAndMetrics() {
        typealias Style = GlobalAppearanceSettings.PaneStyle
        #expect(GlobalAppearanceSettings().paneStyle == .comfortable)
        // UserDefaults keeps these raw values.
        #expect(Style.allCases.map(\.rawValue) == ["comfortable", "compact"])
        #expect(Style(rawValue: "invalid") == nil)
        #expect(Style.allCases.map(\.showsDecorations) == [true, false])
        #expect(Style.allCases.map(\.spacing) == [12, 0])
        #expect(Style.allCases.map(\.cornerRadius) == [14, 0])
        #expect(TerminalWorkspaceSplitView.dividerThickness(cardsEnabled: true, style: .comfortable) == 12)
        #expect(TerminalWorkspaceSplitView.dividerThickness(cardsEnabled: true, style: .compact) == 1)
        #expect(TerminalWorkspaceSplitView.dividerThickness(cardsEnabled: false, style: .comfortable) == 1)
    }

    @Test func topPaddingKeepsTheProgressBarStripWithoutCards() {
        typealias Padding = GlobalAppearanceSettings.TerminalPadding
        #expect(Padding.allCases.map { $0.topPoints(cardsEnabled: false) } == [2, 2, 8, 12])
        #expect(Padding.allCases.map { $0.topPoints(cardsEnabled: true) } == [0, 2, 8, 12])
    }

    @MainActor
    @Test func containerContentSizeAddsThePaddingOnEachSide() {
        let size = TerminalSessionContainerView.contentSize(forTerminalSize: NSSize(width: 100, height: 50),
                                                            padding: 8, top: 10)
        #expect(size == NSSize(width: 116, height: 68))
    }

    @Test func gradientPreservesOpacityAndHonorsReduceTransparency() {
        let appearance = ResolvedWorkspaceAppearance(theme: .fallback)
        #expect(appearance.gradientColors.count == 3)
        #expect(appearance.gradientColors(opacity: 0.4, reduceTransparency: false)
            .allSatisfy { abs($0.alphaComponent - 0.4) < 0.001 })
        #expect(appearance.gradientColors(opacity: 0.4, reduceTransparency: true)
            .allSatisfy { $0.alphaComponent == 1 })
        #expect(appearance.gradientColors(opacity: 2, reduceTransparency: false)
            .allSatisfy { $0.alphaComponent == 1 })
    }
}
