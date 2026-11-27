import AppKit
import Observation
import SwiftUI

/// Coordinates single-row key capture inside Settings → Shortcuts.
@MainActor
@Observable
final class ShortcutRecorderController {
    private(set) var recordingActionID: AppShortcutID?
    private(set) var liveModifiers: ShortcutModifiers = []
    private(set) var validationMessage: String?

    @ObservationIgnored private var eventMonitor: Any?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?
    @ObservationIgnored private var firstResponderObservation: NSKeyValueObservation?
    @ObservationIgnored private weak var observedWindow: NSWindow?
    @ObservationIgnored private weak var initialFirstResponder: NSResponder?
    @ObservationIgnored private weak var activeRecorderView: NSView?
    @ObservationIgnored private weak var activeStore: AppShortcutStore?

    func toggleRecording(for id: AppShortcutID, store: AppShortcutStore) {
        if recordingActionID == id {
            stopRecording()
        } else {
            beginRecording(for: id, store: store)
        }
    }

    func beginRecording(for id: AppShortcutID, store: AppShortcutStore, in window: NSWindow? = nil) {
        stopRecording()
        activeStore = store
        recordingActionID = id
        liveModifiers = []
        validationMessage = nil
        store.isRecording = true

        let targetWindow = window ?? activeRecorderView?.window ?? NSApp.keyWindow
        resignTextFocusIfNeeded(in: targetWindow)
        observeFirstResponder(in: targetWindow)

        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else {
                return event
            }
            return self.handleEvent(event)
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stopRecording()
            }
        }
    }

    func setActiveRecorderView(_ view: NSView?) {
        activeRecorderView = view
        guard recordingActionID != nil, let viewWindow = view?.window, viewWindow !== observedWindow else {
            return
        }
        resignTextFocusIfNeeded(in: viewWindow)
        observeFirstResponder(in: viewWindow)
    }

    func clearActiveRecorderView(ifMatches view: NSView) {
        if activeRecorderView === view {
            activeRecorderView = nil
        }
    }

    func stopRecording(clearMessage: Bool = false) {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        firstResponderObservation?.invalidate()
        firstResponderObservation = nil
        observedWindow = nil
        initialFirstResponder = nil
        activeRecorderView = nil
        recordingActionID = nil
        liveModifiers = []
        activeStore?.isRecording = false
        if clearMessage {
            validationMessage = nil
        }
    }

    func clearValidationMessage() {
        validationMessage = nil
    }

    /// Exposed for unit testing synthetic NSEvent capture.
    @discardableResult
    func handleEvent(_ event: NSEvent) -> NSEvent? {
        guard let actionID = recordingActionID, let store = activeStore else {
            return event
        }

        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if !isPointInsideActiveRecorder(event) {
                stopRecording()
            }
            return event

        case .flagsChanged:
            liveModifiers = ShortcutModifiers(nsModifierFlags: event.modifierFlags)
            return event

        case .keyDown:
            break

        default:
            return event
        }

        let mods = ShortcutModifiers(nsModifierFlags: event.modifierFlags)

        // Bare Escape cancels recording without closing the Settings window.
        if event.keyCode == 53, mods.isEmpty {
            stopRecording(clearMessage: true)
            return nil
        }

        // Bare Delete / Forward Delete clears the shortcut.
        if (event.keyCode == 51 || event.keyCode == 117), mods.isEmpty {
            store.setShortcut(nil, for: actionID)
            stopRecording(clearMessage: true)
            return nil
        }

        switch KeyCombo.capture(from: event) {
        case .valid(let combo):
            store.setShortcut(combo, for: actionID)
            stopRecording(clearMessage: true)
        case .rejected(let message):
            validationMessage = message
        }
        return nil
    }

    private func resignTextFocusIfNeeded(in window: NSWindow?) {
        guard let window, window.firstResponder is NSText else {
            return
        }
        window.makeFirstResponder(nil)
    }

    private func observeFirstResponder(in window: NSWindow?) {
        firstResponderObservation?.invalidate()
        firstResponderObservation = nil
        observedWindow = window
        initialFirstResponder = window?.firstResponder
        guard let window else {
            return
        }
        firstResponderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.handleFirstResponderDidChange()
            }
        }
    }

    private func handleFirstResponderDidChange() {
        guard recordingActionID != nil, let window = observedWindow else {
            return
        }
        if window.firstResponder !== initialFirstResponder {
            stopRecording()
        }
    }

    private func isPointInsideActiveRecorder(_ event: NSEvent) -> Bool {
        guard let view = activeRecorderView,
              let viewWindow = view.window,
              event.window === viewWindow
        else {
            return false
        }
        let point = view.convert(event.locationInWindow, from: nil)
        return view.bounds.contains(point)
    }
}

