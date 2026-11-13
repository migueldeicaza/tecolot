import AppKit
import SwiftUI

/// App-wide pane appearance, retaining the existing preference keys.
struct PanesSettingsView: View {
    @AppStorage(GlobalAppearanceSettings.terminalPaddingKey) private var padding = GlobalAppearanceSettings.TerminalPadding.minimal
    @AppStorage(GlobalAppearanceSettings.paneStyleKey) private var style = GlobalAppearanceSettings.PaneStyle.comfortable
    @AppStorage(GlobalAppearanceSettings.showPaneHeadersKey) private var headers = true
    @AppStorage(GlobalAppearanceSettings.paneCardsBackdropKey) private var backdrop = GlobalAppearanceSettings.Backdrop.chrome
    @AppStorage(GlobalAppearanceSettings.highlightActivePaneKey) private var highlight = true
    @AppStorage(GlobalAppearanceSettings.paneHighlightColorKey) private var colorOverride = ""

    private var settings: GlobalAppearanceSettings {
        var value = GlobalAppearanceSettings()
        value.terminalPadding = padding
        value.paneStyle = style
        value.paneCardsEnabled = headers
        value.paneCardsBackdrop = backdrop
        value.highlightActivePane = highlight
        value.paneHighlightColor = GlobalAppearanceSettings.HighlightColor.decode(colorOverride)
        return value
    }

    /// An empty stored override continues to follow the current system accent.
    private var color: Binding<Color> {
        Binding(get: {
            Color(nsColor: settings.activePaneColor)
        }, set: {
            colorOverride = GlobalAppearanceSettings.HighlightColor(color: NSColor($0))?.encoded ?? ""
        })
    }

    var body: some View {
        Form {
            Section("Panes") {
                Picker("Padding:", selection: $padding) {
                    ForEach(GlobalAppearanceSettings.TerminalPadding.allCases, id: \.self) {
                        Text($0.title).tag($0)
                    }
                }
                Picker("Pane style:", selection: $style) {
                    ForEach(GlobalAppearanceSettings.PaneStyle.allCases, id: \.self) {
                        Text($0.title).tag($0)
                    }
                }
                .help("Compact removes the spacing, rounded corners and shadows around panes.")
                Toggle("Show Pane Headers", isOn: $headers)
                    .help("Comfortable panes keep headers when the window controls need them on the right or with the sidebar hidden.")
                Picker("Background:", selection: $backdrop) {
                    ForEach(GlobalAppearanceSettings.Backdrop.allCases, id: \.self) {
                        Text($0.title).tag($0)
                    }
                }
                .disabled(style == .compact)
            }
            Section("Active Pane") {
                Toggle("Highlight Active Pane", isOn: $highlight)
                HStack {
                    ColorPicker("Highlight Color", selection: color, supportsOpacity: true)
                        .accessibilityLabel("Highlight Color")
                    Button("Use Accent Color") {
                        colorOverride = ""
                    }
                    .disabled(settings.paneHighlightColor == nil)
                }
                .disabled(!highlight)
                Text(settings.paneHighlightColor == nil ? "Follows the system accent color." : "Custom color, including opacity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Preview") {
                PaneAppearancePreview(settings: settings)
                    .frame(height: 180)
                    .accessibilityLabel("Pane appearance preview")
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("Panes")
    }
}

/// Uses real cards without starting shells or touching the user's sessions.
private struct PaneAppearancePreview: NSViewRepresentable {
    let settings: GlobalAppearanceSettings

    func makeNSView(context: Context) -> PaneSettingsPreviewView {
        PaneSettingsPreviewView(settings: settings)
    }

    func updateNSView(_ view: PaneSettingsPreviewView, context: Context) {
        view.host.synchronize(revision: view.host.workspace.revision, settings: settings)
    }
}

/// Gives preview outlines the same unclipped canvas used by terminal windows.
final class PaneSettingsPreviewView: NSView {
    let host: TerminalPaneHostView
    private let outlines = PaneCardOutlineOverlay(frame: .zero)

    init(settings: GlobalAppearanceSettings) {
        let workspace = TerminalPaneWorkspace(startsProcesses: false)
        if let first = workspace.focusedController {
            workspace.split(first, direction: .right)
        }
        host = TerminalPaneHostView(workspace: workspace)
        super.init(frame: .zero)
        addSubview(host)
        addSubview(outlines)
        host.onCardLayout = { [weak self] host in
            self?.outlines.update(cards: host.visibleCards)
        }
        host.synchronize(revision: workspace.revision, settings: settings)
    }

    @available(*, unavailable) required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        host.frame = bounds
        outlines.frame = bounds
        host.layoutSubtreeIfNeeded()
        outlines.update(cards: host.visibleCards)
    }
}

#Preview("Panes") {
    PanesSettingsView()
        .defaultAppStorage(SettingsPreviewData.defaults)
        .frame(width: 650, height: 650)
}
