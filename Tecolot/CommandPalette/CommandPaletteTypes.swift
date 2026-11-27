import AppKit
import Foundation

/// Layout constants measured from Rex's Command Palette and adapted for Tecolot.
nonisolated enum CommandPaletteMetrics {
    static let width: CGFloat = 330
    static let maxHeight: CGFloat = 500
    static let minHeight: CGFloat = 92
    static let topOffset: CGFloat = 76
    static let cornerRadius: CGFloat = 18
    static let horizontalInset: CGFloat = 8
    static let headerTopInset: CGFloat = 8
    static let headerBottomInset: CGFloat = 6
    static let inputHeight: CGFloat = 34
    static let inputCornerRadius: CGFloat = 11
    static let rowHeight: CGFloat = 30
    static let twoLineRowHeight: CGFloat = 44
    static let sectionHeaderHeight: CGFloat = 24
    static let dividerHeight: CGFloat = 9
    static let hintHeight: CGFloat = 56
    static let footerHeight: CGFloat = 34
    static let selectionPillCornerRadius: CGFloat = 9
    static let listTopPadding: CGFloat = 2
    static let listBottomPaddingWithFooter: CGFloat = 4
    static let listBottomPaddingWithoutFooter: CGFloat = 6
}

enum PaletteRowAccessory: Equatable {
    case none
    case shortcut(String)
    case chevron(detail: String? = nil, shortcut: String? = nil)
    case checkmark
    case status(String)
    case returnGlyph
}

enum PaletteOutcome {
    /// Dismisses the palette and restores previous first responder when `restoreFocus` is true.
    case dismiss(restoreFocus: Bool = true)
    /// Pushes a nested drill-down scope onto the stack.
    case push(PaletteScope)
    /// Pops the current scope back to its parent.
    case pop
    /// Keeps the palette open and refreshes rows in-place.
    case stayAndReload
}

enum PaletteProfilePickerMode: Equatable {
    case applyToWindow
    case newTab
    case newWindow

    var chipTitle: String {
        switch self {
        case .applyToWindow:
            "Apply Profile"
        case .newTab:
            "New Tab with Profile"
        case .newWindow:
            "New Window with Profile"
        }
    }

    var placeholder: String {
        "Select Profile…"
    }
}

struct PaletteEnumOption {
    let id: String
    let title: String
    let isSelected: Bool
    let keywords: [String]
    let onSelect: @MainActor () -> Void

    init(
        id: String,
        title: String,
        isSelected: Bool,
        keywords: [String] = [],
        onSelect: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.title = title
        self.isSelected = isSelected
        self.keywords = keywords
        self.onSelect = onSelect
    }
}

/// Interactive scope pushed onto the Command Palette navigation stack.
enum PaletteScope {
    case root
    case groupPicker
    case moveTabToGroup(tabID: UUID)
    case themePicker(originalThemeOverride: String?, controllerID: UUID)
    case profilePicker(mode: PaletteProfilePickerMode)
    case enumPicker(title: String, placeholder: String, options: [PaletteEnumOption])
    case textInput(
        title: String,
        placeholder: String,
        initialText: String,
        emptyActionTitle: String?,
        submitActionPrefix: String,
        onSubmit: @MainActor (String) -> Void,
        onEmptyAction: (@MainActor () -> Void)?
    )
    case numericInput(
        title: String,
        rangeText: String,
        hint: String,
        min: Double,
        max: Double,
        unit: String,
        onSubmit: @MainActor (Double) -> Void
    )
    case directoryPicker(initialPath: String?)
    case sshHostPicker

    var chipTitle: String? {
        switch self {
        case .root:
            nil
        case .groupPicker:
            "Group"
        case .moveTabToGroup:
            "Move to Group"
        case .themePicker:
            "Theme"
        case .profilePicker(let mode):
            mode.chipTitle
        case .enumPicker(let title, _, _):
            title
        case .textInput(let title, _, _, _, _, _, _):
            title
        case .numericInput(let title, _, _, _, _, _, _):
            title
        case .directoryPicker:
            "Go to Directory"
        case .sshHostPicker:
            "Remote Host"
        }
    }

    var placeholder: String {
        switch self {
        case .root:
            "Search commands, groups, and tabs…"
        case .groupPicker:
            "Filter or create…"
        case .moveTabToGroup:
            "Select group…"
        case .themePicker:
            "Select Theme…"
        case .profilePicker(let mode):
            mode.placeholder
        case .enumPicker(_, let placeholder, _):
            placeholder
        case .textInput(_, let placeholder, _, _, _, _, _):
            placeholder
        case .numericInput(_, let rangeText, _, _, _, _, _):
            rangeText
        case .directoryPicker:
            "Enter path…"
        case .sshHostPicker:
            "user@host or SSH alias…"
        }
    }

