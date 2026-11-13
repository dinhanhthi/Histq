// Loads one conflicted path for the conflict editor: which index stages exist (`git ls-files -u`), their
// bytes (`:1` base, `:2` A, `:3` B) and the A/B labels the caller supplies (RepoState knows them, swapped
// during a rebase). Both sides present gives a text merge (add/add has no base) unless a stage holds a NUL
// byte (binary: a take A / take B chooser); a side missing gives the keep/delete chooser.
import Foundation

/// The names shown on panes A and B (e.g. a branch name; during a rebase A = upstream, B = the commit
/// being replayed).
public struct ConflictLabels: Sendable, Hashable {
    public var a: String
    public var b: String

    public init(a: String, b: String) {
        self.a = a
        self.b = b
    }
}

public enum ConflictSourceError: Error, Equatable, Sendable {
    /// The path has no unmerged index entries.
    case notConflicted(path: String)
}

public struct ConflictSource: Sendable, Hashable {
    public enum Content: Sendable, Hashable {
        /// Both sides have the file (UU, or AA with `base` nil): the 3-way editor.
        case text(base: Data?, a: Data, b: Data)
        /// Both sides have the file but a stage contains a NUL byte (treated as binary): no line merge, a
        /// take A / take B chooser.
        case binary(base: Data?, a: Data, b: Data)
        /// At least one side deleted the file (UD, DU, AU, UA, DD): a keep/delete chooser. nil = absent
        /// on that side.
        case modifyDelete(base: Data?, a: Data?, b: Data?)
    }

    /// Root-relative path.
    public let path: String
    public let labels: ConflictLabels
    public let content: Content

    public init(path: String, labels: ConflictLabels, content: Content) {
        self.path = path
        self.labels = labels
        self.content = content
    }

    /// The 3-way merge for a text conflict; nil for binary and modify/delete.
    public func merge() -> ThreeWayMerge? {
        guard case .text(let base, let a, let b) = content else { return nil }
        return ThreeWayMerge(base: base, a: a, b: b)
    }

    /// Reads the stages of `path` (root-relative). `env` must be the read environment for `cwd`.
    public static func load(
        path: String, labels: ConflictLabels, runner: GitRunner, cwd: URL, env: [String: String]
    ) async throws -> ConflictSource {
        let result = try await runner.run(stagesArguments(path: path), cwd: cwd, env: env)
        let stages = parseStages(result.stdout, path: path)
        guard !stages.isEmpty else { throw ConflictSourceError.notConflicted(path: path) }
        func blob(_ stage: Int) async throws -> Data? {
            guard stages.contains(stage) else { return nil }
            return try await DiffReader.file(at: ":\(stage)", path: path, runner: runner, cwd: cwd, env: env)
        }
        let base = try await blob(1)
        let a = try await blob(2)
        let b = try await blob(3)
        if let a, let b {
            let isBinary = [base, a, b].contains { $0?.contains(0) == true }
            let content: Content = isBinary ? .binary(base: base, a: a, b: b) : .text(base: base, a: a, b: b)
            return ConflictSource(path: path, labels: labels, content: content)
        }
        return ConflictSource(path: path, labels: labels, content: .modifyDelete(base: base, a: a, b: b))
    }

    static func stagesArguments(path: String) -> [String] {
        ["--literal-pathspecs", "ls-files", "-u", "-z", "--", path]
    }

    /// The stage numbers of `path` in `ls-files -u -z` output (`<mode> <object> <stage>\t<path>\0`).
    static func parseStages(_ data: Data, path: String) -> Set<Int> {
        var stages = Set<Int>()
        for record in data.split(separator: 0) {
            guard let tab = record.firstIndex(of: 0x09),
                record[(tab + 1)...].elementsEqual(path.utf8), // bytes: a directory pathspec also lists its files
                let stage = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ").last.flatMap({ Int($0) })
            else { continue }
            stages.insert(stage)
        }
        return stages
    }
}
