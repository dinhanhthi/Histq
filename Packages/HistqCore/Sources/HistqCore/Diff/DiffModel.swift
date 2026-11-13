// The diff model and its loaders: unified diffs (`git diff`, `git diff --cached`, `git diff-tree`)
// parsed into files, hunks and lines, plus a file's bytes at a revision (`git show`).
//
// Output is parsed as bytes: a line keeps its exact bytes (CR, non-UTF-8 text) so PatchBuilder can replay
// it, and header paths are C-unquoted byte for byte (git always quotes control bytes, `"` and `\`, and
// bytes >= 0x80 unless the repo sets `core.quotePath=false`, which leaves them raw; both forms parse). Hunk bodies are consumed by their `@@` line counts, so a removed line
// that reads `-- a/x` can never pass for a file header. The output format is pinned on the command line
// (no color, `a/` and `b/` prefixes, no relative paths, rename detection, literal pathspecs) because the
// repo's config could change it, and every loader passes `--no-ext-diff --no-textconv`, so a repo-configured
// `diff.external` or `diff.<driver>.textconv` never runs (the read environment disables them too and a
// read without these flags fails closed).
import Foundation

/// One line of a hunk.
public struct DiffLine: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case context
        case added
        case removed
    }

    public let kind: Kind
    /// The line's bytes as in the file, without the prefix column(s) and without the `\n`.
    public let content: Data
    /// The line number in the old file (the first parent for a combined diff); nil for an added line.
    public let oldLine: Int?
    /// The line number in the new file; nil for a removed line.
    public let newLine: Int?
    /// git printed `\ No newline at end of file` after this line.
    public internal(set) var noNewlineAtEnd: Bool
    /// The prefix columns of a combined (`--cc`) diff, one per parent (e.g. `"+ "`); nil in a two-way diff.
    public let combinedMarkers: String?

    public init(
        kind: Kind, content: Data, oldLine: Int?, newLine: Int?, noNewlineAtEnd: Bool = false,
        combinedMarkers: String? = nil
    ) {
        self.kind = kind
        self.content = content
        self.oldLine = oldLine
        self.newLine = newLine
        self.noNewlineAtEnd = noNewlineAtEnd
        self.combinedMarkers = combinedMarkers
    }

    /// `content` decoded as UTF-8 (invalid bytes replaced), for display.
    public var text: String { String(decoding: content, as: UTF8.self) }
    public var isChange: Bool { kind != .context }
}

/// One `@@ -oldStart,oldCount +newStart,newCount @@ section` hunk. For a combined diff the old range is
/// the first parent's.
public struct DiffHunk: Sendable, Hashable {
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    /// The text git printed after the closing `@@` (usually the enclosing function), without the space.
    public let section: String
    public let lines: [DiffLine]

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String, lines: [DiffLine]) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.section = section
        self.lines = lines
    }
}

/// A line of a `FileDiff`: its hunk index and its index in that hunk's `lines`.
public struct DiffLineID: Sendable, Hashable, Comparable {
    public let hunk: Int
    public let line: Int

    public init(hunk: Int, line: Int) {
        self.hunk = hunk
        self.line = line
    }

    public static func < (lhs: DiffLineID, rhs: DiffLineID) -> Bool {
        (lhs.hunk, lhs.line) < (rhs.hunk, rhs.line)
    }
}

/// The diff of one file.
public struct FileDiff: Sendable, Hashable {
    public enum Change: Sendable, Hashable {
        case added
        case deleted
        case modified
        case renamed
        case copied
    }

    public let change: Change
    /// The path before the change, relative to the repository root; nil for an added file.
    public let oldPath: String?
    /// The path after the change; nil for a deleted file.
    public let newPath: String?
    /// Octal modes such as `100644`, when git printed them (a mode change, an added or a deleted file).
    public let oldMode: String?
    public let newMode: String?
    /// The rename or copy score in percent.
    public let similarity: Int?
    /// git printed `Binary files ... differ` (or a binary patch): there are no hunks.
    public let isBinary: Bool
    /// A combined diff of a merge (`--cc`): read-only, PatchBuilder refuses it.
    public let isCombined: Bool
    public let hunks: [DiffHunk]
    /// The raw header lines, `diff ...` through `+++ ...`, as git printed them.
    let headerLines: [Data]
    /// The unquoted path bytes (exact, even when they are not UTF-8).
    let oldPathBytes: Data?
    let newPathBytes: Data?

