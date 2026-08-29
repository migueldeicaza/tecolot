//
//  ThemeBrowserSectionsTests.swift
//  TecolotTests
//
//  Tests theme browser favorites, page filtering, and search sections.
//
import Testing
@testable import Tecolot

final class ThemeBrowserSectionsTests {
    @Test func favoritesAreFirstAndExcludedFromOtherThemes() {
        let sections = ThemeBrowserSections.compute(
            themes: themes(named: ["Gamma", "Beta", "Alpha"]),
            favorites: ["Gamma", "Alpha"],
            query: "",
            page: nil
        )

        #expect(sections.favorites.map(\.name) == ["Alpha", "Gamma"])
        #expect(sections.others.map(\.name) == ["Beta"])
    }

    @Test func pagedModeKeepsFavoritesFromOutsideThePage() {
        let sections = ThemeBrowserSections.compute(
            themes: themes(named: ["Unlisted Favorite", "Dracula", "Another Theme"]),
            favorites: ["Unlisted Favorite"],
            query: "",
            page: .popular
        )

        #expect(sections.favorites.map(\.name) == ["Unlisted Favorite"])
        #expect(sections.others.map(\.name) == ["Dracula"])
    }

    @Test func allModeReturnsEveryNonFavoriteTheme() {
        let sections = ThemeBrowserSections.compute(
            themes: themes(named: ["Unlisted Theme", "Nord", "Favorite"]),
            favorites: ["Favorite"],
            query: "",
            page: nil
        )

        #expect(sections.favorites.map(\.name) == ["Favorite"])
        #expect(sections.others.map(\.name) == ["Nord", "Unlisted Theme"])
    }

    @Test func searchFiltersFavoriteAndOtherSections() {
        let sections = ThemeBrowserSections.compute(
            themes: themes(named: [
                "Night Favorite", "Day Favorite", "Night Other", "Day Other"
            ]),
            favorites: ["Night Favorite", "Day Favorite"],
            query: "night",
            page: nil
        )

        #expect(sections.favorites.map(\.name) == ["Night Favorite"])
        #expect(sections.others.map(\.name) == ["Night Other"])
    }

    @Test func noFavoritesProducesAnEmptyFavoritesSection() {
        let sections = ThemeBrowserSections.compute(
            themes: themes(named: ["Beta", "Alpha"]),
            favorites: [],
            query: "",
            page: nil
        )

        #expect(sections.favorites.isEmpty)
        #expect(sections.others.map(\.name) == ["Alpha", "Beta"])
    }

    private func themes(named names: [String]) -> [TerminalTheme] {
        names.map { name in
            var theme = TerminalTheme.fallback
            theme.name = name
            return theme
        }
    }
}
