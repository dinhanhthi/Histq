// The languages `SyntaxScanner` knows, as data: each one is the same generic scanner configured with its
// comment and string delimiters, keywords and a type heuristic. Unknown files have no language and render
// as plain text.
import Foundation

/// A string literal form. `close` is searched from just after `open`; a backslash escapes the next unit
/// when `escapes` is set.
struct StringRule: Sendable {
    let open: [UInt16]
    let close: [UInt16]
    var escapes = true
    /// Spans lines (Swift `"""`, Python `'''`, JS template literals): an unclosed one carries over to the
    /// next line. A single-line string that is not closed ends at the end of its line.
    var multiline = false
    /// A character literal (`'a'`, `'\n'`): only taken as a string when it closes right away, so a Rust
    /// lifetime (`'a`) stays code.
    var isCharacter = false
}

/// A block comment form, e.g. `/*` ... `*/`.
struct BlockCommentRule: Sendable {
    let open: [UInt16]
    let close: [UInt16]
    /// Swift and Rust nest block comments.
    var nests = false
}

/// The scanner configuration of one language.
public struct Language: Sendable, Hashable, Identifiable {
    /// Display name, also the identity: "Swift", "C/C++", "Python", ...
    public let id: String
    public var name: String { id }

    var lineComments: [[UInt16]] = []
    var blockComments: [BlockCommentRule] = []
    /// Longest delimiters first (`"""` before `"`).
    var strings: [StringRule] = []
    var keywords: Set<String> = []
    /// Built-in types that are not capitalized (`int`, `u32`, `str`).
    var types: Set<String> = []
    /// Identifiers starting with an ASCII capital letter are types (`String`, `Greeter`).
    var capitalizedTypes = false
    /// Keywords are matched in lowercase (SQL); `keywords` must then be lowercase.
    var caseInsensitive = false
    /// Units that start an attribute or directive (`@` of `@objc`, `#` of `#include`): the whole word
    /// is a keyword.
    var directivePrefixes: Set<UInt16> = []
    /// Units that may start an identifier besides letters and `_` (`$` of `$var`).
    var identifierStarts: Set<UInt16> = []
    /// Units allowed inside an identifier besides letters, digits and `_` (`-` of `font-size`).
    var identifierParts: Set<UInt16> = []
    /// An identifier right before `: ` (or a final `:`) is a key, shown as a keyword (YAML).
    var colonKeys = false
    /// An identifier right after `<` or `</` is a tag name, shown as a keyword (HTML/XML).
    var tagKeywords = false
    /// Line comments start only at the line start or after whitespace, so `$#`, `${#a}` and
    /// `http://host/#x` stay code (Shell, YAML, CSS).
    var lineCommentsAfterSpaceOnly = false
    /// A line whose first unit is this prefix is one token of that kind (Markdown `#` headings).
    var linePrefixes: [(prefix: [UInt16], kind: TokenKind)] = []
    var highlightsNumbers = true
    var highlightsPunctuation = true

    /// Length in UTF-16 units of the longest keyword or built-in type: longer identifiers skip the lookup.
    private(set) var maxWordLength = 0

    init(_ id: String, configure: (inout Language) -> Void) {
        self.id = id
        configure(&self)
        maxWordLength = keywords.union(types).map(\.utf16.count).max() ?? 0
    }

