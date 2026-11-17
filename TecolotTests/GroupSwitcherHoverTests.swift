import AppKit
import Testing
@testable import Tecolot

@MainActor
struct GroupSwitcherHoverTests {
    @Test func highlightFollowsThePointer() throws {
        let panel = GroupSwitcherPanel()
        let groups = (0..<3).map {
            GroupSwitcherModel.Group(id: UUID(), name: "Group \($0)", isCurrent: $0 == 0)
        }
        panel.configure(model: GroupSwitcherModel(groups: groups, filter: ""))
        #expect(panel.table.selectedRow == 0)
        #expect(panel.table.trackingAreas.contains {
            $0.options.contains([.mouseMoved, .activeAlways, .inVisibleRect])
        })
        let target = panel.table.rect(ofRow: 2)
        let point = panel.table.convert(NSPoint(x: target.midX, y: target.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
            context: nil, eventNumber: 0, clickCount: 0, pressure: 0
        ))
        panel.table.mouseMoved(with: event)
        #expect(panel.table.selectedRow == 2)
    }
}
