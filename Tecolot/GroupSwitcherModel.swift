import Foundation

nonisolated struct GroupSwitcherModel {
    struct Group: Equatable {
        let id: UUID
        let name: String
        var isCurrent = false
        var isShownElsewhere = false
    }
    enum Action: Equatable { case group(UUID), newGroup(String?), remote, attach }
    struct Row: Equatable {
        let title: String
        let keycap: String
        let symbol: String?
        let action: Action
        var isCurrent = false
        var isShownElsewhere = false
        var separatorBefore = false
    }
    let groups: [Group]
    let filter: String
    var newGroupKeycap: String = AppShortcutID.newGroup.descriptor.defaultShortcut?.displayString ?? ""

    var rows: [Row] {
        let text = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = groups.filter {
            text.isEmpty || $0.name.localizedStandardContains(text)
        }
        var rows = matches.enumerated().map { index, group in
            Row(
                title: group.name,
                keycap: index < 9 ? "⌘\(index + 1)" : "",
                symbol: nil,
                action: .group(group.id),
                isCurrent: group.isCurrent,
                isShownElsewhere: group.isShownElsewhere
            )
        }
        let name = !text.isEmpty && matches.isEmpty ? text : nil
        rows.append(Row(
            title: name.map {
                "New Group “\($0)”"
            } ?? "New Group",
            keycap: newGroupKeycap,
            symbol: "rectangle.stack.badge.plus",
            action: .newGroup(name),
            separatorBefore: !rows.isEmpty
        ))
        if text.isEmpty {
            rows.append(Row(
                title: "New Remote Session…",
                keycap: "",
                symbol: "network.badge.shield.half.filled",
                action: .remote,
                separatorBefore: true
            ))
            rows.append(Row(title: "Attach to Session…", keycap: "", symbol: "link", action: .attach))
        }
        return rows
    }

    var initialSelection: Int {
        filter.isEmpty ? rows.firstIndex(where: \.isCurrent) ?? 0 : 0
    }
}
