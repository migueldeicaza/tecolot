//
//  WindowCloseInterceptor.swift
//  Tecolot
//
//  NSDocument and SwiftUI both manage NSWindow delegates. This forwarding
//  proxy is deliberately narrow and fragile: re-install it when its window
//  becomes key, and forward all behavior other than closing to the delegate
//  that was already installed.
//

import AppKit
import Darwin
import SwiftTerm
import TerminalProfilesKit

@MainActor
enum TerminalClosePolicy {
    static func requiresConfirmation(for controller: TerminalSessionController) -> Bool {
        guard let process = controller.terminal?.process, process.running else {
            return false
        }

        switch controller.profile.askBeforeClosing {
        case .never:
            return false
        case .always:
            return true
        case .onlyIfProcessesRunning:
            return childProcessCount(parentPID: process.shellPid) > 0
        }
    }

    nonisolated private static func childProcessCount(parentPID: pid_t) -> Int {
        guard parentPID > 0 else { return 0 }
        var childPIDs = [pid_t](repeating: 0, count: 256)
        let count = childPIDs.withUnsafeMutableBufferPointer { buffer in
            proc_listchildpids(parentPID,
                               buffer.baseAddress,
                               Int32(buffer.count * MemoryLayout<pid_t>.stride))
        }
        return max(0, Int(count))
    }
}

@MainActor
final class WindowCloseInterceptor: NSObject, NSWindowDelegate {
    weak var window: NSWindow?
    private weak var forwardedDelegate: (any NSWindowDelegate)?
    private var observers: [NSObjectProtocol] = []
    private var bypassClose = false
    private var isPresentingConfirmation = false

    init(window: NSWindow) {
        self.window = window
        super.init()
        install()
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.install()
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// AppKit can replace this window's delegate during document restoration.
    /// Preserve that delegate and put this proxy back in front of it.
    func install() {
        guard let window, window.delegate !== self else { return }
        forwardedDelegate = window.delegate
        window.delegate = self
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || forwardedDelegate?.responds(to: aSelector) == true
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if aSelector == #selector(windowShouldClose(_:)) {
            return nil
        }
        return forwardedDelegate
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if bypassClose {
            return forwardedDelegate?.windowShouldClose?(sender) ?? true
        }

        guard let controller = TerminalSessionRegistry.shared.controller(for: sender),
              TerminalClosePolicy.requiresConfirmation(for: controller)
        else {
            return forwardedDelegate?.windowShouldClose?(sender) ?? true
        }

        guard !isPresentingConfirmation else { return false }
        isPresentingConfirmation = true

        let alert = NSAlert()
        alert.messageText = "Close this terminal?"
        alert.informativeText = "A process is still running."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
            guard let self else { return }
            self.isPresentingConfirmation = false
            guard response == .alertFirstButtonReturn else { return }
            self.bypassClose = true
            sender?.close()
        }
        return false
    }
}
