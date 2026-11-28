import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI

/// Non-character keys supported by SwiftUI `Commands` keyboard shortcuts.
nonisolated enum ShortcutSpecialKey: String, Codable, CaseIterable, Hashable, Sendable {
    case returnKey
    case tab
    case space
    case delete
    case deleteForward
    case escape
    case upArrow
    case downArrow
    case leftArrow
    case rightArrow
    case home
    case end
    case pageUp
    case pageDown
    case f1
    case f2
    case f3
    case f4
    case f5
    case f6
    case f7
    case f8
    case f9
    case f10
    case f11
    case f12

    var keyEquivalent: KeyEquivalent {
        switch self {
        case .returnKey:
            return .return
        case .tab:
            return .tab
        case .space:
            return .space
        case .delete:
            return .delete
        case .deleteForward:
            return .deleteForward
        case .escape:
            return .escape
        case .upArrow:
            return .upArrow
        case .downArrow:
            return .downArrow
        case .leftArrow:
            return .leftArrow
        case .rightArrow:
            return .rightArrow
        case .home:
            return .home
        case .end:
            return .end
        case .pageUp:
            return .pageUp
        case .pageDown:
            return .pageDown
        case .f1:
            return KeyEquivalent(Character(UnicodeScalar(NSF1FunctionKey)!))
        case .f2:
            return KeyEquivalent(Character(UnicodeScalar(NSF2FunctionKey)!))
        case .f3:
            return KeyEquivalent(Character(UnicodeScalar(NSF3FunctionKey)!))
        case .f4:
            return KeyEquivalent(Character(UnicodeScalar(NSF4FunctionKey)!))
        case .f5:
            return KeyEquivalent(Character(UnicodeScalar(NSF5FunctionKey)!))
        case .f6:
            return KeyEquivalent(Character(UnicodeScalar(NSF6FunctionKey)!))
        case .f7:
            return KeyEquivalent(Character(UnicodeScalar(NSF7FunctionKey)!))
        case .f8:
            return KeyEquivalent(Character(UnicodeScalar(NSF8FunctionKey)!))
        case .f9:
            return KeyEquivalent(Character(UnicodeScalar(NSF9FunctionKey)!))
        case .f10:
            return KeyEquivalent(Character(UnicodeScalar(NSF10FunctionKey)!))
        case .f11:
            return KeyEquivalent(Character(UnicodeScalar(NSF11FunctionKey)!))
        case .f12:
            return KeyEquivalent(Character(UnicodeScalar(NSF12FunctionKey)!))
        }
    }

    var displaySymbol: String {
        switch self {
        case .returnKey:
            return "↩"
        case .tab:
            return "⇥"
        case .space:
            return "Space"
        case .delete:
            return "⌫"
        case .deleteForward:
            return "⌦"
        case .escape:
            return "⎋"
        case .upArrow:
            return "↑"
        case .downArrow:
            return "↓"
        case .leftArrow:
            return "←"
        case .rightArrow:
            return "→"
        case .home:
            return "↖"
        case .end:
            return "↘"
        case .pageUp:
            return "⇞"
        case .pageDown:
            return "⇟"
        case .f1:
            return "F1"
        case .f2:
            return "F2"
        case .f3:
            return "F3"
        case .f4:
            return "F4"
        case .f5:
            return "F5"
        case .f6:
            return "F6"
        case .f7:
            return "F7"
        case .f8:
            return "F8"
        case .f9:
            return "F9"
        case .f10:
            return "F10"
        case .f11:
            return "F11"
        case .f12:
            return "F12"
        }
    }

    var accessibilityName: String {
        switch self {
        case .returnKey:
            return "Return"
        case .tab:
            return "Tab"
        case .space:
            return "Space"
        case .delete:
            return "Delete"
        case .deleteForward:
            return "Forward Delete"
        case .escape:
            return "Escape"
        case .upArrow:
            return "Up Arrow"
        case .downArrow:
            return "Down Arrow"
        case .leftArrow:
            return "Left Arrow"
        case .rightArrow:
            return "Right Arrow"
        case .home:
            return "Home"
        case .end:
            return "End"
        case .pageUp:
            return "Page Up"
        case .pageDown:
            return "Page Down"
        case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
            return displaySymbol
        }
    }

    var isFunctionKey: Bool {
        switch self {
        case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
            return true
        default:
            return false
        }
    }

    var searchAliases: [String] {
        switch self {
        case .returnKey:
            return ["return", "enter", "↩"]
        case .tab:
            return ["tab", "⇥"]
        case .space:
            return ["space", "spacebar", "␣"]
        case .delete:
            return ["delete", "backspace", "⌫"]
        case .deleteForward:
            return ["forwarddelete", "del", "⌦"]
        case .escape:
            return ["esc", "escape", "⎋"]
        case .upArrow:
            return ["up", "uparrow", "↑"]
        case .downArrow:
            return ["down", "downarrow", "↓"]
        case .leftArrow:
            return ["left", "leftarrow", "←"]
        case .rightArrow:
            return ["right", "rightarrow", "→"]
        case .home:
            return ["home", "↖"]
        case .end:
            return ["end", "↘"]
        case .pageUp:
            return ["pageup", "pgup", "⇞"]
        case .pageDown:
            return ["pagedown", "pgdn", "pgdown", "⇟"]
        case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
            return [displaySymbol.lowercased()]
        }
    }

    static func from(keyCode: UInt16) -> ShortcutSpecialKey? {
        switch Int(keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            return .returnKey
        case kVK_Tab:
            return .tab
        case kVK_Space:
            return .space
        case kVK_Delete:
            return .delete
        case kVK_ForwardDelete:
            return .deleteForward
        case kVK_Escape:
            return .escape
        case kVK_UpArrow:
            return .upArrow
        case kVK_DownArrow:
            return .downArrow
        case kVK_LeftArrow:
            return .leftArrow
        case kVK_RightArrow:
            return .rightArrow
        case kVK_Home:
            return .home
        case kVK_End:
            return .end
        case kVK_PageUp:
            return .pageUp
        case kVK_PageDown:
            return .pageDown
        case kVK_F1:
            return .f1
        case kVK_F2:
            return .f2
        case kVK_F3:
            return .f3
        case kVK_F4:
            return .f4
        case kVK_F5:
            return .f5
        case kVK_F6:
            return .f6
        case kVK_F7:
            return .f7
        case kVK_F8:
            return .f8
        case kVK_F9:
            return .f9
        case kVK_F10:
            return .f10
        case kVK_F11:
            return .f11
        case kVK_F12:
            return .f12
        default:
            return nil
        }
    }
}

