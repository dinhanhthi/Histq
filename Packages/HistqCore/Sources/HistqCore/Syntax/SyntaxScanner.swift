// A per-line tokenizer for syntax colors: one generic scanner driven by a `Language` from
// `LanguageTable`. Lines are scanned one at a time and a `ScanState` carries open block comments and
// multi-line strings from one line to the next, so a diff or conflict pane can scan only the lines it
// shows (keeping one state per side) and cache the state at each line start.
import Foundation

/// What a token is, for its color.
public enum TokenKind: Sendable, Hashable {
    case keyword
    case string
    case number
    case comment
    case type
    case punctuation
    /// Everything else. The scanner never emits it: the gaps between tokens are plain.
    case plain
}

/// A colored run of one line. `range` is in UTF-16 units from the start of the line, ready for
/// `NSAttributedString` / `NSString` APIs.
public struct SyntaxToken: Sendable, Hashable {
    public let range: NSRange
    public let kind: TokenKind

    public init(range: NSRange, kind: TokenKind) {
        self.range = range
        self.kind = kind
    }
}

/// What is still open at the end of a line: nothing, a block comment or a multi-line string. Start a
/// file with `ScanState()`.
public struct ScanState: Sendable, Hashable {
    enum Mode: Sendable, Hashable {
        case code
        /// `rule` indexes `Language.blockComments`; `depth` counts nested openings.
        case blockComment(rule: Int, depth: Int)
        /// `rule` indexes `Language.strings`.
        case string(rule: Int)
    }

    var mode: Mode = .code

    public init() {}

    /// The line ended inside a block comment or a multi-line string.
    public var isInsideConstruct: Bool { mode != .code }
}

public enum SyntaxScanner {
    /// Tokens of one line, without its line break, in order and not overlapping. `state` is the state at
    /// the end of the previous line and becomes the state at the end of this one. A `nil` language
    /// (plain text) gives no tokens.
    public static func scan(
        line: some StringProtocol, state: inout ScanState, language: Language?
    ) -> [SyntaxToken] {
        guard let language else { return [] }
        var scanner = LineScanner(text: Array(line.utf16), language: language)
        scanner.run(state: &state)
        return scanner.tokens
    }
}

// MARK: - Scanner

private enum ASCII {
    static let backslash = UInt16(UInt8(ascii: "\\"))
    static let colon = UInt16(UInt8(ascii: ":"))
    static let dot = UInt16(UInt8(ascii: "."))
    static let lessThan = UInt16(UInt8(ascii: "<"))
    static let slash = UInt16(UInt8(ascii: "/"))
    static let underscore = UInt16(UInt8(ascii: "_"))

    static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
    static func isUpper(_ c: UInt16) -> Bool { c >= 0x41 && c <= 0x5A }
    static func isLetter(_ c: UInt16) -> Bool { isUpper(c) || (c >= 0x61 && c <= 0x7A) }
    static func isSpace(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0C || c == 0x0B }
    /// Non-ASCII units (accented letters, CJK, surrogates) count as identifier characters.
    static func isWord(_ c: UInt16) -> Bool { isLetter(c) || isDigit(c) || c == underscore || c >= 0x80 }
    static func isPunctuation(_ c: UInt16) -> Bool {
        switch c {
        case 0x21...0x2F, 0x3A...0x40, 0x5B...0x5E, 0x60, 0x7B...0x7E: true
        default: false
        }
    }
    static func lowercased(_ c: UInt16) -> UInt16 { isUpper(c) ? c + 0x20 : c }
}

private struct LineScanner {
    let text: [UInt16]
    let language: Language
    var tokens: [SyntaxToken] = []

    init(text: [UInt16], language: Language) {
        self.text = text
        self.language = language
    }