    public static func == (lhs: Language, rhs: Language) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Finds the language of a file from its name.
public enum LanguageTable {
    /// The language of `path` (only its last component counts), or `nil` for plain text.
    public static func language(forPath path: String) -> Language? {
        let name = Substring(path.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
        if let language = byFileName[String(name)] { return language }
        if name.hasPrefix("Dockerfile.") || name.hasPrefix("Containerfile.") { return dockerfile }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        return byExtension[name[name.index(after: dot)...].lowercased()]
    }

    /// Every language, in display order.
    public static let all: [Language] = [
        swift, cFamily, rust, go, python, ruby, javaScript, json, yaml, toml, markdown, markup, css, shell,
        sql, java, kotlin, cSharp, php, dockerfile,
    ]

    private static let byExtension: [String: Language] = {
        let table: [(Language, [String])] = [
            (swift, ["swift"]),
            (cFamily, ["c", "h", "cc", "cpp", "cxx", "hh", "hpp", "hxx", "m", "mm", "inl"]),
            (rust, ["rs"]),
            (go, ["go"]),
            (python, ["py", "pyw", "pyi"]),
            (ruby, ["rb", "rake", "gemspec", "podspec"]),
            (javaScript, ["js", "mjs", "cjs", "jsx", "ts", "mts", "cts", "tsx"]),
            (json, ["json", "jsonc", "json5", "geojson"]),
            (yaml, ["yml", "yaml"]),
            (toml, ["toml"]),
            (markdown, ["md", "markdown", "mdx"]),
            (markup, ["html", "htm", "xhtml", "xml", "svg", "plist", "xib", "storyboard", "entitlements", "vue"]),
            (css, ["css", "scss", "sass", "less"]),
            (shell, ["sh", "bash", "zsh", "fish", "command"]),
            (sql, ["sql"]),
            (java, ["java"]),
            (kotlin, ["kt", "kts"]),
            (cSharp, ["cs", "csx"]),
            (php, ["php", "phtml"]),
            (dockerfile, ["dockerfile", "containerfile"]),
        ]
        var map: [String: Language] = [:]
        for (language, extensions) in table {
            for ext in extensions { map[ext] = language }
        }
        return map
    }()

    private static let byFileName: [String: Language] = [
        "Dockerfile": dockerfile, "Containerfile": dockerfile,
        "Gemfile": ruby, "Rakefile": ruby, "Podfile": ruby, "Fastfile": ruby, "Brewfile": ruby,
        ".bashrc": shell, ".bash_profile": shell, ".zshrc": shell, ".zprofile": shell, ".profile": shell,
        "Package.resolved": json, "Cargo.lock": toml,
    ]
}

// MARK: - Language definitions

private func u(_ s: String) -> [UInt16] { Array(s.utf16) }
private func unit(_ s: Unicode.Scalar) -> UInt16 { UInt16(s.value) }
private func words(_ s: String) -> Set<String> { Set(s.split(separator: " ").map(String.init)) }

private let slashComments: [[UInt16]] = [u("//")]
private let cBlockComment = BlockCommentRule(open: u("/*"), close: u("*/"))
private let doubleQuoted = StringRule(open: u("\""), close: u("\""))
private let singleQuoted = StringRule(open: u("'"), close: u("'"))
private let tripleDouble = StringRule(open: u("\"\"\""), close: u("\"\"\""), multiline: true)
private let tripleSingle = StringRule(open: u("'''"), close: u("'''"), multiline: true)
private let charLiteral = StringRule(open: u("'"), close: u("'"), isCharacter: true)

extension LanguageTable {
    static let swift = Language("Swift") {
        $0.lineComments = slashComments
        $0.blockComments = [BlockCommentRule(open: u("/*"), close: u("*/"), nests: true)]
        $0.strings = [tripleDouble, doubleQuoted]
        $0.keywords = words("""
            actor any as associatedtype async await break case catch class continue convenience default defer \
            deinit didSet do dynamic else enum extension fallthrough false fileprivate final for func get guard \
            if import in indirect infix init inout internal is isolated lazy let mutating nil nonisolated \
            nonmutating open operator optional override package postfix precedencegroup prefix private \
            protocol public repeat required rethrows return self Self set some static struct subscript super \
            switch throw throws true try typealias unowned var weak where while willSet consuming borrowing \
            sending
            """)
        $0.capitalizedTypes = true
        $0.directivePrefixes = [unit("@"), unit("#")]
    }

