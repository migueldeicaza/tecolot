//
//  AppTerminalView.swift
//  Tecolot
//

import Foundation
import os
import SwiftTerm

private final class TerminalSessionEventDelivery: Sendable {
    private enum Event: Sendable {
        case bell
        case output
    }

    private let handler = OSAllocatedUnfairLock<(@MainActor @Sendable (Event) -> Void)?>(
        initialState: nil)
    private let lastOutputNotification = OSAllocatedUnfairLock(initialState: Date.distantPast)

    @MainActor
    func setController(_ controller: TerminalSessionController?) {
        handler.withLock { storedHandler in
            storedHandler = { [weak controller] event in
                switch event {
                case .bell:
                    controller?.noteBell()
                case .output:
                    controller?.noteOutputActivity()
                }
            }
        }
    }

    nonisolated func sendBell() {
        guard let handler = handler.withLock({ $0 }) else { return }
        Task { @MainActor in
            handler(.bell)
        }
    }

    nonisolated func sendOutput() {
        let shouldNotify = lastOutputNotification.withLock { lastNotification in
            let now = Date()
            guard now.timeIntervalSince(lastNotification) > 0.25 else { return false }
            lastNotification = now
            return true
        }
        guard shouldNotify, let handler = handler.withLock({ $0 }) else { return }
        Task { @MainActor in
            handler(.output)
        }
    }
}

final class AppTerminalView: LocalProcessTerminalView {
    weak var sessionController: TerminalSessionController? {
        didSet {
            eventDelivery.setController(sessionController)
            setProcessOutputHandler { [eventDelivery] in
                eventDelivery.sendOutput()
            }
        }
    }

    nonisolated private let eventDelivery = TerminalSessionEventDelivery()

    nonisolated override func bell(source: Terminal) {
        super.bell(source: source)
        eventDelivery.sendBell()
    }
}