/// Settings → Shortcuts page: filterable list of SwiftUI command shortcuts with
/// click-to-record capture, reverse key lookup, conflict indicators, and reset.
struct ShortcutsSettingsView: View {
    let store: AppShortcutStore

    @State private var filterText = ""
    @State private var recorder = ShortcutRecorderController()
    @State private var filteredSections: [AppShortcutStore.FilteredSection] = []
    @State private var showingResetConfirmation = false
    @FocusState private var isFilterFocused: Bool

    @MainActor
    init(store: AppShortcutStore? = nil) {
        self.store = store ?? .shared
    }

    var body: some View {
        VStack(spacing: 0) {
            ShortcutsFilterHeader(
                filterText: $filterText,
                isFilterFocused: $isFilterFocused,
                validationMessage: recorder.validationMessage,
                onDismissMessage: {
                    recorder.clearValidationMessage()
                }
            )
            Divider()
            ShortcutsListContent(
                sections: filteredSections,
                store: store,
                recordingActionID: recorder.recordingActionID,
                liveModifiers: recorder.liveModifiers,
                onToggleRecording: { id in
                    if recorder.recordingActionID != id {
                        isFilterFocused = false
                    }
                    recorder.toggleRecording(for: id, store: store)
                },
                onClear: { id in
                    store.setShortcut(nil, for: id)
                    recorder.stopRecording(clearMessage: true)
                },
                onReset: { id in
                    store.reset(id)
                    if recorder.recordingActionID == id {
                        recorder.stopRecording(clearMessage: true)
                    }
                },
                onResolveConflicts: { id in
                    store.resolveConflicts(keeping: id)
                },
                onAttachRecorderView: { view in
                    recorder.setActiveRecorderView(view)
                },
                onDetachRecorderView: { view in
                    recorder.clearActiveRecorderView(ifMatches: view)
                }
            )
        }
        .navigationTitle("Shortcuts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Reset All…", role: .destructive) {
                        recorder.stopRecording(clearMessage: true)
                        showingResetConfirmation = true
                    }
                    .disabled(store.customizedCount == 0)
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .menuIndicator(.hidden)
                .help("Shortcut actions")
            }
        }
        .onAppear {
            recomputeSections()
        }
        .onDisappear {
            recorder.stopRecording(clearMessage: true)
        }
        .onChange(of: isFilterFocused) {
            if isFilterFocused {
                recorder.stopRecording()
            }
        }
        .onChange(of: filterText) {
            recomputeSections()
        }
        .onChange(of: store.effectiveShortcuts) {
            recomputeSections()
        }
        .confirmationDialog(
            "Reset all shortcuts to defaults?",
            isPresented: $showingResetConfirmation
        ) {
            Button("Reset All", role: .destructive) {
                store.resetAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All customized menu and command shortcuts will return to their built-in defaults.")
        }
    }

    private func recomputeSections() {
        filteredSections = store.filteredSections(matching: filterText)
    }
}

