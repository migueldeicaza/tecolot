import AppKit
import Network
import Synchronization
import TecolotSessionClient
import TecolotTransport

/// Shares a connection between the panes that use the same remote account.
@MainActor
final class RemoteHosts {
    static let shared = RemoteHosts()

    private struct Prepared: Sendable {
        let configuration: HostLinkConfiguration
        let askpass: AskpassServer
    }

    private struct Observer {
        let state: (HostLinkState) -> Void
        let notice: (String?) -> Void
        let window: () -> NSWindow?
        var retained: Bool
    }

    private enum Prompt {
        case askpass(AskpassRequest, AskpassServer.Reply)
        case install(UUID, String, Int64, @Sendable (Bool) -> Void)

        var id: UUID {
            switch self {
            case .askpass(let request, _): return request.id
            case .install(let id, _, _, _): return id
            }
        }
    }

    private struct PendingPrompt {
        let link: HostLink
        let prompt: Prompt
    }

    private let active = RemoteAppActivity()
    private let registry = HostLinkRegistry()
    private let monitor = NWPathMonitor()
    private var notifications: [NSObjectProtocol] = []
    private var wakeObserver: NSObjectProtocol?
    private var setup: Task<Prepared, Error>?
    private var prepared: Prepared?
    private var links: [String: HostLink] = [:]
    private var observers: [ObjectIdentifier: [UUID: Observer]] = [:]
    private var notices: [ObjectIdentifier: [UUID: String]] = [:]
    private var prompts: [PendingPrompt] = []
    private var currentPrompt: PendingPrompt?
    private var currentAlert: NSAlert?
    private var stopped = false
    private let approvalKey = "RemoteHelperApprovedHosts"

