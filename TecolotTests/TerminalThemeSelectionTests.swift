import AppKit
import Testing
@testable import Tecolot

@MainActor
struct TerminalThemeSelectionTests {
    @Test func usingThemeForAllWindowsKeepsTheSelectedColorsInTheCurrentTerminal() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-theme-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let profiles = try ProfileStore(directory: directory)
        let controller = TerminalSessionController(startsProcess: false)
        let terminal = controller.makeTerminalView(document: TerminalDocument(content: ""))
        controller.applyProfile(profiles.defaultProfile)
        let theme = try #require(AppModel.shared.themes.themes.first {
            $0.background != controller.effectiveTheme.background
                && $0.foreground != controller.effectiveTheme.foreground
        })
        controller.applyThemeOverride(theme.name)

        try controller.useThemeForAllWindows(in: profiles)

        #expect(profiles.defaultProfile.themeName == theme.name)
        #expect(controller.profile == profiles.defaultProfile)
        #expect(controller.themeOverride == nil)
        #expect(controller.effectiveTheme == theme)
        #expect(terminal.nativeBackgroundColor == ProfileApplier.nativeColor(theme.background))
        #expect(terminal.nativeForegroundColor == ProfileApplier.nativeColor(theme.foreground))
    }

    @Test func failedProfileSaveKeepsTheSessionThemeAndProfile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-theme-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let profiles = try ProfileStore(directory: directory)
        let controller = TerminalSessionController(startsProcess: false)
        let terminal = controller.makeTerminalView(document: TerminalDocument(content: ""))
        // The store does not contain this profile. The update must fail.
        let profile = TerminalProfile(name: "Unsaved")
        controller.applyProfile(profile)
        let theme = try #require(AppModel.shared.themes.themes.first {
            $0.background != controller.effectiveTheme.background
        })
        controller.applyThemeOverride(theme.name)
        let storedProfile = profiles.defaultProfile

        #expect(throws: ProfilesError.profileNotFound) {
            try controller.useThemeForAllWindows(in: profiles)
        }

        #expect(profiles.defaultProfile == storedProfile)
        #expect(controller.profile == profile)
        #expect(controller.themeOverride == theme.name)
        #expect(terminal.nativeBackgroundColor == ProfileApplier.nativeColor(theme.background))
    }
}
