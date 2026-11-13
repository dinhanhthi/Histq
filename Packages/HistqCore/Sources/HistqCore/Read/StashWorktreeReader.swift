// Reads the stashes (each with the commit it was made on, where the graph attaches its row) and the
// worktrees of a repository.
import Foundation

public struct Stash: Sendable, Hashable, Identifiable {
    /// `n` of `stash@{n}`; 0 is the newest.
    public let index: Int
    /// The stash commit (`stash@{n}`).
    public let hash: String
    /// The commit the stash was made on (`stash@{n}^1`).
    public let base: String
    /// The index commit (`^2`) and, for `stash -u`/`-a`, the untracked files commit (`^3`).
    public let otherParents: [String]
    /// The reflog message, e.g. `On main: guide tweaks` or `WIP on main: <subject>`.
    public let message: String
    public let date: Date

    public var id: String { hash }
    /// The ref selector for commands (`stash@{n}`).
    public var selector: String { "stash@{\(index)}" }

    public init(index: Int, hash: String, base: String, otherParents: [String], message: String, date: Date) {
        self.index = index
        self.hash = hash
        self.base = base
        self.otherParents = otherParents
        self.message = message
        self.date = date
    }
}

public struct Worktree: Sendable, Hashable {
    /// The absolute path git reports.
    public let path: String
    /// The checked-out commit; nil for a bare repository or an unborn branch.
    public let head: String?
    /// The full branch ref, e.g. `refs/heads/wt`; nil when detached or bare.
    public let branch: String?
    public let isDetached: Bool
    public let isBare: Bool
    /// The lock reason when locked (empty when no reason was given), nil when not locked.
    public let lockReason: String?
    /// Why git could prune it (its folder is gone), nil when it is fine.
    public let prunableReason: String?
    /// The main worktree (git lists it first).
    public let isMain: Bool

    public var isLocked: Bool { lockReason != nil }
    public var isPrunable: Bool { prunableReason != nil }

    public init(
        path: String, head: String?, branch: String?, isDetached: Bool, isBare: Bool, lockReason: String?,
        prunableReason: String?, isMain: Bool
    ) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isDetached = isDetached
        self.isBare = isBare
        self.lockReason = lockReason
        self.prunableReason = prunableReason
        self.isMain = isMain
    }
}

public enum StashWorktreeReader {
    /// `stash list` walks the `refs/stash` reflog (and handles a repo without stashes). The message comes
    /// last: reflog messages are single-line.
    public static let stashArguments = ["stash", "list", "--format=%H%x1f%P%x1f%ct%x1f%gs"]
    public static let worktreeArguments = ["worktree", "list", "--porcelain", "-z"]

    /// The stashes, newest first. `env` must be the read environment built by
    /// `GitInvocation.readEnvironment` for this `cwd`. Throws `GitError`.
    public static func stashes(runner: GitRunner, cwd: URL, env: [String: String]) async throws -> [Stash] {
        parseStashes(try await runner.run(stashArguments, cwd: cwd, env: env).text)
    }

    /// The worktrees, the main one first. `env` must be the read environment built by
    /// `GitInvocation.readEnvironment` for this `cwd`. Throws `GitError`.
    public static func worktrees(runner: GitRunner, cwd: URL, env: [String: String]) async throws -> [Worktree] {
        parseWorktrees(try await runner.run(worktreeArguments, cwd: cwd, env: env).stdout)
    }

    static func parseStashes(_ output: String) -> [Stash] {
        var stashes: [Stash] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\u{1F}", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4, LogParser.isHash(fields[0]) else { continue }
            let parents = fields[1].split(separator: " ").map(String.init)
            guard let base = parents.first else { continue }
            stashes.append(Stash(
                index: stashes.count, hash: String(fields[0]), base: base, otherParents: Array(parents.dropFirst()),
                message: String(fields[3]), date: Date(timeIntervalSince1970: TimeInterval(fields[2]) ?? 0)))
        }
        return stashes
    }

    /// Each attribute ends with NUL and an empty attribute ends a worktree.
    static func parseWorktrees(_ output: Data) -> [Worktree] {
        var worktrees: [Worktree] = []
        var attributes: [Data] = []
        for field in output.split(separator: 0, omittingEmptySubsequences: false) {
            if field.isEmpty {
                if let worktree = worktree(from: attributes, isMain: worktrees.isEmpty) { worktrees.append(worktree) }
                attributes.removeAll()
            } else {
                attributes.append(field)
            }
        }
        if let worktree = worktree(from: attributes, isMain: worktrees.isEmpty) { worktrees.append(worktree) }
        return worktrees
    }

    /// An attribute is `<key>` or `<key> <value>`, split as bytes so a value keeps every character.
    private static func worktree(from attributes: [Data], isMain: Bool) -> Worktree? {
        var path: String?
        var head: String?
        var branch: String?
        var detached = false
        var bare = false
        var lockReason: String?
        var prunableReason: String?
        for attribute in attributes {
            let parts = attribute.split(separator: UInt8(ascii: " "), maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(decoding: parts[0], as: UTF8.self)
            let value = parts.count > 1 ? String(decoding: parts[1], as: UTF8.self) : ""
            switch key {
            case "worktree": path = value
            case "HEAD": head = value.allSatisfy { $0 == "0" } ? nil : value
            case "branch": branch = value
            case "detached": detached = true
            case "bare": bare = true
            case "locked": lockReason = value
            case "prunable": prunableReason = value
            default: break
            }
        }
        guard let path else { return nil }
        return Worktree(
            path: path, head: head, branch: branch, isDetached: detached, isBare: bare, lockReason: lockReason,
            prunableReason: prunableReason, isMain: isMain)
    }
}