    var showsFooter: Bool {
        if case .root = self {
            return true
        }
        return false
    }

    /// True when the search field edits a freeform value (such as a name, number, path, or host)
    /// where Home/End should pass through to the text field rather than jumping the results list.
    var isTextEntryScope: Bool {
        switch self {
        case .textInput, .numericInput, .directoryPicker, .sshHostPicker:
            true
        case .root, .groupPicker, .moveTabToGroup, .themePicker, .profilePicker, .enumPicker:
            false
        }
    }

    var initialQuery: String {
        switch self {
        case .textInput(_, _, let initialText, _, _, _, _):
            initialText
        case .directoryPicker(let path):
            path ?? ""
        default:
            ""
        }
    }
}

struct PaletteScopeFrame {
    let scope: PaletteScope
    var query: String
    var selectedRowID: String?
}

enum PaletteIcon {
    case symbol(String)
    case image(NSImage)
}

struct PaletteRow {
    enum Style {
        case standard(title: String, icon: PaletteIcon? = nil, accessory: PaletteRowAccessory)
        case twoLine(title: String, subtitle: String, icon: PaletteIcon?, accessory: PaletteRowAccessory)
    }

    let id: String
    let section: String?
    let style: Style
    let keywords: [String]
    let isCommand: Bool
    let isDefaultSelection: Bool
    let completionText: String?
    var matchRanges: [Range<String.Index>]
    var subtitleMatchRanges: [Range<String.Index>]
    let onPreview: (@MainActor () -> Void)?
    let onExecute: @MainActor () -> PaletteOutcome

    var title: String {
        switch style {
        case .standard(let title, _, _), .twoLine(let title, _, _, _):
            title
        }
    }

    var subtitle: String? {
        switch style {
        case .standard:
            nil
        case .twoLine(_, let subtitle, _, _):
            subtitle
        }
    }

    var rowHeight: CGFloat {
        switch style {
        case .standard:
            CommandPaletteMetrics.rowHeight
        case .twoLine:
            CommandPaletteMetrics.twoLineRowHeight
        }
    }

    init(
        id: String,
        section: String? = nil,
        style: Style,
        keywords: [String] = [],
        isCommand: Bool = true,
        isDefaultSelection: Bool = false,
        completionText: String? = nil,
        matchRanges: [Range<String.Index>] = [],
        subtitleMatchRanges: [Range<String.Index>] = [],
        onPreview: (@MainActor () -> Void)? = nil,
        onExecute: @escaping @MainActor () -> PaletteOutcome
    ) {
        self.id = id
        self.section = section
        self.style = style
        self.keywords = keywords
        self.isCommand = isCommand
        self.isDefaultSelection = isDefaultSelection
        self.completionText = completionText
        self.matchRanges = matchRanges
        self.subtitleMatchRanges = subtitleMatchRanges
        self.onPreview = onPreview
        self.onExecute = onExecute
    }
}

enum PaletteDisplayItem {
    case sectionHeader(String)
    case divider
    case row(PaletteRow)
    case hint(String)

    var isSelectable: Bool {
        if case .row = self {
            return true
        }
        return false
    }

    var height: CGFloat {
        switch self {
        case .sectionHeader:
            CommandPaletteMetrics.sectionHeaderHeight
        case .divider:
            CommandPaletteMetrics.dividerHeight
        case .row(let row):
            row.rowHeight
        case .hint:
            CommandPaletteMetrics.hintHeight
        }
    }

    var row: PaletteRow? {
        if case .row(let row) = self {
            return row
        }
        return nil
    }
}

/// Protocol matching GroupSwitcherPresenting so window controllers and tests can substitute presenters.
@MainActor
protocol CommandPalettePresenting: AnyObject {
    var isVisible: Bool { get }
    func present(
        for controller: TerminalWindowController,
        manager: TerminalWindowManager,
        initialScope: PaletteScope,
        anchor: NSPoint?
    )
    func dismiss(restoreFocus: Bool)
}

extension CommandPalettePresenting {
    func present(
        for controller: TerminalWindowController,
        manager: TerminalWindowManager,
        initialScope: PaletteScope = .root
    ) {
        present(for: controller, manager: manager, initialScope: initialScope, anchor: nil)
    }
}