    init(
        change: Change, oldPath: Data?, newPath: Data?, oldMode: String?, newMode: String?, similarity: Int?,
        isBinary: Bool, isCombined: Bool, hunks: [DiffHunk], headerLines: [Data]
    ) {
        self.change = change
        oldPathBytes = oldPath
        newPathBytes = newPath
        self.oldPath = oldPath.map { String(decoding: $0, as: UTF8.self) }
        self.newPath = newPath.map { String(decoding: $0, as: UTF8.self) }
        self.oldMode = oldMode
        self.newMode = newMode
        self.similarity = similarity
        self.isBinary = isBinary
        self.isCombined = isCombined
        self.hunks = hunks
        self.headerLines = headerLines
    }

    /// The path to show: the new path, or the old one for a deleted file.
    public var path: String { newPath ?? oldPath ?? "" }
    public var isModeChange: Bool { oldMode != nil && newMode != nil && oldMode != newMode }
    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .added } } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .removed } } }

    /// The added and removed lines of hunk `hunk` (selecting them all stages or unstages the hunk).
    public func changedLineIDs(inHunk hunk: Int) -> [DiffLineID] {
        hunks[hunk].lines.indices.filter { hunks[hunk].lines[$0].isChange }.map { DiffLineID(hunk: hunk, line: $0) }
    }

    /// Every added and removed line of the file, in order.
    public var changedLineIDs: [DiffLineID] { hunks.indices.flatMap { changedLineIDs(inHunk: $0) } }
}

/// A read hit an object that is not in the repository. Reads block every transport, so a legitimate
/// partial clone (`--filter=blob:none`) cannot fetch it lazily: the UI offers the fetch as a user action,
/// run with the write environment (e.g. `git fetch` from the promisor remote).
public enum DiffReadError: Error, Equatable, Sendable {
    case missingObjects(stderrTail: String)
}

public enum DiffReader {
    /// The working tree against the index (unstaged changes). `env` must be the read environment built by
    /// `GitInvocation.readEnvironment` for this `cwd`; `paths` limits the diff (literal, root-relative);
    /// `context` sets the context lines (git's default 3 when nil; at least 1, since git apply misplaces a
    /// context-free hunk; a huge value gives the full file).
    /// Throws `GitError`, or `DiffReadError.missingObjects` on a partial clone.
    public static func unstaged(
        runner: GitRunner, cwd: URL, env: [String: String], paths: [String] = [], context: Int? = nil
    ) async throws -> [FileDiff] {
        try await load(unstagedArguments(paths: paths, context: context), runner: runner, cwd: cwd, env: env)
    }

    /// The index against HEAD (staged changes; against the empty tree on an unborn branch).
    public static func staged(
        runner: GitRunner, cwd: URL, env: [String: String], paths: [String] = [], context: Int? = nil
    ) async throws -> [FileDiff] {
        try await load(stagedArguments(paths: paths, context: context), runner: runner, cwd: cwd, env: env)
    }

    /// A commit against its first parent (a root commit against the empty tree). A merge commit (and a stash)
    /// is diffed against its first parent too (`--diff-merges=first-parent`), so its files match the commit's
    /// file list: a combined diff (`--cc`) would drop every file the merge took from one side without edits.
    public static func commit(
        _ revision: String, runner: GitRunner, cwd: URL, env: [String: String], paths: [String] = [],
        context: Int? = nil
    ) async throws -> [FileDiff] {
        try await load(
            commitArguments(revision, paths: paths, context: context), runner: runner, cwd: cwd, env: env)
    }