    static let cFamily = Language("C/C++/Objective-C") {
        $0.lineComments = slashComments
        $0.blockComments = [cBlockComment]
        $0.strings = [doubleQuoted, charLiteral]
        $0.keywords = words("""
            auto break case catch class const constexpr consteval constinit continue default delete do else \
            enum explicit export extern false final for friend goto if inline mutable namespace new noexcept \
            nullptr operator override private protected public register return sizeof static static_assert \
            static_cast dynamic_cast reinterpret_cast const_cast struct switch template this throw true try \
            typedef typeid typename union using virtual volatile while NULL nil Nil YES NO self super id \
            instancetype nonatomic atomic strong weak assign copy readonly readwrite nullable nonnull \
            __block __weak __strong
            """)
        $0.types = words("""
            void bool char short int long float double signed unsigned size_t ssize_t int8_t int16_t int32_t \
            int64_t uint8_t uint16_t uint32_t uint64_t uintptr_t intptr_t wchar_t char16_t char32_t BOOL SEL \
            IMP Class NSInteger NSUInteger CGFloat std string vector
            """)
        $0.capitalizedTypes = true
        $0.directivePrefixes = [unit("@"), unit("#")]
    }

    static let rust = Language("Rust") {
        $0.lineComments = slashComments
        $0.blockComments = [BlockCommentRule(open: u("/*"), close: u("*/"), nests: true)]
        // Rust strings may span lines.
        $0.strings = [StringRule(open: u("\""), close: u("\""), multiline: true), charLiteral]
        $0.keywords = words("""
            as async await break const continue crate dyn else enum extern false fn for if impl in let loop \
            match mod move mut pub ref return self Self static struct super trait true type union unsafe use \
            where while macro_rules
            """)
        $0.types = words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str")
        $0.capitalizedTypes = true
        $0.directivePrefixes = [unit("#")]
    }

    static let go = Language("Go") {
        $0.lineComments = slashComments
        $0.blockComments = [cBlockComment]
        $0.strings = [StringRule(open: u("`"), close: u("`"), escapes: false, multiline: true), doubleQuoted, charLiteral]
        $0.keywords = words("""
            break case chan const continue default defer else fallthrough for func go goto if import interface \
            map package range return select struct switch type var true false nil iota
            """)
        $0.types = words("""
            bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint \
            uint8 uint16 uint32 uint64 uintptr any comparable
            """)
    }

    static let python = Language("Python") {
        $0.lineComments = [u("#")]
        $0.strings = [tripleDouble, tripleSingle, doubleQuoted, singleQuoted]
        $0.keywords = words("""
            and as assert async await break class continue def del elif else except False finally for from \
            global if import in is lambda None nonlocal not or pass raise return True try while with yield \
            match case self cls
            """)
        $0.types = words("int float str bytes bool list dict set tuple object complex frozenset bytearray")
        $0.capitalizedTypes = true
        $0.directivePrefixes = [unit("@")]
    }

    static let ruby = Language("Ruby") {
        $0.lineComments = [u("#")]
        $0.blockComments = [BlockCommentRule(open: u("=begin"), close: u("=end"))]
        $0.strings = [doubleQuoted, singleQuoted, StringRule(open: u("`"), close: u("`"))]
        $0.keywords = words("""
            alias and begin break case class def defined do else elsif end ensure false for if in module next \
            nil not or redo rescue retry return self super then true undef unless until when while yield \
            require require_relative attr_reader attr_writer attr_accessor private protected public lambda proc
            """)
        $0.capitalizedTypes = true
        $0.identifierStarts = [unit("@"), unit("$")]
    }

    static let javaScript = Language("JavaScript/TypeScript") {
        $0.lineComments = slashComments
        $0.blockComments = [cBlockComment]
        $0.strings = [StringRule(open: u("`"), close: u("`"), multiline: true), doubleQuoted, singleQuoted]
        $0.keywords = words("""
            abstract as async await break case catch class const continue debugger declare default delete do \
            else enum export extends false finally for from function get if implements import in instanceof \
            interface is keyof let namespace new null of package private protected public readonly return \
            satisfies set static super switch this throw true try type typeof undefined var void while with \
            yield
            """)
        $0.types = words("any boolean never number object string symbol unknown bigint")
        $0.capitalizedTypes = true
        $0.directivePrefixes = [unit("@")]
        $0.identifierStarts = [unit("$")]
    }

