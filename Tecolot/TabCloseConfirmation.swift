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
        let monitor = ConfirmationKeyboard.install(on: alert)
        if let window {
            alert.beginSheetModal(for: window) { response in
                monitor.map(NSEvent.removeMonitor)
                if response == .alertFirstButtonReturn {
                    close()
                }
            }
        } else {
            defer { monitor.map(NSEvent.removeMonitor) }
            if alert.runModal() == .alertFirstButtonReturn {
                close()
            }
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

/// Keeps destructive buttons red while restoring plain Return and Escape.
@MainActor
enum ConfirmationKeyboard {
    static func button(for event: NSEvent, in alert: NSAlert) -> NSButton? {
        guard
            event.window === alert.window,
            event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]) else {
            return nil
        }
        let index: Int
        if event.keyCode == 53 {
            index = 1
        } else if event.specialKey == .carriageReturn || event.specialKey == .enter {
            index = 0
        } else {
            return nil
        }
        guard alert.buttons.indices.contains(index), alert.buttons[index].isEnabled else {
            return nil
        }
        return alert.buttons[index]
    }

    static func install(on alert: NSAlert) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak alert] event in
            guard let alert, let button = button(for: event, in: alert) else {
                return event
            }
            button.performClick(nil)
            return nil
        }
    }

    static func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let monitor = install(on: alert)
        defer { monitor.map(NSEvent.removeMonitor) }
        return alert.runModal()
    }
}