    mutating func run(state: inout ScanState) {
        var i = 0
        switch state.mode {
        case .code:
            if let kind = linePrefixKind() {
                emit(0, text.count, kind)
                return
            }
        case let .blockComment(rule, depth):
            i = blockComment(from: 0, start: 0, rule: rule, depth: depth, state: &state)
        case let .string(rule):
            i = string(from: 0, start: 0, rule: rule, state: &state)
        }
        while i < text.count {
            i = step(at: i, state: &state)
        }
    }

    /// Scans one construct starting at `i` (which is in code) and returns where the next one starts,
    /// always past `i`.
    private mutating func step(at i: Int, state: inout ScanState) -> Int {
        let c = text[i]
        if ASCII.isSpace(c) { return i + 1 }
        for delimiter in language.lineComments where matches(delimiter, at: i) && lineCommentMayStart(at: i) {
            emit(i, text.count, .comment)
            return text.count
        }
        for (rule, comment) in language.blockComments.enumerated() where matches(comment.open, at: i) {
            return blockComment(from: i + comment.open.count, start: i, rule: rule, depth: 1, state: &state)
        }
        for (rule, literal) in language.strings.enumerated() where matches(literal.open, at: i) {
            if literal.isCharacter {
                guard let end = characterEnd(from: i + 1, close: literal.close) else { continue }
                emit(i, end, .string)
                return end
            }
            return string(from: i + literal.open.count, start: i, rule: rule, state: &state)
        }
        if ASCII.isDigit(c) { return number(at: i) }
        if ASCII.isLetter(c) || c == ASCII.underscore || c >= 0x80
            || language.identifierStarts.contains(c) || language.directivePrefixes.contains(c) {
            if let end = word(at: i) { return end }
        }
        if ASCII.isPunctuation(c) {
            var end = i + 1
            while end < text.count, ASCII.isPunctuation(text[end]), !startsConstruct(at: end) { end += 1 }
            if language.highlightsPunctuation { emit(i, end, .punctuation) }
            return end
        }
        return i + 1
    }

    // MARK: Constructs

    /// Scans a block comment body from `i` to its close (or the line end) and emits it from `start`.
    private mutating func blockComment(from i: Int, start: Int, rule: Int, depth: Int, state: inout ScanState) -> Int {
        let comment = language.blockComments[rule]
        var depth = depth
        var j = i
        while j < text.count {
            if matches(comment.close, at: j) {
                j += comment.close.count
                depth -= 1
                if depth == 0 {
                    state.mode = .code
                    emit(start, j, .comment)
                    return j
                }
            } else if comment.nests, matches(comment.open, at: j) {
                j += comment.open.count
                depth += 1
            } else {
                j += 1
            }
        }
        state.mode = .blockComment(rule: rule, depth: depth)
        emit(start, text.count, .comment)
        return text.count
    }

    /// Scans a string body from `i` to its close and emits it from `start`. An unclosed multi-line
    /// string stays open into the next line; an unclosed single-line one ends here.
    private mutating func string(from i: Int, start: Int, rule: Int, state: inout ScanState) -> Int {
        let literal = language.strings[rule]
        var j = i
        while j < text.count {
            if literal.escapes, text[j] == ASCII.backslash {
                j += 2
            } else if matches(literal.close, at: j) {
                j += literal.close.count
                state.mode = .code
                emit(start, j, .string)
                return j
            } else {
                j += 1
            }
        }
        state.mode = literal.multiline ? .string(rule: rule) : .code
        emit(start, text.count, .string)
        return text.count
    }

    /// The end of a character literal whose body starts at `i`: one character or one escape sequence,
    /// then `close`. `nil` when it does not close that way (a Rust lifetime `'a`).
    private func characterEnd(from i: Int, close: [UInt16]) -> Int? {
        guard i < text.count else { return nil }
        if text[i] == ASCII.backslash {
            // `\n`, `\x41`, `\u{1F600}`: close within a short distance.
            var j = i + 2
            while j < text.count, j <= i + 12 {
                if matches(close, at: j) { return j + close.count }
                j += 1
            }
            return nil
        }
        let width = UTF16.isLeadSurrogate(text[i]) ? 2 : 1
        return matches(close, at: i + width) ? i + width + close.count : nil
    }

