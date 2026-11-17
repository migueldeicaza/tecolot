import AppKit
import SwiftUI
import Testing
@testable import Tecolot

@MainActor
struct SettingsSearchTests {
    // MARK: - Catalog

    @Test func everyEntryHasTextForTheResultsList() {
        for entry in SettingsCatalog.entries {
            #expect(!entry.title.isEmpty, "\(entry.id) has no title")
            #expect(entry.summary.hasSuffix("."), "\(entry.id) needs a summary sentence")
            #expect(entry.id.entry.id == entry.id)
        }
    }

    @Test func everyPageHasOnePageEntry() {
        for destination in SettingsDestination.allCases {
            let pages = SettingsCatalog.entries.filter { $0.kind == .page && $0.destination == destination }
            #expect(pages.count == 1, "\(destination) needs one page entry")
        }
    }

    @Test func sectionsBelongToThePageOfTheirSettings() {
        for entry in SettingsCatalog.entries {
            guard let section = entry.section?.entry else {
                continue
            }
            #expect(section.kind == .section, "\(entry.id) is in \(section.id), which is not a section")
            #expect(section.destination == entry.destination)
        }
        for section in SettingsCatalog.entries where section.kind == .section {
            #expect(!section.id.revealTargets.isEmpty, "\(section.id) has no settings to show")
        }
    }

    @Test func conditionalRowsLeadToARowThatIsAlwaysThere() {
        for entry in SettingsCatalog.entries {
            guard let controller = entry.revealedBy?.entry else {
                #expect(entry.note == nil || entry.kind == .section, "\(entry.id) has a note but no controlling row")
                continue
            }
            #expect(entry.note != nil, "\(entry.id) must say when it is shown")
            #expect(controller.kind == .setting)
            #expect(controller.revealedBy == nil, "\(entry.id) is controlled by a conditional row")
            #expect(controller.destination == entry.destination)
        }
    }

    @Test func breadcrumbsShowTheWayToARow() {
        #expect(SettingID.pageTabs.entry.breadcrumb == "")
        #expect(SettingID.tabsStyle.entry.breadcrumb == "Tabs \u{203A} Layout")
        #expect(SettingID.generalUseMetal.entry.breadcrumb == "General")
        #expect(SettingID.pageAppearance.entry.breadcrumb == "Profile")
        #expect(SettingID.windowCustomTitle.entry.breadcrumb == "Profile \u{203A} Window \u{203A} Title")
    }

    // MARK: - Engine

    private func ids(_ query: String, context: SettingsSearchContext = SettingsSearchContext()) -> [SettingID] {
        SettingsSearchEngine.search(query, context: context).map(\.id)
    }

    @Test func titleMatchesComeFirst() {
        #expect(ids("font").first == .appearanceFont)
        #expect(ids("bell").first == .notificationsBell)
        #expect(ids("tabs").first == .pageTabs)
        #expect(ids("copy on selection").first == .generalCopyOnSelection)
    }

    @Test func keywordsFindRowsThatDoNotShowTheWord() {
        #expect(ids("transparency") == [.appearanceBackgroundOpacity])
        #expect(ids("gpu") == [.generalUseMetal])
        #expect(ids("terminfo") == [.terminalDeclareAs])
        #expect(ids("keybindings").contains(.keyboardKeyMappings))
    }

    @Test func everyWordMustMatchAndTheLastCanBeAPrefix() {
        #expect(ids("cursor bl") == [.appearanceCursor])
        #expect(ids("option meta") == [.keyboardOptionAsMeta])
        #expect(ids("scrollback li").contains(.terminalScrollbackLines))
        #expect(ids("font zebra").isEmpty)
    }

    @Test func matchingIgnoresCaseAccentsAndPunctuation() {
        #expect(ids("FONT").first == .appearanceFont)
        #expect(ids("fónt").first == .appearanceFont)
        #expect(ids("control-h") == [.keyboardDeleteSendsControlH])
        #expect(ids("osc 8").first == .terminalOSC8Links)
    }

    @Test func emptyAndUnknownQueriesFindNothing() {
        #expect(ids("").isEmpty)
        #expect(ids("   ").isEmpty)
        #expect(ids("fontfont").isEmpty)
    }

    @Test func rowsThatCannotExistAreLeftOut() {
        #expect(ids("updates").contains(.generalCheckForUpdates))
        let noUpdater = SettingsSearchContext(updatesEnabled: false)
        #expect(!ids("update", context: noUpdater).contains { $0.entry.requiresUpdater })

        #expect(ids("cursor").contains(.appearanceCursor))
        let noProfiles = SettingsSearchContext(profilesAreEmpty: true)
        #expect(!ids("cursor", context: noProfiles).contains(.appearanceCursor))
        #expect(ids("profile", context: noProfiles).contains(.pageManageProfiles))
    }

