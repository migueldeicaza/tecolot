//
//  HotReloadCoordinator.swift
//  Tecolot
//
//  Orchestrates two-phase in-place hot reload ("upgrade program in place")
//  for local terminal panes using SCM_RIGHTS over a private Unix domain socket
//  and Tecolot's existing RestoreStore layout + scrollback files.
//

import AppKit
import Darwin
import Foundation
import os
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers

nonisolated enum HotReloadEnvironment {
    static let socketPathKey = "TECOLOT_HOT_RELOAD_SOCKET"
    static let tokenKey = "TECOLOT_HOT_RELOAD_TOKEN"
}

/// Holds PTY master descriptors received over `SCM_RIGHTS` at launch until each
/// restored `TerminalSessionController` claims its descriptor.
@MainActor
final class HotReloadInbox {
    static let shared = HotReloadInbox()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.tirania.Tecolot", category: "HotReload")

    /// True if this process launched from a successful hot-reload handoff.
    private(set) var hasReceivedHandoff = false
    /// PID of the sender instance that handed off these sessions.
    private(set) var sourcePID: pid_t?
    /// Any error encountered while attempting to receive a handoff at launch.
    private(set) var lastReceiveError: String?

    private var pending: [UUID: HotReloadPaneTransfer] = [:]

    /// Called early in `applicationDidFinishLaunching`, before `RestoreStore`
    /// restores windows.
    @discardableResult
    func receiveIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 10
    ) -> Bool {
        guard
            let socketPath = environment[HotReloadEnvironment.socketPathKey],
            !socketPath.isEmpty,
            let token = environment[HotReloadEnvironment.tokenKey],
            !token.isEmpty
        else {
            return false
        }

        do {
            let result = try FDTransferSocket.receiveHandoff(
                socketPath: socketPath,
                token: token,
                timeout: timeout
            )
            sourcePID = result.sourcePID
            hasReceivedHandoff = true
            lastReceiveError = nil
            for transfer in result.transfers {
                if let existing = pending.updateValue(transfer, forKey: transfer.entry.paneID) {
                    Darwin.close(existing.fd)
                }
            }
            logger.notice("Received \(result.transfers.count) local PTY descriptor(s) from PID \(result.sourcePID).")
            return true
        } catch {
            lastReceiveError = error.localizedDescription
            logger.error("Failed to receive hot-reload handoff: \(error.localizedDescription)")
            return false
        }
    }

    /// Injects pre-received transfers (used by tests and chained-reload rollback).
    func storeForTesting(_ transfers: [HotReloadPaneTransfer], markReceived: Bool = true) {
        if markReceived {
            hasReceivedHandoff = true
        }
        for transfer in transfers {
            if let existing = pending.updateValue(transfer, forKey: transfer.entry.paneID) {
                Darwin.close(existing.fd)
            }
        }
    }

    func contains(paneID: UUID) -> Bool {
        pending[paneID] != nil
    }

    /// Claims ownership of the transferred descriptor for `paneID`.
    func take(paneID: UUID) -> HotReloadPaneTransfer? {
        pending.removeValue(forKey: paneID)
    }

    /// Closes and discards an unclaimed descriptor if its dormant pane closes.
    func discard(paneID: UUID) {
        if let transfer = pending.removeValue(forKey: paneID) {
            Darwin.close(transfer.fd)
        }
    }

    /// Temporarily removes all still-unclaimed descriptors (e.g. dormant tabs)
    /// so they can be forwarded across a chained hot reload.
    func drainUnclaimedForHandoff() -> [HotReloadPaneTransfer] {
        let items = Array(pending.values)
        pending.removeAll()
        return items
    }

    /// Restores drained unclaimed descriptors after an aborted hot reload.
    func restoreUnclaimed(_ transfers: [HotReloadPaneTransfer]) {
        for transfer in transfers {
            if let existing = pending.updateValue(transfer, forKey: transfer.entry.paneID) {
                Darwin.close(existing.fd)
            }
        }
    }

    /// Closes any descriptors that were never claimed before normal termination.
    func closeAllUnclaimed() {
        for transfer in pending.values {
            Darwin.close(transfer.fd)
        }
        pending.removeAll()
    }

    /// Resets state for isolated unit tests.
    func resetForTesting() {
        closeAllUnclaimed()
        hasReceivedHandoff = false
        sourcePID = nil
        lastReceiveError = nil
    }
}

