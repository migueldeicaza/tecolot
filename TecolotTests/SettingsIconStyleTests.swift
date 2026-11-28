import AppKit
import SwiftUI
import Testing
@testable import Tecolot

@MainActor
struct SettingsIconStyleTests {
    @Test func everyDestinationResolvesToAValidSFSymbol() {
        for destination in SettingsDestination.allCases {
            let image = NSImage(systemSymbolName: destination.systemImage, accessibilityDescription: nil)
            #expect(image != nil, "Missing SF Symbol '\(destination.systemImage)' for \(destination)")
        }
    }

    @Test func destinationIconStylesMatchSpecification() {
        #expect(SettingsDestination.general.iconStyle == .systemGray)
        #expect(SettingsDestination.shell.iconStyle == .systemGray)

        #expect(SettingsDestination.tabs.iconStyle == .systemBlue)
        #expect(SettingsDestination.panes.iconStyle == .systemBlue)

        #expect(SettingsDestination.appearance.iconStyle == .appleIntelligenceSpectrum)
        #expect(SettingsDestination.notifications.iconStyle == .notificationRed)
        #expect(SettingsDestination.shortcuts.iconStyle == .silverGradient)

        #expect(SettingsDestination.data.iconStyle == .aboutGray)
        #expect(SettingsDestination.crashReports.iconStyle == .aboutGray)

        #expect(SettingsDestination.keyboardAndMouse.iconStyle == .keyboardGray)
        #expect(SettingsDestination.terminal.iconStyle == .terminalDarkGreen)

        #expect(SettingsDestination.window.iconStyle == .systemBlue)
        #expect(SettingsDestination.manageProfiles.iconStyle == .systemBlue)
    }

    @Test func updatedDestinationIconsAndSessionTitle() {
        #expect(SettingsDestination.appearance.systemImage == "paintpalette.fill")
        #expect(SettingsDestination.shell.systemImage == "switch.2")
        #expect(SettingsDestination.shell.title == "Session")
        #expect(ProfileSettingsSection.shell.title == "Session")
        #expect(SettingsDestination.terminal.systemImage == "apple.terminal.fill")
        #expect(SettingsDestination.profilePages == [.appearance, .window, .shell, .keyboardAndMouse, .terminal, .manageProfiles])
        #expect(SettingsDestination.bottomPages == [.data, .crashReports])
        #expect(Array(SettingsDestination.sidebarPages.suffix(3)) == [.manageProfiles, .data, .crashReports])
    }

    @Test func terminalBadgeExtractsGreenPromptWithoutLeakingEdges() throws {
        let renderer = ImageRenderer(
            content: SettingsIconBadge(
                systemImage: SettingsDestination.terminal.systemImage,
                style: SettingsDestination.terminal.iconStyle
            )
            .environment(\.colorScheme, .dark)
        )
        renderer.scale = 2
        let cgImage = try #require(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: cgImage)

        var greenCenterPixels = 0
        var greenEdgePixels = 0
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        for y in 0..<height {
            for x in 0..<width {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    continue
                }
                let isGreenPrompt = color.greenComponent > 0.65 && (color.greenComponent - color.redComponent) > 0.20
                guard isGreenPrompt else {
                    continue
                }
                let onEdge = x < 4 || x >= width - 4 || y < 4 || y >= height - 4
                if onEdge {
                    greenEdgePixels += 1
                } else {
                    greenCenterPixels += 1
                }
            }
        }
        #expect(greenEdgePixels == 0, "Green prompt backing leaked onto badge edges (\(greenEdgePixels) pixels)")
        #expect(greenCenterPixels > 20 && greenCenterPixels < (width * height) / 3, "Expected crisp centered green prompt (got \(greenCenterPixels) pixels)")
    }

    @Test func sessionPageRemainsSearchableByBothSessionAndShell() {
        #expect(SettingsSearchEngine.search("session").map(\.id).contains(.pageShell))
        #expect(SettingsSearchEngine.search("shell").map(\.id).contains(.pageShell))
    }

    @Test func everyIconStyleResolvesDistinctLightAndDarkContrastSafely() {
        for style in SettingsIconStyle.allCases {
            let light = style.palette(for: .light, increasedContrast: false)
            let lightHighContrast = style.palette(for: .light, increasedContrast: true)
            let dark = style.palette(for: .dark, increasedContrast: false)

            #expect(lightHighContrast.border.opacity > light.border.opacity, "\(style) should strengthen border in high contrast")
            #expect(light.shadowOpacity > 0 && dark.shadowOpacity > 0, "\(style) should include a subtle drop shadow")
        }

        let terminalPalette = SettingsIconStyle.terminalDarkGreen.palette(for: .dark)
        #expect(terminalPalette.foreground == SettingsIconStyle.RGBColor(hex: ProgramGlyphCatalog.terminal.foreground))
    }
}
