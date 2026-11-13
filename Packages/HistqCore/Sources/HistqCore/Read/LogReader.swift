// Streams the commit history for the graph: every ref but the stash and notes, in topological order, parsed
// as git writes it and published in pages so the first rows can show before git has finished.
import Foundation

/// One commit of the history. Text fields come from the repo and are untrusted.
public struct Commit: Sendable, Hashable, Identifiable {
    public let hash: String
    /// First parent first; empty for a root commit, two or more for a merge.
    public let parents: [String]
    public let authorName: String
    public let authorEmail: String
    public let authorDate: Date
    public let committerDate: Date
    public let subject: String
    public let body: String

    public var id: String { hash }
    public var isMerge: Bool { parents.count > 1 }

    public init(
        hash: String, parents: [String], authorName: String, authorEmail: String, authorDate: Date,
        committerDate: Date, subject: String, body: String
    ) {
        self.hash = hash
        self.parents = parents
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authorDate = authorDate
        self.committerDate = committerDate
        self.subject = subject
        self.body = body
    }
}

public enum LogReader {
    public static let defaultPageSize = 500

    /// `--exclude` must come before `--all` (git applies it to the next `--all`/`--branches`/...), so stash
    /// internals (`stash@{n}` and its index and untracked commits) and notes never become rows. `-z` ends
    /// every record with NUL, which git cannot emit inside a name or message (its formatter stops at a NUL,
    /// and the read environment pins UTF-8 output), so no commit text can start a record of its own. Fields
    /// are separated by `\x1f`, which git does not escape: the fixed-format fields come first and the body
    /// last, so a stray `\x1f` in a name or message cannot shift the hash, parents or dates (see `LogParser`).
    public static let arguments = [
        "log", "-z", "--exclude=refs/stash", "--exclude=refs/notes/*", "--all", "--topo-order",
        "--format=%H%x1f%P%x1f%at%x1f%ct%x1f%an%x1f%ae%x1f%s%x1f%b",
    ]

    /// Streams the history of the repository at `cwd` in pages of up to `pageSize` commits (the last page
    /// may be shorter; an empty repository yields no page). `env` must be the read environment built by
    /// `GitInvocation.readEnvironment` for this `cwd`. The stream throws `GitError` when git fails. Ending
    /// the iteration early stops git; a cancelled consumer's loop ends without an error.
    public static func pages(
        runner: GitRunner, cwd: URL, env: [String: String], pageSize: Int = defaultPageSize
    ) -> AsyncThrowingStream<[Commit], Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: [Commit].self)
        let task = Task {
            do {
                var page: [Commit] = []
                page.reserveCapacity(pageSize)
                let lines = await runner.stream(arguments, cwd: cwd, env: env, delimiter: 0)
                for try await line in lines where line.source == .stdout {
                    guard let commit = LogParser.parse(Substring(line.text)) else { continue }
                    page.append(commit)
                    if page.count >= pageSize {
                        continuation.yield(page)
                        page.removeAll(keepingCapacity: true)
                    }
                }
                try Task.checkCancellation()
                if !page.isEmpty { continuation.yield(page) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

/// Turns NUL-terminated records into commits, one record each.
enum LogParser {
    /// A record needs a hash, parents and both dates, or it is no commit. The body takes everything after
    /// the seventh `\x1f`, so a stray `\x1f` in a name or subject only misplaces text.
    static func parse(_ record: Substring) -> Commit? {
        let fields = record.split(separator: "\u{1F}", maxSplits: 7, omittingEmptySubsequences: false)
        guard fields.count >= 4, isHash(fields[0]),
              let authorTime = TimeInterval(fields[2]), let commitTime = TimeInterval(fields[3])
        else { return nil }
        let parents = fields[1].split(separator: " ")
        guard parents.allSatisfy(isHash) else { return nil }
        let text = { (index: Int) in index < fields.count ? fields[index] : "" }
        var body = text(7)
        while body.last == "\n" { body.removeLast() }
        return Commit(
            hash: String(fields[0]), parents: parents.map(String.init), authorName: String(text(4)),
            authorEmail: String(text(5)), authorDate: Date(timeIntervalSince1970: authorTime),
            committerDate: Date(timeIntervalSince1970: commitTime), subject: String(text(6)), body: String(body))
    }

    /// A full SHA-1 (40) or SHA-256 (64) object name in lowercase hex.
    static func isHash(_ text: Substring) -> Bool {
        (text.utf8.count == 40 || text.utf8.count == 64)
            && text.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
}
