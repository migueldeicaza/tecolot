import AppKit
import Foundation

/// Pure fuzzy, substring, and token matcher for the Command Palette.
nonisolated enum CommandPaletteSearch {
    struct Match: Equatable {
        let score: Int
        let titleRanges: [Range<String.Index>]
        let subtitleRanges: [Range<String.Index>]
    }

    /// Scores one candidate against a trimmed query. Returns nil when it does not match.
    static func match(
        query rawQuery: String,
        title: String,
        subtitle: String? = nil,
        keywords: [String] = []
    ) -> Match? {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return Match(score: 0, titleRanges: [], subtitleRanges: [])
        }

        let foldedQuery = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard !foldedQuery.isEmpty else {
            return Match(score: 0, titleRanges: [], subtitleRanges: [])
        }

        var bestScore: Int?
        var bestTitleRanges: [Range<String.Index>] = []
        var bestSubtitleRanges: [Range<String.Index>] = []

        if let titleMatch = scoreField(query: query, foldedQuery: foldedQuery, text: title, weight: 0) {
            bestScore = titleMatch.score
            bestTitleRanges = titleMatch.ranges
        }

        if
            let subtitle, !subtitle.isEmpty,
            let subtitleMatch = scoreField(query: query, foldedQuery: foldedQuery, text: subtitle, weight: -120) {
            if bestScore == nil || subtitleMatch.score > bestScore! {
                bestScore = subtitleMatch.score
                bestTitleRanges = []
                bestSubtitleRanges = subtitleMatch.ranges
            } else if bestSubtitleRanges.isEmpty {
                bestSubtitleRanges = subtitleMatch.ranges
            }
        }

        // Multi-word token search across title + subtitle + keywords.
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        if tokens.count > 1 {
            if let multi = scoreMultiToken(tokens: tokens, title: title, subtitle: subtitle, keywords: keywords) {
                if bestScore == nil || multi.score > bestScore! {
                    bestScore = multi.score
                    bestTitleRanges = multi.titleRanges
                    bestSubtitleRanges = multi.subtitleRanges
                }
            }
        }

        // Keyword match fallback: always ranks below direct title matches so synonyms assist without drowning titles.
        for keyword in keywords where !keyword.isEmpty {
            if let kwMatch = scoreField(query: query, foldedQuery: foldedQuery, text: keyword, weight: 0) {
                let adjusted = max(40, min(160, kwMatch.score / 6))
                if bestScore == nil || adjusted > bestScore! {
                    bestScore = adjusted
                    bestTitleRanges = []
                    bestSubtitleRanges = []
                }
            }
        }

        guard let finalScore = bestScore else {
            return nil
        }
        return Match(score: finalScore, titleRanges: bestTitleRanges, subtitleRanges: bestSubtitleRanges)
    }

    private static func scoreField(
        query: String,
        foldedQuery: String,
        text: String,
        weight: Int
    ) -> (score: Int, ranges: [Range<String.Index>])? {
        guard !text.isEmpty else {
            return nil
        }

        // 1. Exact match
        if text.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return (1000 + weight, [text.startIndex..<text.endIndex])
        }

        // 2. Contiguous substring match (prefers prefix and word boundaries)
        if let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            let score: Int
            if range.lowerBound == text.startIndex {
                score = 650 - min(40, text.count)
            } else if isWordBoundary(in: text, at: range.lowerBound) {
                let distance = text.distance(from: text.startIndex, to: range.lowerBound)
                score = 500 - min(40, distance)
            } else {
                let distance = text.distance(from: text.startIndex, to: range.lowerBound)
                score = 360 - min(40, distance)
            }
            return (score + weight, [range])
        }

        // 3. Subsequence fuzzy match (e.g., "cltb" -> "Close Tab")
        let foldedText = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard let fuzzyScore = subsequenceScore(query: foldedQuery, text: foldedText) else {
            return nil
        }
        // Like Rex, non-contiguous fuzzy matches do not highlight scattered individual letters.
        return (fuzzyScore + weight, [])
    }

    private static func scoreMultiToken(
        tokens: [String],
        title: String,
        subtitle: String?,
        keywords: [String]
    ) -> Match? {
        var titleRanges: [Range<String.Index>] = []
        var subtitleRanges: [Range<String.Index>] = []
        var total = 320

        for token in tokens {
            if let range = title.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) {
                titleRanges.append(range)
                total += isWordBoundary(in: title, at: range.lowerBound) ? 45 : 25
            } else if let subtitle, let range = subtitle.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) {
                subtitleRanges.append(range)
                total += isWordBoundary(in: subtitle, at: range.lowerBound) ? 25 : 15
            } else if
                keywords.contains(where: {
                    $0.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }) {
                total += 10
            } else {
                return nil
            }
        }
        return Match(score: total, titleRanges: mergeRanges(titleRanges), subtitleRanges: mergeRanges(subtitleRanges))
    }

    private static func subsequenceScore(query: String, text: String) -> Int? {
        guard !query.isEmpty, query.count <= text.count else {
            return nil
        }
        let qChars = Array(query)
        let tChars = Array(text)
        var qIndex = 0
        var lastMatch = -1
        var consecutive = 0
        var wordStarts = 0
        var totalGap = 0

        for tIndex in tChars.indices {
            if tChars[tIndex] == qChars[qIndex] {
                if lastMatch >= 0 {
                    let gap = tIndex - lastMatch - 1
                    if gap == 0 {
                        consecutive += 1
                    } else {
                        totalGap += gap
                    }
                }
                if tIndex == 0 || !tChars[tIndex - 1].isLetter && !tChars[tIndex - 1].isNumber {
                    wordStarts += 1
                }
                lastMatch = tIndex
                qIndex += 1
                if qIndex == qChars.count {
                    break
                }
            }
        }

        guard qIndex == qChars.count else {
            return nil
        }
        return max(60, 180 + wordStarts * 22 + consecutive * 14 - min(100, totalGap * 3))
    }

    private static func isWordBoundary(in text: String, at index: String.Index) -> Bool {
        guard index > text.startIndex else {
            return true
        }
        let previous = text[text.index(before: index)]
        return !previous.isLetter && !previous.isNumber
    }

    private static func mergeRanges(_ ranges: [Range<String.Index>]) -> [Range<String.Index>] {
        guard ranges.count > 1 else {
            return ranges
        }
        let sorted = ranges.sorted {
            $0.lowerBound < $1.lowerBound
        }
        var merged: [Range<String.Index>] = []
        for range in sorted {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Renders a label with bold accent (or bold white on selected rows) highlight ranges.
    static func attributedString(
        _ text: String,
        matchRanges: [Range<String.Index>],
        font: NSFont,
        highlightFont: NSFont,
        baseColor: NSColor,
        highlightColor: NSColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: baseColor]
        )
        for range in matchRanges {
            let nsRange = NSRange(range, in: text)
            if nsRange.location != NSNotFound, nsRange.length > 0 {
                result.addAttributes(
                    [.font: highlightFont, .foregroundColor: highlightColor],
                    range: nsRange
                )
            }
        }
        return result
    }
}
