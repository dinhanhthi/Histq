// Interactive rebase without an editor (task 9.2). A `RebaseTodo` lists the commits of the current branch from a
// commit X up to HEAD, each with an action (pick, reword, edit, squash, fixup, drop) in any order the user drags
// them to. Running it writes git's todo file into a folder the caller owns and starts `git rebase -i` with
// `GIT_SEQUENCE_EDITOR="cp '<todo>'"` (git's own todo is replaced by ours) and `-c core.editor=true` (squash
// messages are accepted as they are). A new message (reword, or the message of a squash group) is applied by an
// `exec '<git>' commit --amend --only -F '<message file>'` line after the commit's group, so no message ever
// passes through argv or an editor.
//
// Safety: every commit is a full object id resolved by git (`rev-parse --verify <id>^{commit}`) and the rebase
// upstream is X's parent's object id, never the text `X^`; a root X uses `--root`. Paths in the todo and the
// sequence editor are single-quoted for `sh` (`'` becomes `'\''`) and refused when they hold a line break or NUL,
// which would end a todo line. Merges are refused anywhere in the range: `rebase -i` would flatten them.
import Foundation

public enum RebaseTodoError: Error, Equatable, Sendable {
    /// Not 4 to 64 hex digits.
    case invalidObjectID(String)
    /// The id names no commit here.
    case notACommit(String)
    /// The commit is not on the current branch's first-parent line (or HEAD has no commit).
    case notAncestorOfHead(String)
    /// A merge commit is selected or lies between the commit and HEAD.
    case mergeCommit(String)
    /// The selected commits have other commits between them.
    case nonContiguousSelection
    /// A squash needs at least two commits.
    case selectionTooSmall
    /// A squash or fixup with no kept commit before it.
    case nothingToFoldInto(String)
    /// A new message with no text.
    case emptyMessage(String)
    /// The rows are not exactly the commits the todo was built from (one would be dropped silently).
    case commitsChanged
    /// A path with a line break or NUL, which cannot go into a todo line or a shell word.
    case unsafePath(String)

    /// A sentence for the UI.
    public var message: String {
        switch self {
        case .invalidObjectID(let text): "\(text) is not a commit id."
        case .notACommit(let text): "\(text) is not a commit in this repository."
        case .notAncestorOfHead(let text): "\(GitOperations.shortRevision(text)) is not on the current branch."
        case .mergeCommit(let oid):
            "\(GitOperations.shortRevision(oid)) is a merge commit; an interactive rebase would flatten it."
        case .nonContiguousSelection: "Only commits that follow each other can be squashed."
        case .selectionTooSmall: "Select at least two commits to squash."
        case .nothingToFoldInto(let oid): "\(GitOperations.shortRevision(oid)) has no earlier commit to be squashed into."
        case .emptyMessage(let oid): "The new message of \(GitOperations.shortRevision(oid)) is empty."
        case .commitsChanged: "The list of commits changed; start the interactive rebase again."
        case .unsafePath(let path): "\"\(path)\" cannot be used for the rebase files."
        }
    }
}

public struct RebaseTodo: Sendable, Equatable {
    public enum Action: String, Sendable, CaseIterable {
        case pick, reword, edit, squash, fixup, drop
    }

    public struct Item: Sendable, Equatable, Identifiable {
        /// The full object id.
        public let commit: String
        public let subject: String
        /// The full original message.
        public let message: String
        public var action: Action
        /// The message of the commit this row ends up in: for pick, reword and edit the row's own commit, for squash
        /// and fixup the commit they fold into (the last one given in a group wins). nil keeps git's message.
        public var newMessage: String?

        public var id: String { commit }
    }

    public enum Base: Sendable, Equatable {
        /// Rebase onto the first commit's parent (its full object id).
        case parent(String)
        /// The first commit has no parent: `git rebase -i --root`.
        case root
    }

    public let base: Base
    /// Oldest first, as git lists them; reorder and change actions freely, but keep every commit.
    public var items: [Item]
    /// What Undo calls the rebase.
    public let title: String
    /// The commits the todo was built from, so a run never drops one by omission.
    let range: [String]

