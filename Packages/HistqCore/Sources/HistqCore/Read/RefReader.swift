// Reads the refs the graph labels: local branches with their upstream and ahead/behind counts, remote
// branches, tags (annotated ones peeled to their commit) and HEAD.
import Foundation

public struct LocalBranch: Sendable, Hashable {
    /// The short name, e.g. `main` or `fix/login`.
    public let name: String
    /// The full ref, e.g. `refs/heads/main`.
    public let refName: String
    public let commit: String
    /// The short upstream name, e.g. `origin/main`; nil without an upstream.
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    /// The upstream is configured but its ref no longer exists (deleted on the remote, then pruned).
    public let upstreamGone: Bool
    /// HEAD of the worktree the read ran in points at this branch.
    public let isHead: Bool

    public init(
        name: String, refName: String, commit: String, upstream: String?, ahead: Int, behind: Int,
        upstreamGone: Bool, isHead: Bool
    ) {
        self.name = name
        self.refName = refName
        self.commit = commit
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.upstreamGone = upstreamGone
        self.isHead = isHead
    }
}

public struct RemoteBranch: Sendable, Hashable {
    /// The short name, e.g. `origin/main`.
    public let name: String
    /// The full ref, e.g. `refs/remotes/origin/main`.
    public let refName: String
    /// The first path component of `name` (a remote whose own name contains `/` is cut at the first one).
    public let remote: String
    public let commit: String

    public init(name: String, refName: String, remote: String, commit: String) {
        self.name = name
        self.refName = refName
        self.remote = remote
        self.commit = commit
    }
}

/// A tag (named `TagRef` because Swift Testing exports a `Tag` type too).
public struct TagRef: Sendable, Hashable {
    public let name: String
    public let refName: String
    /// The object the ref points at: the tag object for an annotated tag, else the tagged object itself.
    public let target: String
    public let isAnnotated: Bool
    /// The commit the tag finally points at (peeled); nil for a tag of a tree or blob.
    public let commit: String?

    public init(name: String, refName: String, target: String, isAnnotated: Bool, commit: String?) {
        self.name = name
        self.refName = refName
        self.target = target
        self.isAnnotated = isAnnotated
        self.commit = commit
    }
}

public enum Head: Sendable, Hashable {
    /// On a branch (short name) at `commit`.
    case branch(String, commit: String)
    case detached(commit: String)
    /// On a branch that has no commit yet (a new repository or an orphan branch).
    case unborn(String)

    public var commit: String? {
        switch self {
        case .branch(_, let commit), .detached(let commit): commit
        case .unborn: nil
        }
    }
}

public struct Refs: Sendable, Hashable {
    public let head: Head
    /// Sorted by ref name, like every list here.
    public let localBranches: [LocalBranch]
    /// Symbolic remote refs (`origin/HEAD`) are left out.
    public let remoteBranches: [RemoteBranch]
    public let tags: [TagRef]

    public init(head: Head, localBranches: [LocalBranch], remoteBranches: [RemoteBranch], tags: [TagRef]) {
        self.head = head
        self.localBranches = localBranches
        self.remoteBranches = remoteBranches
        self.tags = tags
    }
}

public enum RefReader {
    /// Fields separated by `\x1f` (`%1f`); ref names cannot contain control characters or newlines.
    /// `%(*objectname)`/`%(*objecttype)` are the peeled object of an annotated tag (empty otherwise).
    public static let arguments = [
        "for-each-ref",
        "--format=%(refname)%1f%(objectname)%1f%(objecttype)%1f%(*objectname)%1f%(*objecttype)%1f"
            + "%(upstream:short)%1f%(upstream:track,nobracket)%1f%(symref)",
        "refs/heads", "refs/remotes", "refs/tags",
    ]

    /// Reads the refs and HEAD of the repository (worktree) at `cwd`. `env` must be the read environment
    /// built by `GitInvocation.readEnvironment` for this `cwd`. Throws `GitError`.
    public static func read(runner: GitRunner, cwd: URL, env: [String: String]) async throws -> Refs {
        let output = try await runner.run(arguments, cwd: cwd, env: env).text
        let headRef = try await runner.run(
            ["symbolic-ref", "-q", "HEAD"], cwd: cwd, env: env, allowedExitCodes: [0, 1]
        ).text.trimmingCharacters(in: .newlines)
        let headCommit = try await runner.run(
            ["rev-parse", "-q", "--verify", "HEAD"], cwd: cwd, env: env, allowedExitCodes: [0, 1]
        ).text.trimmingCharacters(in: .newlines)
        return parse(output, headRef: headRef, headCommit: headCommit)
    }

    /// `headRef` is the output of `symbolic-ref -q HEAD` (empty when detached), `headCommit` that of
    /// `rev-parse -q --verify HEAD` (empty when unborn).
    static func parse(_ output: String, headRef: String, headCommit: String) -> Refs {
        var locals: [LocalBranch] = []
        var remotes: [RemoteBranch] = []
        var tags: [TagRef] = []
        for line in output.split(separator: "\n") {
            let f = line.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 8 else { continue }
            let (refName, object, type, peeled, peeledType, upstream, track, symref) =
                (f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7])
            if let name = refName.dropPrefix("refs/heads/") {
                let counts = parseTrack(track)
                locals.append(LocalBranch(
                    name: name, refName: refName, commit: object, upstream: upstream.isEmpty ? nil : upstream,
                    ahead: counts.ahead, behind: counts.behind, upstreamGone: counts.gone,
                    isHead: refName == headRef))
            } else if let name = refName.dropPrefix("refs/remotes/") {
                guard symref.isEmpty else { continue }
                let remote = name.utf8.split(separator: UInt8(ascii: "/"), maxSplits: 1).first
                    .map { String(decoding: $0, as: UTF8.self) } ?? name
                remotes.append(RemoteBranch(name: name, refName: refName, remote: remote, commit: object))
            } else if let name = refName.dropPrefix("refs/tags/") {
                let annotated = type == "tag"
                let commit: String? =
                    annotated ? (peeledType == "commit" ? peeled : nil) : (type == "commit" ? object : nil)
                tags.append(TagRef(
                    name: name, refName: refName, target: object, isAnnotated: annotated, commit: commit))
            }
        }
        let head: Head
        if let branch = headRef.dropPrefix("refs/heads/") {
            head = headCommit.isEmpty ? .unborn(branch) : .branch(branch, commit: headCommit)
        } else {
            head = .detached(commit: headCommit)
        }
        return Refs(head: head, localBranches: locals, remoteBranches: remotes, tags: tags)
    }

    /// `ahead N`, `behind N`, `ahead N, behind M`, `gone` or empty (in sync or no upstream).
    static func parseTrack(_ track: String) -> (ahead: Int, behind: Int, gone: Bool) {
        if track == "gone" { return (0, 0, true) }
        var ahead = 0
        var behind = 0
        for part in track.split(separator: ",") {
            let words = part.split(separator: " ")
            guard words.count == 2, let count = Int(words[1]) else { continue }
            if words[0] == "ahead" { ahead = count } else if words[0] == "behind" { behind = count }
        }
        return (ahead, behind, false)
    }
}

extension String {
    /// The rest of the string after `prefix`, or nil when it does not start with it. Compared as bytes:
    /// `hasPrefix` works on characters, so a name starting with a combining mark would not match.
    fileprivate func dropPrefix(_ prefix: String) -> String? {
        guard utf8.starts(with: prefix.utf8) else { return nil }
        return String(decoding: utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
    }
}
