//
//  AppTerminalView.swift
//  Tecolot
//

import Foundation
import os
import SwiftTerm

final class AppTerminalView: LocalProcessTerminalView {
    weak var sessionController: TerminalSessionController?

    private let outputActivityLock = OSAllocatedUnfairLock(initialState: Date.distantPast)

    override func bell(source: Terminal) {
        super.bell(source: source)
        sessionController?.noteBell()
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)

        let shouldNotify = outputActivityLock.withLock { lastNotification in
            let now = Date()
            guard now.timeIntervalSince(lastNotification) > 0.25 else { return false }
            lastNotification = now
            return true
        }
        guard shouldNotify else { return }

        DispatchQueue.main.async { [weak self] in
            self?.sessionController?.noteOutputActivity()
        }
    }
}
