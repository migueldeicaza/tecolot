import AppKit
import Foundation
import Testing
@testable import Tecolot
import TecolotSessionClient

struct RemoteDestinationTests {
    @Test func destinationValidation() throws {
        for destination in ["server", "user@server", "build-host", "user@[::1]"] {
            try SSHConfiguration.validate(destination)
        }
        for destination in ["", "-server", "user name@server", "server\n", "server\0"] {
            #expect(throws: SSHConfigurationError.invalidDestination) {
                try SSHConfiguration.validate(destination)
            }
        }
    }

    @Test func recentDestinationsMoveToFrontAndHaveALimit() throws {
        let suite = "RemoteDestinationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recent = RecentRemoteDestinations(defaults: defaults)
        for index in 0..<25 {
            recent.record("host\(index)")
        }
        #expect(recent.destinations.count == RecentRemoteDestinations.limit)
        #expect(recent.destinations.first == "host24")
        #expect(recent.destinations.last == "host15")
        recent.record("host10")
        #expect(recent.destinations.first == "host10")
        #expect(recent.destinations.filter {
            $0 == "host10"
        }.count == 1)
        recent.record("-invalid")
        #expect(recent.destinations.first == "host10")
    }

    @MainActor
    @Test func newTabInheritsDirectoryOnSameRemoteHost() throws {
        let suite = "RemoteDestinationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profileID = UUID()
        let remote = WindowOpener.inheritedTabSpec(
            profileID: profileID,
            workingDirectory: "/remote/path",
            remoteDestination: "host",
            defaults: defaults
        )
        #expect(remote.profileID == profileID)
        #expect(remote.remoteDestination == "host")
        #expect(remote.workingDirectory == "/remote/path")
        #expect(remote.persistent)
        let local = WindowOpener.inheritedTabSpec(
            profileID: profileID,
            workingDirectory: "/local/path",
            remoteDestination: nil,
            defaults: defaults
        )
        #expect(local.workingDirectory == "/local/path")
        #expect(!local.persistent)
        defaults.set(false, forKey: WindowOpener.newTabsUseCurrentProfileKey)
        defaults.set(false, forKey: WindowOpener.newTabsUseCurrentDirectoryKey)
        let noProfile = WindowOpener.inheritedTabSpec(
            profileID: profileID,
            workingDirectory: "/remote/path",
            remoteDestination: "host",
            defaults: defaults
        )
        #expect(noProfile.profileID == nil)
        #expect(noProfile.remoteDestination == "host")
        #expect(noProfile.workingDirectory == nil)
    }

    @Test func recentDestinationsFilterInvalidSavedValues() throws {
        let suite = "RemoteDestinationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            ["host", "host", "-option", "has space", "other"],
            forKey: RecentRemoteDestinations.key
        )
        #expect(RecentRemoteDestinations(defaults: defaults).destinations == ["host", "other"])
    }

    @Test func recentDestinationsRemove() throws {
        let suite = "RemoteDestinationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recent = RecentRemoteDestinations(defaults: defaults)
        recent.record("one")
        recent.record("two")
        recent.remove("one")
        #expect(recent.destinations == ["two"])
    }
}

@MainActor
struct RemoteDestinationPickerTests {
    private func model(removed: @escaping (String) -> Void = { _ in }) -> RemoteDestinationPickerModel {
        RemoteDestinationPickerModel(
            recents: ["miguel@studio", "build-host"],
            aliases: ["prod", "build-host", "staging-build"],
            removeRecent: removed
        )
    }

    @Test func emptyTextListsRecentsThenAliasesAndChoosesTheMostRecent() {
        let model = model()
        #expect(model.entries.map(\.destination) == ["miguel@studio", "build-host", "prod", "staging-build"])
        #expect(model.entries.map(\.source) == [.recent, .recent, .alias, .alias])
        #expect(model.chosen == "miguel@studio")
    }

    @Test func textFiltersAndOffersTheTypedDestinationFirst() {
        let model = model()
        model.text = " build "
        #expect(model.entries.map(\.destination) == ["build", "build-host", "staging-build"])
        #expect(model.entries.first?.source == .typed)
        #expect(model.chosen == "build")
        model.text = "prod"
        #expect(model.entries.map(\.destination) == ["prod"])
        #expect(model.entries.first?.source == .alias)
        #expect(model.chosen == "prod")
    }

    @Test func invalidTextCannotConnect() {
        let model = model()
        model.text = "-oProxyCommand=x"
        #expect(model.chosen == nil)
        #expect(model.showsInvalidText)
        model.text = "user name@host"
        #expect(model.chosen == nil)
        #expect(model.showsInvalidText)
        model.text = ""
        #expect(!model.showsInvalidText)
    }