    /// `42`, `2.5`, `0x1F`, `0b1010`, `1_000`, `10px`, `1e9`: digits, letters and `_`, plus one `.` when
    /// a digit follows (so `1..5` keeps its range operator).
    private mutating func number(at i: Int) -> Int {
        var j = i + 1
        var sawDot = false
        while j < text.count {
            let c = text[j]
            if ASCII.isLetter(c) || ASCII.isDigit(c) || c == ASCII.underscore {
                j += 1
            } else if c == ASCII.dot, !sawDot, j + 1 < text.count, ASCII.isDigit(text[j + 1]) {
                sawDot = true
                j += 1
            } else {
                break
            }
        }
        if language.highlightsNumbers { emit(i, j, .number) }
        return j
    }

    /// An identifier, keyword, type or directive at `i`; `nil` when a prefix unit is not followed by a
    /// word (a lone `@` or `$`), so the caller treats it as punctuation.
    private mutating func word(at i: Int) -> Int? {
        let first = text[i]
        let isPrefixed = language.directivePrefixes.contains(first) || language.identifierStarts.contains(first)
        var j = i + 1
        while j < text.count, ASCII.isWord(text[j]) || language.identifierParts.contains(text[j]) { j += 1 }
        if isPrefixed, j == i + 1 { return nil }
        if let kind = wordKind(i, j, directive: language.directivePrefixes.contains(first)) {
            emit(i, j, kind)
        }
        return j
    }

    private func wordKind(_ start: Int, _ end: Int, directive: Bool) -> TokenKind? {
        if end - start <= language.maxWordLength {
            let units = text[start..<end]
            let word = language.caseInsensitive
                ? String(decoding: units.map(ASCII.lowercased), as: UTF16.self)
                : String(decoding: units, as: UTF16.self)
            if language.keywords.contains(word) { return .keyword }
            if language.types.contains(word) { return .type }
        }
        if directive { return .keyword }
        if language.colonKeys, end < text.count, text[end] == ASCII.colon,
           end + 1 == text.count || ASCII.isSpace(text[end + 1]) {
            return .keyword
        }
        if language.tagKeywords, start > 0, text[start - 1] == ASCII.lessThan
            || (start > 1 && text[start - 1] == ASCII.slash && text[start - 2] == ASCII.lessThan) {
            return .keyword
        }
        if language.capitalizedTypes, ASCII.isUpper(text[start]) { return .type }
        return nil
    }

    // MARK: Helpers

    private func lineCommentMayStart(at i: Int) -> Bool {
        !language.lineCommentsAfterSpaceOnly || i == 0 || ASCII.isSpace(text[i - 1])
    }

    private func linePrefixKind() -> TokenKind? {
        language.linePrefixes.first { matches($0.prefix, at: 0) }?.kind
    }

    /// Punctuation runs stop where a comment or string starts (`);//`, `=("`).
    private func startsConstruct(at i: Int) -> Bool {
        language.lineComments.contains { matches($0, at: i) && lineCommentMayStart(at: i) }
            || language.blockComments.contains { matches($0.open, at: i) }
            || language.strings.contains { matches($0.open, at: i) }
    }

    private func matches(_ delimiter: [UInt16], at i: Int) -> Bool {
        guard i + delimiter.count <= text.count else { return false }
        for k in 0..<delimiter.count where text[i + k] != delimiter[k] { return false }
        return true
    }

    private mutating func emit(_ start: Int, _ end: Int, _ kind: TokenKind) {
        let end = min(end, text.count)
        guard end > start, kind != .plain else { return }
        tokens.append(SyntaxToken(range: NSRange(location: start, length: end - start), kind: kind))
    }
}