    /// The bytes of `path` (root-relative) at `revision`: a commit-ish such as a hash or `HEAD`, `""` for
    /// the index, or `":2"`/`":3"` for a conflict stage. Content is raw (no textconv, no filters).
    public static func file(
        at revision: String, path: String, runner: GitRunner, cwd: URL, env: [String: String]
    ) async throws -> Data {
        try await run(fileArguments(at: revision, path: path), runner: runner, cwd: cwd, env: env).stdout
    }

    // MARK: Arguments

    /// Pins the output format against the repo's config (`color.*`, `diff.noprefix`, `diff.mnemonicPrefix`,
    /// `diff.relative`, `diff.renames`).
    static let formatOptions = [
        "--no-color", "--no-ext-diff", "--no-textconv", "--src-prefix=a/", "--dst-prefix=b/", "--no-relative", "-M",
    ]

    static func unstagedArguments(paths: [String], context: Int?) -> [String] {
        ["--literal-pathspecs", "diff"] + formatOptions + contextOption(context) + ["--ignore-submodules=dirty", "--"]
            + paths
    }

    static func stagedArguments(paths: [String], context: Int?) -> [String] {
        ["--literal-pathspecs", "diff", "--cached"] + formatOptions + contextOption(context)
            + ["--ignore-submodules=dirty", "--"] + paths
    }

    static func commitArguments(_ revision: String, paths: [String], context: Int?) -> [String] {
        // `-m --first-parent` would not do: diff-tree ignores `--first-parent` and prints every parent's diff.
        ["--literal-pathspecs", "diff-tree", "-r", "-p", "--root", "--diff-merges=first-parent", "--no-commit-id"]
            + formatOptions
            + contextOption(context) + ["--end-of-options", revision, "--"] + paths
    }

    static func fileArguments(at revision: String, path: String) -> [String] {
        // `:0:<path>` for the index: `:<path>` would read a file named `2:notes.txt` as stage 2 of `notes.txt`.
        ["show", "--no-ext-diff", "--no-textconv", "--end-of-options", "\(revision.isEmpty ? ":0" : revision):\(path)"]
    }

    private static func contextOption(_ context: Int?) -> [String] {
        context.map { ["-U\(max(1, $0))"] } ?? []
    }

    // MARK: Running

    private static func load(_ args: [String], runner: GitRunner, cwd: URL, env: [String: String]) async throws
        -> [FileDiff]
    {
        parse(try await run(args, runner: runner, cwd: cwd, env: env).stdout)
    }

    /// Runs a read and turns a missing-object failure on a partial clone into `DiffReadError.missingObjects`.
    private static func run(_ args: [String], runner: GitRunner, cwd: URL, env: [String: String]) async throws
        -> GitResult
    {
        do {
            return try await runner.run(args, cwd: cwd, env: env)
        } catch let error as GitError {
            let tail = error.stderrTail
            let lower = tail.lowercased()
            if lower.contains("lazy fetching disabled") || lower.contains("promisor remote") {
                throw DiffReadError.missingObjects(stderrTail: tail)
            }
            // `git show` under GIT_NO_LAZY_FETCH only says `bad object <rev>:<path>`; a fetch can only help
            // when the repo has a promisor remote (otherwise it is corrupt, not partial).
            if lower.contains("bad object") || lower.contains("missing blob") || lower.contains("unable to read"),
               (try? await isPartialClone(runner: runner, cwd: cwd, env: env)) == true
            {
                throw DiffReadError.missingObjects(stderrTail: tail)
            }
            throw error
        }
    }

    private static func isPartialClone(runner: GitRunner, cwd: URL, env: [String: String]) async throws -> Bool {
        let result = try await runner.run(
            ["config", "--name-only", "--get-regexp", "^(remote\\..+\\.promisor|extensions\\.partialclone)$"],
            cwd: cwd, env: env, timeout: .seconds(10), allowedExitCodes: [0, 1])
        return result.exitCode == 0
    }

    // MARK: Parsing