    static let json = Language("JSON") {
        $0.lineComments = slashComments
        $0.blockComments = [cBlockComment]
        $0.strings = [doubleQuoted]
        $0.keywords = words("true false null")
    }

    static let yaml = Language("YAML") {
        $0.lineComments = [u("#")]
        $0.strings = [doubleQuoted, StringRule(open: u("'"), close: u("'"), escapes: false)]
        $0.keywords = words("true false null yes no on off True False Null Yes No On Off TRUE FALSE NULL")
        $0.identifierParts = [unit("-"), unit(".")]
        $0.colonKeys = true
        $0.lineCommentsAfterSpaceOnly = true
    }

    static let toml = Language("TOML") {
        $0.lineComments = [u("#")]
        $0.strings = [
            tripleDouble, StringRule(open: u("'''"), close: u("'''"), escapes: false, multiline: true),
            doubleQuoted, StringRule(open: u("'"), close: u("'"), escapes: false),
        ]
        $0.keywords = words("true false inf nan")
        $0.identifierParts = [unit("-")]
    }

    static let markdown = Language("Markdown") {
        $0.blockComments = [BlockCommentRule(open: u("<!--"), close: u("-->"))]
        // Fenced code blocks as strings; no `'` or `"`, which prose uses as apostrophes and quotes.
        $0.strings = [
            StringRule(open: u("```"), close: u("```"), escapes: false, multiline: true),
            StringRule(open: u("`"), close: u("`"), escapes: false),
        ]
        $0.linePrefixes = [(u("#"), .keyword), (u(">"), .comment)]
        $0.highlightsNumbers = false
        $0.highlightsPunctuation = false
    }

    static let markup = Language("HTML/XML") {
        $0.blockComments = [
            BlockCommentRule(open: u("<!--"), close: u("-->")),
            BlockCommentRule(open: u("<![CDATA["), close: u("]]>")),
        ]
        // Only `"`: text content uses `'` as an apostrophe.
        $0.strings = [StringRule(open: u("\""), close: u("\""), escapes: false)]
        $0.tagKeywords = true
        $0.identifierParts = [unit("-"), unit(":")]
        $0.highlightsNumbers = false
    }

    static let css = Language("CSS/SCSS") {
        $0.lineComments = slashComments
        $0.blockComments = [cBlockComment]
        $0.strings = [doubleQuoted, singleQuoted]
        $0.keywords = words("!important important inherit initial unset none auto from to and not only")
        $0.directivePrefixes = [unit("@")]
        $0.identifierStarts = [unit("$")]
        $0.identifierParts = [unit("-")]
        // `url(http://x)` is not a comment.
        $0.lineCommentsAfterSpaceOnly = true
    }

    static let shell = Language("Shell") {
        $0.lineComments = [u("#")]
        $0.strings = [doubleQuoted, StringRule(open: u("'"), close: u("'"), escapes: false), StringRule(open: u("`"), close: u("`"))]
        $0.keywords = words("""
            if then else elif fi case esac for select while until do done in function time return exit break \
            continue local export readonly declare typeset unset shift source alias eval exec set trap echo \
            printf cd test true false
            """)
        $0.lineCommentsAfterSpaceOnly = true
        $0.identifierStarts = [unit("$")]
    }