    @Test func pagesWithResultsKeepSidebarOrder() {
        let results = SettingsSearchEngine.search("color")
        let pages = SettingsSearchEngine.pages(in: results)
        #expect(pages == (SettingsDestination.appPages + SettingsDestination.profilePages).filter(pages.contains))
        #expect(pages.contains(.tabs))
        #expect(pages.contains(.panes))
        #expect(SettingsSearchResultsView.countLabel(1) == "1 result")
        #expect(SettingsSearchResultsView.countLabel(16) == "16 results")
    }

    @Test func catalogLookupsMatchTheEntryList() {
        #expect(SettingsCatalog.entries.map(\.id) == SettingID.allCases)
        #expect(SettingsCatalog.entriesByID.count == SettingID.allCases.count)
        #expect(SettingID.tabsSectionLook.revealTargets == [.tabsIconColor, .tabsGeneratedTitles, .tabsAnimationStyle])
        #expect(SettingID.pageTabs.revealTargets == [])
        #expect(SettingID.tabsStyle.revealTargets == [.tabsStyle])
    }

    // MARK: - Anchors

    /// Puts a page in a window that is tall enough to show every row.
    private func host(_ page: some View, defaults: UserDefaults) -> NSWindow {
        let view = NSHostingView(
            rootView: page
                .environmentObject(SettingsPreviewData.profiles)
                .environmentObject(SettingsPreviewData.themes)
                .environmentObject(SettingsPreviewData.themeIndex)
                .environmentObject(SystemAppearance(isDark: false))
                .defaultAppStorage(defaults)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 1600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return window
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "com.tirania.Tecolot.SettingsSearchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        body(defaults)
        defaults.removePersistentDomain(forName: name)
    }

    /// The rows that a page always shows.
    private func fixedSettings(on destination: SettingsDestination) -> Set<SettingID> {
        Set(SettingsCatalog.entries.filter {
            $0.destination == destination && $0.kind == .setting && $0.revealedBy == nil && !$0.requiresUpdater
        }.map(\.id))
    }

    private func missingAnchors(on destination: SettingsDestination, in window: NSWindow) -> Set<SettingID> {
        fixedSettings(on: destination).subtracting(SettingsAnchorRegistry.shared.ids(in: window))
    }

    @Test func appPagesMarkEveryFixedRow() {
        withDefaults { defaults in
            let general = host(
                GeneralSettingsView(
                    groups: TerminalWindowManager(registry: TerminalSessionRegistry()),
                    secureKeyboardEntry: SecureKeyboardEntry(isEnabled: false)
                ),
                defaults: defaults
            )
            #expect(missingAnchors(on: .general, in: general) == [])
            let tabs = host(TabsSettingsView(), defaults: defaults)
            #expect(missingAnchors(on: .tabs, in: tabs) == [])
            let panes = host(PanesSettingsView(), defaults: defaults)
            #expect(missingAnchors(on: .panes, in: panes) == [])
            let notifications = host(NotificationsSettingsView(), defaults: defaults)
            #expect(missingAnchors(on: .notifications, in: notifications) == [])
        }
    }

    @Test(arguments: [
        SettingsDestination.appearance, .window, .shell, .keyboardAndMouse, .terminal,
    ])
    func profilePagesMarkEveryFixedRow(destination: SettingsDestination) throws {
        let section = try #require(ProfileSettingsSection(destination: destination))
        withDefaults { defaults in
            let window = host(ProfileSettingsPagePreview(section: section), defaults: defaults)
            #expect(missingAnchors(on: destination, in: window) == [])
        }
    }

    // MARK: - Reveal

    @Test func revealShowsARowAndFallsBackForAConditionalRow() {
        withDefaults { defaults in
            // Tabs above the terminal: the Sidebar section is not on the page.
            defaults.set("horizontal", forKey: ProgramActivityPreferences.tabStyleKey)
            let window = host(TabsSettingsView(), defaults: defaults)
            let controller = SettingsSpotlightController()

            #expect(controller.reveal(.tabsShowIcons, in: window, allowsFallback: false))
            #expect(controller.revealedIDs == [.tabsShowIcons])

            #expect(!controller.reveal(.tabsSidebarTextSize, in: window, allowsFallback: false))
            #expect(controller.reveal(.tabsSidebarTextSize, in: window, allowsFallback: true))
            #expect(controller.revealedIDs == [.tabsStyle])

            #expect(controller.reveal(.tabsSectionLook, in: window, allowsFallback: false))
            #expect(controller.revealedIDs == [.tabsIconColor, .tabsGeneratedTitles, .tabsAnimationStyle])
            #expect(controller.revealedSection)

            // A section that is not on the page falls back to one row, and
            // the spotlight has the padding of a row.
            #expect(controller.reveal(.tabsSectionSidebar, in: window, allowsFallback: true))
            #expect(controller.revealedIDs == [.tabsStyle])
            #expect(!controller.revealedSection)

            #expect(!controller.reveal(.pageTabs, in: window, allowsFallback: true))
            controller.invalidate()
        }
    }
}
