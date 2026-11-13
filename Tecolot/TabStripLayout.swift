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
    static let colorModeKey = "tabIconColorMode"
    static let fillKey = "fillAvailableTabSpace"
    static let animationStyleKey = "tabAnimationStyle"
    static let preferGeneratedTitlesKey = "preferGeneratedTabTitles"
    enum ColorMode: String { case always, activeTabs, activePanes, never }
    var iconCount: Int
    var colorMode: ColorMode
    var fill: Bool
    var animationStyle: String
    var preferGeneratedTitles: Bool

    init(defaults: UserDefaults = .standard) {
        iconCount = min(5, max(0, defaults.object(forKey: Self.iconCountKey) as? Int ?? 3))
        colorMode = defaults.string(forKey: Self.colorModeKey).flatMap(ColorMode.init(rawValue:)) ?? .always
        fill = defaults.bool(forKey: Self.fillKey)
        animationStyle = defaults.string(forKey: Self.animationStyleKey) ?? "natural"
        preferGeneratedTitles = defaults.object(forKey: Self.preferGeneratedTitlesKey) as? Bool ?? true
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