    /// The rebase command (run with `GIT_SEQUENCE_EDITOR` set): the upstream is an object id after
    /// `--end-of-options`, or `--root`.
    public var arguments: [String] {
        switch base {
        case .parent(let oid): ["-c", "core.editor=true", "rebase", "-i", "--end-of-options", oid]
        case .root: ["-c", "core.editor=true", "rebase", "-i", "--root"]
        }
    }

    // MARK: - Building

    /// "Interactive rebase from here" on `commit`: the current branch rebased onto `commit`'s parent, so the todo
    /// lists `commit` and every commit after it up to HEAD, all `pick`. `commit` must be an ancestor of HEAD with
    /// no merge from it to HEAD. A read: `env` may be the read environment.
    public static func fromCommit(
        _ commit: String, runner: GitRunner, cwd: URL, env: [String: String]
    ) async throws -> RebaseTodo {
        let git = Reader(runner: runner, cwd: cwd, env: env)
        let oid = try await git.resolve(commit)
        guard try await git.run(["rev-parse", "-q", "--verify", "HEAD"], allowed: [0, 1]).exitCode == 0,
            try await git.run(["merge-base", "--is-ancestor", oid, "HEAD"], allowed: [0, 1]).exitCode == 0
        else { throw RebaseTodoError.notAncestorOfHead(oid) }
        let parents = try await git.run(["rev-list", "--parents", "-n", "1", oid]).text
            .split(whereSeparator: \.isWhitespace).dropFirst().map(String.init)
        guard parents.count <= 1 else { throw RebaseTodoError.mergeCommit(oid) }

        let log = try await git.run(
            ["log", "-z", "--reverse", "--topo-order", "--no-show-signature", "--format=%H%x1f%P%x1f%B",
             "--end-of-options", parents.first.map { "\($0)..HEAD" } ?? "HEAD"])
        var items: [Item] = []
        for record in log.text.split(separator: "\0") {
            let fields = record.split(separator: "\u{1F}", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            let hash = String(fields[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            if fields[1].split(separator: " ").count > 1 { throw RebaseTodoError.mergeCommit(hash) }
            let message = String(fields[2])
            let subject = message.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            items.append(Item(commit: hash, subject: subject, message: message, action: .pick, newMessage: nil))
        }
        guard items.first?.commit == oid else { throw RebaseTodoError.notAncestorOfHead(oid) }
        return RebaseTodo(
            base: parents.first.map(Base.parent) ?? .root, items: items, title: "Interactive rebase",
            range: items.map(\.commit))
    }

    /// "Squash N commits": the selected commits (any order, at least two) must follow each other on the current
    /// branch's first-parent line with no merge among them or after them. The oldest is picked with the default
    /// message (`defaultSquashMessage`, editable in `items[0].newMessage`), the others squashed into it, and every
    /// later commit picked.
    public static func squash(
        _ commits: [String], runner: GitRunner, cwd: URL, env: [String: String]
    ) async throws -> RebaseTodo {
        let git = Reader(runner: runner, cwd: cwd, env: env)
        var selected: [String] = []
        for commit in commits {
            let oid = try await git.resolve(commit)
            if !selected.contains(oid) { selected.append(oid) }
        }
        guard selected.count >= 2 else { throw RebaseTodoError.selectionTooSmall }
        let line = try await git.run(["rev-list", "--first-parent", "HEAD"]).text.split(separator: "\n").map(String.init)
        var positions: [Int] = []
        for oid in selected {
            guard let position = line.firstIndex(of: oid) else { throw RebaseTodoError.notAncestorOfHead(oid) }
            positions.append(position)
        }
        guard let newest = positions.min(), let oldest = positions.max(), oldest - newest + 1 == selected.count else {
            throw RebaseTodoError.nonContiguousSelection
        }

        let todo = try await fromCommit(line[oldest], runner: runner, cwd: cwd, env: env)
        var items = todo.items
        items[0].newMessage = defaultSquashMessage(items.prefix(selected.count).map(\.message))
        for index in 1..<selected.count { items[index].action = .squash }
        return RebaseTodo(base: todo.base, items: items, title: "Squash \(selected.count) commits", range: todo.range)
    }

    /// Every message in order, oldest first, separated by a blank line: the oldest subject becomes the subject and
    /// the rest is kept in the description (as `reset --soft` and one commit would).
    public static func defaultSquashMessage(_ messages: [String]) -> String {
        messages.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    // MARK: - Writing

    /// `text` as one single-quoted `sh` word. Throws for a line break or NUL (a todo line would end there).
    public static func shellQuoted(_ text: String) throws -> String {
        guard !text.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else {
            throw RebaseTodoError.unsafePath(text)
        }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Writes the message files and the todo into `folder` and returns the todo file. `git` is the executable the
    /// `exec` lines run (the runner's, not whichever `git` comes first on PATH).
    func write(to folder: URL, git: URL) throws -> URL {
        guard items.map(\.commit).sorted() == range.sorted(),
            items.allSatisfy({ GitOperations.isObjectID($0.commit) })
        else { throw RebaseTodoError.commitsChanged }
        let quotedGit = try Self.shellQuoted(git.path)
        var lines: [String] = []
        var message: (text: String, commit: String)?
        var hasKeptCommit = false
        var files = 0

        // The exec line goes after the whole group (a commit and the squashes and fixups that follow it), so it
        // amends the commit the group ends as.
        func flush() throws {
            guard let pending = message else { return }
            message = nil
            guard !pending.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RebaseTodoError.emptyMessage(pending.commit)
            }
            files += 1
            let file = folder.appending(path: "message-\(files).txt", directoryHint: .notDirectory)
            try Data(pending.text.utf8).write(to: file)
            lines.append("exec \(quotedGit) commit --amend --only -F \(try Self.shellQuoted(file.path))")
        }

        for item in items {
            switch item.action {
            case .drop:
                lines.append("drop \(item.commit)")
            case .squash, .fixup:
                guard hasKeptCommit else { throw RebaseTodoError.nothingToFoldInto(item.commit) }
                lines.append("\(item.action.rawValue) \(item.commit)")
                if let text = item.newMessage { message = (text, item.commit) }
            case .pick, .reword, .edit:
                try flush()
                hasKeptCommit = true
                lines.append("\(item.action == .edit ? "edit" : "pick") \(item.commit)")
                message = item.newMessage.map { ($0, item.commit) }
            }
        }
        try flush()
        let todo = folder.appending(path: "git-rebase-todo", directoryHint: .notDirectory)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: todo)
        return todo
    }

    /// Runs the read commands of the builders.
    private struct Reader {
        let runner: GitRunner
        let cwd: URL
        let env: [String: String]

        func run(_ args: [String], allowed: Set<Int32> = [0]) async throws -> GitResult {
            try await runner.run(args, cwd: cwd, env: env, allowedExitCodes: allowed)
        }

        /// The full object id of the commit `id` names.
        func resolve(_ id: String) async throws -> String {
            guard GitOperations.isObjectID(id) else { throw RebaseTodoError.invalidObjectID(id) }
            let result = try await run(["rev-parse", "-q", "--verify", "--end-of-options", id + "^{commit}"], allowed: [0, 1])
            let oid = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.exitCode == 0, GitOperations.isObjectID(oid) else { throw RebaseTodoError.notACommit(id) }
            return oid
        }
    }
}

extension GitOperations {
    /// Runs `todo` on the current branch (journaled as a rebase, so a completed one can be undone). `folder` is an
    /// existing folder the caller owns for the todo and message files: keep it until no rebase is in progress,
    /// because the `exec` lines of a rebase that stopped (conflict, `edit`) read their message files only after
    /// `continueOperation`. A conflict throws `GitError.conflict` and leaves the rebase in progress (`RepoState`).
    public func interactiveRebase(_ todo: RebaseTodo, files folder: URL) async throws {
        let file = try todo.write(to: folder, git: runner.executable)
        let editor = "cp " + (try RebaseTodo.shellQuoted(file.path))
        try await journaled(.rebase, todo.title, mode: .carry) { ops in
            try await ops.exec(todo.arguments, extraEnv: ["GIT_SEQUENCE_EDITOR": editor])
        }
    }
}
