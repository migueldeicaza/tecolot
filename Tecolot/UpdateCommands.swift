//
//  UpdateCommands.swift
//  Tecolot
//
//  In-app updates through Sparkle. Tecolot ships as a Developer ID signed app
//  outside the Mac App Store, so Sparkle checks an appcast feed that the
//  release workflow publishes to https://tecolot.com/appcast.xml.
//

import Combine
import Sparkle
import SwiftUI

/// Owns the one updater instance for the process.
///
/// The updater starts with the app, so a scheduled check can run even if the
/// user never opens the menu. `SUEnableAutomaticChecks` is deliberately absent
/// from Info.plist: Sparkle then asks for permission on the second launch, and
/// checks nothing until the user agrees.
@MainActor
final class UpdaterModel: ObservableObject {
    static let shared = UpdaterModel()

    let controller: SPUStandardUpdaterController

    /// False while a check is in progress, which is when the menu item is disabled.
    @Published private(set) var canCheckForUpdates = false

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    var updater: SPUUpdater { controller.updater }
}

struct UpdateCommands: Commands {
    @ObservedObject private var model = UpdaterModel.shared

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                model.controller.checkForUpdates(nil)
            }
            .disabled(!model.canCheckForUpdates)
        }
    }
}