    static let sql = Language("SQL") {
        $0.lineComments = [u("--")]
        $0.blockComments = [cBlockComment]
        $0.strings = [singleQuoted, doubleQuoted, StringRule(open: u("`"), close: u("`"), escapes: false)]
        $0.keywords = words("""
            select insert update delete from where join on and or not in between like ilike is null as order \
            by group having limit offset union intersect except all distinct into values set returning create \
            alter drop table index view database schema constraint primary key foreign references unique check \
            default cascade restrict truncate inner left right full outer cross natural exists any some case \
            when then else end begin commit rollback transaction with recursive over partition window asc desc \
            if replace true false using grant revoke
            """)
        $0.types = words("""
            integer int smallint bigint serial bigserial decimal numeric real double precision float varchar \
            char character text varying bytea blob boolean bool date time timestamp timestamptz interval uuid \
            json jsonb
            """)
        $0.caseInsensitive = true
    }

    static let java = Language("Java") {
        $0.lineComments = slashComments
        $0.blockComments = [cBlockComment]
        $0.strings = [tripleDouble, doubleQuoted, charLiteral]
        $0.keywords = words("""
            abstract assert break case catch class const continue default do else enum extends final finally \
            for goto if implements import instanceof interface native new package private protected public \
            record return sealed permits static strictfp super switch synchronized this throw throws transient \
            try var void volatile while yield true false null
            """)
        $0.types = words("boolean byte char short int long float double")
        $0.capitalizedTypes = true
        $0.directivePrefixes = [unit("@")]
    }

    static let kotlin = Language("Kotlin") {
        $0.lineComments = slashComments
        $0.blockComments = [BlockCommentRule(open: u("/*"), close: u("*/"), nests: true)]
        $0.strings = [tripleDouble, doubleQuoted, charLiteral]
        $0.keywords = words("""
            abstract actual annotation as break by catch class companion const constructor continue crossinline \
            data do else enum expect external false final finally for fun get if import in infix init inline \
            inner interface internal is lateinit noinline null object open operator out override package \
            private protected public reified return sealed set super suspend this throw true try typealias \
            val var vararg when where while
            """)
        $0.capitalizedTypes = true
        $0.directivePrefixes = [unit("@")]
    }

    static let cSharp = Language("C#") {
        $0.lineComments = slashComments
        $0.blockComments = [cBlockComment]
        $0.strings = [tripleDouble, doubleQuoted, charLiteral]
        $0.keywords = words("""
            abstract as async await base break case catch checked class const continue default delegate do \
            else enum event explicit extern false finally fixed for foreach get goto if implicit in init \
            interface internal is lock namespace new null operator out override params partial private \
            protected public readonly record ref return sealed set sizeof stackalloc static struct switch this \
            throw true try typeof unchecked unsafe using value var virtual void volatile when where while yield
            """)
        $0.types = words("""
            bool byte sbyte char decimal double float int uint long ulong short ushort object string dynamic \
            nint nuint
            """)
        $0.capitalizedTypes = true
        $0.directivePrefixes = [unit("#")]
    }

    static let php = Language("PHP") {
        $0.lineComments = [u("//"), u("#")]
        $0.blockComments = [cBlockComment]
        $0.strings = [doubleQuoted, singleQuoted]
        $0.keywords = words("""
            abstract and array as break callable case catch class clone const continue declare default do echo \
            else elseif empty enddeclare endfor endforeach endif endswitch endwhile enum extends final finally \
            fn for foreach function global goto if implements include include_once instanceof insteadof \
            interface isset list match namespace new or print private protected public readonly require \
            require_once return static switch throw trait try unset use var while xor yield true false null \
            self parent
            """)
        $0.types = words("int float bool string void mixed never iterable object")
        $0.capitalizedTypes = true
        $0.identifierStarts = [unit("$")]
    }

    static let dockerfile = Language("Dockerfile") {
        $0.lineComments = [u("#")]
        $0.strings = [doubleQuoted, singleQuoted]
        $0.keywords = words("""
            FROM RUN CMD LABEL MAINTAINER EXPOSE ENV ADD COPY ENTRYPOINT VOLUME USER WORKDIR ARG ONBUILD \
            STOPSIGNAL HEALTHCHECK SHELL AS as
            """)
        $0.identifierStarts = [unit("$")]
    }
}
