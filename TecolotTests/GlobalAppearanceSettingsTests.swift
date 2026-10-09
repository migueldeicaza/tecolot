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
