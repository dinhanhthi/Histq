// Fuzzy ranking of the command palette's rows (ported from Dblore's `SidebarEntityFilter` and
// `CommandPaletteRanking`, without its one-typo tier): each whitespace-separated keyword must hit one of a row's
// texts, as the whole text, a prefix, a word start, anywhere, or as an in-order abbreviation ("chk" in "checkout");
// a row's score is the sum of its keywords' best hits. Pure and synchronous, so the app runs it off the main actor.
import Foundation

public enum FuzzyRank {
    /// Higher is a stronger hit. Callers compare scores; the gaps are not a contract.
    private enum Rank: Int {
        case subsequence = 2
        case contains = 3
        case wordBoundary = 4
        case prefix = 5
        case exact = 6
    }

    /// The query's whitespace-separated terms, lowercased. An empty query has none and matches every row.
    public static func keywords(in query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map { String($0).lowercased() }
    }

    /// The indices of the rows whose texts every keyword of `query` hits, best total score first, at most `limit`.
    /// On equal scores the shorter first text (the title) wins, as the tighter match ("Checkout develop" before
    /// "Checkout origin/develop"), then the rows' order. `rows` holds each row's search texts, already lowercased. An
    /// empty query returns the first `limit` rows. A cancelled task gets an empty list.
    public static func rank(_ rows: [[String]], query: String, limit: Int) -> [Int] {
        let keywords = keywords(in: query)
        guard !keywords.isEmpty else { return Array(rows.indices.prefix(limit)) }
        var scored: [(index: Int, score: Int, length: Int)] = []
        for (index, texts) in rows.enumerated() {
            if index.isMultiple(of: 32), Task.isCancelled { return [] }
            if let score = score(texts, keywords: keywords) { scored.append((index, score, texts.first?.count ?? 0)) }
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.length != rhs.length { return lhs.length < rhs.length }
            return lhs.index < rhs.index
        }
        return scored.prefix(limit).map(\.index)
    }

    /// The sum of each keyword's best hit in `texts`; nil when a keyword hits none of them.
    private static func score(_ texts: [String], keywords: [String]) -> Int? {
        var total = 0
        for keyword in keywords {
            guard let best = texts.compactMap({ score(lowercased: keyword, in: $0) }).max() else { return nil }
            total += best
        }
        return total
    }

    /// The rank of one keyword in one text, both lowercased; nil for no hit.
    public static func score(lowercased needle: String, in haystack: String) -> Int? {
        if needle.isEmpty { return Rank.exact.rawValue }
        if let contiguous = contiguousRank(of: needle, in: haystack) { return contiguous }
        // Two-letter terms stay contiguous ("id" still means id); longer ones may skip letters within a short span.
        let maxSpan = needle.count <= 2 ? needle.count : needle.count * 3
        return hasSubsequence(in: haystack, needle: needle, maxSpan: maxSpan) ? Rank.subsequence.rawValue : nil
    }

    /// The best contiguous hit: the whole text is exact, a hit at index 0 a prefix, a later hit after a character that
    /// is not a letter (space, `/`, `-`, a digit) a word start, anything else a plain contains.
    private static func contiguousRank(of needle: String, in haystack: String) -> Int? {
        if haystack == needle { return Rank.exact.rawValue }
        var best: Int?
        var start = haystack.startIndex
        while start < haystack.endIndex, let range = haystack.range(of: needle, range: start..<haystack.endIndex) {
            let rank: Int
            if range.lowerBound == haystack.startIndex {
                rank = Rank.prefix.rawValue
            } else {
                let previous = haystack[haystack.index(before: range.lowerBound)]
                rank = previous.isLetter ? Rank.contains.rawValue : Rank.wordBoundary.rawValue
            }
            best = max(best ?? rank, rank)
            if rank >= Rank.wordBoundary.rawValue { break }
            start = haystack.index(after: range.lowerBound)
        }
        return best
    }

    /// The needle's characters appear in order within `maxSpan` characters, so abbreviations match ("chk" in
    /// "checkout") without scattered letters of a long title counting as a hit.
    private static func hasSubsequence(in haystack: String, needle: String, maxSpan: Int) -> Bool {
        let h = Array(haystack)
        let n = Array(needle)
        guard n.count >= 2, h.count >= n.count else { return false }
        var start = 0
        while start <= h.count - n.count {
            guard let first = h[start...].firstIndex(of: n[0]) else { return false }
            var end = first
            var matched = true
            for character in n.dropFirst() {
                guard end + 1 < h.count, let next = h[(end + 1)...].firstIndex(of: character) else {
                    matched = false
                    break
                }
                end = next
            }
            if matched, end - first + 1 <= maxSpan { return true }
            start = first + 1
        }
        return false
    }
}
