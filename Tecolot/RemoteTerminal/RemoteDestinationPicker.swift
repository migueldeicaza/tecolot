//
//  RemoteDestinationPicker.swift
//  Tecolot
//
//  The Connect to Host panel: one field that filters the recent hosts and
//  the Host aliases of the SSH configuration. The arrow keys or the pointer
//  choose a row, Return connects, Tab copies the row to the field.
//

import AppKit
import SwiftUI
import TecolotSessionClient

/// The rows of the Connect to Host panel and the row that Return uses.
@MainActor
@Observable
final class RemoteDestinationPickerModel {
    struct Entry: Identifiable, Equatable {
        enum Source: Equatable {
            /// The text in the field, when no row has that text.
            case typed
            case recent
            case alias
        }

        let destination: String
        let source: Source

        var id: String {
            "\(source)\u{0}\(destination)"
        }
    }

    var text = "" {
        didSet {
            guard text != oldValue else {
                return
            }
            rebuild()
            let typed = typed
            // The row with the same text, else a known host that differs
            // only in case, else the first row. The row for the text stays
            // above the known host: user names depend on case.
            selection = entries.firstIndex {
                $0.source != .typed && $0.destination == typed
            } ?? entries.firstIndex {
                $0.source != .typed && $0.destination.caseInsensitiveCompare(typed) == .orderedSame
            } ?? 0
            rowsChanged()
        }
    }

    /// The typed text first if no row has it, then the recent hosts, then
    /// the aliases. In each group, the names that start with the text are
    /// first. Changes only with the text and the recent hosts.
    private(set) var entries: [Entry] = []
    private(set) var selection = 0
    /// Changes when the keyboard moves the selection: the list then scrolls
    /// to the selected row. The pointer does not scroll the list.
    private(set) var revealCount = 0
    /// The pointer took the focus from the field: the view gives it back.
    private(set) var fieldFocusCount = 0
    private(set) var recents: [String]
    /// All the aliases. The list hides those that are also recent hosts.
    let aliases: [String]
    @ObservationIgnored private let removeRecent: (String) -> Void
    /// True after the pointer moved, until a row uses the movement. As in
    /// the group menu, only a pointer that moves takes the selection: a row
    /// that shows or scrolls under a pointer at rest does not.
    @ObservationIgnored private var pointerMovedSinceRowsChanged = false

    init(recents: [String], aliases: [String], removeRecent: @escaping (String) -> Void = { _ in }) {
        self.recents = recents
        self.aliases = aliases
        self.removeRecent = removeRecent
        rebuild()
    }

    /// The text in the field without the spaces around it.
    var typed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rebuild() {
        let typed = typed
        func matches(_ names: [String], _ source: Entry.Source) -> [Entry] {
            guard !typed.isEmpty else {
                return names.map {
                    Entry(destination: $0, source: source)
                }
            }
            var leading: [Entry] = []
            var inside: [Entry] = []
            for name in names {
                guard let range = name.localizedStandardRange(of: typed) else {
                    continue
                }
                let entry = Entry(destination: name, source: source)
                if range.lowerBound == name.startIndex {
                    leading.append(entry)
                } else {
                    inside.append(entry)
                }
            }
            return leading + inside
        }
        let recent = Set(recents)
        let known = matches(recents, .recent) + matches(aliases.filter {
            !recent.contains($0)
        }, .alias)
        let isKnown = known.contains {
            $0.destination == typed
        }
        entries = typed.isEmpty || isKnown ? known : [Entry(destination: typed, source: .typed)] + known
    }

    /// The rows changed or the keyboard chose a row: the pointer must move
    /// again to take the selection, and the list shows the selected row.
    private func rowsChanged() {
        pointerMovedSinceRowsChanged = false
        revealCount += 1
    }

    var selectedEntry: Entry? {
        entries.indices.contains(selection) ? entries[selection] : nil
    }

    /// The destination that Return connects to. Nil for no row and for
    /// text that is not an SSH destination.
    var chosen: String? {
        guard let destination = selectedEntry?.destination, Self.isValid(destination) else {
            return nil
        }
        return destination
    }

    /// True if the field has text that SSH cannot use.
    var showsInvalidText: Bool {
        !typed.isEmpty && selectedEntry?.source == .typed && !Self.isValid(typed)
    }

    static func isValid(_ destination: String) -> Bool {
        (try? SSHConfiguration.validate(destination)) != nil
    }

    func moveSelection(_ delta: Int) {
        guard !entries.isEmpty else {
            return
        }
        selection = max(0, min(entries.count - 1, selection + delta))
        rowsChanged()
    }