    private init() {
        active.set(NSApp.isActive)
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            notifications.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.active.set(NSApp.isActive)
                    self.showNextPrompt()
                }
            })
        }
        notifications.append(center.addObserver(forName: NSApplication.willTerminateNotification,
                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        })
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkLiveness() }
        }
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkLiveness() }
        }
        monitor.start(queue: DispatchQueue(label: "tecolot.remote-network"))
    }

    /// Resolves SSH settings without blocking the app. This does not connect.
    func link(destination: String, completion: @escaping (Result<HostLink, Error>) -> Void) {
        guard !stopped else { completion(.failure(CocoaError(.userCancelled))); return }
        let task = configurationTask()
        Task { @MainActor in
            do {
                let prepared = try await task.value
                guard !stopped else {
                    prepared.askpass.close()
                    throw CocoaError(.userCancelled)
                }
                self.prepared = prepared
                let configuration = prepared.configuration
                let resolved = try await Task.detached {
                    try SSHConfiguration.resolve(destination: destination,
                        sshPath: configuration.sshPath, environment: configuration.environment)
                }.value
                guard !stopped else { throw CocoaError(.userCancelled) }
                let key = resolved.hostKey + " " + resolved.destination
                if let link = links[key] { completion(.success(link)); return }
                let link = registry.link(configuration: resolved, hostConfiguration: configuration,
                                         askpassServer: prepared.askpass)
                installCallbacks(on: link)
                links[key] = link
                completion(.success(link))
            } catch { completion(.failure(error)) }
        }
    }

    /// An observer keeps the connection open until it is removed.
    func observe(link: HostLink, observer id: UUID,
                 state: @escaping (HostLinkState) -> Void,
                 notice: @escaping (String?) -> Void,
                 window: @escaping () -> NSWindow? = { nil }) {
        guard !stopped else { return }
        let key = ObjectIdentifier(link)
        let retained = observers[key]?[id]?.retained ?? true
        let isNew = observers[key]?[id] == nil
        observers[key, default: [:]][id] = Observer(state: state, notice: notice, window: window,
                                                   retained: retained)
        state(displayState(for: link))
        notice(notices[key]?.values.first)
        if isNew && retained { link.retain() }
        showNextPrompt()
    }

    func removeObserver(link: HostLink, observer id: UUID) {
        let key = ObjectIdentifier(link)
        if let observer = observers[key]?.removeValue(forKey: id), observer.retained { link.release() }
        if observers[key]?.isEmpty == true {
            observers.removeValue(forKey: key)
            cancelPrompts(for: link)
        }
    }

    func checkLiveness() {
        guard !stopped else { return }
        for link in links.values { link.checkLiveness() }
    }

    func shutdown() {
        guard !stopped else { return }
        stopped = true
        monitor.cancel()
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        notifications.removeAll()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        let pending = prompts
        prompts.removeAll()
        for item in pending { answer(item, accepted: false, text: nil) }
        dismissCurrentPrompt(cancel: true)
        registry.stopAll()
        prepared?.askpass.close()
        observers.removeAll()
        notices.removeAll()
        links.removeAll()
    }

    private func configurationTask() -> Task<Prepared, Error> {
        if let setup { return setup }
        let bundle = Bundle.main
        let helper = bundle.url(forAuxiliaryExecutable: "tecolot-sessiond")
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let bundleID = bundle.bundleIdentifier ?? "com.tirania.Tecolot"
        let task = Task.detached { try Self.prepare(helper: helper, version: version, build: build, bundleID: bundleID) }
        setup = task
        return task
    }

    nonisolated private static func prepare(helper: URL?, version: String, build: String,
                                           bundleID: String) throws -> Prepared {
        guard let helper else { throw PersistentSessionError.helperMissing }
        try RemoteBootstrap.validateComponent(build)
        let manager = FileManager.default
        let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true)
        let cache = support.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Runtime", isDirectory: true)
            .appendingPathComponent(build, isDirectory: true)
        try manager.createDirectory(at: cache, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let cachedHelper = cache.appendingPathComponent("tecolot-sessiond")
        let temporary = cache.appendingPathComponent(".helper-\(UUID().uuidString)")
        try manager.copyItem(at: helper, to: temporary)
        defer { try? manager.removeItem(at: temporary) }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporary.path)
        if manager.fileExists(atPath: cachedHelper.path) {
            _ = try manager.replaceItemAt(cachedHelper, withItemAt: temporary)
        } else { try manager.moveItem(at: temporary, to: cachedHelper) }
        let source = try LocalHelperSource(executable: cachedHelper, version: version)
        let runtime = RuntimeDirectory.defaultLocation()
        try RuntimeDirectory.prepare(runtime)
        let environment = ProcessInfo.processInfo.environment
        let base = environment["TECOLOT_REMOTE_BASE_DIRECTORY"].flatMap { $0.isEmpty ? nil : $0 } ?? ".tecolot"
        let remoteRuntime = environment["TECOLOT_REMOTE_RUNTIME_DIRECTORY"].flatMap { $0.isEmpty ? nil : $0 }
        let layout = try RemoteLayout(baseDirectory: base, runtimeDirectory: remoteRuntime)
        var configuration = HostLinkConfiguration(appRuntimeDirectory: runtime, remoteLayout: layout,
                                                  helperSource: source, build: version)
        _ = try AskpassServer.writeWrapper(helperPath: cachedHelper.path, in: runtime)
        configuration.askpassHelperPath = cachedHelper.path
        return Prepared(configuration: configuration, askpass: try AskpassServer(runtimeDirectory: runtime))
    }

    private func installCallbacks(on link: HostLink) {
        let activity = active
        link.isAppActive = { activity.get() }
        link.onStateChange = { [weak self, weak link] state in
            Task { @MainActor [weak self, weak link] in
                guard let self, let link else { return }
                self.publish(state: state, link: link)
            }
        }
        link.askpass = { [weak self, weak link] request, reply in
            Task { @MainActor [weak self, weak link] in
                guard let self, let link, !self.stopped else { reply(nil); return }
                if request.style == .notice {
                    let text = "Touch your security key for \(request.host)"
                    let key = ObjectIdentifier(link)
                    self.notices[key, default: [:]][request.id] = text
                    self.publishNotice(link: link)
                } else {
                    self.prompts.append(PendingPrompt(link: link, prompt: .askpass(request, reply)))
                    self.showNextPrompt()
                }
            }
        }
        link.onAskpassDismiss = { [weak self, weak link] id in
            Task { @MainActor [weak self, weak link] in
                guard let self, let link else { return }
                self.notices[ObjectIdentifier(link)]?.removeValue(forKey: id)
                self.publishNotice(link: link)
                self.prompts.removeAll { $0.prompt.id == id }
                if self.currentPrompt?.prompt.id == id { self.dismissCurrentPrompt(cancel: false) }
            }
        }
        link.confirmInstall = { [weak self, weak link] host, bytes, reply in
            Task { @MainActor [weak self, weak link] in
                guard let self, let link, !self.stopped else { reply(false); return }
                if self.approvedHosts.contains(host) { reply(true); return }
                self.prompts.append(PendingPrompt(link: link, prompt: .install(UUID(), host, bytes, reply)))
                self.showNextPrompt()
            }
        }
    }

    private var approvedHosts: Set<String> { Set(UserDefaults.standard.stringArray(forKey: approvalKey) ?? []) }

    private func displayState(for link: HostLink) -> HostLinkState {
        link.state
    }

    private func publish(state: HostLinkState, link: HostLink) {
        let callbacks = observers[ObjectIdentifier(link)]?.values.map(\.state) ?? []
        for callback in callbacks { callback(state) }
    }

    private func publishNotice(link: HostLink) {
        let key = ObjectIdentifier(link)
        let text = notices[key]?.values.first
        let callbacks = observers[key]?.values.map(\.notice) ?? []
        for callback in callbacks { callback(text) }
    }

    private func window(for link: HostLink) -> NSWindow? {
        let windows = observers[ObjectIdentifier(link)]?.values.compactMap { $0.window() } ?? []
        if let key = NSApp.keyWindow, windows.contains(where: { $0 === key }), key.attachedSheet == nil { return key }
        let matching = NSApp.orderedWindows.first { candidate in
            candidate.isVisible && candidate.attachedSheet == nil && windows.contains { $0 === candidate }
        }
        if let matching { return matching }
        return NSApp.keyWindow.flatMap { $0.attachedSheet == nil ? $0 : nil }
    }

    private func showNextPrompt() {
        guard !stopped, currentPrompt == nil else { return }
        guard !prompts.isEmpty else { return }
        let pending = prompts.removeFirst()
        let window = window(for: pending.link)
        let alert = NSAlert()
        var field: NSTextField?
        switch pending.prompt {
        case .askpass(let request, _):
            alert.messageText = "Sign in to \(request.host)"
            alert.informativeText = [request.stderr, request.prompt].filter { !$0.isEmpty }.joined(separator: "\n\n")
            switch request.style {
            case .secret:
                field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
            case .text:
                field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
            case .hostKey:
                alert.messageText = "Confirm the host key for \(request.host)"
            case .notice: break
            }
            alert.addButton(withTitle: request.style == .hostKey ? "Connect" : "Enter")
        case .install(_, let host, let bytes, _):
            alert.messageText = "Install the Tecolot helper on \(host)?"
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            let path = ProcessInfo.processInfo.environment["TECOLOT_REMOTE_BASE_DIRECTORY"]
                .flatMap { $0.isEmpty ? nil : $0 } ?? ".tecolot"
            alert.informativeText = "Tecolot will install its helper (\(size)) in ~/\(path) on \(host). The helper runs your shell, so that the session continues when you disconnect."
            alert.addButton(withTitle: "Install")
        }
        alert.addButton(withTitle: "Cancel")
        if let field {
            field.placeholderString = "Response"
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
        }
        currentPrompt = pending
        currentAlert = alert
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self, weak field] response in
            guard let self, self.currentPrompt?.prompt.id == pending.prompt.id else { return }
            self.currentPrompt = nil
            self.currentAlert = nil
            let text = field?.stringValue
            field?.stringValue = ""
            self.answer(pending, accepted: response == .alertFirstButtonReturn, text: text)
            self.showNextPrompt()
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(alert.runModal()) }
    }

    private func answer(_ pending: PendingPrompt, accepted: Bool, text: String?) {
        switch pending.prompt {
        case .askpass(let request, let reply): reply(accepted ? (request.style == .hostKey ? "yes" : text ?? "") : nil)
        case .install(_, let host, _, let reply):
            if accepted {
                var approved = approvedHosts
                approved.insert(host)
                UserDefaults.standard.set(approved.sorted(), forKey: approvalKey)
            }
            reply(accepted)
        }
    }

    private func cancelPrompts(for link: HostLink) {
        let cancelled = prompts.filter { $0.link === link }
        prompts.removeAll { $0.link === link }
        for pending in cancelled { answer(pending, accepted: false, text: nil) }
        if currentPrompt?.link === link { dismissCurrentPrompt(cancel: true) }
    }

    private func dismissCurrentPrompt(cancel: Bool) {
        let pending = currentPrompt
        let alert = currentAlert
        currentPrompt = nil
        currentAlert = nil
        if let alert {
            if let parent = alert.window.sheetParent { parent.endSheet(alert.window) }
            else if NSApp.modalWindow === alert.window { NSApp.abortModal() }
            alert.window.orderOut(nil)
            if let field = alert.accessoryView as? NSTextField { field.stringValue = "" }
        }
        if cancel, let pending { answer(pending, accepted: false, text: nil) }
        showNextPrompt()
    }
}

/// SSH callbacks read this value without access to AppKit.
nonisolated private final class RemoteAppActivity: Sendable {
    private let value = Mutex(false)
    func set(_ active: Bool) { value.withLock { $0 = active } }
    func get() -> Bool { value.withLock { $0 } }
}
