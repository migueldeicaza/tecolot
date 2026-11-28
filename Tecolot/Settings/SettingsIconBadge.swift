//
//  SettingsIconBadge.swift
//  Tecolot
//
//  macOS System Settings–style rounded-square icon badges for the Settings
//  sidebar. Each destination picks a SettingsIconStyle case so individual
//  slots can be reassigned in one line and all slots sharing a style kind can
//  be restyled together.
//
import SwiftUI

/// Visual style families for Settings sidebar icon badges.
enum SettingsIconStyle: String, CaseIterable, Hashable, Sendable {
    /// Medium cool-gray gradient matching macOS System Settings "General".
    case systemGray
    /// Crisp white tile with dark symbol matching macOS System Settings "Desktop & Dock".
    case monochromeLight
    /// Multi-color luminous spectrum matching macOS System Settings "Apple Intelligence & Siri".
    case appleIntelligenceSpectrum
    /// Vibrant coral-red gradient matching macOS System Settings "Notifications".
    case notificationRed
    /// Cool light-silver gradient with dark symbol, harmonized with Tabs & Panes.
    case silverGradient
    /// Neutral silver-slate gray gradient matching macOS System Settings "About".
    case aboutGray
    /// Cool graphite-slate gray gradient matching macOS System Settings "Keyboard".
    case keyboardGray
    /// Dark terminal charcoal with green glyph matching Tecolot's default terminal tab tile.
    case terminalDarkGreen
    /// Vibrant macOS System Settings blue gradient.
    case systemBlue

    enum Background: Equatable, Sendable {
        case solid(RGBColor)
        case linearGradient(top: RGBColor, bottom: RGBColor)
        case appleIntelligenceSpectrum
    }

    struct RGBColor: Equatable, Sendable {
        let red: Double
        let green: Double
        let blue: Double
        var opacity: Double = 1

        init(hex: UInt32, opacity: Double = 1) {
            self.red = Double((hex >> 16) & 0xFF) / 255
            self.green = Double((hex >> 8) & 0xFF) / 255
            self.blue = Double(hex & 0xFF) / 255
            self.opacity = opacity
        }

        init(white: Double, opacity: Double = 1) {
            self.red = white
            self.green = white
            self.blue = white
            self.opacity = opacity
        }

        var color: Color {
            Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
        }
    }

    /// Resolved visual tokens for a badge in a given color scheme and contrast mode.
    struct Palette: Equatable, Sendable {
        let background: Background
        let foreground: RGBColor
        let topSheenOpacity: Double
        let innerBevelOpacity: Double
        let border: RGBColor
        let shadowOpacity: Double
        let shadowRadius: CGFloat
        let shadowYOffset: CGFloat
        let glyphShadowOpacity: Double
        let glyphShadowRadius: CGFloat
    }