/// The key portion of a customizable application shortcut.
nonisolated enum ShortcutKey: Hashable, Codable, Sendable {
    case character(String)
    case special(ShortcutSpecialKey)

    var keyEquivalent: KeyEquivalent {
        switch self {
        case .character(let text):
            guard let ch = text.first else {
                return KeyEquivalent(" ")
            }
            return KeyEquivalent(ch)
        case .special(let special):
            return special.keyEquivalent
        }
    }

    var displaySymbol: String {
        switch self {
        case .character(let text):
            return text.uppercased()
        case .special(let special):
            return special.displaySymbol
        }
    }

    var accessibilityName: String {
        switch self {
        case .character(let text):
            switch text {
            case ",":
                return "Comma"
            case ".":
                return "Period"
            case "/":
                return "Slash"
            case "[":
                return "Left Bracket"
            case "]":
                return "Right Bracket"
            case "=":
                return "Equals"
            case "+":
                return "Plus"
            case "-":
                return "Minus"
            default:
                return text.uppercased()
            }
        case .special(let special):
            return special.accessibilityName
        }
    }

    var isFunctionKey: Bool {
        if case .special(let special) = self {
            return special.isFunctionKey
        }
        return false
    }

    var searchAliases: [String] {
        switch self {
        case .character(let text):
            var aliases = [text.lowercased()]
            switch text {
            case "/":
                aliases.append("slash")
            case ".":
                aliases.append(contentsOf: ["period", "dot"])
            case ",":
                aliases.append("comma")
            case "[":
                aliases.append("leftbracket")
            case "]":
                aliases.append("rightbracket")
            case "+":
                aliases.append("plus")
            case "-":
                aliases.append("minus")
            case "=":
                aliases.append(contentsOf: ["equals", "equal"])
            default:
                break
            }
            return aliases
        case .special(let special):
            return special.searchAliases
        }
    }
}

