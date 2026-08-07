//
//  ContentView.swift
//  MacTerminalUI
//
//  Created by Miguel de Icaza on 8/5/25.
//

import AppKit
import SwiftUI

struct ContentView: View {
    @Binding var document: TerminalDocument
    @State private var controller = TerminalSessionController()

    var body: some View {
        TerminalSessionView(controller: controller)
            .background(WindowTabbingConfigurator())
    }
}

struct WindowTabbingConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configureWindow(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureWindow(for: nsView)
    }

    private func configureWindow(for view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.tabbingIdentifier = "TerminalDocument"
            window.tabbingMode = .preferred
        }
    }
}

#Preview {
    ContentView(document: .constant(TerminalDocument(content: "")))
}
