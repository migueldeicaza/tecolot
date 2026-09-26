import AppKit
import Observation

enum TitlebarAccessoryAlignment {
    /// AppKit's accessory center can include a toolbar row. Align content to
    /// the standard window buttons instead of the accessory's full height.
    static func centerYConstant(for view: NSView) -> CGFloat? {
        guard let button = view.window?.standardWindowButton(.closeButton) else { return nil }
        let buttonCenter = button.convert(
            NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: view
        ).y
        return view.bounds.midY - buttonCenter
    }
}

/// The titlebar only shows paths reported by the shell through OSC 7.
/// A launch directory is not proof that the shell is still there.
enum TerminalWorkingDirectory {
    static func path(from report: String?) -> String? {
        guard let report,
              let url = URL(string: report),
              url.scheme == "file" || url.scheme == "kitty-shell-cwd",
              url.path.hasPrefix("/"),
              !url.path.isEmpty else {
            return nil
        }

        if let host = url.host, !host.isEmpty {
            guard LocalHostNames.shared.contains(host) else { return nil }
        }
        return url.standardizedFileURL.path
    }

    static func ancestors(of path: String) -> [URL] {
        var url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var result: [URL] = []
        while true {
            result.append(url)
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return result
    }
}

/// The names of this Mac that a shell can put in an OSC 7 report.
/// `ProcessInfo.hostName` can block for seconds on a network lookup, thus
/// the names load in a background task. Until then, only "localhost" is
/// local. Views that read the names update when the task completes.
@Observable
final class LocalHostNames {
    static let shared = LocalHostNames()

    private(set) var names = ["localhost"]
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    func contains(_ host: String) -> Bool {
        load()
        return names.contains { $0.caseInsensitiveCompare(host) == .orderedSame }
    }

    @discardableResult
    func load() -> Task<Void, Never> {
        if let loadTask { return loadTask }
        let task = Task {
            names = await Task.detached(priority: .utility) {
                LocalHostNames.lookUp()
            }.value
        }
        loadTask = task
        return task
    }

    nonisolated private static func lookUp() -> [String] {
        var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        let systemName = gethostname(&buffer, buffer.count) == 0
            ? String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : ""
        var names = ["localhost"]
        for name in [systemName, ProcessInfo.processInfo.hostName] where !name.isEmpty {
            let shortName = name.split(separator: ".").first.map(String.init) ?? name
            names += [name, shortName, "\(shortName).local"]
        }
        return names
    }
}

@MainActor
enum TerminalWorkingDirectoryTitlebar {
    private static let identifier = NSUserInterfaceItemIdentifier("TecolotWorkingDirectory")

    static func configure(
        _ window: NSWindow, path: String?, title: String, hasActivity: Bool,
        enableProxyIcon: Bool
    ) {
        window.titleVisibility = .hidden
        let accessory: WorkingDirectoryTitlebarAccessory
        if let existing = window.titlebarAccessoryViewControllers.first(where: {
            $0.identifier == identifier
        }) as? WorkingDirectoryTitlebarAccessory {
            accessory = existing
        } else {
            accessory = WorkingDirectoryTitlebarAccessory()
            accessory.identifier = identifier
            accessory.layoutAttribute = .left
            window.addTitlebarAccessoryViewController(accessory)
        }
        accessory.control.configure(
            path: enableProxyIcon ? path : nil, title: title, hasActivity: hasActivity
        )
        accessory.view.setFrameSize(accessory.control.intrinsicContentSize)
    }
}

private final class WorkingDirectoryTitlebarAccessory: NSTitlebarAccessoryViewController {
    let control = WorkingDirectoryTitlebarControl()

    override func loadView() {
        view = control
    }
}

/// Receives mouse events itself so a drag starts from the icon or the text,
/// instead of moving the window behind the titlebar.
final class WorkingDirectoryTitlebarControl: NSView, NSDraggingSource {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var stackCenterY: NSLayoutConstraint!
    private(set) var path: String?

    override var mouseDownCanMoveWindow: Bool { path == nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 22 + min(label.intrinsicContentSize.width, 440), height: 24)
    }

    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyDown
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16)
        ])

        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.textColor = .labelColor

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(label)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        stackCenterY = stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -8)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackCenterY,
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 440)
        ])
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not available")
    }

    func configure(path: String?, title: String, hasActivity: Bool) {
        var titleWithoutActivity = title.hasPrefix("● ") ? String(title.dropFirst(2)) : title
        // The profile can put the full path in the title. The label shows
        // the path after the title, thus remove it from the title.
        if let path {
            titleWithoutActivity = titleWithoutActivity
                .components(separatedBy: " — ")
                .filter {
                    !$0.hasPrefix("/") || URL(fileURLWithPath: $0).standardizedFileURL.path != path
                }
                .joined(separator: " — ")
        }
        let status = hasActivity
            ? (titleWithoutActivity.isEmpty ? "●" : "● \(titleWithoutActivity)")
            : titleWithoutActivity
        let text = path.map { status.isEmpty ? $0 : "\(status) | \($0)" } ?? title
        guard self.path != path || label.stringValue != text else {
            return
        }
        self.path = path
        label.stringValue = text
        icon.image = path == nil
            ? NSApp.applicationIconImage
            : NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")
        toolTip = path ?? title
        setAccessibilityLabel(path.map {
            let activity = hasActivity ? "Activity. " : ""
            let terminalTitle = titleWithoutActivity.isEmpty ? "" : "\(titleWithoutActivity). "
            return "\(activity)\(terminalTitle)Working directory: \($0)"
        } ?? title)
        invalidateIntrinsicContentSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let constant = TitlebarAccessoryAlignment.centerYConstant(for: self),
              abs(stackCenterY.constant - constant) > 0.5 else { return }
        stackCenterY.constant = constant
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Keep the mouse sequence here. The default sends it to the titlebar,
    // which can track the drag itself and then mouseDragged does not come.
    override func mouseDown(with event: NSEvent) {
        guard path == nil else { return }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let path else { return }
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem(for: path))
        let image = NSImage(data: dataWithPDF(inside: bounds)) ?? icon.image ?? NSImage()
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func pasteboardItem(for path: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(path, forType: .string)
        item.setString(
            URL(fileURLWithPath: path, isDirectory: true).absoluteString,
            forType: .fileURL
        )
        return item
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let path else { return nil }
        let directories = TerminalWorkingDirectory.ancestors(of: path)
        let menu = NSMenu()
        for (index, directory) in directories.enumerated() {
            if index == 1 { menu.addItem(.separator()) }
            let item = NSMenuItem(
                title: index == 0 ? "Open in Finder" : directory.path,
                action: #selector(openDirectory(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = directory
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            menu.addItem(item)
        }
        return menu
    }

    @objc private func openDirectory(_ sender: NSMenuItem) {
        guard let directory = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(directory)
    }
}
