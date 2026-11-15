import AppKit
import Observation

/// A tab keeps its pane host alive while its group is in the background.
@Observable
@MainActor
final class TerminalTab: Identifiable {
    private static let generatedTitlePreference = DefaultsValueObserver(
        defaults: .standard, keys: [TabStripPreferences.preferGeneratedTitlesKey]
    ) {
        $0.object(forKey: TabStripPreferences.preferGeneratedTitlesKey) as? Bool ?? TabStripPreferences.preferGeneratedTitlesDefault
    }
    @ObservationIgnored private let titlePreference: DefaultsValueObserver<Bool>
    private enum WorkspaceState {
        case dormant(LaunchSpec)
        case live(TerminalPaneWorkspace)
    }

    @ObservationIgnored weak var group: TerminalTabGroup?
    let id: UUID
    private var workspaceState: WorkspaceState
    var loadedWorkspace: TerminalPaneWorkspace? {
        guard case .live(let workspace) = workspaceState else {
            return nil
        }
        return workspace
    }
    /// Access only for a tab that is being shown or explicitly started.
    var workspace: TerminalPaneWorkspace {
        switch workspaceState {
        case .live(let workspace):
            return workspace
        case .dormant(let spec):
            let workspace = TerminalPaneWorkspace(spec: spec, startsProcesses: startsProcesses)
            workspaceState = .live(workspace)
            workspace.owningTab = self
            return workspace
        }
    }
    var savedSpec: LaunchSpec? {
        guard case .dormant(let spec) = workspaceState else {
            return nil
        }
        return spec
    }
    @ObservationIgnored private let startsProcesses: Bool
    var isDormant: Bool {
        loadedWorkspace == nil
    }
    var customName: String?
    var isMuted = false
    var status: TabStatus {
        guard let workspace = loadedWorkspace else {
            return .none
        }
        let panes = workspace.controllers.map(\.programStatus)
        return TabStatus.reduce(
            panes.flatMap(\.activityRecords),
            quiet: panes.contains(where: \.quiet),
            notified: panes.contains(where: \.notified),
            muted: isMuted,
            disabledStates: ProgramActivitySettings.shared.value.disabledStates
        )
    }
    @ObservationIgnored private var retainedHost: TerminalPaneHostView?

    init(id: UUID = UUID(), workspace: TerminalPaneWorkspace, titlePreference: DefaultsValueObserver<Bool>? = nil) {
        self.titlePreference = titlePreference ?? Self.generatedTitlePreference
        self.id = id
        workspaceState = .live(workspace)
        startsProcesses = true
        workspace.owningTab = self
    }

    convenience init(spec: LaunchSpec = LaunchSpec(), startsProcesses: Bool = true) {
        self.init(
            id: spec.restoredTab?.tab.id ?? UUID(),
            workspace: TerminalPaneWorkspace(spec: spec, startsProcesses: startsProcesses)
        )
        customName = spec.restoredTab?.tab.name
    }

    /// A saved description allocates no controller, terminal, shell or connection.
    init(dormant spec: LaunchSpec, startsProcesses: Bool = true) {
        titlePreference = Self.generatedTitlePreference
        id = spec.restoredTab?.tab.id ?? UUID()
        workspaceState = .dormant(spec)
        self.startsProcesses = startsProcesses
        customName = spec.restoredTab?.tab.name
    }

    func start() {
        _ = workspace
        // The host adopts the tree and its divider positions before building views.
    }

    /// The cached "Prefer generated tab titles" value. Window chrome tracks
    /// it, because the cache updates after the tab bar's own preference
    /// refresh has already read the old title.
    var prefersGeneratedTitle: Bool {
        titlePreference.value
    }

    var title: String {
        let parts = titleParts
        return parts.primary + (parts.directory.map {
            " " + $0
        } ?? "")
    }

    /// Kept separate so M4's title ticker can replace the text without moving
    /// the icon, status slot, or the title's clipping/fade surface.
    var titleParts: (primary: String, directory: String?) {
        if let customName {
            return (customName, nil)
        }
        guard let pane = loadedWorkspace?.focusedController?.panePresentation else {
            return (savedSpec?.restoredTab?.tab.root.panes.first?.title ?? "Terminal", nil)
        }
        guard prefersGeneratedTitle else {
            return (pane.title, nil)
        }
        let entry = ProgramGlyphCatalog.entry(forExecutablePath: status.app ?? pane.executablePath)
        let directory = pane.directory.map {
            ($0 as NSString).abbreviatingWithTildeInPath
        }
        return (entry.displayName, directory)
    }

    var hostView: TerminalPaneHostView {
        if let retainedHost {
            return retainedHost
        }
        let host = TerminalPaneHostView(workspace: workspace)
        retainedHost = host
        host.synchronize(revision: workspace.revision)
        return host
    }
}
