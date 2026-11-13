// What the repository is in the middle of (a stopped merge, rebase, cherry-pick or revert), its conflicted
// paths and the names of the conflict editor's A and B panes. During a rebase git replays the branch's
// commits on top of the upstream, so stage :2 ("ours", pane A) is the upstream and stage :3 ("theirs",
// pane B) is the commit being replayed: the labels follow the stages, not the checked-out branch.
import Foundation

public struct RepoState: Sendable, Equatable {
    public enum Operation: Sendable, Equatable {
        case none, merge, rebase, cherryPick, revert
    }

    public let operation: Operation
    /// Root-relative paths with unmerged index entries, in index order (also set after a conflicting
    /// `stash pop`/`apply`, where `operation` is `.none`).
    public let conflictedPaths: [String]
    /// Pane A = stage :2, pane B = stage :3. Merge: the current branch / the merged ref. Rebase: the
    /// upstream (`onto`) / the commit being replayed. Cherry-pick and revert: the current branch / the
    /// picked (reverted) commit. No operation: the current branch / "Incoming".
    public let labels: ConflictLabels

    public init(operation: Operation, conflictedPaths: [String], labels: ConflictLabels) {
        self.operation = operation
        self.conflictedPaths = conflictedPaths
        self.labels = labels
    }

    public var isOperationInProgress: Bool { operation != .none }

    /// Reads the state of the worktree at `cwd`. `env` must be the read environment for `cwd`.
    public static func read(runner: GitRunner, cwd: URL, env: [String: String]) async throws -> RepoState {
        let names = ["MERGE_HEAD", "rebase-merge", "rebase-apply", "CHERRY_PICK_HEAD", "REVERT_HEAD"]
        // Per-worktree paths (`.git` is a file in a linked worktree), absolute.
        let pathsResult = try await runner.run(
            ["rev-parse", "--path-format=absolute"] + names.flatMap { ["--git-path", $0] }, cwd: cwd, env: env)
        let paths = pathsResult.text.split(separator: "\n").map { URL(filePath: String($0)) }
        guard paths.count == names.count else {
            throw GitError.other(exit: 0, stderrTail: "unexpected rev-parse --git-path output")
        }
        let mergeHead = paths[0], rebaseMerge = paths[1], rebaseApply = paths[2]
        let cherryPickHead = paths[3], revertHead = paths[4]
        let fm = FileManager.default

        let conflicted = try await conflictedPaths(runner: runner, cwd: cwd, env: env)
        let head = try await headLabel(runner: runner, cwd: cwd, env: env)

        // A rebase may leave REBASE_HEAD/MERGE_MSG next to its folder: check it first.
        if fm.fileExists(atPath: rebaseMerge.path)
            || (fm.fileExists(atPath: rebaseApply.path)
                && !fm.fileExists(atPath: rebaseApply.appending(path: "applying").path))
        {
            let folder = fm.fileExists(atPath: rebaseMerge.path) ? rebaseMerge : rebaseApply
            let onto = firstLine(folder.appending(path: "onto"))
            let replayed = firstLine(folder.appending(path: "stopped-sha"))
                ?? firstLine(folder.deletingLastPathComponent().appending(path: "REBASE_HEAD"))
            let a = try await refLabel(onto, runner: runner, cwd: cwd, env: env) ?? "upstream"
            let b = try await commitLabel(replayed, runner: runner, cwd: cwd, env: env) ?? "commit being replayed"
            return RepoState(operation: .rebase, conflictedPaths: conflicted, labels: ConflictLabels(a: a, b: b))
        }
        if let merged = firstLine(mergeHead) {
            let b = try await refLabel(merged, runner: runner, cwd: cwd, env: env) ?? "MERGE_HEAD"
            return RepoState(operation: .merge, conflictedPaths: conflicted, labels: ConflictLabels(a: head, b: b))
        }
        if let picked = firstLine(cherryPickHead) {
            let b = try await commitLabel(picked, runner: runner, cwd: cwd, env: env) ?? "CHERRY_PICK_HEAD"
            return RepoState(
                operation: .cherryPick, conflictedPaths: conflicted, labels: ConflictLabels(a: head, b: b))
        }
        if let reverted = firstLine(revertHead) {
            let b = try await commitLabel(reverted, runner: runner, cwd: cwd, env: env).map { "Revert \($0)" }
                ?? "REVERT_HEAD"
            return RepoState(operation: .revert, conflictedPaths: conflicted, labels: ConflictLabels(a: head, b: b))
        }
        return RepoState(operation: .none, conflictedPaths: conflicted, labels: ConflictLabels(a: head, b: "Incoming"))
    }

    // MARK: - Helpers

    /// Unique paths of `ls-files -u -z` records (`<mode> <object> <stage>\t<path>\0`), in order.
    static func conflictedPaths(runner: GitRunner, cwd: URL, env: [String: String]) async throws -> [String] {
        let result = try await runner.run(["--literal-pathspecs", "ls-files", "-u", "-z"], cwd: cwd, env: env)
        var seen = Set<String>()
        var paths: [String] = []
        for record in result.stdout.split(separator: 0) {
            guard let tab = record.firstIndex(of: 0x09) else { continue }
            let path = String(decoding: record[(tab + 1)...], as: UTF8.self)
            if seen.insert(path).inserted { paths.append(path) }
        }
        return paths
    }

    /// The current branch name, else the short hash of a detached HEAD, else "HEAD" (unborn and detached
    /// cannot both fail).
    static func headLabel(runner: GitRunner, cwd: URL, env: [String: String]) async throws -> String {
        let branch = try await runner.run(
            ["symbolic-ref", "-q", "--short", "HEAD"], cwd: cwd, env: env, allowedExitCodes: [0, 1])
        if branch.exitCode == 0, let name = trimmed(branch.text) { return name }
        let short = try await runner.run(
            ["rev-parse", "-q", "--short", "--verify", "HEAD"], cwd: cwd, env: env, allowedExitCodes: [0, 1])
        return trimmed(short.text) ?? "HEAD"
    }

    /// A ref pointing at `hash` (local branch, then remote branch, then tag), else its short hash.
    static func refLabel(_ hash: String?, runner: GitRunner, cwd: URL, env: [String: String]) async throws
        -> String?
    {
        guard let hash, GitOperations.isObjectID(hash) else { return nil }
        let refs = try await runner.run(
            ["for-each-ref", "--points-at", hash, "--format=%(refname)", "refs/heads", "refs/remotes", "refs/tags"],
            cwd: cwd, env: env
        ).text.split(separator: "\n").map(String.init)
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] {
            if let ref = refs.first(where: { $0.hasPrefix(prefix) && !($0.hasPrefix("refs/remotes/") && $0.hasSuffix("/HEAD")) }) {
                return String(ref.dropFirst(prefix.count))
            }
        }
        return try await commitLabel(hash, runner: runner, cwd: cwd, env: env, subject: false)
    }

    /// "<short hash> <subject>" (or the short hash alone) of the commit `hash`.
    static func commitLabel(
        _ hash: String?, runner: GitRunner, cwd: URL, env: [String: String], subject: Bool = true
    ) async throws -> String? {
        guard let hash, GitOperations.isObjectID(hash) else { return nil }
        let format = subject ? "--format=%h %s" : "--format=%h"
        let result = try await runner.run(
            ["log", "-1", "--no-walk", format, "--end-of-options", hash], cwd: cwd, env: env, allowedExitCodes: [0, 128])
        return result.exitCode == 0 ? trimmed(result.text) : String(hash.prefix(7))
    }

    private static func firstLine(_ url: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return trimmed(String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? "")
    }

    private static func trimmed(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
