import Foundation
import Testing
@testable import Tecolot

@MainActor
struct SettingsProfilePickerTests {
    @Test func creatingAProfileKeepsProfilePagesAndManageProfiles() {
        for destination in SettingsDestination.allCases {
            let expected: SettingsDestination = SettingsDestination.appPages.contains(destination) ? .appearance : destination
            #expect(SettingsDestination.destinationAfterCreatingProfile(from: destination) == expected)
        }
    }

    @Test func emptyProfilesHideEditingPagesAndRepairOnlyTheirDestinations() {
        #expect(SettingsDestination.visibleProfileEditingPages(profilesAreEmpty: true).isEmpty)
        #expect(SettingsDestination.visibleProfileEditingPages(profilesAreEmpty: false) == [.appearance, .window, .shell, .keyboardAndMouse, .terminal])
        for destination in SettingsDestination.allCases {
            #expect(SettingsDestination.repairedDestination(destination, profilesAreEmpty: false) == destination)
            let expected: SettingsDestination = destination.isProfileDriven ? .manageProfiles : destination
            #expect(SettingsDestination.repairedDestination(destination, profilesAreEmpty: true) == expected)
        }
    }

    @Test func selectionRepairPreservesKnownIDsAndFallsBackToDefault() {
        let defaultID = UUID()
        let selectedID = UUID()
        let ids = [defaultID, selectedID]
        #expect(SettingsView.repairedProfileID(selectedID: selectedID, profileIDs: ids, defaultID: defaultID) == selectedID)
        for invalidID in [nil, UUID()] {
            #expect(SettingsView.repairedProfileID(selectedID: invalidID, profileIDs: ids, defaultID: defaultID) == defaultID)
        }
        #expect(SettingsView.repairedProfileID(selectedID: selectedID, profileIDs: [defaultID], defaultID: defaultID) == defaultID)
        #expect(SettingsView.repairedProfileID(selectedID: selectedID, profileIDs: [], defaultID: defaultID) == nil)
    }

    @Test func sharedActionsKeepUniqueNamesAndCopyTheDefaultProfile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("settings-profile-picker-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProfileStore(directory: directory)
        var defaultProfile = store.defaultProfile
        defaultProfile.fontSize = 23
        try store.update(defaultProfile)

        let first = try store.addNewProfile()
        let second = try store.addNewProfile()
        #expect(first.name == "New Profile")
        #expect(second.name == "New Profile 2")
        #expect(first.id != second.id && first.id != defaultProfile.id)
        #expect(first.fontSize == 23 && second.fontSize == 23)

        try store.rename(first.id, to: "Work")
        let copy = try store.duplicate(first.id)
        #expect(copy.name == "Work copy")
        #expect(try store.duplicate(first.id).name == "Work copy 2")
        #expect(copy.fontSize == 23 && copy.id != first.id)
        try store.setDefault(copy.id)
        #expect(store.defaultProfileID == copy.id)
        #expect(try ProfileStore(directory: directory).defaultProfileID == copy.id)
    }

    @Test func sharedNamingAvoidsCaseInsensitiveCollisions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("settings-profile-picker-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProfileStore(directory: directory)
        try store.add(TerminalProfile(name: "new profile"))
        #expect(try store.addNewProfile().name == "New Profile 2")
        let work = TerminalProfile(name: "Work")
        try store.add(work)
        try store.add(TerminalProfile(name: "work COPY"))
        #expect(try store.duplicate(work.id).name == "Work copy 2")
    }
}
