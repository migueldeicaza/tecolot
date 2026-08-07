//
//  ThemePreview.swift
//  Tecolot
//
//  A miniature, purely synthetic terminal snippet rendered from a theme's
//  colors, used as the card face in the theme browser and pickers.
//
import SwiftUI
import TerminalProfilesKit

extension ProfileColor {
    var swiftUIColor: Color {
        Color(red: Double(red) / 65535.0,
              green: Double(green) / 65535.0,
              blue: Double(blue) / 65535.0)
    }
}

struct ThemePreview: View {
    let theme: TerminalTheme
    var fontSize: CGFloat = 9

    private var mono: Font {
        .system(size: fontSize, design: .monospaced)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            promptLine
            listingLine
            diffLines
            statusLine
        }
        .font(mono)
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.background.swiftUIColor)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Theme preview: \(theme.name)")
    }

    private var promptLine: some View {
        HStack(spacing: 0) {
            Text("user@mac").foregroundStyle(theme.ansi[10].swiftUIColor)
            Text(" ~/src").foregroundStyle(theme.ansi[12].swiftUIColor)
            Text(" % ").foregroundStyle(theme.foreground.swiftUIColor)
            Text("ls -l").foregroundStyle(theme.foreground.swiftUIColor)
            Rectangle()
                .fill((theme.cursor ?? theme.foreground).swiftUIColor)
                .frame(width: fontSize * 0.6, height: fontSize + 1)
        }
    }

    private var listingLine: some View {
        HStack(spacing: fontSize * 0.6) {
            Text("docs").foregroundStyle(theme.ansi[4].swiftUIColor)
            Text("main.swift").foregroundStyle(theme.foreground.swiftUIColor)
            Text("build.sh").foregroundStyle(theme.ansi[2].swiftUIColor)
            Text("a.out").foregroundStyle(theme.ansi[1].swiftUIColor)
        }
    }

    private var diffLines: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("+ added line").foregroundStyle(theme.ansi[2].swiftUIColor)
            Text("- removed line").foregroundStyle(theme.ansi[1].swiftUIColor)
        }
    }

    private var statusLine: some View {
        HStack(spacing: fontSize * 0.6) {
            Text("warn").foregroundStyle(theme.ansi[3].swiftUIColor)
            Text("info").foregroundStyle(theme.ansi[6].swiftUIColor)
            Text("note").foregroundStyle(theme.ansi[5].swiftUIColor)
        }
    }
}

/// A selectable card wrapping the preview with its name and selection ring
struct ThemeCard: View {
    let theme: TerminalTheme
    let isSelected: Bool
    let isFavorite: Bool

    var body: some View {
        VStack(spacing: 4) {
            ThemePreview(theme: theme)
                .frame(height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.15),
                                      lineWidth: isSelected ? 2 : 1)
                )
            HStack(spacing: 3) {
                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.yellow)
                }
                Text(theme.name)
                    .font(.caption)
                    .lineLimit(1)
            }
        }
    }
}