    func palette(for colorScheme: ColorScheme, increasedContrast: Bool = false) -> Palette {
        let isDark = colorScheme == .dark
        let contrastBoost = increasedContrast ? 0.14 : 0
        let dropShadowOpacity = isDark ? 0.36 : 0.18

        switch self {
        case .systemGray:
            return Palette(
                background: .linearGradient(
                    top: RGBColor(hex: isDark ? 0x8F949C : 0x9FA4AC),
                    bottom: RGBColor(hex: isDark ? 0x676B73 : 0x767B83)
                ),
                foreground: RGBColor(white: 1),
                topSheenOpacity: 0.14,
                innerBevelOpacity: 0.24,
                border: isDark
                    ? RGBColor(white: 1, opacity: 0.16 + contrastBoost)
                    : RGBColor(white: 0, opacity: 0.12 + contrastBoost),
                shadowOpacity: dropShadowOpacity,
                shadowRadius: 1.0,
                shadowYOffset: 0.75,
                glyphShadowOpacity: 0.16,
                glyphShadowRadius: 0.5
            )

        case .monochromeLight:
            return Palette(
                background: .linearGradient(
                    top: RGBColor(hex: isDark ? 0xF5F6F8 : 0xFFFFFF),
                    bottom: RGBColor(hex: isDark ? 0xDFE2E8 : 0xECEDF0)
                ),
                foreground: RGBColor(hex: 0x1D1D1F),
                topSheenOpacity: 0,
                innerBevelOpacity: 0,
                border: isDark
                    ? RGBColor(white: 1, opacity: 0.22 + contrastBoost)
                    : RGBColor(white: 0, opacity: 0.16 + contrastBoost),
                shadowOpacity: isDark ? 0.34 : 0.14,
                shadowRadius: 1.0,
                shadowYOffset: 0.75,
                glyphShadowOpacity: 0,
                glyphShadowRadius: 0
            )

        case .appleIntelligenceSpectrum:
            return Palette(
                background: .appleIntelligenceSpectrum,
                foreground: RGBColor(white: 1),
                topSheenOpacity: 0,
                innerBevelOpacity: 0.16,
                border: isDark
                    ? RGBColor(white: 1, opacity: 0.18 + contrastBoost)
                    : RGBColor(white: 0, opacity: 0.06 + contrastBoost),
                shadowOpacity: isDark ? 0.32 : 0.14,
                shadowRadius: 1.0,
                shadowYOffset: 0.6,
                glyphShadowOpacity: 0.08,
                glyphShadowRadius: 0.6
            )

        case .notificationRed:
            return Palette(
                background: .linearGradient(
                    top: RGBColor(hex: 0xFF6257),
                    bottom: RGBColor(hex: 0xF72B27)
                ),
                foreground: RGBColor(white: 1),
                topSheenOpacity: 0.10,
                innerBevelOpacity: 0.22,
                border: isDark
                    ? RGBColor(white: 1, opacity: 0.16 + contrastBoost)
                    : RGBColor(white: 0, opacity: 0.08 + contrastBoost),
                shadowOpacity: isDark ? 0.34 : 0.15,
                shadowRadius: 1.0,
                shadowYOffset: 0.65,
                glyphShadowOpacity: 0.08,
                glyphShadowRadius: 0.4
            )

        case .silverGradient:
            return Palette(
                background: .linearGradient(
                    top: RGBColor(hex: isDark ? 0xF1F3F6 : 0xF9FAFC),
                    bottom: RGBColor(hex: isDark ? 0xD2D6DE : 0xDCDFE6)
                ),
                foreground: RGBColor(hex: 0x222429),
                topSheenOpacity: 0.14,
                innerBevelOpacity: 0.28,
                border: isDark
                    ? RGBColor(white: 1, opacity: 0.22 + contrastBoost)
                    : RGBColor(white: 0, opacity: 0.15 + contrastBoost),
                shadowOpacity: isDark ? 0.34 : 0.14,
                shadowRadius: 1.0,
                shadowYOffset: 0.7,
                glyphShadowOpacity: 0,
                glyphShadowRadius: 0
            )

        case .aboutGray:
            return Palette(
                background: .linearGradient(
                    top: RGBColor(hex: isDark ? 0x9C9FA8 : 0xAFB3BB),
                    bottom: RGBColor(hex: isDark ? 0x767A83 : 0x898E96)
                ),
                foreground: RGBColor(white: 1),
                topSheenOpacity: 0.14,
                innerBevelOpacity: 0.24,
                border: isDark
                    ? RGBColor(white: 1, opacity: 0.16 + contrastBoost)
                    : RGBColor(white: 0, opacity: 0.12 + contrastBoost),
                shadowOpacity: dropShadowOpacity,
                shadowRadius: 1.0,
                shadowYOffset: 0.75,
                glyphShadowOpacity: 0.14,
                glyphShadowRadius: 0.5
            )

        case .keyboardGray:
            return Palette(
                background: .linearGradient(
                    top: RGBColor(hex: isDark ? 0x7C818B : 0x868B94),
                    bottom: RGBColor(hex: isDark ? 0x575C65 : 0x61666F)
                ),
                foreground: RGBColor(white: 1),
                topSheenOpacity: 0.14,
                innerBevelOpacity: 0.22,
                border: isDark
                    ? RGBColor(white: 1, opacity: 0.18 + contrastBoost)
                    : RGBColor(white: 0, opacity: 0.14 + contrastBoost),
                shadowOpacity: dropShadowOpacity,
                shadowRadius: 1.0,
                shadowYOffset: 0.75,
                glyphShadowOpacity: 0.18,
                glyphShadowRadius: 0.5
            )

        case .terminalDarkGreen:
            return Palette(
                background: .linearGradient(
                    top: RGBColor(hex: 0x393C42),
                    bottom: RGBColor(hex: 0x1E2024)
                ),
                foreground: RGBColor(hex: ProgramGlyphCatalog.terminal.foreground),
                topSheenOpacity: 0.15,
                innerBevelOpacity: 0.20,
                border: isDark
                    ? RGBColor(white: 1, opacity: 0.18 + contrastBoost)
                    : RGBColor(white: 0, opacity: 0.28 + contrastBoost),
                shadowOpacity: dropShadowOpacity,
                shadowRadius: 1.0,
                shadowYOffset: 0.75,
                glyphShadowOpacity: 0.34,
                glyphShadowRadius: 0.6
            )

        case .systemBlue:
            return Palette(
                background: .linearGradient(
                    top: RGBColor(hex: 0x3A9CFF),
                    bottom: RGBColor(hex: 0x0071F5)
                ),
                foreground: RGBColor(white: 1),
                topSheenOpacity: 0.14,
                innerBevelOpacity: 0.26,
                border: isDark
                    ? RGBColor(white: 1, opacity: 0.22 + contrastBoost)
                    : RGBColor(white: 0, opacity: 0.14 + contrastBoost),
                shadowOpacity: dropShadowOpacity,
                shadowRadius: 1.0,
                shadowYOffset: 0.75,
                glyphShadowOpacity: 0.18,
                glyphShadowRadius: 0.5
            )
        }
    }
}

