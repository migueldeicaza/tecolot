import AppKit
import QuartzCore

/// Global style and sidebar geometry, shared by all terminal windows.
struct SidebarPreferences: Equatable {
    static let positionKey = "sidebarPosition"
    static let positionDefault = "left"
    static let hiddenKey = "sidebarHidden"
    static let hiddenDefault = false
    static let widthKey = "sidebarWidth"
    static let widthDefault = 240.0
    static let textSizeKey = "sidebarTextSize"
    static let textSizeDefault = 0.0
    static let preserveWidthKey = "preserveWidthWhenResizingSidebar"
    static let preserveWidthDefault = true
    static let gestureKey = "sidebarGesture"
    static let gestureDefault = "swipe"

    static let systemSizeKey = "NSTableViewDefaultSizeMode"
    static let observedKeys = [ProgramActivityPreferences.tabStyleKey, positionKey, hiddenKey,
                               widthKey, textSizeKey, preserveWidthKey, gestureKey, systemSizeKey]

    enum Style: String, CaseIterable {
        case above, left, right
    }
    let style: Style
    let hidden: Bool
    let width: CGFloat
    let textSize: CGFloat
    let preserveWidth: Bool
    let gesture: String

    init(defaults: UserDefaults = .standard) {
        style = defaults.string(forKey: ProgramActivityPreferences.tabStyleKey) == "vertical"
            ? (defaults.string(forKey: SidebarPreferences.positionKey) == "right" ? .right : .left) : .above
        hidden = defaults.bool(forKey: SidebarPreferences.hiddenKey)
        width = Self.clampWidth(defaults.object(forKey: SidebarPreferences.widthKey) == nil ? Self.widthDefault : defaults.double(forKey: SidebarPreferences.widthKey))
        let size = defaults.double(forKey: SidebarPreferences.textSizeKey)
        let systemSize = defaults.integer(forKey: Self.systemSizeKey)
        textSize = size > 0 ? size : (systemSize == 1 ? 11 : systemSize == 3 ? 15 : 13)
        preserveWidth = defaults.object(forKey: SidebarPreferences.preserveWidthKey) as? Bool ?? Self.preserveWidthDefault
        gesture = defaults.string(forKey: SidebarPreferences.gestureKey) ?? Self.gestureDefault
    }

    static func clampWidth(_ width: CGFloat) -> CGFloat {
        min(480, max(167, width.isFinite ? width : Self.widthDefault))
    }

    static func setStyle(_ style: Style, defaults: UserDefaults = .standard) {
        if style != .above {
            defaults.set(style.rawValue, forKey: SidebarPreferences.positionKey)
        }
        defaults.set(style == .above ? "horizontal" : "vertical", forKey: ProgramActivityPreferences.tabStyleKey)
    }

    static func toggleStyle(defaults: UserDefaults = .standard) {
        defaults.set(defaults.string(forKey: ProgramActivityPreferences.tabStyleKey) == "vertical" ? "horizontal" : "vertical", forKey: ProgramActivityPreferences.tabStyleKey)
    }
}

/// A snapshot of the outline, including filtered children and digit destinations.
@MainActor
struct SidebarModel {
    enum Kind: Equatable { case current, otherWindow, background, dormant }
    struct Section {
        let group: TerminalTabGroup
        let kind: Kind
        let tabs: [TerminalTab]
    }
    let sections: [Section]
    var numberedTabs: [(group: TerminalTabGroup, tab: TerminalTab)] {
        sections.filter {
            !$0.group.isCollapsed
        }.flatMap { section in
            section.tabs.map {
                (section.group, $0)
            }
        }
    }

    init(manager: TerminalWindowManager, current: TerminalTabGroup, filter: String = "") {
        sections = manager.groups.compactMap { group in
            let all = filter.isEmpty || group.name.localizedCaseInsensitiveContains(filter)
            let tabs = all ? group.tabs : group.tabs.filter {
                $0.title.localizedCaseInsensitiveContains(filter)
            }
            guard all || !tabs.isEmpty else {
                return nil
            }
            let kind: Kind = group === current ? .current : manager.window(showing: group) != nil ? .otherWindow
                : group.tabs.allSatisfy(\.isDormant) ? .dormant : .background
            return Section(group: group, kind: kind, tabs: tabs)
        }
    }

    /// Converts a filtered outline boundary back to the group's original tab order.
    static func insertionIndex(group: TerminalTabGroup, visible: [TerminalTab], boundary: Int) -> Int {
        if boundary < 0 {
            return group.tabs.count
        }
        if boundary < visible.count {
            return group.tabs.firstIndex {
                $0 === visible[boundary]
            } ?? group.tabs.count
        }
        return visible.last.flatMap { last in
            group.tabs.firstIndex {
                $0 === last
            }.map {
                $0 + 1
            }
        } ?? group.tabs.count
    }
}

/// Uses the measured sidebar spring without delaying terminal layout or resize delivery.
@MainActor
enum SidebarMotion {
    static func move(_ view: NSView, from old: NSRect, style: String = TabStripPreferences().animationStyle) {
        guard old != view.frame, old.width > 0, let layer = view.layer, style != "off" else {
            return
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.12
            layer.add(fade, forKey: "sidebarLayout")
            return
        }
        let response = style == "snappy" ? 0.20 : 0.32
        let damping = style == "snappy" ? 1.0 : 0.91
        let delta = NSPoint(x: old.midX - view.frame.midX, y: old.midY - view.frame.midY)
        let position = CASpringAnimation(keyPath: "position")
        position.mass = 1
        position.stiffness = pow(2 * .pi / response, 2)
        position.damping = 2 * damping * sqrt(position.stiffness)
        position.fromValue = NSValue(point: NSPoint(x: layer.position.x + delta.x, y: layer.position.y + delta.y))
        position.toValue = NSValue(point: layer.position)
        position.duration = 0.35
        layer.add(position, forKey: "sidebarPosition")
        let size = position.copy() as! CASpringAnimation
        size.keyPath = "bounds.size"
        size.fromValue = NSValue(size: old.size)
        size.toValue = NSValue(size: view.frame.size)
        layer.add(size, forKey: "sidebarSize")
    }
}
