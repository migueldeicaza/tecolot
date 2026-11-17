import AppKit
import Foundation
import Testing
@testable import Tecolot
import TecolotSessionDirectory

@MainActor
struct SessionDialogTests {
    private func record(_ id: String, exited: Bool = false) -> SessionRecord {
        var record = SessionRecord(id: id, pid: 1, shellPID: 2, protocolVersion: 1, build: "test",
                                   createdAt: Date(), executable: "/bin/zsh", workingDirectory: "/home/me",
                                   labels: ["profile": "Default"], columns: 80, rows: 24)
        record.exited = exited
        return record
    }

    // MARK: Termination

    @Test func terminationTitleNamesTheHost() {
        #expect(SessionTermination.title(for: [SessionRef(id: "a", destination: nil)]) == "Terminate this session?")
        #expect(SessionTermination.title(for: [SessionRef(id: "a", destination: "dev@build-01")])
                == "Terminate this session on dev@build-01?")
        #expect(SessionTermination.title(for: [SessionRef(id: "a", destination: nil),
                                               SessionRef(id: "b", destination: "staging")])
                == "Terminate 2 sessions?")
    }

    @Test func terminateIsNeverTheReturnDefault() {
        let alert = SessionTermination.makeAlert(for: [SessionRef(id: "a", destination: nil)])
        #expect(alert.informativeText == "The shell and the programs that it runs end. You cannot undo this.")
        #expect(alert.buttons.map(\.title) == ["Terminate", "Cancel"])
        #expect(alert.buttons[0].hasDestructiveAction)
        #expect(alert.buttons[0].keyEquivalent == "")
        #expect(alert.buttons[1].keyEquivalent == "\r")
    }

    // MARK: Host key

    private let hostKeyText = """
        The authenticity of host 'build-01.example.com (192.0.2.10)' can't be established.
        ED25519 key fingerprint is SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s.
        This key is not known by any other names.
        Are you sure you want to continue connecting (yes/no/[fingerprint])?
        """

    @Test func fingerprintComesFromTheSSHText() throws {
        let fingerprint = try #require(HostKeyFingerprint(sshText: hostKeyText))
        #expect(fingerprint.hostName == "build-01.example.com")
        #expect(fingerprint.address == "192.0.2.10")
        #expect(fingerprint.keyType == "ED25519")
        #expect(fingerprint.hash == "SHA256")
        #expect(fingerprint.full == "SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s.")
        #expect(fingerprint.groupedLines == ["uNiV ztks CsDh cc0u 9e8B ujQX", "VUpK ZIDT MczC vj3t D2s."])
    }

    @Test func partialSSHTextKeepsTheRawSheet() {
        #expect(HostKeyFingerprint(sshText: "ED25519 key fingerprint is SHA256:abc") == nil)
        #expect(HostKeyFingerprint(sshText: "The authenticity of host 'a (1.2.3.4)' can't be established.") == nil)
        let alert = NSAlert()
        alert.informativeText = "raw"
        #expect(!HostKeyConfirmation.configure(alert, sshText: "raw"))
        #expect(alert.informativeText == "raw" && alert.accessoryView == nil)
    }

    @Test func hostKeySheetShowsTheFingerprintAndCopiesIt() throws {
        let alert = NSAlert()
        #expect(HostKeyConfirmation.configure(alert, sshText: hostKeyText))
        #expect(alert.informativeText.hasPrefix("Tecolot has not connected to build-01.example.com (192.0.2.10) before."))
        let accessory = try #require(alert.accessoryView as? HostKeyAccessoryView)
        #expect(accessory.frame.width == 360)
        let collapsed = accessory.frame.height
        #expect(!accessory.isShowingOutput)
        accessory.toggleFromLabel()
        #expect(accessory.isShowingOutput && accessory.frame.height > collapsed)
        accessory.copyFingerprint()
        #expect(NSPasteboard.general.string(forType: .string) == "SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s.")
    }

    // MARK: Helper install

    @Test func installQuestionTellsSizeAndDirectory() {
        let prompt = RemoteInstallPrompt(id: UUID(), destination: "dev@build-01", bytes: 12_000_000)
        #expect(prompt.title == "Install the Tecolot helper on dev@build-01?")
        #expect(prompt.text.contains("goes in \(RemoteHosts.helperDirectory) and runs your shell"))
    }

    @Test func installBannerMovesTheTerminalDown() {
        let terminal = TestSurface(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let container = TerminalSessionContainerView(terminal: terminal)
        container.frame = NSRect(x: 0, y: 0, width: 404, height: 304)
        container.layoutSubtreeIfNeeded()
        let fullHeight = terminal.frame.height
        var answers: [Bool] = []
        let banner = RemoteInstallBanner(prompt: RemoteInstallPrompt(id: UUID(), destination: "staging", bytes: 1),
                                         isActive: { false }, answer: { answers.append($0) })
        container.setTopBanner(banner)
        container.layoutSubtreeIfNeeded()
        #expect(terminal.frame.height < fullHeight)
        #expect(!banner.frame.intersects(terminal.frame))
        banner.notNow()
        banner.install()
        #expect(answers == [false, true])
        container.setTopBanner(nil)
        container.layoutSubtreeIfNeeded()
        #expect(terminal.frame.height == fullHeight)
    }

    /// A dark theme makes the terminal window dark: the banners must be dark
    /// too, or their light text is not visible.
    @Test func bannersFollowTheAppearanceOfTheWindow() throws {
        func brightness(_ view: NSView) throws -> CGFloat {
            view.updateLayer()
            let color = try #require(view.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)))
            return try #require(color.usingColorSpace(.sRGB)).brightnessComponent
        }
        let install = RemoteInstallBanner(prompt: RemoteInstallPrompt(id: UUID(), destination: "staging", bytes: 1),
                                          isActive: { false }, answer: { _ in })
        let warning = RemoteSessionBanner()
        warning.configure(text: "Connection lost.", actionTitle: "Retry", action: nil)
        for banner in [install, warning] as [NSView] {
            banner.appearance = NSAppearance(named: .darkAqua)
            #expect(try brightness(banner) < 0.5)
            banner.appearance = NSAppearance(named: .aqua)
            #expect(try brightness(banner) > 0.5)
        }
    }

    // MARK: Sessions window

    @Test func remoteHostsPersistInTheOrderTheyWereAdded() throws {
        let suite = "SessionDialogTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SessionBrowserModel(list: { [] }, shown: { [] }, defaults: defaults)
        model.addHost("staging")
        model.addHost("dev@build-01")
        model.addHost("staging")
        #expect(model.hosts.map(\.displayName) == ["This Mac", "staging", "dev@build-01"])

        let restored = SessionBrowserModel(list: { [] }, shown: { [] }, defaults: defaults)
        #expect(restored.hosts.map(\.id) == ["local", "staging", "dev@build-01"])
        let remote = try #require(restored.host("staging"))
        #expect(remote.state == .notConnected && !remote.isExpanded)
        #expect(remote.meta == "Not connected")
        #expect(restored.children(of: remote).isEmpty)
    }

    @Test func thisMacIsFirstAndShowsAnEmptyLine() throws {
        var records: [SessionRecord] = []
        let model = SessionBrowserModel(list: { records }, shown: { [] })
        model.refresh()
        let local = try #require(model.hosts.first)
        #expect(local.displayName == "This Mac" && local.isExpanded)
        #expect(local.meta == "0 sessions")
        #expect(model.children(of: local) == [.status(local)])

        records = [record("a")]
        model.refresh()
        let loaded = try #require(model.hosts.first)
        #expect(loaded.meta == "1 session")
        #expect(model.children(of: loaded).map(\.id) == ["a"])

        // Host rows cannot be selected.
        model.select([SessionBrowserItem.host(loaded).id, "a"])
        #expect(model.selection == ["a"])
    }

    @Test func remoteRowsAttachThroughTheirHost() {
        let row = SessionBrowserRow.make(record("s1"), shown: [], destination: "staging")
        #expect(row.id == "staging/s1")
        #expect(row.ref == SessionRef(id: "s1", destination: "staging"))
        #expect(row.directory == "/home/me")
        let spec = SessionBrowserModel.attachSpec(row.record, destination: "staging")
        #expect(spec.attachSessionID == "s1" && spec.remoteDestination == "staging" && spec.persistent)
    }

    @Test func removeAlertCountsTheRunningSessions() {
        var host = SessionHost.remote("staging")
        host.state = .loaded
        host.sessions = [SessionBrowserRow.make(record("a"), shown: [], destination: "staging"),
                         SessionBrowserRow.make(record("b"), shown: [], destination: "staging"),
                         SessionBrowserRow.make(record("c", exited: true), shown: [], destination: "staging")]
        let alert = SessionBrowserModel.removeAlert(for: host)
        #expect(alert.messageText == "Remove Tecolot from staging?")
        #expect(alert.informativeText
                == "2 sessions on staging end. The helper in \(RemoteHosts.helperDirectory) is deleted. You cannot undo this.")
        #expect(alert.buttons.map(\.title) == ["Remove", "Cancel"])
        #expect(alert.buttons[0].hasDestructiveAction && alert.buttons[1].keyEquivalent == "\r")

        host.sessions = []
        #expect(SessionBrowserModel.removeAlert(for: host).informativeText
                == "The helper in \(RemoteHosts.helperDirectory) is deleted. You cannot undo this.")
    }
}

private final class TestSurface: NSView, TerminalSurface {
    var nativeForegroundColor: NSColor { .white }
    var nativeBackgroundColor: NSColor { .black }
    var gridDimensions: (cols: Int, rows: Int) { (80, 24) }
    var selectionActive: Bool { false }
    func requestRedraw() {}
}