/// Renders a 20×20pt continuous rounded-square icon badge styled after macOS
/// System Settings.
struct SettingsIconBadge: View {
    let systemImage: String
    let style: SettingsIconStyle

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private static let badgeSize: CGFloat = 20
    private static let cornerRadius: CGFloat = 5

    private var badgeShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    }

    private var symbolPointSize: CGFloat {
        switch systemImage {
        case "person.2.badge.gearshape.fill", "externaldrive.fill.badge.checkmark":
            return 10.5
        case "keyboard.fill", "rectangle.split.2x1", "macwindow":
            return 11.0
        case "paintpalette.fill":
            return 12.0
        case "apple.terminal.fill":
            // Secondary fill layer is transparent so the prompt fills the tile directly.
            return 16.5
        default:
            return 11.5
        }
    }

    private var symbolWeight: Font.Weight {
        switch systemImage {
        case "command", "switch.2", "apple.terminal", "apple.terminal.fill", "magnifyingglass":
            return .semibold
        default:
            return .medium
        }
    }

    var body: some View {
        let palette = style.palette(
            for: colorScheme,
            increasedContrast: colorSchemeContrast == .increased
        )

        ZStack {
            backgroundFill(for: palette.background)

            if palette.topSheenOpacity > 0 {
                LinearGradient(
                    colors: [
                        .white.opacity(palette.topSheenOpacity),
                        .white.opacity(0),
                    ],
                    startPoint: .top,
                    endPoint: .center
                )
            }

            symbolView(for: palette)
                .shadow(
                    color: .black.opacity(palette.glyphShadowOpacity),
                    radius: palette.glyphShadowRadius,
                    x: 0,
                    y: palette.glyphShadowOpacity > 0 ? 0.5 : 0
                )
        }
        .frame(width: Self.badgeSize, height: Self.badgeSize)
        .clipShape(badgeShape)
        .overlay {
            if palette.innerBevelOpacity > 0 {
                badgeShape
                    .inset(by: 0.5)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(palette.innerBevelOpacity),
                                .white.opacity(0),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
            }
        }
        .overlay {
            badgeShape
                .strokeBorder(palette.border.color, lineWidth: 0.5)
        }
        .shadow(
            color: .black.opacity(palette.shadowOpacity),
            radius: palette.shadowRadius,
            x: 0,
            y: palette.shadowYOffset
        )
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func symbolView(for palette: SettingsIconStyle.Palette) -> some View {
        if systemImage == "apple.terminal.fill" {
            // `apple.terminal.fill` is a filled box with `>_` knocked out. Punching it
            // out of a centered foreground rectangle extracts the bold `>_` prompt directly
            // onto our badge so there is no double-border padding.
            ZStack {
                palette.foreground.color
                    .frame(width: 13, height: 10)
                Image(systemName: systemImage)
                    .font(.system(size: symbolPointSize, weight: symbolWeight))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.black)
                    .blendMode(.destinationOut)
            }
            .frame(width: Self.badgeSize, height: Self.badgeSize)
            .compositingGroup()
        } else {
            Image(systemName: systemImage)
                .font(.system(size: symbolPointSize, weight: symbolWeight))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(palette.foreground.color)
        }
    }

    @ViewBuilder
    private func backgroundFill(for background: SettingsIconStyle.Background) -> some View {
        switch background {
        case .solid(let fill):
            fill.color
        case .linearGradient(let top, let bottom):
            LinearGradient(
                colors: [top.color, bottom.color],
                startPoint: .top,
                endPoint: .bottom
            )
        case .appleIntelligenceSpectrum:
            AppleIntelligenceSpectrumBackground()
        }
    }
}

