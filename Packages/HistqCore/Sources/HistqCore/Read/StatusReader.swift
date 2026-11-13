// Reads the working tree status (`git status --porcelain=v2 -z`): the branch header and one entry per
// changed, renamed, conflicted or untracked path. Paths are taken byte for byte (NUL-separated, never
// quoted), so names such as `-rf` or names with spaces come through unchanged.
import Foundation

public struct WorkingStatus: Sendable, Hashable {
    public struct Branch: Sendable, Hashable {
        /// The HEAD commit; nil on an unborn branch (`(initial)`).
        public let commit: String?
        /// The branch name; nil when HEAD is detached.
        public let name: String?
        /// The short upstream name, e.g. `origin/main`.
        public let upstream: String?
        /// Commits ahead of and behind the upstream; nil without one (or when it is gone).
        public let ahead: Int?
        public let behind: Int?

        public init(commit: String?, name: String?, upstream: String?, ahead: Int?, behind: Int?) {
            self.commit = commit
            self.name = name
            self.upstream = upstream
            self.ahead = ahead
            self.behind = behind
        }
    }

    public let branch: Branch
    /// In git's order.
    public let entries: [StatusEntry]

    public init(branch: Branch, entries: [StatusEntry]) {
        self.branch = branch
        self.entries = entries
    }

    public var conflicted: [StatusEntry] { entries.filter { $0.kind == .unmerged } }
    /// Entries with a change in the index (staged).
    public var staged: [StatusEntry] { entries.filter { $0.isStaged } }
    /// Tracked entries with a change in the working tree (unstaged), conflicts excluded.
    public var unstaged: [StatusEntry] { entries.filter { $0.isUnstaged } }
    public var untracked: [StatusEntry] { entries.filter { $0.kind == .untracked } }
}

public struct StatusEntry: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case ordinary
        /// Staged rename or copy (`git mv`, or detected in the index); `originalPath` is set.
        case renamed
        case copied
        /// A conflict; `index`/`worktree` hold git's two letters (`UU`, `AA`, `DU`, `UD`, `AU`, `UA`, `DD`).
        case unmerged
        case untracked
        case ignored
    }

    /// git's one-letter change code for one side of an entry.
    public enum Change: Character, Sendable, Hashable {
        case unmodified = "."
        case modified = "M"
        case typeChanged = "T"
        case added = "A"
        case deleted = "D"
        case renamed = "R"
        case copied = "C"
        case unmerged = "U"
    }

    public let kind: Kind
    public let path: String
    /// The path before a rename or copy.
    public let originalPath: String?
    /// The staged side (`X`). `.unmodified` for untracked and ignored entries.
    public let index: Change
    /// The working tree side (`Y`). `.unmodified` for untracked and ignored entries.
    public let worktree: Change
    /// A submodule (`S...` in git's `<sub>` field).
    public let isSubmodule: Bool
    /// The rename or copy score, e.g. `R100` → 100.
    public let similarity: Int?

    public init(
        kind: Kind, path: String, originalPath: String? = nil, index: Change = .unmodified,
        worktree: Change = .unmodified, isSubmodule: Bool = false, similarity: Int? = nil
    ) {
        self.kind = kind
        self.path = path
        self.originalPath = originalPath
        self.index = index
        self.worktree = worktree
        self.isSubmodule = isSubmodule
        self.similarity = similarity
    }

    /// Untracked and ignored entries are `.unmodified` on both sides, so neither is staged nor unstaged.
    public var isStaged: Bool { kind != .unmerged && index != .unmodified }
    public var isUnstaged: Bool { kind != .unmerged && worktree != .unmodified }
}

public enum StatusReader {
    /// `--ignore-submodules=dirty`: git never recurses into a submodule's working tree (whose config could
    /// name other filters); submodule commit changes still show.
    public static let arguments = [
        "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all", "--ignore-submodules=dirty",
    ]