    /// Parses `git diff`/`git diff-tree -p`/`--cc` output.
    static func parse(_ output: Data) -> [FileDiff] {
        var lines = output.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        var files: [FileDiff] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.starts(with: Bytes.diffGit) || line.starts(with: Bytes.diffCC)
                || line.starts(with: Bytes.diffCombined)
            {
                files.append(parseFile(lines, &index))
            } else {
                index += 1
            }
        }
        return files
    }

    private enum Bytes {
        static let diffGit = Array("diff --git ".utf8)
        static let diffCC = Array("diff --cc ".utf8)
        static let diffCombined = Array("diff --combined ".utf8)
        static let hunk = Array("@@".utf8)
        static let binaryFiles = Array("Binary files ".utf8)
        static let binaryPatch = Array("GIT binary patch".utf8)
        static let diff = Array("diff ".utf8)
    }

    /// Parses one file starting at its `diff ...` line and leaves `index` on the line after it.
    private static func parseFile(_ lines: [Data.SubSequence], _ index: inout Int) -> FileDiff {
        let first = lines[index]
        let isCombined = !first.starts(with: Bytes.diffGit)
        var header = [Data(first)]
        index += 1

        var headerOld: Data?
        var headerNew: Data?
        if isCombined {
            let prefix = first.starts(with: Bytes.diffCC) ? Bytes.diffCC.count : Bytes.diffCombined.count
            headerNew = PathQuoting.name(first.dropFirst(prefix))
            headerOld = headerNew
        } else if let names = PathQuoting.gitHeaderNames(first.dropFirst(Bytes.diffGit.count)) {
            (headerOld, headerNew) = names
        }

        var change = FileDiff.Change.modified
        var oldMode: String?
        var newMode: String?
        var similarity: Int?
        var minusName: Data?
        var plusName: Data?
        var renameFrom: Data?
        var renameTo: Data?
        var isBinary = false

        while index < lines.count {
            let line = lines[index]
            if line.starts(with: Bytes.hunk) || line.starts(with: Bytes.diff) { break }
            if line.starts(with: Bytes.binaryFiles) || line.starts(with: Bytes.binaryPatch) {
                isBinary = true
                index += 1
                // Skip a binary patch's base85 body up to the next file.
                while index < lines.count, !lines[index].starts(with: Bytes.diff) { index += 1 }
                break
            }
            header.append(Data(line))
            index += 1
            let text = String(decoding: line, as: UTF8.self)
            func rest(_ key: String) -> Data.SubSequence? {
                line.starts(with: Array(key.utf8)) ? line.dropFirst(key.utf8.count) : nil
            }
            if let value = rest("old mode ") {
                oldMode = String(decoding: value, as: UTF8.self)
            } else if let value = rest("new mode ") {
                newMode = String(decoding: value, as: UTF8.self)
            } else if let value = rest("new file mode ") {
                change = .added
                newMode = String(decoding: value, as: UTF8.self)
            } else if let value = rest("deleted file mode ") {
                change = .deleted
                oldMode = String(decoding: value, as: UTF8.self)
            } else if let value = rest("rename from ") ?? rest("copy from ") {
                change = text.hasPrefix("rename") ? .renamed : .copied
                renameFrom = PathQuoting.name(value)
            } else if let value = rest("rename to ") ?? rest("copy to ") {
                renameTo = PathQuoting.name(value)
            } else if let value = rest("similarity index ") {
                similarity = Int(String(decoding: value, as: UTF8.self).trimmingCharacters(in: ["%"]))
            } else if let value = rest("--- ") {
                minusName = PathQuoting.patchName(value, prefix: "a/")
            } else if let value = rest("+++ ") {
                plusName = PathQuoting.patchName(value, prefix: "b/")
            }
        }

        var hunks: [DiffHunk] = []
        while !isBinary, index < lines.count, lines[index].starts(with: Bytes.hunk) {
            let parsed = isCombined ? parseCombinedHunk(lines, &index) : parseHunk(lines, &index)
            guard let parsed else { break }
            hunks.append(parsed)
        }

        // Paths: rename/copy lines, then `---`/`+++`, then the `diff` line (mode-only, binary, empty files).
        var oldPath = renameFrom ?? minusName ?? headerOld
        var newPath = renameTo ?? plusName ?? headerNew
        if isCombined {
            oldPath = headerOld
            newPath = headerNew
        }
        if change == .added { oldPath = nil }
        if change == .deleted { newPath = nil }
        return FileDiff(
            change: change, oldPath: oldPath, newPath: newPath, oldMode: oldMode, newMode: newMode,
            similarity: similarity, isBinary: isBinary, isCombined: isCombined, hunks: hunks, headerLines: header)
    }

    /// A two-way hunk, read by its line counts. An empty line inside the body is a blank context line
    /// (`diff.suppressBlankEmpty`); `\` lines mark the previous line as having no final newline.
    private static func parseHunk(_ lines: [Data.SubSequence], _ index: inout Int) -> DiffHunk? {
        guard let head = HunkHeader(lines[index], parents: 1) else { return nil }
        index += 1
        let old = head.ranges[0]
        let new = head.ranges[1]
        var remainingOld = old.count
        var remainingNew = new.count
        var oldLine = old.start
        var newLine = new.start
        var body: [DiffLine] = []
        while index < lines.count {
            let line = lines[index]
            let prefix = line.first
            if prefix == UInt8(ascii: "\\") {
                if !body.isEmpty { body[body.count - 1].noNewlineAtEnd = true }
                index += 1
                continue
            }
            guard remainingOld > 0 || remainingNew > 0 else { break }
            let content = Data(line.dropFirst())
            switch prefix {
            case UInt8(ascii: " "), nil:
                guard remainingOld > 0, remainingNew > 0 else { return finish() }
                body.append(DiffLine(kind: .context, content: content, oldLine: oldLine, newLine: newLine))
                oldLine += 1
                newLine += 1
                remainingOld -= 1
                remainingNew -= 1
            case UInt8(ascii: "-"):
                guard remainingOld > 0 else { return finish() }
                body.append(DiffLine(kind: .removed, content: content, oldLine: oldLine, newLine: nil))
                oldLine += 1
                remainingOld -= 1
            case UInt8(ascii: "+"):
                guard remainingNew > 0 else { return finish() }
                body.append(DiffLine(kind: .added, content: content, oldLine: nil, newLine: newLine))
                newLine += 1
                remainingNew -= 1
            default:
                return finish()
            }
            index += 1
        }
        return finish()

        func finish() -> DiffHunk {
            DiffHunk(
                oldStart: old.start, oldCount: old.count, newStart: new.start, newCount: new.count,
                section: head.section, lines: body)
        }
    }

    /// A combined hunk (`@@@ -a,b -c,d +e,f @@@`): one prefix column per parent. The body ends at the first
    /// line that does not start with a prefix column (the next hunk or file, whose lines start with `@`
    /// or `d`). The kind is `.removed` when any column is `-`, `.added` when any is `+`.
    private static func parseCombinedHunk(_ lines: [Data.SubSequence], _ index: inout Int) -> DiffHunk? {
        let atCount = lines[index].prefix { $0 == UInt8(ascii: "@") }.count
        guard atCount >= 3, let head = HunkHeader(lines[index], parents: atCount - 1) else { return nil }
        index += 1
        let parents = atCount - 1
        var oldLine = head.ranges[0].start
        var newLine = head.ranges[parents].start
        var body: [DiffLine] = []
        let columns: Set<UInt8> = [UInt8(ascii: " "), UInt8(ascii: "+"), UInt8(ascii: "-")]
        while index < lines.count {
            let line = lines[index]
            if line.first == UInt8(ascii: "\\") {
                if !body.isEmpty { body[body.count - 1].noNewlineAtEnd = true }
                index += 1
                continue
            }
            guard line.count >= parents, line.prefix(parents).allSatisfy(columns.contains) else { break }
            let markers = Array(line.prefix(parents))
            let content = Data(line.dropFirst(parents))
            let removed = markers.contains(UInt8(ascii: "-"))
            let kind: DiffLine.Kind = removed ? .removed : markers.contains(UInt8(ascii: "+")) ? .added : .context
            // In the first parent: a `-` in its column, or a line of the result its column does not add.
            let inFirstParent = markers[0] == UInt8(ascii: "-") || (!removed && markers[0] == UInt8(ascii: " "))
            body.append(DiffLine(
                kind: kind, content: content, oldLine: inFirstParent ? oldLine : nil,
                newLine: removed ? nil : newLine, combinedMarkers: String(decoding: markers, as: UTF8.self)))
            if inFirstParent { oldLine += 1 }
            if !removed { newLine += 1 }
            index += 1
        }
        let old = head.ranges[0]
        let new = head.ranges[parents]
        return DiffHunk(
            oldStart: old.start, oldCount: old.count, newStart: new.start, newCount: new.count,
            section: head.section, lines: body)
    }
}

