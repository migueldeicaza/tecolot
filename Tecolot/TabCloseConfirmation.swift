import AppKit

@MainActor
enum TabCloseConfirmation {
    static func confirm(_ tab: TerminalTab, in window: NSWindow?, close: @escaping () -> Void) {
        confirm(controllers: tab.loadedWorkspace?.controllers ?? [], title: "Close this tab?", in: window, close: close)
    }

    static func confirm(controllers: [TerminalSessionController], title: String, in window: NSWindow?, close: @escaping () -> Void) {
        present(required: controllers.contains(where: TerminalClosePolicy.requiresConfirmation), title: title, in: window, close: close)
    }

    static func present(required: Bool, title: String, in window: NSWindow?, close: @escaping () -> Void) {
        guard required else {
            close()
            return
        }
        if let window, window.attachedSheet != nil {
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Closing will end the local shells and their programs."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if let window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    close()
                }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            close()
        }
    }
}

@MainActor
enum GroupCloseConfirmation {
    static func requiresConfirmation(_ group: TerminalTabGroup) -> Bool {
        TerminalClosePolicy.confirmationCount(in: group.tabs.flatMap {
            $0.loadedWorkspace?.controllers ?? []
        }) > 0
    }

    static func confirm(_ group: TerminalTabGroup, in window: NSWindow?, close: @escaping () -> Void) {
        TabCloseConfirmation.present(required: requiresConfirmation(group), title: "Close this group?", in: window, close: close)
    }
}