/// Coordinates pausing local PTYs, saving layout + scrollback, launching the
/// replacement Tecolot process, streaming descriptors via `SCM_RIGHTS`, and
/// either committing (exiting cleanly) or rolling back on failure.
@MainActor
final class HotReloadCoordinator {
    static let shared = HotReloadCoordinator()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.tirania.Tecolot", category: "HotReload")

    private(set) var isReloading = false
    /// Checked by `AppDelegate` so hot-reload termination bypasses the "Quit
    /// and terminate running processes?" confirmation and skips overwriting
    /// `RestoreStore`.
    private(set) var isExitingForHotReload = false

    /// Lets the user pick a replacement `.app` bundle (e.g. a newly built or
    /// downloaded Tecolot.app) and upgrades into it in place.
    func upgradeFromChosenApp() {
        guard !isReloading else {
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Upgrade Tecolot in Place"
        panel.message = "Choose a Tecolot application bundle to hand off all running local terminal sessions to."
        panel.prompt = "Upgrade & Hand Off"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        guard panel.runModal() == .OK, let targetURL = panel.url else {
            return
        }
        reloadInPlace(targetAppURL: targetURL)
    }

    /// Performs an in-place hot reload into `targetAppURL` (or the current
    /// application bundle when `nil`).
    func reloadInPlace(targetAppURL: URL? = nil) {
        guard !isReloading else {
            return
        }
        let resolvedTarget = targetAppURL ?? Bundle.main.bundleURL
        isReloading = true

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.performReload(targetURL: resolvedTarget)
        }
    }

    private func performReload(targetURL: URL) async {
        // Phase 1: Pause every running local pane so no bytes are read while we
        // snapshot RestoreStore and stream FDs over SCM_RIGHTS.
        let pausedPanes = pauseAllRunningLocalPanes()
        let unclaimedTransfers = HotReloadInbox.shared.drainUnclaimedForHandoff()

        var transfers: [HotReloadPaneTransfer] = pausedPanes.map { item in
            let dims = item.terminal.terminalDimensions
            let entry = HotReloadPaneEntry(
                paneID: item.paneID,
                shellPid: item.snapshot.shellPid,
                startTime: item.snapshot.startTime,
                cols: dims.cols,
                rows: dims.rows
            )
            return HotReloadPaneTransfer(entry: entry, fd: item.snapshot.fd)
        }
        transfers.append(contentsOf: unclaimedTransfers)

        let rollback: (Error) -> Void = { [weak self] error in
            guard let self else {
                return
            }
            for item in pausedPanes {
                item.terminal.resumeAfterAbortedHandoff()
            }
            HotReloadInbox.shared.restoreUnclaimed(unclaimedTransfers)
            self.isReloading = false
            self.logger.error("Hot reload aborted: \(error.localizedDescription)")
            self.presentAbortAlert(error: error)
        }

        // Phase 2: Persist window/tab/split layout + normal scrollback before
        // spawning the replacement instance.
        await withCheckedContinuation { continuation in
            RestoreStore.shared.saveForHotReload {
                continuation.resume()
            }
        }

        // Phase 3: Create a private 0600 Unix domain socket and start listening
        // before launching the replacement process.
        let socketInfo: (directoryURL: URL, socketPath: String)
        let listeningFD: Int32
        do {
            socketInfo = try FDTransferSocket.makePrivateSocketPath()
            do {
                listeningFD = try FDTransferSocket.listen(at: socketInfo.socketPath)
            } catch {
                FDTransferSocket.removePrivateSocket(
                    directoryURL: socketInfo.directoryURL,
                    socketPath: socketInfo.socketPath
                )
                throw error
            }
        } catch {
            rollback(error)
            return
        }

        let token = FDTransferSocket.makeRandomToken()
        let cleanupSocket = {
            Darwin.close(listeningFD)
            FDTransferSocket.removePrivateSocket(
                directoryURL: socketInfo.directoryURL,
                socketPath: socketInfo.socketPath
            )
        }

        // Start serving on a background task so the listening socket accepts
        // immediately once the replacement process launches.
        let handoffTask = Task.detached(priority: .userInitiated) {
            try FDTransferSocket.serveHandoff(
                listeningFD: listeningFD,
                token: token,
                transfers: transfers,
                timeout: 15
            )
        }

        // Phase 4: Launch the replacement Tecolot instance with handoff env vars.
        do {
            try await launchReplacementInstance(
                targetURL: targetURL,
                socketPath: socketInfo.socketPath,
                token: token
            )
        } catch {
            handoffTask.cancel()
            cleanupSocket()
            rollback(error)
            return
        }

        // Phase 5: Wait for the replacement instance to receive all FDs and ACK.
        do {
            let acceptedCount = try await handoffTask.value
            cleanupSocket()
            logger.notice("Hot reload acknowledged (\(acceptedCount) local PTY descriptor(s) transferred). Exiting.")

            // Phase 6 (Commit): Close our local copies of the handed-off FDs
            // without sending SIGTERM/SIGHUP, then exit cleanly.
            for item in pausedPanes {
                item.terminal.commitHandoff()
            }
            for item in unclaimedTransfers {
                Darwin.close(item.fd)
            }
            isExitingForHotReload = true
            isReloading = false
            NSApp.terminate(nil)
        } catch {
            cleanupSocket()
            rollback(error)
        }
    }