/// `@@ -1,3 +1,4 @@ section` (or `@@@ -1,3 -1,3 +1,4 @@@` with `parents` old ranges).
private struct HunkHeader {
    var ranges: [(start: Int, count: Int)] = []
    var section = ""

    init?(_ line: Data.SubSequence, parents: Int) {
        let marker = String(repeating: "@", count: parents + 1)
        let text = String(decoding: line, as: UTF8.self)
        guard text.hasPrefix(marker + " ") else { return nil }
        let afterOpen = text.dropFirst(marker.count + 1)
        guard let close = afterOpen.range(of: " " + marker) else { return nil }
        let fields = afterOpen[..<close.lowerBound].split(separator: " ")
        guard fields.count == parents + 1 else { return nil }
        for (position, field) in fields.enumerated() {
            let sign: Character = position < parents ? "-" : "+"
            guard field.first == sign else { return nil }
            let parts = field.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard let start = parts.first.flatMap({ Int($0) }) else { return nil }
            let count = parts.count > 1 ? Int(parts[1]) : 1
            guard let count else { return nil }
            ranges.append((start, count))
        }
        let rest = afterOpen[close.upperBound...]
        section = rest.hasPrefix(" ") ? String(rest.dropFirst()) : String(rest)
    }
}

/// git's C-style path quoting (`quote_c_style`), on bytes.
enum PathQuoting {
    /// A header name as printed after `rename from`, `diff --cc`, ...: unquoted when it starts with `"`.
    static func name(_ bytes: Data.SubSequence) -> Data {
        if bytes.first == UInt8(ascii: "\""), let (name, end) = unquote(bytes), end == bytes.endIndex {
            return name
        }
        return Data(bytes)
    }