    func focusField() {
        fieldFocusCount += 1
    }

    /// The window got a pointer movement.
    func pointerMoved() {
        pointerMovedSinceRowsChanged = true
    }

    /// The pointer is over a row. Does not scroll the list: the row is
    /// under the pointer.
    func hover(_ index: Int) {
        guard pointerMovedSinceRowsChanged, entries.indices.contains(index) else {
            return
        }
        pointerMovedSinceRowsChanged = false
        if selection != index {
            selection = index
        }
    }

    func select(_ index: Int) {
        if entries.indices.contains(index) {
            selection = index
        }
    }

    /// Copies the selected row to the field, to change it there (for
    /// example to add a user name). Returns false if the field has the row.
    @discardableResult
    func completeFromSelection() -> Bool {
        guard let entry = selectedEntry, entry.source != .typed, entry.destination != text else {
            return false
        }
        text = entry.destination
        return true
    }

    func forget(_ entry: Entry) {
        guard entry.source == .recent else {
            return
        }
        removeRecent(entry.destination)
        recents.removeAll {
            $0 == entry.destination
        }
        rebuild()
        selection = max(0, min(entries.count - 1, selection))
        pointerMovedSinceRowsChanged = false
    }
}

struct RemoteDestinationPickerView: View {
    /// The size of the window.
    static let size = CGSize(width: 540, height: 420)

