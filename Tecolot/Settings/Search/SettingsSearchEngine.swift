//
//  SettingsSearchEngine.swift
//  Tecolot
//
//  Finds and ranks Settings catalog entries for a typed query.
//
import Foundation

/// The app state that decides which entries can be found.
struct SettingsSearchContext: Equatable {
    var profilesAreEmpty = false
    var updatesEnabled = true
}

struct SettingsSearchResult: Identifiable {
    let entry: SettingsSearchEntry
    let score: Int

    var id: SettingID {
        entry.id
    }
}

enum SettingsSearchEngine {
    /// The words of one entry, split once for every search.
    private struct Indexed {
        let entry: SettingsSearchEntry
        let title: [String]
        let titlePhrase: String
        let keywords: [String]
        let breadcrumb: [String]
        let summary: [String]

        init(_ entry: SettingsSearchEntry) {
            self.entry = entry
            title = SettingsSearchEngine.words(in: entry.title)
            titlePhrase = title.joined(separator: " ")
            keywords = entry.keywords.flatMap(SettingsSearchEngine.words(in:))
            breadcrumb = SettingsSearchEngine.words(in: entry.breadcrumb)
            summary = SettingsSearchEngine.words(in: entry.summary)
        }
    }

    private static let index: [Indexed] = SettingsCatalog.entries.map(Indexed.init)

    /// Returns the entries that match every word of the query, best first.
    ///
    /// A query word matches when a word of the title, the keywords, the
    /// breadcrumb or the summary starts with it. Entries with the same
    /// score keep the catalog order.
    static func search(
        _ query: String,
        context: SettingsSearchContext = SettingsSearchContext()
    ) -> [SettingsSearchResult] {
        let tokens = words(in: query)
        guard !tokens.isEmpty else {
            return []
        }
        let phrase = tokens.joined(separator: " ")
        var results: [(offset: Int, result: SettingsSearchResult)] = []
        for (offset, indexed) in index.enumerated() where isIndexed(indexed.entry, context: context) {
            if let score = score(indexed, tokens: tokens, phrase: phrase) {
                results.append((offset, SettingsSearchResult(entry: indexed.entry, score: score)))
            }
        }
        results.sort { left, right in
            left.result.score != right.result.score ? left.result.score > right.result.score : left.offset < right.offset
        }
        return results.map(\.result)
    }

    /// The pages that have results, in sidebar order.
    static func pages(in results: [SettingsSearchResult]) -> [SettingsDestination] {
        let found = Set(results.map(\.entry.destination))
        return SettingsDestination.sidebarPages.filter(found.contains)
    }

    static func isIndexed(_ entry: SettingsSearchEntry, context: SettingsSearchContext) -> Bool {
        if entry.requiresUpdater && !context.updatesEnabled {
            return false
        }
        if entry.destination.isProfileDriven && context.profilesAreEmpty {
            return false
        }
        return true
    }

    /// Lowercase words without accents, split at spaces and punctuation.
    static func words(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    private static func score(_ indexed: Indexed, tokens: [String], phrase: String) -> Int? {
        var total = 0
        for token in tokens {
            if indexed.title.first?.hasPrefix(token) == true {
                total += 120
            } else if indexed.title.contains(where: { $0.hasPrefix(token) }) {
                total += 100
            } else if indexed.keywords.contains(where: { $0.hasPrefix(token) }) {
                total += 60
            } else if indexed.breadcrumb.contains(where: { $0.hasPrefix(token) }) {
                total += 40
            } else if indexed.summary.contains(where: { $0.hasPrefix(token) }) {
                total += 20
            } else {
                return nil
            }
        }
        if indexed.titlePhrase == phrase {
            total += 80
        } else if indexed.titlePhrase.hasPrefix(phrase) {
            total += 50
        }
        return total
    }
}