    /// A `---`/`+++` name: nil for `/dev/null`, else unquoted, without the `a/`/`b/` prefix and without the
    /// TAB git appends to a name (quoted or not) that contains a space. A raw TAB is never part of a name:
    /// a name with a TAB is quoted.
    static func patchName(_ bytes: Data.SubSequence, prefix: String) -> Data? {
        var raw = bytes
        if raw.last == UInt8(ascii: "\t") { raw = raw.dropLast() }
        if raw.elementsEqual("/dev/null".utf8) { return nil }
        return stripPrefix(name(raw), prefix)
    }

    /// The two names of `diff --git <a> <b>` (after `diff --git `), without their prefixes. Unquoted names
    /// with spaces are split where both halves are the same path (as git apply does); nil when ambiguous.
    static func gitHeaderNames(_ rest: Data.SubSequence) -> (Data, Data)? {
        if rest.first == UInt8(ascii: "\"") {
            guard let (a, end) = unquote(rest), end < rest.endIndex, rest[end] == UInt8(ascii: " ") else {
                return nil
            }
            return (stripPrefix(a, "a/"), stripPrefix(name(rest[(end + 1)...]), "b/"))
        }
        // An unquoted a-name never contains `"`, so ` "` starts a quoted b-name.
        let bytes = Array(rest)
        if let split = (0..<max(0, bytes.count - 1)).first(where: {
            bytes[$0] == UInt8(ascii: " ") && bytes[$0 + 1] == UInt8(ascii: "\"")
        }) {
            let a = Data(bytes[..<split])
            return (stripPrefix(a, "a/"), stripPrefix(name(rest.dropFirst(split + 1)), "b/"))
        }
        // `a/X b/X`: X has (count - 5) / 2 bytes.
        guard bytes.count >= 5, (bytes.count - 5) % 2 == 0 else { return nil }
        let length = (bytes.count - 5) / 2
        let a = bytes[2..<(2 + length)]
        let b = bytes[(5 + length)...]
        guard bytes.starts(with: "a/".utf8), bytes[2 + length] == UInt8(ascii: " "),
              bytes[(3 + length)..<(5 + length)].elementsEqual("b/".utf8), a.elementsEqual(b)
        else { return nil }
        return (Data(a), Data(b))
    }