/// Modifier flags stored for an application shortcut.
nonisolated struct ShortcutModifiers: OptionSet, Hashable, Codable, Sendable {
    let rawValue: UInt8

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    static let control = ShortcutModifiers(rawValue: 1 << 0)
    static let option = ShortcutModifiers(rawValue: 1 << 1)
    static let shift = ShortcutModifiers(rawValue: 1 << 2)
    static let command = ShortcutModifiers(rawValue: 1 << 3)

    var eventModifiers: SwiftUI.EventModifiers {
        var result: SwiftUI.EventModifiers = []
        if contains(.control) {
            result.insert(.control)
        }
        if contains(.option) {
            result.insert(.option)
        }
        if contains(.shift) {
            result.insert(.shift)
        }
        if contains(.command) {
            result.insert(.command)
        }
        return result
    }

    var nsModifierFlags: NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if contains(.control) {
            result.insert(.control)
        }
        if contains(.option) {
            result.insert(.option)
        }
        if contains(.shift) {
            result.insert(.shift)
        }
        if contains(.command) {
            result.insert(.command)
        }
        return result
    }

    init(nsModifierFlags: NSEvent.ModifierFlags) {
        let relevant = nsModifierFlags.intersection([.control, .option, .shift, .command])
        var value: ShortcutModifiers = []
        if relevant.contains(.control) {
            value.insert(.control)
        }
        if relevant.contains(.option) {
            value.insert(.option)
        }
        if relevant.contains(.shift) {
            value.insert(.shift)
        }
        if relevant.contains(.command) {
            value.insert(.command)
        }
        self = value
    }

    /// Canonical macOS display order: Control, Option, Shift, Command.
    var displayString: String {
        var parts = ""
        if contains(.control) {
            parts.append("⌃")
        }
        if contains(.option) {
            parts.append("⌥")
        }
        if contains(.shift) {
            parts.append("⇧")
        }
        if contains(.command) {
            parts.append("⌘")
        }
        return parts
    }

    var accessibilityNames: [String] {
        var parts: [String] = []
        if contains(.control) {
            parts.append("Control")
        }
        if contains(.option) {
            parts.append("Option")
        }
        if contains(.shift) {
            parts.append("Shift")
        }
        if contains(.command) {
            parts.append("Command")
        }
        return parts
    }

    /// True when at least one non-Shift modifier is held.
    var hasPrimaryModifier: Bool {
        contains(.command) || contains(.control) || contains(.option)
    }
}

/// Validation result when capturing a user-recorded key combination.
nonisolated enum ShortcutCaptureResult: Equatable, Sendable {
    case valid(KeyCombo)
    case rejected(String)
}

