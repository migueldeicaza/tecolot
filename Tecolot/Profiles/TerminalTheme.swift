//
//  TerminalTheme.swift
//  Tecolot
//
//  A theme is a named set of terminal colors: the 16 ANSI colors plus
//  foreground/background/cursor/selection. Themes are the user-facing way
//  of styling a terminal; profiles reference a theme by name.
//
import Foundation

public struct TerminalTheme: Identifiable, Codable, Equatable, Sendable {
    /// Stable identifier derived from the name (lowercased, dashed)
    public var id: String { TerminalTheme.slug (for: name) }

    /// Display name, unique within a store
    public var name: String

    /// Name of the built-in theme from which this theme was forked
    public var baseThemeName: String?

    /// The 16 ANSI colors: 0-7 normal (black, red, green, yellow, blue,
    /// magenta, cyan, white), 8-15 their bright variants
    public var ansi: [ProfileColor]

    /// Default text color
    public var foreground: ProfileColor
    /// Default background color
    public var background: ProfileColor
    /// Cursor color; nil uses the view's default
    public var cursor: ProfileColor?
    /// Color of the text under a block cursor; nil derives from foreground
    public var cursorText: ProfileColor?
    /// Selection background; nil uses the view's default
    public var selectionBackground: ProfileColor?
    /// Selection text color; nil uses the view's default
    public var selectionText: ProfileColor?

    /// True for themes bundled with the application; these cannot be edited
    /// in place (a copy is saved as a user theme instead). Not persisted.
    public var isBuiltIn: Bool = false

    enum CodingKeys: String, CodingKey {
        case name, baseThemeName, ansi, foreground, background, cursor, cursorText
        case selectionBackground, selectionText
    }

    public init (name: String, ansi: [ProfileColor], foreground: ProfileColor,
                 background: ProfileColor, cursor: ProfileColor? = nil,
                 cursorText: ProfileColor? = nil, selectionBackground: ProfileColor? = nil,
                 selectionText: ProfileColor? = nil, isBuiltIn: Bool = false,
                 baseThemeName: String? = nil) {
        self.name = name
        self.baseThemeName = baseThemeName
        self.ansi = ansi
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.cursorText = cursorText
        self.selectionBackground = selectionBackground
        self.selectionText = selectionText
        self.isBuiltIn = isBuiltIn
    }

    /// A theme is usable only with a full set of 16 ANSI colors
    public var isValid: Bool {
        ansi.count == 16
    }

    /// True when the background is dark (used to pick contrasting UI chrome)
    public var isDark: Bool {
        // Relative luminance, sRGB approximation
        let r = Double (background.red) / 65535.0
        let g = Double (background.green) / 65535.0
        let b = Double (background.blue) / 65535.0
        return (0.2126 * r + 0.7152 * g + 0.0722 * b) < 0.5
    }

    public static func slug (for name: String) -> String {
        let lowered = name.lowercased ()
        let mapped = lowered.map { ch -> Character in
            if ch.isLetter || ch.isNumber {
                return ch
            }
            return "-"
        }
        // collapse runs of dashes
        var result = ""
        var lastWasDash = false
        for ch in mapped {
            if ch == "-" {
                if !lastWasDash {
                    result.append (ch)
                }
                lastWasDash = true
            } else {
                result.append (ch)
                lastWasDash = false
            }
        }
        return result.trimmingCharacters (in: CharacterSet (charactersIn: "-"))
    }

    /// An always-available fallback theme that matches the SwiftTerm MacTerminal app.
    /// It is used when a referenced theme cannot be resolved.
    public static let fallback = TerminalTheme (
        name: "SwiftTerm",
        ansi: [
            ProfileColor (hex: "#000000")!, ProfileColor (hex: "#c23621")!,
            ProfileColor (hex: "#25bc24")!, ProfileColor (hex: "#adad27")!,
            ProfileColor (hex: "#492ee1")!, ProfileColor (hex: "#d338d3")!,
            ProfileColor (hex: "#33bbc8")!, ProfileColor (hex: "#cbcccd")!,
            ProfileColor (hex: "#818383")!, ProfileColor (hex: "#fc391f")!,
            ProfileColor (hex: "#31e722")!, ProfileColor (hex: "#eaec23")!,
            ProfileColor (hex: "#5833ff")!, ProfileColor (hex: "#f935f8")!,
            ProfileColor (hex: "#14f0f0")!, ProfileColor (hex: "#e9ebeb")!
        ],
        foreground: ProfileColor (hex: "#ffffff")!,
        background: ProfileColor (hex: "#282c34")!,
        cursor: ProfileColor (hex: "#30d158")!,
        isBuiltIn: true
    )
}
