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

enum UpdatePolicy {
    static var permitsUpdates: Bool {
#if DEBUG
        false
#else
        permitsUpdates(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            bundleNames: [
                Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ].compactMap { $0 }
        )
#endif
    }

    static func permitsUpdates(bundleIdentifier: String?, bundleNames: [String]) -> Bool {
        if bundleIdentifier?.lowercased().hasSuffix(".debug") == true {
            return false
        }

        return !bundleNames.contains { name in
            let lowercaseName = name.lowercased()
            return lowercaseName == "debug" || lowercaseName.hasSuffix(" debug")
        }
    }
}

/// Owns the one updater instance for the process.
///
/// In an eligible release bundle, the updater starts with the app. Thus, a
/// scheduled check can run if the user does not open the menu. `SUEnableAutomaticChecks`
/// is absent from Info.plist. Sparkle asks for permission on the second launch
/// and does not check until the user agrees.
@MainActor
final class UpdaterModel: ObservableObject {
    static let shared = UpdaterModel()

    let controller: SPUStandardUpdaterController
    let updatesEnabled: Bool

    /// False while a check is in progress, which is when the menu item is disabled.
    @Published private(set) var canCheckForUpdates = false

    private init() {
        updatesEnabled = UpdatePolicy.permitsUpdates
        controller = SPUStandardUpdaterController(
            startingUpdater: updatesEnabled,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        if updatesEnabled {
            controller.updater.publisher(for: \.canCheckForUpdates)
                .assign(to: &$canCheckForUpdates)
        }
    }

    var updater: SPUUpdater { controller.updater }
}

struct UpdateCommands: Commands {
    @ObservedObject private var model = UpdaterModel.shared

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if model.updatesEnabled {
                Button("Check for Updates…") {
                    model.controller.checkForUpdates(nil)
                }
                .disabled(!model.canCheckForUpdates)
            }
        }
    }
}
