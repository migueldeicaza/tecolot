import Foundation
import CoreGraphics

/// Above-style geometry, independent of AppKit and the currently selected tab.
nonisolated struct TabStripLayout {
    let available: CGFloat
    let count: Int
    let fill: Bool

    var step: CGFloat {
        guard count > 0 else {
            return 0
        }
        let cap: CGFloat = fill && count > 1 ? .infinity : 241
        return min(cap, max(65, max(0, available) / CGFloat(count)))
    }
    var cellWidth: CGFloat {
        count == 0 ? 0 : step + 1
    }
    var contentWidth: CGFloat {
        count == 0 ? 0 : step * CGFloat(count) + 1
    }
    var overflows: Bool {
        contentWidth > available + 1
    }
    var showsSurface: Bool {
        !(fill && count == 1)
    }

    func frame(at index: Int) -> CGRect {
        CGRect(x: CGFloat(index) * step, y: 0, width: cellWidth, height: 32)
    }

    func visibleIndices(offset: CGFloat) -> Range<Int> {
        guard count > 0, available > 0 else {
            return 0..<0
        }
        let first = max(0, min(count, Int(floor(max(0, offset - 1) / step))))
        let end = max(first, min(count, Int(ceil((offset + available) / step))))
        return first..<end
    }

    func offset(revealing index: Int, from offset: CGFloat) -> CGFloat {
        guard (0..<count).contains(index) else {
            return offset
        }
        let rect = frame(at: index)
        let next = rect.minX < offset ? rect.minX : max(offset, rect.maxX - available)
        return max(0, min(max(0, contentWidth - available), next))
    }

    /// A drop is an insertion boundary in the original array, before removal.
    static func reorderIndex(source: Int, insertion: Int, count: Int) -> Int {
        max(0, min(max(0, count - 1), insertion > source ? insertion - 1 : insertion))
    }

    func insertionIndex(at x: CGFloat) -> Int {
        guard count > 0 else {
            return 0
        }
        return max(0, min(count, Int(floor((x + step / 2) / step))))
    }
}

nonisolated enum TabAnimationPolicy: Equatable {
    case moving, crossfade, immediate

    static func layout(reduceMotion: Bool, style: String) -> Self {
        if style == "off" {
            return .immediate
        }
        return reduceMotion ? .crossfade : .moving
    }
}

/// Preferences for tab content shared by the strip and sidebar.
nonisolated struct TabStripPreferences: Equatable {
    static let iconCountKey = "showTabIcons"
    static let iconCountDefault = 3
    static let colorModeKey = "tabIconColorMode"
    static let colorModeDefault = ColorMode.always
    static let fillKey = "fillAvailableTabSpace"
    static let fillDefault = false
    static let animationStyleKey = "tabAnimationStyle"
    static let animationStyleDefault = "natural"
    static let preferGeneratedTitlesKey = "preferGeneratedTabTitles"
    static let preferGeneratedTitlesDefault = true
    static let observedKeys = [iconCountKey, colorModeKey, fillKey, animationStyleKey, preferGeneratedTitlesKey]
    enum ColorMode: String { case always, activeTabs, activePanes, never }

    /// The source of tab and window titles. The value is kept in the
    /// `preferGeneratedTitlesKey` Bool, so existing choices stay the same.
    enum TitleSource: String, CaseIterable {
        /// The name of the running program and the current folder.
        case generated
        /// The pane title from the items of the profile Window › Title
        /// section. The Active title item is the title that the program
        /// sets with OSC 0 or OSC 2.
        case profile

        /// The name of the setting on the Tabs page and on the profile
        /// Window page. The search catalog also uses it, so it cannot read
        /// `SettingID.title`.
        static let settingTitle = "Title shows"

        init(preferGeneratedTitles: Bool) {
            self = preferGeneratedTitles ? .generated : .profile
        }

        var prefersGeneratedTitles: Bool {
            self == .generated
        }

        var title: String {
            switch self {
            case .generated: "Program and folder"
            case .profile: "Profile title items"
            }
        }
    }
    var iconCount: Int
    var colorMode: ColorMode
    var fill: Bool
    var animationStyle: String
    var preferGeneratedTitles: Bool

    init(defaults: UserDefaults = .standard) {
        iconCount = min(5, max(0, defaults.object(forKey: Self.iconCountKey) as? Int ?? Self.iconCountDefault))
        colorMode = defaults.string(forKey: Self.colorModeKey).flatMap(ColorMode.init(rawValue:)) ?? Self.colorModeDefault
        fill = defaults.bool(forKey: Self.fillKey)
        animationStyle = defaults.string(forKey: Self.animationStyleKey) ?? Self.animationStyleDefault
        preferGeneratedTitles = defaults.object(forKey: Self.preferGeneratedTitlesKey) as? Bool ?? Self.preferGeneratedTitlesDefault
    }

    func colorsTile(selected: Bool, index: Int) -> Bool {
        switch colorMode {
        case .always:
            true
        case .activeTabs:
            selected
        case .activePanes:
            selected && index == 0
        case .never:
            false
        }
    }

    static func inspectsProcesses(paneCards: Bool, iconCount: Int) -> Bool {
        paneCards || iconCount > 0
    }
}
