//
//  ThemePreview.swift
//  Tecolot
//
//  A miniature, purely synthetic terminal snippet rendered from a theme's
//  colors, used as the card face in the theme browser and pickers.
//
import AppKit
import SwiftUI

extension ProfileColor {
    var swiftUIColor: Color {
        Color(red: Double(red) / 65535.0,
              green: Double(green) / 65535.0,
              blue: Double(blue) / 65535.0)
    }

    init? (swiftUIColor: Color) {
        guard let color = NSColor (swiftUIColor).usingColorSpace (.sRGB) else {
            return nil
        }

        func channel (_ value: CGFloat) -> UInt16 {
            UInt16 ((min (max (value, 0), 1) * 65535).rounded ())
        }
        self.init (red: channel (color.redComponent),
                   green: channel (color.greenComponent),
                   blue: channel (color.blueComponent))
    }
}

struct ThemePreview: View {
    let theme: TerminalTheme
    var fontSize: CGFloat = 9
    var extended = false

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
            if extended {
                Text("main.swift")
                    .foregroundStyle((theme.selectionText ?? theme.foreground).swiftUIColor)
                    .background(selectionBackground)
            } else {
                Text("main.swift").foregroundStyle(theme.foreground.swiftUIColor)
            }
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
            if extended {
                Text("bold text")
                    .bold()
                    .foregroundStyle(theme.foreground.swiftUIColor)
            }
        }
    }

    private var selectionBackground: Color {
        theme.selectionBackground?.swiftUIColor
            ?? Color(nsColor: .selectedTextBackgroundColor)
    }
}

enum ThemePreviewPage: Int, CaseIterable, Identifiable {
    case shell
    case midnightCommander
    case claudeCode

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .shell: "Shell"
        case .midnightCommander: "mc"
        case .claudeCode: "Claude"
        }
    }
}

/// Shows small terminal samples that the user can page through.
struct ThemePreviewPager: View {
    let theme: TerminalTheme
    @Binding var selectedPage: ThemePreviewPage?

    var body: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(ThemePreviewPage.allCases) { page in
                        ThemePreviewPageView(page: page, theme: theme)
                            .containerRelativeFrame(.horizontal)
                            .id(page)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $selectedPage)
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .clipShape(.rect(cornerRadius: 8))

            HStack(spacing: 8) {
                Text("Sample Usage")
                    .foregroundStyle(.secondary)
                Picker("Sample Usage", selection: $selectedPage) {
                    ForEach(ThemePreviewPage.allCases) { page in
                        Text(page.title).tag(Optional(page))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 260)
                .accessibilityLabel("Sample Usage")
            }
        }
    }
}

private struct ThemePreviewPageView: View {
    let page: ThemePreviewPage
    let theme: TerminalTheme
    var compact = false

    var body: some View {
        ZStack {
            switch page {
            case .shell:
                ThemePreview(
                    theme: theme,
                    fontSize: compact ? 8 : 12,
                    extended: !compact
                )
            case .midnightCommander:
                MidnightCommanderThemePreview(theme: theme)
            case .claudeCode:
                ClaudeCodeThemePreview(theme: theme, compact: compact)
            }
        }
    }
}

/// Reproduces the stable regions of an 80-column Midnight Commander capture.
private struct MidnightCommanderThemePreview: View {
    let theme: TerminalTheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Left")
                Text("File")
                Text("Command")
                Text("Options")
                Text("Right")
                Spacer(minLength: 0)
            }
            .foregroundStyle(theme.ansi[0].swiftUIColor)
            .padding(.horizontal, 5)
            .background(theme.ansi[6].swiftUIColor)

            HStack(spacing: 4) {
                MidnightCommanderPanel(
                    path: "~/cvs/tecolot",
                    selectedEntry: "/Tecolot",
                    secondEntry: "/TecolotTests",
                    thirdEntry: "/scripts",
                    fileEntry: "README.md",
                    theme: theme
                )
                MidnightCommanderPanel(
                    path: "~/src/SwiftTerm",
                    selectedEntry: "/Sources",
                    secondEntry: "/Tests",
                    thirdEntry: "/Tools",
                    fileEntry: "Package.swift",
                    theme: theme
                )
            }
            .padding(4)

            Spacer(minLength: 1)

            Text("bash-3.2$ ")
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(theme.foreground.swiftUIColor)
                .padding(.horizontal, 5)

            HStack(spacing: 0) {
                Text(" 1").foregroundStyle(theme.ansi[15].swiftUIColor)
                Text("Help  ").foregroundStyle(theme.ansi[0].swiftUIColor)
                Text(" 3").foregroundStyle(theme.ansi[15].swiftUIColor)
                Text("View  ").foregroundStyle(theme.ansi[0].swiftUIColor)
                Text(" 5").foregroundStyle(theme.ansi[15].swiftUIColor)
                Text("Copy  ").foregroundStyle(theme.ansi[0].swiftUIColor)
                Text("10").foregroundStyle(theme.ansi[15].swiftUIColor)
                Text("Quit").foregroundStyle(theme.ansi[0].swiftUIColor)
                Spacer(minLength: 0)
            }
            .background(theme.ansi[6].swiftUIColor)
        }
        .font(.system(size: 8, design: .monospaced))
        .background(theme.ansi[4].swiftUIColor)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Midnight Commander preview with the \(theme.name) theme")
    }
}