/// A single key + modifier combination bound to a SwiftUI command.
nonisolated struct KeyCombo: Hashable, Codable, Sendable {
    let key: ShortcutKey
    let modifiers: ShortcutModifiers

    init(_ key: ShortcutKey, modifiers: ShortcutModifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    init(_ character: String, modifiers: ShortcutModifiers) {
        self.key = .character(character.lowercased())
        self.modifiers = modifiers
    }

    init(_ special: ShortcutSpecialKey, modifiers: ShortcutModifiers) {
        self.key = .special(special)
        self.modifiers = modifiers
    }

    /// Keep `.automatic` for macOS's standard ⌘+ zoom shortcut so both unshifted ⌘=
    /// and ⇧⌘= work on US keyboards while unshifted ⌘+ works on ISO layouts. Use
    /// `.custom` everywhere else so menu equivalents match `KeyCombo.matches(_:)`
    /// and `displayString` verbatim across keyboard layouts.
    var usesAutomaticLocalization: Bool {
        key == .character("+") && modifiers == [.command]
    }

    var swiftUIShortcut: KeyboardShortcut {
        KeyboardShortcut(
            key.keyEquivalent,
            modifiers: modifiers.eventModifiers,
            localization: usesAutomaticLocalization ? .automatic : .custom
        )
    }

    var displayString: String {
        "\(modifiers.displayString)\(key.displaySymbol)"
    }

    var accessibilityLabel: String {
        (modifiers.accessibilityNames + [key.accessibilityName]).joined(separator: " ")
    }

    /// macOS system-reserved shortcuts that should not be stolen by app actions.
    static let systemReserved: Set<KeyCombo> = [
        KeyCombo("q", modifiers: [.command]),
        KeyCombo("h", modifiers: [.command]),
        KeyCombo("h", modifiers: [.command, .option]),
        KeyCombo("m", modifiers: [.command]),
        KeyCombo(.tab, modifiers: [.command]),
        KeyCombo(.space, modifiers: [.command]),
        KeyCombo("q", modifiers: [.command, .control])
    ]

    /// Non-catalog application and standard menu shortcuts that cannot be rebound here.
    /// Audited against the built `NSApp.mainMenu`; `⌘1`–`⌘9` are intentionally omitted
    /// so users can bind them (the matching `Select Tab` menu item yields automatically).
    static let menuReserved: [KeyCombo: String] = [
        KeyCombo("c", modifiers: [.command]): "Copy",
        KeyCombo("v", modifiers: [.command]): "Paste",
        KeyCombo("x", modifiers: [.command]): "Cut",
        KeyCombo("a", modifiers: [.command]): "Select All",
        KeyCombo("z", modifiers: [.command]): "Undo",
        KeyCombo("z", modifiers: [.command, .shift]): "Redo",
        KeyCombo("f", modifiers: [.command, .control]): "Enter Full Screen",
        KeyCombo(.space, modifiers: [.command, .control]): "Emoji & Symbols",
        KeyCombo("?", modifiers: [.command]): "Help",
        KeyCombo("/", modifiers: [.command, .shift]): "Help",
        KeyCombo("s", modifiers: [.command, .option]): "Toggle Sidebar"
    ]

    /// Extracts and validates a `KeyCombo` from a keyDown `NSEvent`.
    static func capture(from event: NSEvent) -> ShortcutCaptureResult {
        let modifiers = ShortcutModifiers(nsModifierFlags: event.modifierFlags)
        let key: ShortcutKey

        if let special = ShortcutSpecialKey.from(keyCode: event.keyCode) {
            key = .special(special)
        } else if let raw = character(from: event) {
            key = .character(raw)
        } else {
            return .rejected("That key cannot be used as a shortcut.")
        }

        let combo = KeyCombo(key, modifiers: modifiers)

        switch key {
        case .character:
            if !modifiers.contains(.command) {
                return .rejected("Include Command (⌘) with character keys so terminal control and Option sequences keep working.")
            }
        case .special(let special):
            if !special.isFunctionKey && !modifiers.hasPrimaryModifier {
                return .rejected("Include Command, Control, or Option with navigation keys.")
            }
        }

        if systemReserved.contains(combo) {
            return .rejected("macOS reserves \(combo.displayString) for system use.")
        }

        if let owner = menuReserved[combo] {
            return .rejected("\(combo.displayString) is used by \(owner).")
        }

        return .valid(combo)
    }

    /// Matches a live `NSEvent` against this `KeyCombo`.
    func matches(_ event: NSEvent) -> Bool {
        let eventMods = ShortcutModifiers(nsModifierFlags: event.modifierFlags)
        guard eventMods == modifiers else {
            return false
        }
        if let special = ShortcutSpecialKey.from(keyCode: event.keyCode) {
            return key == .special(special)
        }
        guard let raw = Self.character(from: event) else {
            return false
        }
        return key == .character(raw)
    }

    static func character(from event: NSEvent) -> String? {
        character(
            modifiers: event.modifierFlags,
            charactersApplying: { event.characters(byApplyingModifiers: $0) },
            fallbackCharacters: event.charactersIgnoringModifiers
        )
    }

    /// Resolves the canonical character AppKit matches for shortcut capture and live matching.
    ///
    /// When Command is held, translates with `[.command]` only (stripping Shift, Option, and
    /// Control) so layouts whose Command layer differs from the base layer — such as
    /// Dvorak-QWERTY ⌘ and Russian — record and match the same key AppKit menus use, while
    /// preserving unshifted US characters like `⇧⌘[` -> `[`. When Command is not held,
    /// strips all modifiers to read the unshifted keycap.
    static func character(
        modifiers: NSEvent.ModifierFlags,
        charactersApplying: (NSEvent.ModifierFlags) -> String?,
        fallbackCharacters: String? = nil
    ) -> String? {
        let queryModifiers: NSEvent.ModifierFlags = modifiers.contains(.command) ? [.command] : []
        let candidate = charactersApplying(queryModifiers) ?? fallbackCharacters
        guard let candidate, let scalar = candidate.unicodeScalars.first else {
            return nil
        }
        // Reject control characters and private-use function keys not mapped above.
        if CharacterSet.controlCharacters.contains(scalar) {
            return nil
        }
        if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
            return nil
        }
        let lowered = String(candidate.prefix(1)).lowercased()
        return lowered.isEmpty ? nil : lowered
    }
}