/// Bright multi-stop spectrum sampled from the macOS System Settings
/// "Apple Intelligence & Siri" icon: warm tangerine top-left, hot pink
/// top-right, airy cerulean bottom-center, and luminous orchid bottom-right.
private struct AppleIntelligenceSpectrumBackground: View {
    var body: some View {
        MeshGradient(
            width: 3,
            height: 3,
            points: [
                [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                [0.0, 0.5], [0.5, 0.5], [1.0, 0.5],
                [0.0, 1.0], [0.5, 1.0], [1.0, 1.0],
            ],
            colors: [
                Color(red: 0.99, green: 0.65, blue: 0.20), // warm tangerine-orange
                Color(red: 0.97, green: 0.45, blue: 0.32), // coral-salmon
                Color(red: 0.98, green: 0.20, blue: 0.45), // vivid raspberry-pink
                Color(red: 0.89, green: 0.74, blue: 0.57), // soft warm peach
                Color(red: 0.88, green: 0.56, blue: 0.64), // bright warm rose center
                Color(red: 0.93, green: 0.34, blue: 0.68), // vibrant magenta-rose
                Color(red: 0.63, green: 0.80, blue: 0.90), // airy mist sky-blue
                Color(red: 0.28, green: 0.72, blue: 0.97), // bright cerulean blue
                Color(red: 0.78, green: 0.53, blue: 0.98), // luminous orchid-lavender
            ]
        )
    }
}

/// Sidebar row displaying a SettingsIconBadge alongside its title.
/// Uses an HStack rather than Label so macOS List selection tinting never
/// washes out badge colors or clips badge drop shadows.
struct SettingsSidebarRow: View {
    let title: String
    let systemImage: String
    let style: SettingsIconStyle

    var body: some View {
        HStack(spacing: 8) {
            SettingsIconBadge(systemImage: systemImage, style: style)
            Text(title)
                .lineLimit(1)
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Settings Icon Badges") {
    HStack(spacing: 24) {
        previewColumn
            .environment(\.colorScheme, .light)
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))

        previewColumn
            .environment(\.colorScheme, .dark)
            .padding()
            .background(Color(red: 0.14, green: 0.14, blue: 0.15))
    }
    .padding()
}

private var previewColumn: some View {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(SettingsDestination.sidebarPages) { destination in
            SettingsSidebarRow(
                title: destination.title,
                systemImage: destination.systemImage,
                style: destination.iconStyle
            )
        }
    }
    .frame(width: 200, alignment: .leading)
}