    /// Reads the status of the worktree at `cwd`. `env` must be the read environment built by
    /// `GitInvocation.readEnvironment` for this `cwd`. Throws `GitError`.
    public static func read(runner: GitRunner, cwd: URL, env: [String: String]) async throws -> WorkingStatus {
        parse(try await runner.run(arguments, cwd: cwd, env: env).stdout)
    }

    static func parse(_ output: Data) -> WorkingStatus {
        var commit: String?
        var name: String?
        var upstream: String?
        var ahead: Int?
        var behind: Int?
        var entries: [StatusEntry] = []
        var fields = output.split(separator: 0, omittingEmptySubsequences: false).makeIterator()
        while let field = fields.next() {
            guard let type = field.first else { continue }
            switch type {
            case UInt8(ascii: "#"):
                let parts = text(field).split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count == 3 else { continue }
                switch parts[1] {
                case "branch.oid": commit = parts[2] == "(initial)" ? nil : parts[2]
                case "branch.head": name = parts[2] == "(detached)" ? nil : parts[2]
                case "branch.upstream": upstream = parts[2]
                case "branch.ab":
                    let counts = parts[2].split(separator: " ")
                    if counts.count == 2 {
                        ahead = Int(counts[0].dropFirst())
                        behind = Int(counts[1].dropFirst())
                    }
                default: break
                }
            case UInt8(ascii: "1"):
                // 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
                let parts = split(field, count: 9)
                guard parts.count == 9 else { continue }
                entries.append(entry(.ordinary, xy: parts[1], sub: parts[2], path: parts[8]))
            case UInt8(ascii: "2"):
                // 2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>, then <origPath> as the next field
                let parts = split(field, count: 10)
                let original = fields.next().map(text)
                guard parts.count == 10 else { continue }
                let score = parts[8]
                let kind: StatusEntry.Kind = score.first == UInt8(ascii: "C") ? .copied : .renamed
                entries.append(entry(
                    kind, xy: parts[1], sub: parts[2], path: parts[9], originalPath: original,
                    similarity: Int(text(score.dropFirst()))))
            case UInt8(ascii: "u"):
                // u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
                let parts = split(field, count: 11)
                guard parts.count == 11 else { continue }
                entries.append(entry(.unmerged, xy: parts[1], sub: parts[2], path: parts[10]))
            case UInt8(ascii: "?"), UInt8(ascii: "!"):
                guard field.count > 2 else { continue }
                entries.append(StatusEntry(
                    kind: type == UInt8(ascii: "?") ? .untracked : .ignored, path: text(field.dropFirst(2))))
            default:
                continue
            }
        }
        let branch = WorkingStatus.Branch(commit: commit, name: name, upstream: upstream, ahead: ahead, behind: behind)
        return WorkingStatus(branch: branch, entries: entries)
    }

    private static func entry(
        _ kind: StatusEntry.Kind, xy: Data.SubSequence, sub: Data.SubSequence, path: Data.SubSequence,
        originalPath: String? = nil, similarity: Int? = nil
    ) -> StatusEntry {
        let codes = Array(xy)
        let change = { (index: Int) -> StatusEntry.Change in
            codes.count == 2 ? StatusEntry.Change(rawValue: Character(UnicodeScalar(codes[index]))) ?? .unmodified
                : .unmodified
        }
        return StatusEntry(
            kind: kind, path: text(path), originalPath: originalPath, index: change(0), worktree: change(1),
            isSubmodule: sub.first == UInt8(ascii: "S"), similarity: similarity)
    }

    /// Splits a record on spaces into at most `count` parts; the last part (the path) keeps its spaces.
    private static func split(_ field: Data.SubSequence, count: Int) -> [Data.SubSequence] {
        field.split(separator: UInt8(ascii: " "), maxSplits: count - 1, omittingEmptySubsequences: false)
    }

    private static func text(_ bytes: Data.SubSequence) -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}