    @Bindable var model: RemoteDestinationPickerModel
    let finish: (String?) -> Void
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            field
            Divider()
            list
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PanelMaterial().ignoresSafeArea())
        .onAppear {
            fieldFocused = true
        }
        .onChange(of: model.fieldFocusCount) {
            fieldFocused = true
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "network")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Connect to Host")
                    .font(.headline)
                Text("Sessions on the host keep running when you disconnect.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("user@host or SSH Host alias", text: $model.text)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .autocorrectionDisabled()
                .focused($fieldFocused)
                .accessibilityLabel("SSH destination")
            if !model.text.isEmpty {
                Button {
                    model.text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(model.showsInvalidText ? Color.red.opacity(0.7) : Color.clear, lineWidth: 1)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var list: some View {
        let entries = model.entries
        if entries.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "server.rack")
                    .font(.system(size: 26))
                    .foregroundStyle(.tertiary)
                Text("No Recent Hosts")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Enter a destination such as user@host.\nHost aliases from ~/.ssh/config also show here.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            // The title is part of the first row of its
                            // section: the list scrolls to both.
                            VStack(alignment: .leading, spacing: 1) {
                                if let title = sectionTitle(entry, after: index > 0 ? entries[index - 1] : nil) {
                                    Text(title)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.top, index == 0 ? 2 : 10)
                                        .padding(.bottom, 3)
                                        .accessibilityAddTraits(.isHeader)
                                }
                                row(entry, index: index)
                            }
                            .id(entry.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: model.revealCount) {
                    if let entry = model.selectedEntry {
                        proxy.scrollTo(entry.id)
                    }
                }
            }
        }
    }

    private func sectionTitle(_ entry: RemoteDestinationPickerModel.Entry, after previous: RemoteDestinationPickerModel.Entry?) -> String? {
        guard entry.source != previous?.source else {
            return nil
        }
        switch entry.source {
        case .typed:
            return nil
        case .recent:
            return "Recent"
        case .alias:
            return "SSH Config"
        }
    }

    private func row(_ entry: RemoteDestinationPickerModel.Entry, index: Int) -> some View {
        let selected = model.selection == index
        let invalid = entry.source == .typed && !RemoteDestinationPickerModel.isValid(entry.destination)
        return HStack(spacing: 9) {
            Image(systemName: symbol(entry.source))
                .font(.system(size: 13))
                .frame(width: 18)
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
            Text(entry.source == .typed ? "Connect to “\(entry.destination)”" : entry.destination)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(invalid ? .secondary : .primary))
            Spacer(minLength: 8)
            if selected, !invalid {
                Text("↩")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(
            selected ? AnyShapeStyle(invalid ? Color.secondary.opacity(0.35) : Color.accentColor) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case .active = phase {
                model.hover(index)
            }
        }
        .onTapGesture {
            model.select(index)
            if let chosen = model.chosen {
                finish(chosen)
            }
        }
        .contextMenu {
            if entry.source == .recent {
                Button("Remove from Recent Hosts") {
                    model.forget(entry)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func symbol(_ source: RemoteDestinationPickerModel.Entry.Source) -> String {
        switch source {
        case .typed:
            return "arrow.right.circle"
        case .recent:
            return "clock.arrow.circlepath"
        case .alias:
            return "server.rack"
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.showsInvalidText {
                Label("Enter a host name, user@host or a Host alias, without spaces and not starting with a hyphen.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else {
                Text("↑↓ Choose   ⇥ Edit   ↩ Connect")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 8)
            Button("Cancel") {
                finish(nil)
            }
            Button("Connect") {
                if let chosen = model.chosen {
                    finish(chosen)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.chosen == nil)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }
}

/// The window material under the panel content.
private struct PanelMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// The window of the Connect to Host panel. It handles the keys before the
/// field editor does: the field keeps the focus while the arrow keys move
/// the selection in the list.
final class RemoteDestinationWindow: NSPanel {
    let model: RemoteDestinationPickerModel
    /// Runs one time, with the destination or nil for Cancel.
    var onFinish: ((String?) -> Void)?
    private var finished = false

    override var canBecomeKey: Bool {
        true
    }

    init(model: RemoteDestinationPickerModel) {
        self.model = model
        super.init(
            contentRect: NSRect(origin: .zero, size: RemoteDestinationPickerView.size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "Connect to Host"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        // The panel runs modally: a hidden panel would block the app.
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        let host = NSHostingView(rootView: RemoteDestinationPickerView(model: model) { [weak self] in
            self?.finish($0)
        })
        // The hosting view is not the content view: as the content view it
        // makes the window taller by the title bar height in each layout.
        host.sizingOptions = []
        host.safeAreaRegions = []
        let container = NSView(frame: NSRect(origin: .zero, size: RemoteDestinationPickerView.size))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        contentView = container
        // The content also covers the hidden title bar.
        setFrame(NSRect(origin: .zero, size: RemoteDestinationPickerView.size), display: false)
    }

    /// Puts the panel in the upper part of `parent`, else in the screen center.
    func place(over parent: NSWindow?) {
        guard let parent, parent.isVisible else {
            center()
            return
        }
        var origin = NSPoint(
            x: parent.frame.midX - frame.width / 2,
            y: parent.frame.maxY - frame.height - max(40, parent.frame.height * 0.12)
        )
        if let visible = parent.screen?.visibleFrame {
            origin.x = max(visible.minX, min(visible.maxX - frame.width, origin.x))
            origin.y = max(visible.minY, min(visible.maxY - frame.height, origin.y))
        }
        setFrameOrigin(origin)
    }

    /// The view can ask for the focus before the window is the key window,
    /// and then the field does not get it.
    override func becomeKey() {
        super.becomeKey()
        // After SwiftUI knows that the window is the key window.
        DispatchQueue.main.async { [weak self] in
            if let self, self.firstResponder === self {
                self.model.focusField()
            }
        }
    }

    /// Ends the panel. Only the first call does something: a double click
    /// on a row, or a key after a click, must not end it again.
    func finish(_ destination: String?) {
        guard !finished else {
            return
        }
        finished = true
        onFinish?(destination)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .mouseMoved {
            model.pointerMoved()
        }
        // The window itself has the focus after a click that took it from
        // the field: the keys are then still those of the panel.
        if event.type == .keyDown, handleKey(event, inField: firstResponder is NSTextView || firstResponder === self) {
            return
        }
        super.sendEvent(event)
        if event.type == .leftMouseUp, firstResponder === self {
            model.focusField()
        }
    }

    /// Returns true if the panel used the key. The arrow keys, Return and
    /// Tab belong to the panel only while the field has the focus
    /// (`inField`): a button that has the focus gets its own keys.
    func handleKey(_ event: NSEvent, inField: Bool) -> Bool {
        // An input method that composes text uses these keys itself.
        if let editor = firstResponder as? NSTextView, editor.hasMarkedText() {
            return false
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // Standard macOS Cmd+. modal cancel (distinct from the configurable Activity shortcut).
        if KeyCombo(".", modifiers: [.command]).matches(event) {
            finish(nil)
            return true
        }
        guard flags.isEmpty else {
            return false
        }
        if event.keyCode == 53 {
            if model.text.isEmpty {
                finish(nil)
            } else {
                model.text = ""
            }
            return true
        }
        guard inField else {
            return false
        }
        switch event.keyCode {
        case 125:
            model.moveSelection(1)
        case 126:
            model.moveSelection(-1)
        case 36, 76:
            if let chosen = model.chosen {
                finish(chosen)
            } else {
                NSSound.beep()
            }
        case 48:
            // With nothing to copy, Tab moves the focus as usual.
            return model.completeFromSelection()
        default:
            return false
        }
        return true
    }

    override func cancelOperation(_ sender: Any?) {
        finish(nil)
    }
}