    private struct PausedPane {
        let paneID: UUID
        let terminal: AppTerminalView
        let snapshot: HotReloadProcessPauseSnapshot
    }

    private func pauseAllRunningLocalPanes() -> [PausedPane] {
        var seen = Set<UUID>()
        var controllers: [TerminalSessionController] = []

        for group in TerminalWindowManager.shared.groups {
            for tab in group.tabs {
                guard let workspace = tab.loadedWorkspace else {
                    continue
                }
                for controller in workspace.controllers where seen.insert(controller.id).inserted {
                    controllers.append(controller)
                }
            }
        }
        for controller in TerminalSessionRegistry.shared.allControllers where seen.insert(controller.id).inserted {
            controllers.append(controller)
        }

        var paused: [PausedPane] = []
        for controller in controllers {
            guard !controller.isPersistent, let terminal = controller.terminal else {
                continue
            }
            if let snapshot = terminal.pauseForHandoff() {
                paused.append(PausedPane(paneID: controller.id, terminal: terminal, snapshot: snapshot))
            }
        }
        return paused
    }

    private func launchReplacementInstance(
        targetURL: URL,
        socketPath: String,
        token: String
    ) async throws {
        var env = ProcessInfo.processInfo.environment
        env[HotReloadEnvironment.socketPathKey] = socketPath
        env[HotReloadEnvironment.tokenKey] = token

        if targetURL.pathExtension.lowercased() == "app" {
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            config.activates = true
            config.environment = env
            _ = try await NSWorkspace.shared.openApplication(at: targetURL, configuration: config)
            return
        }

        let process = Process()
        process.executableURL = targetURL
        process.environment = env
        try process.run()
    }

    private func presentAbortAlert(error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Hot Reload Aborted"
        alert.informativeText = "\(error.localizedDescription)\n\nAll running terminal sessions were resumed in this window."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

struct HotReloadCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Divider()
            Button("Hot Reload Tecolot (Prototype)") {
                HotReloadCoordinator.shared.reloadInPlace()
            }
            Button("Upgrade in Place from App…") {
                HotReloadCoordinator.shared.upgradeFromChosenApp()
            }
        }
    }
}