private struct ShortcutsFilterHeader: View {
    @Binding var filterText: String
    var isFilterFocused: FocusState<Bool>.Binding
    let validationMessage: String?
    let onDismissMessage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Filter Shortcuts…", text: $filterText)
                    .textFieldStyle(.plain)
                    .focused(isFilterFocused)
                    .accessibilityLabel("Filter Shortcuts")
                if !filterText.isEmpty {
                    Button {
                        filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear filter")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text("Click a shortcut to record a new key combination. Press Escape to cancel or Delete to clear. Search for a key, such as cmd+k, to see everything bound to it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let validationMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.primary)
                    Spacer()
                    Button {
                        onDismissMessage()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss message")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

private struct ShortcutsListContent: View {
    let sections: [AppShortcutStore.FilteredSection]
    let store: AppShortcutStore
    let recordingActionID: AppShortcutID?
    let liveModifiers: ShortcutModifiers
    let onToggleRecording: (AppShortcutID) -> Void
    let onClear: (AppShortcutID) -> Void
    let onReset: (AppShortcutID) -> Void
    let onResolveConflicts: (AppShortcutID) -> Void
    let onAttachRecorderView: (NSView) -> Void
    let onDetachRecorderView: (NSView) -> Void

    var body: some View {
        if sections.isEmpty {
            ContentUnavailableView {
                Label("No Matching Shortcuts", systemImage: "command")
            } description: {
                Text("Try searching by command name or key combination such as cmd+k.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Form {
                ForEach(sections) { section in
                    Section(section.category.title) {
                        ForEach(section.items) { descriptor in
                            ShortcutActionRow(
                                descriptor: descriptor,
                                activeShortcut: store.shortcut(for: descriptor.id),
                                isCustomized: store.isCustomized(descriptor.id),
                                conflictTitles: store.conflicts(for: descriptor.id).map(\.descriptor.title),
                                isRecording: recordingActionID == descriptor.id,
                                liveModifiers: recordingActionID == descriptor.id ? liveModifiers : [],
                                onToggleRecording: {
                                    onToggleRecording(descriptor.id)
                                },
                                onClear: {
                                    onClear(descriptor.id)
                                },
                                onReset: {
                                    onReset(descriptor.id)
                                },
                                onResolveConflicts: {
                                    onResolveConflicts(descriptor.id)
                                },
                                onAttachRecorderView: onAttachRecorderView,
                                onDetachRecorderView: onDetachRecorderView
                            )
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

private struct ShortcutActionRow: View {
    let descriptor: AppShortcutDescriptor
    let activeShortcut: KeyCombo?
    let isCustomized: Bool
    let conflictTitles: [String]
    let isRecording: Bool
    let liveModifiers: ShortcutModifiers
    let onToggleRecording: () -> Void
    let onClear: () -> Void
    let onReset: () -> Void
    let onResolveConflicts: () -> Void
    let onAttachRecorderView: (NSView) -> Void
    let onDetachRecorderView: (NSView) -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(descriptor.title)
                if !conflictTitles.isEmpty {
                    HStack(spacing: 8) {
                        Label(
                            "Conflicts with \(conflictTitles.formatted(.list(type: .and)))",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)

                        Button(conflictTitles.count == 1 ? "Unbind Other" : "Unbind Others", action: onResolveConflicts)
                            .buttonStyle(.link)
                            .font(.caption)
                            .help("Clear this shortcut from \(conflictTitles.formatted(.list(type: .and))) so only \(descriptor.title) uses it.")
                    }
                }
            }

            Spacer(minLength: 8)

            if isCustomized && !isRecording {
                Button(action: onReset) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(resetHelpText)
                .accessibilityLabel("Reset \(descriptor.title) to default")
            }

            ShortcutRecorderButton(
                actionTitle: descriptor.title,
                activeShortcut: activeShortcut,
                isRecording: isRecording,
                liveModifiers: liveModifiers,
                hasConflict: !conflictTitles.isEmpty,
                onToggleRecording: onToggleRecording,
                onClear: onClear,
                onAttachRecorderView: onAttachRecorderView,
                onDetachRecorderView: onDetachRecorderView
            )
        }
    }

    private var resetHelpText: String {
        if let defaultShortcut = descriptor.defaultShortcut {
            return "Reset to \(defaultShortcut.displayString)"
        }
        return "Reset to default (unbound)"
    }
}

private struct ShortcutRecorderButton: View {
    let actionTitle: String
    let activeShortcut: KeyCombo?
    let isRecording: Bool
    let liveModifiers: ShortcutModifiers
    let hasConflict: Bool
    let onToggleRecording: () -> Void
    let onClear: () -> Void
    let onAttachRecorderView: (NSView) -> Void
    let onDetachRecorderView: (NSView) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onToggleRecording) {
                Text(buttonLabel)
                    .font(.system(size: 12.5, weight: isRecording || activeShortcut != nil ? .medium : .regular))
                    .foregroundStyle(labelColor)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(buttonHelp)
            .accessibilityLabel(accessibilityTitle)
            .accessibilityValue(activeShortcut?.accessibilityLabel ?? "None")

            if isRecording && activeShortcut != nil {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear shortcut")
                .accessibilityLabel("Clear shortcut for \(actionTitle)")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 152, height: 26)
        .background(backgroundFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .background {
            if isRecording {
                RecorderHitRegionAnchor(
                    onAttach: onAttachRecorderView,
                    onDetach: onDetachRecorderView
                )
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isRecording || hasConflict ? 1.5 : 0.5)
        )
    }

    private var buttonLabel: String {
        if isRecording {
            if liveModifiers.isEmpty {
                return "Type shortcut…"
            }
            return "\(liveModifiers.displayString)…"
        }
        return activeShortcut?.displayString ?? "Record Shortcut"
    }

    private var labelColor: Color {
        if isRecording {
            return .accentColor
        }
        return activeShortcut == nil ? .secondary : .primary
    }

    private var backgroundFill: AnyShapeStyle {
        if isRecording {
            return AnyShapeStyle(Color.accentColor.opacity(0.14))
        }
        if hasConflict {
            return AnyShapeStyle(Color.orange.opacity(0.12))
        }
        return AnyShapeStyle(.quaternary.opacity(0.65))
    }

    private var borderColor: Color {
        if isRecording {
            return .accentColor
        }
        if hasConflict {
            return .orange.opacity(0.7)
        }
        return Color(nsColor: .separatorColor).opacity(0.4)
    }

    private var buttonHelp: String {
        if isRecording {
            return "Press a key combination, Delete to clear, or Escape to cancel."
        }
        return activeShortcut == nil ? "Click to record a shortcut." : "Click to record a different shortcut."
    }

    private var accessibilityTitle: String {
        activeShortcut == nil
            ? "Record a shortcut for \(actionTitle)"
            : "Change the shortcut for \(actionTitle)"
    }
}

private struct RecorderHitRegionAnchor: NSViewRepresentable {
    let onAttach: (NSView) -> Void
    let onDetach: (NSView) -> Void

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.onMoveToWindow = onAttach
        view.onDetach = onDetach
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.onMoveToWindow = onAttach
        nsView.onDetach = onDetach
        onAttach(nsView)
    }

    static func dismantleNSView(_ nsView: AnchorView, coordinator: ()) {
        nsView.onMoveToWindow = nil
        nsView.onDetach?(nsView)
        nsView.onDetach = nil
    }

    final class AnchorView: NSView {
        var onMoveToWindow: ((NSView) -> Void)?
        var onDetach: ((NSView) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                onMoveToWindow?(self)
            }
        }
    }
}

#Preview("Shortcuts") {
    ShortcutsSettingsView(store: AppShortcutStore(defaults: SettingsPreviewData.defaults))
        .frame(width: 620, height: 560)
}
