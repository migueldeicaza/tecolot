//
//  SettingsWindowCloseObserver.swift
//  Tecolot
//
//  Tells the Settings view when its window closes.
//
import AppKit
import SwiftUI

/// SwiftUI keeps the state of a closed window. This lets the Settings view
/// reset the search before the window opens again.
struct SettingsWindowCloseObserver: NSViewRepresentable {
    let windowWillClose: () -> Void

    func makeNSView(context: Context) -> ObserverView {
        ObserverView()
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.windowWillClose = windowWillClose
    }

    final class ObserverView: NSView {
        var windowWillClose: () -> Void = {}
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            guard let window else {
                return
            }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.windowWillClose()
                }
            }
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}