private struct MidnightCommanderPanel: View {
    let path: String
    let selectedEntry: String
    let secondEntry: String
    let thirdEntry: String
    let fileEntry: String
    let theme: TerminalTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("<─ \(path) ─>")
                .lineLimit(1)
            Text("Name                 Size")
                .foregroundStyle(theme.ansi[11].swiftUIColor)
            Text(selectedEntry)
                .foregroundStyle(theme.ansi[0].swiftUIColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.ansi[14].swiftUIColor)
            Text(secondEntry)
            Text(thirdEntry)
            Text(fileEntry)
                .foregroundStyle(theme.ansi[11].swiftUIColor)
            Spacer(minLength: 0)
            Divider().overlay(theme.ansi[15].swiftUIColor)
            Text("698G / 3722G (18%)")
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .foregroundStyle(theme.ansi[15].swiftUIColor)
        .padding(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            Rectangle().stroke(theme.ansi[15].swiftUIColor.opacity(0.8))
        }
    }
}

/// Reproduces the stable regions of an 80-column Claude Code capture.
private struct ClaudeCodeThemePreview: View {
    let theme: TerminalTheme
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 5) {
            HStack(spacing: compact ? 4 : 7) {
                Text("✻")
                    .foregroundStyle(theme.ansi[3].swiftUIColor)
                Text("Claude Code")
                    .bold()
                Spacer(minLength: 4)
                Text("Opus")
                    .foregroundStyle(theme.ansi[8].swiftUIColor)
            }

            if !compact {
                Text("~/cvs/tecolot")
                    .foregroundStyle(theme.ansi[8].swiftUIColor)
                Text("Good morning! How can I help you?")
                Spacer(minLength: 0)
            }

            Divider()
                .overlay(theme.ansi[8].swiftUIColor)
            HStack(spacing: 5) {
                Text("❯")
                    .foregroundStyle(theme.ansi[13].swiftUIColor)
                Text(compact ? "Ask Claude…" : "Try “explain the theme preview code”")
                    .foregroundStyle(theme.ansi[8].swiftUIColor)
                    .lineLimit(1)
            }
            if !compact {
                Divider()
                    .overlay(theme.ansi[8].swiftUIColor)
                Text("⏵⏵ auto mode on · shift+tab to cycle")
                    .foregroundStyle(theme.ansi[8].swiftUIColor)
            }
        }
        .font(.system(size: compact ? 8 : 9, design: .monospaced))
        .foregroundStyle(theme.foreground.swiftUIColor)
        .padding(compact ? 6 : 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.background.swiftUIColor)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Claude Code preview with the \(theme.name) theme")
    }
}

/// A selectable card wrapping the preview with its name and selection ring
struct ThemeCard: View {
    let theme: TerminalTheme
    let isSelected: Bool
    let isFavorite: Bool
    var samplePage: ThemePreviewPage = .shell
    var onSelect: (() -> Void)? = nil
    var onToggleFavorite: (() -> Void)? = nil

    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let onSelect {
                Button(action: onSelect) {
                    ThemeCardContent(
                        theme: theme,
                        isSelected: isSelected,
                        samplePage: samplePage
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Select \(theme.name) theme")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            } else {
                ThemeCardContent(
                    theme: theme,
                    isSelected: isSelected,
                    samplePage: samplePage
                )
            }
            if let onToggleFavorite {
                Button(action: onToggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.caption)
                        .foregroundStyle(isFavorite ? .yellow : .secondary)
                        .frame(width: 22, height: 22)
                        .background(.regularMaterial, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    isFavorite ? "Remove from Favorites" : "Add to Favorites"
                )
                .opacity(isFavorite || isHovering ? 1 : 0)
                .allowsHitTesting(isFavorite || isHovering)
                .accessibilityHidden(!isFavorite && !isHovering)
                .padding(5)
            }
        }
        .onHover { hovering in
            if isHovering != hovering {
                isHovering = hovering
            }
        }
    }
}

private struct ThemeCardContent: View {
    let theme: TerminalTheme
    let isSelected: Bool
    let samplePage: ThemePreviewPage

    var body: some View {
        VStack(spacing: 4) {
            ThemePreviewPageView(page: samplePage, theme: theme, compact: true)
                .frame(height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.15),
                                      lineWidth: isSelected ? 2 : 1)
                )
                .overlay(alignment: .topTrailing) {
                    if !theme.isBuiltIn {
                        Text("CUSTOM")
                            .font(.caption2.bold())
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.regularMaterial, in: Capsule())
                            .padding(5)
                            .accessibilityLabel("Custom theme")
                    }
                }
            Text(theme.name)
                .font(.caption)
                .lineLimit(1)
        }
    }
}

#Preview("Theme Preview") {
    ThemePreview(
        theme: SettingsPreviewData.themes.theme(
            named: SettingsPreviewData.profile.themeName
        ),
        fontSize: 12,
        extended: true
    )
    .frame(width: 420, height: 180)
}

#Preview("Theme Preview Pager") {
    @Previewable @State var selectedPage: ThemePreviewPage? = .claudeCode

    ThemePreviewPager(
        theme: SettingsPreviewData.themes.theme(
            named: SettingsPreviewData.profile.themeName
        ),
        selectedPage: $selectedPage
    )
    .frame(width: 520, height: 260)
    .padding()
}

#Preview("Theme Card") {
    ThemeCard(
        theme: SettingsPreviewData.themes.theme(
            named: SettingsPreviewData.profile.themeName
        ),
        isSelected: true,
        isFavorite: true,
        samplePage: .midnightCommander
    )
    .frame(width: 180)
    .padding()
}