    @Test func arrowKeysAndAMovingPointerMoveTheSelection() {
        let model = model()
        // A row under a pointer at rest does not take the selection when
        // the panel opens.
        model.hover(2)
        #expect(model.chosen == "miguel@studio")
        model.moveSelection(2)
        #expect(model.chosen == "prod")
        model.moveSelection(10)
        #expect(model.chosen == "staging-build")
        // Nor when the keyboard scrolls a row under it.
        model.hover(0)
        #expect(model.chosen == "staging-build")
        let reveals = model.revealCount
        model.pointerMoved()
        model.hover(1)
        #expect(model.chosen == "build-host")
        // The pointer does not scroll the list.
        #expect(model.revealCount == reveals)
        // Nor when the text changes the rows.
        model.pointerMoved()
        model.text = "b"
        model.hover(1)
        #expect(model.selection == 0)
        model.moveSelection(1)
        #expect(model.revealCount > reveals)
    }

    @Test func textThatDiffersOnlyInCaseChoosesTheKnownHostAndKeepsTheTypedRow() {
        let model = model()
        model.text = "Prod"
        #expect(model.entries.map(\.destination) == ["Prod", "prod"])
        #expect(model.chosen == "prod")
        // User names depend on case: the text is one row up.
        model.moveSelection(-1)
        #expect(model.chosen == "Prod")
        model.text = "Miguel@studio"
        #expect(model.chosen == "miguel@studio")
        #expect(model.entries.first == .init(destination: "Miguel@studio", source: .typed))
        model.text = "prod"
        #expect(model.entries.map(\.destination) == ["prod"])
    }

    @Test func forgottenRecentHostShowsAgainAsAnAlias() {
        let model = model()
        #expect(model.entries.map(\.destination) == ["miguel@studio", "build-host", "prod", "staging-build"])
        model.forget(model.entries[1])
        #expect(model.entries.map(\.destination) == ["miguel@studio", "prod", "build-host", "staging-build"])
        #expect(model.entries.map(\.source) == [.recent, .alias, .alias, .alias])
    }

    @Test func tabCopiesTheSelectedRowToTheField() {
        let model = model()
        model.moveSelection(2)
        model.completeFromSelection()
        #expect(model.text == "prod")
        #expect(model.chosen == "prod")
    }

    @Test func forgetRemovesARecentHost() {
        var removed: [String] = []
        let model = model {
            removed.append($0)
        }
        model.forget(model.entries[0])
        #expect(removed == ["miguel@studio"])
        #expect(model.entries.map(\.destination) == ["build-host", "prod", "staging-build"])
        model.forget(model.entries[1])
        #expect(removed == ["miguel@studio"])
    }

    private func key(_ code: UInt16, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code
        ))
    }

    @Test func windowKeysChooseAndFinishOneTime() throws {
        let model = model()
        let window = RemoteDestinationWindow(model: model)
        var results: [String?] = []
        window.onFinish = {
            results.append($0)
        }
        model.text = "x"
        #expect(try window.handleKey(key(53, in: window), inField: true))
        #expect(model.text.isEmpty)
        #expect(results.isEmpty)
        #expect(try window.handleKey(key(125, in: window), inField: true))
        #expect(try window.handleKey(key(36, in: window), inField: true))
        #expect(results == ["build-host"])
        // A second click or key does not end the panel again.
        window.finish("prod")
        #expect(try window.handleKey(key(53, in: window), inField: true))
        #expect(results == ["build-host"])
    }

    @Test func keysBelongToAFocusedButton() throws {
        let model = model()
        let window = RemoteDestinationWindow(model: model)
        var results: [String?] = []
        window.onFinish = {
            results.append($0)
        }
        for code: UInt16 in [36, 48, 125, 126] {
            #expect(try !window.handleKey(key(code, in: window), inField: false))
        }
        #expect(model.selection == 0)
        #expect(results.isEmpty)
        // In the field, Tab copies the row one time, then moves the focus.
        #expect(try window.handleKey(key(48, in: window), inField: true))
        #expect(model.text == "miguel@studio")
        #expect(try !window.handleKey(key(48, in: window), inField: true))
        #expect(try window.handleKey(key(53, in: window), inField: false))
        #expect(try window.handleKey(key(53, in: window), inField: false))
        #expect(results == [nil])
    }

    @Test func modalPanelStaysVisibleWhenTheAppIsNotActive() {
        #expect(!RemoteDestinationWindow(model: model()).hidesOnDeactivate)
    }
}