    /// Unquotes a C-quoted string starting at `bytes.startIndex` (a `"`). Returns the bytes and the index
    /// after the closing quote.
    static func unquote(_ bytes: Data.SubSequence) -> (Data, Data.Index)? {
        var output = Data()
        var index = bytes.index(after: bytes.startIndex)
        while index < bytes.endIndex {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") { return (output, bytes.index(after: index)) }
            guard byte == UInt8(ascii: "\\") else {
                output.append(byte)
                index += 1
                continue
            }
            index += 1
            guard index < bytes.endIndex else { return nil }
            let escaped = bytes[index]
            switch escaped {
            case UInt8(ascii: "a"): output.append(0x07)
            case UInt8(ascii: "b"): output.append(0x08)
            case UInt8(ascii: "t"): output.append(0x09)
            case UInt8(ascii: "n"): output.append(0x0A)
            case UInt8(ascii: "v"): output.append(0x0B)
            case UInt8(ascii: "f"): output.append(0x0C)
            case UInt8(ascii: "r"): output.append(0x0D)
            case UInt8(ascii: "0")...UInt8(ascii: "3"):
                guard index + 2 < bytes.endIndex else { return nil }
                let digits = [escaped, bytes[index + 1], bytes[index + 2]]
                guard digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "7")).contains($0) }) else { return nil }
                output.append(digits.reduce(0) { $0 * 8 + ($1 - UInt8(ascii: "0")) })
                index += 2
            default: output.append(escaped)
            }
            index += 1
        }
        return nil
    }

    /// `prefix` + `path`, C-quoted as git prints it when the path needs it (control bytes, `"`, `\`, DEL,
    /// bytes >= 0x80).
    static func quoted(_ path: Data, prefix: String) -> Data {
        let bytes = Data(prefix.utf8) + path
        guard bytes.contains(where: { $0 < 0x20 || $0 == UInt8(ascii: "\"") || $0 == UInt8(ascii: "\\") || $0 >= 0x7F })
        else { return bytes }
        var output = Data([UInt8(ascii: "\"")])
        for byte in bytes {
            switch byte {
            case 0x07: output.append(contentsOf: Array("\\a".utf8))
            case 0x08: output.append(contentsOf: Array("\\b".utf8))
            case 0x09: output.append(contentsOf: Array("\\t".utf8))
            case 0x0A: output.append(contentsOf: Array("\\n".utf8))
            case 0x0B: output.append(contentsOf: Array("\\v".utf8))
            case 0x0C: output.append(contentsOf: Array("\\f".utf8))
            case 0x0D: output.append(contentsOf: Array("\\r".utf8))
            case UInt8(ascii: "\""), UInt8(ascii: "\\"): output.append(contentsOf: [UInt8(ascii: "\\"), byte])
            case _ where byte < 0x20 || byte >= 0x7F:
                let octal = String(byte, radix: 8)
                output.append(contentsOf: Array(("\\" + String(repeating: "0", count: 3 - octal.count) + octal).utf8))
            default: output.append(byte)
            }
        }
        output.append(UInt8(ascii: "\""))
        return output
    }

    private static func stripPrefix(_ name: Data, _ prefix: String) -> Data {
        name.starts(with: prefix.utf8) ? Data(name.dropFirst(prefix.utf8.count)) : name
    }
}
