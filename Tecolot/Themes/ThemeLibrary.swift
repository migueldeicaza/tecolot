//
//  ThemeLibrary.swift
//  Tecolot
//
//  Saves and deletes user themes, and keeps the profiles in agreement.
//  Profiles refer to themes by name: a rename or a delete must also
//  change each profile slot that uses the theme. All views that save or
//  delete a user theme use this type, so that no view forgets a step.
//
import Foundation

@MainActor
struct ThemeLibrary {
    let themes: ThemeStore
    let profiles: ProfileStore

    /// Saves a user theme. If the theme has a new name, each profile slot
    /// that used `oldName` changes to the new name.
    ///
    /// The profiles change first. If the theme save fails, the profiles
    /// get their old values again.
    func save(_ theme: TerminalTheme, replacing oldName: String?) throws {
        var changedProfiles: [TerminalProfile] = []
        if let oldName, oldName != theme.name {
            changedProfiles = try profiles.replaceThemeName(oldName) { _ in theme.name }
        }
        do {
            try themes.saveUserTheme(theme, replacing: oldName)
        } catch {
            profiles.restore(changedProfiles)
            throw error
        }
    }

    /// Deletes a user theme. Each profile slot that used it changes to
    /// `replacementName(forDeleted:isDark:)`.
    func delete(named name: String) throws {
        guard let theme = themes.themes.first(where: { $0.name == name }), !theme.isBuiltIn else {
            throw ProfilesError.themeIsBuiltIn
        }
        let changedProfiles = try profiles.replaceThemeName(name) { isDark in
            replacementName(forDeleted: theme, isDark: isDark)
        }
        do {
            try themes.deleteUserTheme(named: name)
        } catch {
            profiles.restore(changedProfiles)
            throw error
        }
    }

    /// The theme for a slot whose theme is deleted: the base theme of the
    /// deleted theme if it exists and agrees with the mode of the slot,
    /// else the default theme of the mode.
    func replacementName(forDeleted theme: TerminalTheme, isDark: Bool) -> String {
        if let baseName = theme.baseThemeName,
           let base = themes.themes.first(where: { $0.name == baseName }),
           base.name != theme.name,
           base.isDark == isDark {
            return base.name
        }
        return TerminalProfile.defaultThemeName(isDark: isDark)
    }
}
