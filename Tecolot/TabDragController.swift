import AppKit

nonisolated struct TabDropPayload: Codable, Equatable {
    static let typeName = "com.tirania.tecolot.tab"
    let groupID: UUID
    let tabID: UUID
    var data: Data? {
        try? JSONEncoder().encode(self)
    }
    init(groupID: UUID, tabID: UUID) {
        self.groupID = groupID
        self.tabID = tabID
    }
    init?(data: Data) {
        guard let value = try? JSONDecoder().decode(Self.self, from: data) else {
            return nil
        }
        self = value
    }
    @MainActor static let pasteboardType = NSPasteboard.PasteboardType(typeName)
}

/// AppKit's dragging image is the snapshot window that follows the pointer.
/// The original cell remains dimmed in a gap until the drag commits or cancels.
final class TabDragController: NSObject, NSDraggingSource {
    private weak var bar: HorizontalTabBarView?
    private var dragged: TerminalTab?
    private var sourceGroup: TerminalTabGroup?
    private var escapeMonitor: Any?
    private var cancelled = false
    init(bar: HorizontalTabBarView) {
        self.bar = bar
    }
    deinit {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
    }

    func begin(tab: TerminalTab, cell: TabItemView, event: NSEvent) {
        guard let bar, let owner = bar.controller else {
            return
        }
        dragged = tab
        sourceGroup = owner.group
        cancelled = false
        let item = NSPasteboardItem()
        guard let data = TabDropPayload(groupID: owner.group.id, tabID: tab.id).data else {
            return
        }
        item.setData(data, forType: TabDropPayload.pasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let image: NSImage
        if let rep = cell.bitmapImageRepForCachingDisplay(in: cell.bounds) {
            cell.cacheDisplay(in: cell.bounds, to: rep)
            image = NSImage(size: cell.bounds.size)
            image.addRepresentation(rep)
        } else {
            image = NSImage(size: cell.bounds.size)
        }
        draggingItem.setDraggingFrame(cell.bounds, contents: image)
        let index = owner.group.tabs.firstIndex {
            $0 === tab
        } ?? 0
        bar.showDrop(at: index, tabID: tab.id)
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.cancelled = true
            }
            return event
        }
        let session = cell.beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
        session.draggingFormation = .none
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        defer {
            (bar?.window as? TerminalWindow)?.finishTabPointerGesture()
            bar?.showDrop(at: nil)
            dragged = nil
            sourceGroup = nil
            if let escapeMonitor {
                NSEvent.removeMonitor(escapeMonitor)
                self.escapeMonitor = nil
            }
        }
        guard
            operation.isEmpty, !cancelled, NSEvent.pressedMouseButtons == 0, let bar, let owner = bar.controller,
            let tab = dragged, let sourceGroup, sourceGroup.tabs.contains(where: {
                $0 === tab
            }) else {
            return
        }
        // A failed drop within the original bar is a cancellation, not a tear-off.
        if let window = bar.window {
            let point = bar.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
            if bar.bounds.insetBy(dx: 0, dy: -12).contains(point) {
                return
            }
        }
        if let detached = owner.manager.moveToNewWindow(tab, from: sourceGroup, activate: false) as? TerminalWindowController {
            detached.window?.setFrameTopLeftPoint(NSPoint(x: screenPoint.x - 100, y: screenPoint.y + 23))
            detached.window?.orderFront(nil)
        }
    }

    private func resolved(_ sender: any NSDraggingInfo) -> (TerminalTabGroup, TerminalTab)? {
        // Foreign applications cannot introduce ids into the manager.
        guard
            sender.draggingSource is TabDragController || sender.draggingSource is SidebarTabBarView, let owner = bar?.controller,
            let data = sender.draggingPasteboard.data(forType: TabDropPayload.pasteboardType),
            let payload = TabDropPayload(data: data),
            let group = owner.manager.groups.first(where: {
                $0.id == payload.groupID
            }),
            let tab = group.tabs.first(where: {
                $0.id == payload.tabID
            }) else {
            return nil
        }
        return (group, tab)
    }
    func accepts(_ sender: any NSDraggingInfo) -> Bool {
        guard let bar else {
            return false
        }
        let point = bar.scroll.convert(sender.draggingLocation, from: nil)
        return bar.scroll.bounds.contains(point) && resolved(sender) != nil
    }
    func update(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender) else {
            bar?.showDrop(at: nil)
            return []
        }
        guard let bar, let (source, tab) = resolved(sender), let window = bar.window else {
            return []
        }
        let point = window.convertPoint(toScreen: sender.draggingLocation)
        bar.autoscrollDrop(screenPoint: point)
        let insertion = bar.dropIndex(screenPoint: point)
        let index: Int
        if
            source === bar.controller?.group, let old = source.tabs.firstIndex(where: {
                $0 === tab
            }) {
            index = TabStripLayout.reorderIndex(source: old, insertion: insertion, count: source.tabs.count)
        } else {
            index = insertion
        }
        bar.showDrop(at: index, tabID: tab.id)
        return .move
    }
    func drop(_ sender: any NSDraggingInfo) -> Bool {
        guard accepts(sender) else {
            return false
        }
        guard let bar, let owner = bar.controller, let window = bar.window, let (source, tab) = resolved(sender) else {
            return false
        }
        let insertion = bar.dropIndex(screenPoint: window.convertPoint(toScreen: sender.draggingLocation))
        bar.showDrop(at: nil)
        if source === owner.group {
            owner.manager.reorder(tab, in: source, insertion: insertion)
        } else {
            owner.manager.move(tab, from: source, to: owner.group, insertion: insertion)
        }
        return true
    }
}
