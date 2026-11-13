// One tab's repository: its git runner, what it has read (status, refs, the log and its graph layout), the selected
// detail with its loading state, and the watcher that keeps them current. Every git call runs off the main actor;
// the main actor only publishes results.
import Foundation
import HistqCore
import os

/// The git executable and the read base environment, resolved off the main actor (`git --version` from the fixed
/// folders, never the login shell) and kept, a failure too, until `reset()`. Reads and writes run the same git.
/// Writes and network commands take `writeBase()`: the login shell's PATH, cached in `StatePaths.root`.
/// `prepare()` starts both at launch.
enum GitToolchain {
    struct Resolved: Sendable {
        let executable: GitExecutable
        /// `GitInvocation.baseEnvironment()` with the fixed PATH: what every automatic read starts from. Never
        /// for writes or network commands: use `writeBase()`.
        let readBase: [String: String]
    }

    /// The login shell's PATH for writes, cached across launches; the shell runs once per launch.
    private static let loginPath = LoginShellPath(
        cacheFile: StatePaths.root.appending(path: "login-path", directoryHint: .notDirectory))

    /// What write and network commands (clone, init, fetch, push, commit) start from: the login shell's PATH, so
    /// git-lfs, gpg, credential helpers and hooks find the user's tools. The cached PATH at once, else it waits for
    /// the login shell (seconds).
    static func writeBase() async -> [String: String] {
        GitInvocation.baseEnvironment(path: await loginPath.value())
    }

    /// The resolution in flight or done; nil after `reset()`, until the next `resolve()` starts a new one.
    private static let current = OSAllocatedUnfairLock<Task<Resolved, Error>?>(initialState: nil)

    /// Starts resolving git and the login shell's PATH; call once at launch so the first repo does not wait for it.
    static func prepare() {
        _ = task()
        loginPath.prepare()
    }

    static func resolve() async throws -> Resolved { try await task().value }

    /// Forgets the result, so the next `resolve()` looks for git again: after the `gitPath` preference changed or
    /// the Command Line Tools were installed. Sessions whose setup failed retry on their next load. The login
    /// shell's PATH is kept.
    static func reset() {
        current.withLock { $0 = nil }
    }

    private static func task() -> Task<Resolved, Error> {
        current.withLock { task in
            if let task { return task }
            let new = Task.detached(priority: .userInitiated) { () async throws -> Resolved in
                let override = Preferences.defaults.string(forKey: PrefKey.gitPath.rawValue)
                let executable = try await GitExecutable.resolve(override: override)
                return Resolved(executable: executable, readBase: GitInvocation.baseEnvironment())
            }
            task = new
            return new
        }
    }
}

/// The log of a repo with its graph rows, in `git log --all --topo-order` order. `rows[i]` is `commits[i]`'s row; the
/// rows above the commits (WIP, stashes) are in `syntheticRows`.
struct LogSnapshot: Sendable {
    var commits: [Commit] = []
    var rows: [GraphRow] = []
    /// Laid out before the commits, shown above them: the WIP row when the working tree has changes, then one row per
    /// stash, newest first.
    var syntheticRows: [GraphRow] = []
    /// What `syntheticRows` were laid out from (`RepoSession.syntheticRows(status:stashes:)`).
    var synthetic: [GraphSyntheticRow] = []
    /// The stashes of the stash rows, newest first.
    var stashes: [Stash] = []
    /// Every page has been parsed and laid out; false while only the first pages are in.
    var isComplete = false
    /// The same for every snapshot of one load (its first page, then the whole log), new for each load: the graph
    /// inserts the rows a snapshot of the same load adds and reloads for a new one.
    var generation = 0
}

/// A commit or a stash as the detail panel shows it: its message, people, dates, parents and changed files (against
/// its first parent; a stash adds the untracked files it saved).
struct CommitDetail: Sendable {
    let hash: String
    /// First parent first. A stash's are its base, its index commit and, with untracked files, their commit.
    let parents: [String]
    let authorName: String
    let authorEmail: String
    let authorDate: Date
    let committerName: String
    let committerEmail: String
    let committerDate: Date
    let subject: String
    let body: String
    let files: [FileChange]
    let isStash: Bool
}

/// A remote and its fetch URL.
struct RemoteInfo: Hashable, Sendable {
    let name: String
    let url: String
}

/// A user operation in flight: what the action bar shows while it runs.
struct RunningOperation: Identifiable, Hashable {
    let id: Int
    /// "Pull", "Merge develop into main".
    let title: String
    /// The action bar button that shows its progress, if it started there.
    let key: ActionBarAction?
}

/// A user operation that failed: the action bar's error banner, with the write (to retry it or force it) and the error
/// (`GitError` cases get a hint).
struct OperationFailure: Identifiable {
    let id = UUID()
    let title: String
    let write: RepoSession.Write
    let error: Error
    let message: String
}

/// One tab's repository. `select(_:)` switches the detail at once (`detail` becomes `.loading` in the same call)
/// and loads it in a cancellable task; a newer select cancels the older load. `refresh(scope:)` rereads status, refs
/// or the log (the watcher calls it). All git runs on `GitRunner`, with the read environment for this folder.
@Observable
@MainActor
final class RepoSession: Identifiable {
    /// What the detail area shows.
    enum Selection: Hashable, Sendable {
        /// Nothing picked yet (a tab just opened): it loads as the WIP when the working tree has changes, else as
        /// HEAD's commit, and `selection` becomes that; the overview cards only for an unborn branch.
        case overview
        /// The working tree: unstaged and staged files, the commit box.
        case wip
        case commit(String)
        /// A stash, by its commit hash.
        case stash(String)
        /// Several graph rows; the count.
        case multiple(Int)
        /// A sidebar ref picked before the refs were read (a launch request): it loads as its commit, and
        /// `selection` becomes `.commit` with the graph on that row.
        case ref(SidebarItem)
    }

    /// The loaded detail of a selection; the views read `status`, `refs` and `log` for its values.
    enum Detail: Sendable {
        /// The overview cards (an unborn branch: no commit, no change).
        case overview
        /// The WIP panel, which reads the live `status`.
        case wip
        /// A commit or a stash.
        case commit(CommitDetail)
        case multiple(Int)
    }

    /// A user-initiated write (the WIP panel, the action bar, the menus and dialogs), run by `perform` with the write
    /// environment through `GitOperations`. Names come from the refs or from a dialog; the operations validate new
    /// names and put `--end-of-options` / `--` where they belong.
    enum Write: Sendable {
        case stage([String])
        case stageAll
        case unstage([String])
        case unstageAll
        /// Tracked files: their working tree takes the index version.
        case discard([String])
        /// Untracked files: deleted.
        case removeUntracked([String])
        /// Index and tracked files back to HEAD (`reset --hard`), untracked files too when asked.
        case discardAll(includingUntracked: Bool)
        case commit(message: String)
        case amend(message: String)
        /// Selected lines of a diff (`PatchBuilder.patch`): staged, unstaged or discarded with `git apply`.
        case applyPatch(Data, PatchBuilder.Action)

        case checkoutBranch(String)
        /// A local branch `localName` tracking the remote branch (`origin/x`), checked out.
        case checkoutTracking(remoteBranch: String, as: String)
        /// A detached HEAD.
        case checkoutCommit(String)
        case checkoutFiles([String], from: String)

        case fetchAll(prune: Bool)
        case pull(GitOperations.PullMode)
        case push(branch: String, remote: String, remoteBranch: String?, setUpstream: Bool, forceWithLease: String?)
        case pushTag(String, remote: String)
        case pushMirror(remote: String)
        case deleteRemoteBranch(String, remote: String)
        case deleteRemoteTag(String, remote: String)

        case createBranch(String, from: String, checkout: Bool)
        case renameBranch(String, to: String)
        case deleteBranch(String, force: Bool)
        case setUpstream(branch: String, upstream: String)

        case addRemote(String, url: String)
        case removeRemote(String)
        case renameRemote(String, to: String)
        case setRemoteURL(String, url: String)

        /// Merges `revision` into the current branch; `checkoutFirst` switches to that branch first.
        case merge(String, checkoutFirst: String?)
        /// Rebases the current branch onto `upstream`; `checkoutFirst` switches to that branch first.
        case rebase(onto: String, checkoutFirst: String?)
        /// Fast-forwards the local branch to a full ref (`refs/heads/x`, `refs/remotes/origin/x`).
        case fastForward(String, to: String)
        case cherryPick(String, mainline: Int?)
        case revert(String, mainline: Int?)
        case reset(to: String, mode: GitOperations.ResetMode)

        case stashPush(message: String?)
        /// By the stash's commit hash: its `stash@{n}` is looked up when it runs, so a stale index never hits
        /// another stash.
        case stashApply(hash: String)
        case stashPop(hash: String)
        case stashDrop(hash: String)

        /// Annotated when `message` is given.
        case createTag(String, at: String, message: String?)
        case deleteTag(String)

        /// A conflicted file resolved by the conflict editor: `content` written to it (atomically, keeping its mode),
        /// or the file deleted when nil, then `git add` so the path leaves the unmerged list.
        case resolveConflict(path: String, content: Data?)
        /// `git mergetool` on one conflicted path: `tool` is `PrefKey.mergeTool`, nil for git's configured tool. It runs
        /// the repo's configured merge command, so only on the user's click.
        case mergeTool(path: String, tool: String?)

        /// The operation banner's buttons: `git <merge|rebase|cherry-pick|revert> --continue|--abort|--skip` (never
        /// waits for an editor: `GitOperations` passes `-c core.editor=true`).
        case continueOperation(RepoState.Operation)
        case abortOperation(RepoState.Operation)
        case skipOperation(RepoState.Operation)

        /// The remote a network write talks to, for the host-key check of its failure.
        var remote: String? {
            switch self {
            case .push(_, let remote, _, _, _), .pushTag(_, let remote), .pushMirror(let remote),
                 .deleteRemoteBranch(_, let remote), .deleteRemoteTag(_, let remote):
                remote
            default:
                nil
            }
        }
    }

    let id = UUID()
    /// The folder the tab opened.
    let url: URL
    private(set) var selection: Selection = .overview
    private(set) var detail: Loadable<Detail> = .idle
    /// Changes with every `select`, even of the same selection: the placeholder logs a line per select.
    private(set) var selectToken = 0
    /// The timing log's detail of the last select (`wip`, `commit <hash>`, `overview <repo>`): its placeholder,
    /// spinner and content lines carry it.
    private(set) var selectDetail = ""
    /// The graph's selected rows, in row order. The graph follows it (a parent jump, the default selection), and a
    /// click in the graph sets it through `selectGraph(_:)`.
    private(set) var graphSelection: [GraphItem] = []
    /// The WIP panel's commit box, kept while other rows are selected.
    var commitDraft = CommitDraft()
    private(set) var status: Loadable<WorkingStatus> = .idle
    private(set) var refs: Loadable<Refs> = .idle
    private(set) var log: Loadable<LogSnapshot> = .idle
    /// The merge, rebase, cherry-pick or revert in progress (the operation banner), read with every status read; nil
    /// until the first one.
    private(set) var repoState: RepoState?

    /// The sidebar's tab, its selected row and its expanded section cards, kept per tab. A click sets them at once; the
    /// branch actions come in Phase 5.
    private(set) var sidebarTab: SidebarTab = .branches
    private(set) var sidebarSelection: SidebarItem?
    var localExpanded = true
    var remoteExpanded = true
    var tagsExpanded = true

    /// The repo's remotes and their fetch URLs (`git remote -v`), read with the refs: a remote with no fetched branch
    /// shows too.
    private(set) var remotes: [RemoteInfo] = []
    /// The operations started from the action bar, the menus and the dialogs that are still running, oldest first.
    private(set) var running: [RunningOperation] = []
    /// The last operation that failed: the action bar's error banner. A new operation clears it.
    var failure: OperationFailure?
    /// The form a menu or a button asked for (create branch, tag, reset, remotes); `OperationDialogs` presents it.
    var dialog: OperationDialog?
    /// The destructive operation that waits for its confirmation.
    var confirmation: OperationConfirmation?
    /// The host-key sheet: the scan of the failure's host, then "Trust host".
    var hostKeyCheck: HostKeyCheck?
    @ObservationIgnored private var nextOperationID = 0

    /// The runner and the folders, set up once (`backend()`).
    @ObservationIgnored private var setUpTask: Task<Backend, Error>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// The scope of the refresh in flight: a newer refresh cancels it and takes over its scope.
    @ObservationIgnored private var refreshScope: RefreshScope = []
    @ObservationIgnored private var logTask: Task<Void, Never>?
    /// The last load's `LogSnapshot.generation`.
    @ObservationIgnored private var logGeneration = 0
    /// The stashes, read with the refs; nil until the first read. Compared with the log's to reload it when they change.
    @ObservationIgnored private var stashes: [Stash]?
    @ObservationIgnored private let watcher = RepoWatcher()

    /// The file panel2 shows instead of the graph (a click in the WIP panel or a commit's files); nil shows the graph.
    private(set) var openFile: FileTarget?
    /// The open file's diff: `.loading` in the same call as the click, then its cards.
    private(set) var fileDiff: Loadable<FileDiffDetail> = .idle
    /// Changes with every file select (and "Load anyway"): the diff placeholder logs a line per select.
    private(set) var fileToken = 0
    /// Hunks only, or the whole file with its changes; kept while other files are opened.
    var diffMode: DiffMode = .diff
    @ObservationIgnored private var fileTask: Task<Void, Never>?
    /// The user chose "Load anyway" on the open file's size card.
    @ObservationIgnored private var fileIgnoresSizeLimit = false
    /// Numbers the file loads, so the diff tables tell a reloaded diff (after a stage) from a redraw.
    @ObservationIgnored private var fileLoadCount = 0
    /// The open conflicted file's stages and its resolution so far (`openFile` is a WIP file of kind `.conflicted`):
    /// `.loading` in the same call as the click. Ticks and edits live here, so a tab switch keeps them.
    private(set) var conflict: Loadable<ConflictDocument> = .idle
    /// The conflict editor's write in flight ("Saving…"), which disables its buttons.
    private(set) var conflictBusy: String?
    /// The conflict editor's last failed write, shown in its header card.
    var conflictError: String?

    private static let logger = Logger(subsystem: "com.math2it.histq", category: "repo")

    /// What every read needs: the tab's runner, the base environment, the repo's folders.
    private struct Backend: Sendable {
        let runner: GitRunner
        let base: [String: String]
        let directories: RepoDirectories

        /// The read environment for this folder, built once per load: it lists the repo's filter and diff drivers
        /// first, so they can be disabled. Phase 7 passes the tab's profile.
        func readEnvironment(cwd: URL) async throws -> [String: String] {
            try await GitInvocation.readEnvironment(profile: nil, base: base, runner: runner, cwd: cwd)
        }
    }

    init(url: URL) {
        self.url = url
        #if DEBUG
        // `-HistqRun`: menu actions on a fixture copy, once the refs and the whole log are in.
        if let spec = AppState.launchFlag("-HistqRun") {
            Task { [weak self] in
                for _ in 0..<100 {
                    if self?.refs.value != nil, self?.log.value?.isComplete == true { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard let self else { return }
                await RepoMenus.debugRun(spec, session: self)
            }
        }
        // `-HistqOperation`: the operation banner's buttons on a fixture copy, once the state is read.
        if let step = AppState.launchFlag("-HistqOperation") {
            Task { [weak self] in
                for _ in 0..<100 {
                    if self?.status.value != nil, self?.repoState?.isOperationInProgress == true { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                self?.runLaunchOperation(step)
            }
        }
        #endif
    }

    deinit {
        // A window closing drops its sessions without `close()`.
        watcher.stop()
        detailTask?.cancel()
        fileTask?.cancel()
        refreshTask?.cancel()
        logTask?.cancel()
        setUpTask?.cancel()
    }

    /// Stops loading and watching; the tab closed.
    func close() {
        watcher.stop()
        detailTask?.cancel()
        fileTask?.cancel()
        refreshTask?.cancel()
        logTask?.cancel()
        setUpTask?.cancel()
    }

    // MARK: Select

    /// Switches the detail to `selection` now: `detail` is `.loading` when this returns, so the placeholder shows in
    /// the same frame as the click. The load runs in a task that a newer select cancels. Selecting the current
    /// selection again (a tab switch) reloads it.
    func select(_ selection: Selection) {
        // Another row (a parent jump, a vanished WIP) shows the graph again; a tab switch keeps the open file.
        if selection != self.selection { closeFile() }
        self.selection = selection
        selectToken &+= 1
        selectDetail = timingDetail(selection)
        detail = .loading
        detailTask?.cancel()
        let token = selectToken
        detailTask = Task { [weak self] in
            await self?.loadDetail(selection, token: token)
        }
    }

    /// Selects graph rows: the path a click in the graph takes (and `-HistqSelect wip|commit:<sha>`, a parent
    /// jump). One row shows its detail, several a count; none keeps the detail as it is.
    func selectGraph(_ items: [GraphItem]) {
        closeFile()
        graphSelection = items
        guard let first = items.first else { return }
        let selection: Selection
        if items.count > 1 {
            selection = .multiple(items.count)
        } else {
            switch first {
            case .wip: selection = .wip
            case .stash(let hash): selection = .stash(hash)
            case .commit(let hash): selection = .commit(hash)
            }
        }
        UITiming.select(timingDetail(selection))
        select(selection)
    }

    private func timingDetail(_ selection: Selection) -> String {
        switch selection {
        case .overview: "overview \(url.lastPathComponent)"
        case .wip: "wip"
        case .commit(let hash): "commit \(hash)"
        case .stash(let hash): "stash \(hash)"
        case .multiple(let count): "commits \(count)"
        case .ref(let item): item.timingDetail
        }
    }

    private func loadDetail(_ selection: Selection, token: Int) async {
        do {
            let backend = try await backend()
            // The log loads once per session, beside the detail; a tab switch does not restart it.
            if log.value == nil, logTask == nil { loadLog(backend) }
            let loaded: Detail
            switch selection {
            case .overview, .wip:
                if try await readStatusAndRefs(backend, scope: [.status, .refs]) { loadLog(backend) }
                guard token == selectToken else { return }
                if selection == .wip {
                    loaded = .wip
                } else if let status = status.value, !status.entries.isEmpty {
                    self.selection = .wip
                    graphSelection = [.wip]
                    loaded = .wip
                } else if let head = status.value?.branch.commit {
                    let commit = try await Self.readCommit(backend, cwd: url, hash: head, isStash: false)
                    guard token == selectToken else { return }
                    self.selection = .commit(head)
                    graphSelection = [.commit(head)]
                    loaded = .commit(commit)
                } else {
                    loaded = .overview
                }
            case .commit(let hash), .stash(let hash):
                // A first select that is not the overview (`-HistqSelect commit:`) still loads the sidebar's refs.
                if status.value == nil || refs.value == nil,
                   try await readStatusAndRefs(backend, scope: [.status, .refs])
                {
                    loadLog(backend)
                }
                let isStash = if case .stash = selection { true } else { false }
                loaded = .commit(try await Self.readCommit(backend, cwd: url, hash: hash, isStash: isStash))
            case .multiple(let count):
                loaded = .multiple(count)
            case .ref(let item):
                if refs.value == nil, try await readStatusAndRefs(backend, scope: [.status, .refs]) {
                    loadLog(backend)
                }
                guard token == selectToken else { return }
                guard let refs = refs.value, case let (resolved, hash)? = Self.resolve(item, in: refs) else {
                    throw CommitReadError.refGone(item.timingDetail)
                }
                if resolved != item { sidebarSelection = resolved }
                self.selection = .commit(hash)
                graphSelection = [.commit(hash)]
                loaded = .commit(try await Self.readCommit(backend, cwd: url, hash: hash, isStash: false))
            }
            guard token == selectToken else { return }
            detail = .loaded(loaded)
        } catch {
            guard token == selectToken, !Self.isCancellation(error) else { return }
            let message = Self.message(for: error)
            detail = .failed(message)
            failUnread(message)
        }
    }

    /// After a failed setup or read: whatever has never loaded shows `message` too (the sidebar, the commit list), so
    /// no panel stays on its placeholder. Loaded values stay; a log still loading ends on its own.
    private func failUnread(_ message: String) {
        if status.value == nil { status = .failed(message) }
        if refs.value == nil { refs = .failed(message) }
        if log.value == nil, logTask == nil { log = .failed(message) }
    }

    // MARK: Sidebar

    /// Shows a sidebar tab: the path a click on its capsule takes.
    func selectSidebarTab(_ tab: SidebarTab) {
        UITiming.select("sidebar \(tab.rawValue)")
        sidebarTab = tab
    }

    /// Selects a sidebar row now, showing its tab and opening its accordion.
    func selectSidebarItem(_ item: SidebarItem) {
        UITiming.select(item.timingDetail)
        sidebarSelection = item
        switch item {
        case .local: sidebarTab = .branches; localExpanded = true
        case .remote: sidebarTab = .branches; remoteExpanded = true
        case .tag: sidebarTab = .tags
        }
    }

    /// A click on a sidebar row: selects it, and the graph and the detail jump to its commit (the branch tip, the tag's
    /// commit) in the same call; the graph scrolls that row into view. Before the refs are read (a launch request), the
    /// detail shows the commit placeholder at once and jumps once they are in (`Selection.ref`).
    func selectRef(_ item: SidebarItem) {
        closeFile()
        selectSidebarItem(item)
        guard let refs = refs.value else { return select(.ref(item)) }
        if let commit = Self.resolve(item, in: refs)?.1 { selectGraph([.commit(commit)]) }
    }

    /// Selects a branch by name (DEBUG `-HistqSelect branch:<name>`) through `selectRef`, the path a click takes: a
    /// remote branch when the refs are in and only a remote branch has that name, else a local one (the refs may not be
    /// read yet; the load then falls back to a remote branch of that name).
    func selectBranch(named name: String) {
        let isRemote = refs.value.map { refs in
            !refs.localBranches.contains { $0.name == name } && refs.remoteBranches.contains { $0.name == name }
        } ?? false
        selectRef(isRemote ? .remote(name) : .local(name))
    }

    /// The commit a sidebar ref points at, with the ref as found: a local branch that does not exist resolves to the
    /// remote branch of that name, if any.
    private static func resolve(_ item: SidebarItem, in refs: Refs) -> (SidebarItem, String)? {
        switch item {
        case .local(let name):
            if let commit = refs.localBranches.first(where: { $0.name == name })?.commit { return (item, commit) }
            return refs.remoteBranches.first { $0.name == name }.map { (.remote(name), $0.commit) }
        case .remote(let name):
            return refs.remoteBranches.first { $0.name == name }.map { (item, $0.commit) }
        case .tag(let name):
            return refs.tags.first { $0.name == name }.map { (item, $0.commit ?? $0.target) }
        }
    }

    // MARK: Keeping the selection

    /// After a refresh or a log reload, a selected row that is gone moves to HEAD (the detail shows it): the WIP once the
    /// working tree is clean (a commit, a stash, a discard), a stash once dropped or popped, and a commit that was in the
    /// previous complete log and is not in the new one (an amend, a reset). A selection that still exists stays, and the
    /// graph selects its row again after the reload. `previousLog` is nil outside a log reload: commits are not checked.
    private func dropVanishedSelection(previousLog: LogSnapshot? = nil) {
        let vanished: Bool
        switch selection {
        case .wip:
            vanished = status.value?.entries.isEmpty == true
        case .stash(let hash):
            vanished = stashes.map { !$0.contains { $0.hash == hash } } ?? false
        case .commit(let hash):
            guard let previousLog, previousLog.isComplete, let log = log.value, log.isComplete else { return }
            vanished = previousLog.commits.contains { $0.hash == hash } && !log.commits.contains { $0.hash == hash }
        case .overview, .multiple, .ref:
            return
        }
        guard vanished else { return }
        if let head = status.value?.branch.commit {
            selectGraph([.commit(head)])
        } else {
            // An unborn branch: the overview cards.
            graphSelection = []
            UITiming.select(timingDetail(.overview))
            select(.overview)
        }
    }

    // MARK: Refresh

    /// Rereads what `scope` names. A refresh in flight is cancelled and its scope added to this one. `refs` also
    /// reloads the log when a ref moved.
    func refresh(scope: RefreshScope) {
        let scope = refreshTask == nil ? scope : scope.union(refreshScope)
        refreshTask?.cancel()
        refreshScope = scope
        refreshTask = Task { [weak self] in
            await self?.performRefresh(scope)
        }
    }

    private func performRefresh(_ scope: RefreshScope) async {
        do {
            let backend = try await backend()
            // A newer refresh took over (it owns `refreshTask` now).
            try Task.checkCancellation()
            let refsMoved = try await readStatusAndRefs(backend, scope: scope)
            if scope.contains(.log) || refsMoved { loadLog(backend) }
            refreshTask = nil
            refreshScope = []
        } catch {
            guard !Self.isCancellation(error) else { return }
            Self.logger.error("refresh \(scope.description, privacy: .public) failed: \(error, privacy: .public)")
            failUnread(Self.message(for: error))
            refreshTask = nil
            refreshScope = []
        }
    }

    /// Reads the status and the refs (those `scope` names) off the main actor, then publishes them. Returns whether
    /// a ref moved since the last read (a commit, a checkout, a fetch: the log changed). Throws `CancellationError`
    /// when cancelled, so nothing stale is published.
    private func readStatusAndRefs(_ backend: Backend, scope: RefreshScope) async throws -> Bool {
        guard scope.contains(.status) || scope.contains(.refs) else { return false }
        let (newStatus, newState, newRefs, newStashes, newRemotes) = try await Self.read(
            backend, cwd: url, status: scope.contains(.status), refs: scope.contains(.refs))
        try Task.checkCancellation()
        if let newState, newState != repoState { repoState = newState }
        if let newStatus {
            status = .loaded(newStatus)
            if let target = openFile, target.source == .wip {
                if target.isConflict {
                    // The conflict editor keeps its ticks and edits; it closes once the path is resolved (its Save, the
                    // merge tool, a `git add` in a terminal).
                    if !newStatus.conflicted.contains(where: { $0.path == target.path }) { closeFile() }
                } else {
                    // A stage, a discard or an edit changed the open WIP file: its diff follows without a placeholder.
                    loadFile(quietly: true)
                }
            }
        }
        if let newStashes { stashes = newStashes }
        if let newRemotes, newRemotes != remotes { remotes = newRemotes }
        var moved = false
        if let newRefs {
            moved = refs.value.map { $0 != newRefs } ?? false
            refs = .loaded(newRefs)
        }
        dropVanishedSelection()
        return moved || syntheticRowsChanged
    }

    /// Whether the loaded log's WIP and stash rows no longer match the status and the stashes (the working tree
    /// became clean or dirty, HEAD moved, a stash was pushed or dropped): the graph is laid out again. False while a
    /// log load runs; its completion checks again.
    private var syntheticRowsChanged: Bool {
        guard logTask == nil, let log = log.value, log.isComplete, let status = status.value, let stashes else {
            return false
        }
        return Self.syntheticRows(status: status, stashes: stashes) != log.synthetic
    }

    /// The rows above the commits: the WIP row when the working tree has changes (hanging from HEAD), then the stashes
    /// (each hanging from the commit it was made on), newest first.
    nonisolated static func syntheticRows(status: WorkingStatus, stashes: [Stash]) -> [GraphSyntheticRow] {
        var rows: [GraphSyntheticRow] = []
        if !status.entries.isEmpty {
            rows.append(GraphSyntheticRow(kind: .wip, id: "wip", base: status.branch.commit))
        }
        for stash in stashes {
            rows.append(GraphSyntheticRow(kind: .stash, id: stash.hash, base: stash.base))
        }
        return rows
    }

    @concurrent
    private nonisolated static func read(_ backend: Backend, cwd: URL, status: Bool, refs: Bool) async throws
        -> (WorkingStatus?, RepoState?, Refs?, [Stash]?, [RemoteInfo]?)
    {
        let env = try await backend.readEnvironment(cwd: cwd)
        async let newStatus = status ? StatusReader.read(runner: backend.runner, cwd: cwd, env: env) : nil
        // The banner is secondary: a state that cannot be read keeps the last one rather than failing the status.
        async let newState = status ? (try? await RepoState.read(runner: backend.runner, cwd: cwd, env: env)) : nil
        async let newRefs = refs ? RefReader.read(runner: backend.runner, cwd: cwd, env: env) : nil
        // `refs/stash` is a ref: the watcher reports a stash change as `.refs`.
        async let newStashes = refs ? StashWorktreeReader.stashes(runner: backend.runner, cwd: cwd, env: env) : nil
        // The remotes live in the config, which the watcher does not follow: read with every refs read (each write
        // rereads the refs).
        async let newRemotes = refs ? readRemotes(backend, cwd: cwd, env: env) : nil
        return (try await newStatus, await newState, try await newRefs, try await newStashes, try await newRemotes)
    }

    /// `git remote -v`: each remote's fetch URL, in git's order.
    private nonisolated static func readRemotes(_ backend: Backend, cwd: URL, env: [String: String]) async throws
        -> [RemoteInfo]
    {
        let output = try await backend.runner.run(["remote", "-v"], cwd: cwd, env: env).text
        var remotes: [RemoteInfo] = []
        for line in output.split(separator: "\n") where line.hasSuffix(" (fetch)") {
            let fields = line.dropLast(" (fetch)".count).split(separator: "\t", maxSplits: 1)
            guard fields.count == 2 else { continue }
            remotes.append(RemoteInfo(name: String(fields[0]), url: String(fields[1])))
        }
        return remotes
    }

    // MARK: Log

    /// (Re)loads the whole log and lays out its graph off the main actor. The first load publishes the first page
    /// as soon as it is parsed; a reload keeps the old log on screen until the new one is complete. A newer load
    /// cancels this one.
    private func loadLog(_ backend: Backend) {
        logTask?.cancel()
        let isFirstLoad = log.value == nil
        if isFirstLoad { log = .loading }
        let cwd = url
        logGeneration &+= 1
        let generation = logGeneration
        logTask = Task { [weak self] in
            do {
                let snapshot = try await Self.readLog(backend, cwd: cwd, generation: generation) { first in
                    guard isFirstLoad, !Task.isCancelled else { return }
                    await MainActor.run { self?.log = .loaded(first) }
                }
                try Task.checkCancellation()
                guard let self else { return }
                let previous = log.value
                log = .loaded(snapshot)
                logTask = nil
                UITiming.logComplete(commitCount: snapshot.commits.count)
                if !isFirstLoad { dropVanishedSelection(previousLog: previous) }
                // The status or the stashes changed while it loaded.
                if syntheticRowsChanged { loadLog(backend) }
            } catch {
                guard !Self.isCancellation(error), let self else { return }
                logTask = nil
                if isFirstLoad || log.value == nil {
                    log = .failed(Self.message(for: error))
                } else {
                    Self.logger.error("log reload failed: \(error, privacy: .public)")
                }
            }
        }
    }

    /// Parses every page and lays it out, off the main actor, below the WIP and stash rows (the status and the stashes
    /// are read while git walks the history). `firstPage` gets the first page (laid out) as soon as it is ready.
    /// Throws `CancellationError` when cancelled (the stream itself ends without an error then).
    @concurrent
    private nonisolated static func readLog(
        _ backend: Backend, cwd: URL, generation: Int, firstPage: @Sendable (LogSnapshot) async -> Void
    ) async throws -> LogSnapshot {
        let env = try await backend.readEnvironment(cwd: cwd)
        let pages = LogReader.pages(runner: backend.runner, cwd: cwd, env: env)
        async let status = StatusReader.read(runner: backend.runner, cwd: cwd, env: env)
        async let stashes = StashWorktreeReader.stashes(runner: backend.runner, cwd: cwd, env: env)
        var layout = GraphLayout()
        var snapshot = LogSnapshot(generation: generation)
        snapshot.stashes = try await stashes
        snapshot.synthetic = syntheticRows(status: try await status, stashes: snapshot.stashes)
        snapshot.syntheticRows = layout.append(snapshot.synthetic)
        var isFirst = true
        for try await page in pages {
            snapshot.commits += page
            snapshot.rows += layout.append(page)
            if isFirst {
                isFirst = false
                await firstPage(snapshot)
            }
        }
        try Task.checkCancellation()
        snapshot.isComplete = true
        return snapshot
    }

    // MARK: File diff

    /// Files over this size (any side of the diff) show a "Load anyway" card instead of their diff.
    nonisolated static let fileSizeLimit = 2 * 1024 * 1024
    /// The context of a "Full file" diff: more lines than any file has, so its one hunk is the whole file.
    private nonisolated static let fullFileContext = 10_000_000

    /// The timing log's detail of the open file (`file src/app.swift`, `conflict long.txt`).
    var fileDetail: String { openFile.map(fileDetail) ?? "" }

    /// Shows `target`'s diff in panel2 instead of the graph now: `fileDiff` is `.loading` when this returns, so the
    /// placeholder shows in the click's frame. The diff loads in a task that a newer select cancels.
    /// A conflicted WIP file opens the conflict editor instead of a diff (`FileTarget.isConflict`).
    func selectFile(_ target: FileTarget) {
        UITiming.select(fileDetail(target))
        openFile = target
        fileIgnoresSizeLimit = false
        startFileLoad()
    }

    /// Opens a WIP file by its path (DEBUG `-HistqSelect file:<path>`) as its row in the WIP panel would: an
    /// untracked file as untracked, a file with unstaged changes as its Unstaged row, else as its Staged row.
    func selectWIPFile(_ path: String) {
        let file: FileChange = switch status.value?.entries.first(where: { $0.path == path }) {
        case let entry? where entry.kind == .untracked: FileChange(kind: .untracked, path: path)
        case let entry? where entry.kind == .unmerged: FileChange(kind: .conflicted, path: path)
        case let entry? where entry.isUnstaged: FileChange(letter: entry.worktree.rawValue, path: path)
        case let entry?: FileChange(letter: entry.index.rawValue, path: path, originalPath: entry.originalPath)
        case nil: FileChange(kind: .modified, path: path)
        }
        selectFile(FileTarget(source: .wip, file: file))
    }

    /// Shows the graph again (Esc, the back button, the conflict editor's close, another graph row or sidebar ref).
    /// The conflict editor's unsaved ticks and edits go with it.
    func closeFile() {
        guard openFile != nil else { return }
        fileTask?.cancel()
        fileTask = nil
        openFile = nil
        fileDiff = .idle
        conflict = .idle
        conflictBusy = nil
        conflictError = nil
    }

    /// Loads the open file past the size limit: its card's "Load anyway".
    func loadFileAnyway() {
        guard openFile != nil else { return }
        fileIgnoresSizeLimit = true
        startFileLoad()
    }

    /// Stages, unstages or discards `lines` of `file` (the diff a table shows, so the patch matches what the user
    /// selected) through the write path. Discarding asks first: the working tree loses those lines.
    func apply(_ action: PatchBuilder.Action, lines: Set<DiffLineID>, of file: FileDiff) {
        let patch: Data
        do {
            patch = try PatchBuilder.patch(for: file, selecting: lines, action: action)
        } catch {
            Self.logger.error("no patch for \(file.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }
        let count = lines.count { id in
            file.hunks.indices.contains(id.hunk) && file.hunks[id.hunk].lines.indices.contains(id.line)
                && file.hunks[id.hunk].lines[id.line].isChange
        }
        let what = count == 1 ? "1 line" : "\(count) lines"
        let name = (file.path as NSString).lastPathComponent
        switch action {
        case .stage:
            run(.applyPatch(patch, .stage), title: "Stage \(what) of \(name)")
        case .unstage:
            run(.applyPatch(patch, .unstage), title: "Unstage \(what) of \(name)")
        case .discard:
            confirm("Discard \(what) of \(name)?", message: "This cannot be undone.", button: "Discard",
                    write: .applyPatch(patch, .discard), operation: "Discard \(what) of \(name)")
        }
    }

    private func fileDetail(_ target: FileTarget) -> String {
        target.isConflict ? "conflict \(target.path)" : "file \(target.path)"
    }

    private func startFileLoad() {
        fileToken &+= 1
        if openFile?.isConflict == true {
            conflict = .loading
            conflictBusy = nil
            conflictError = nil
            return loadConflict()
        }
        fileDiff = .loading
        loadFile(quietly: false)
    }

    /// Reads the open file's diff off the main actor. A quiet load (after a status change) keeps the diff on screen
    /// until the new one is in, and goes back to the graph when the file no longer has a change.
    private func loadFile(quietly: Bool) {
        guard let target = openFile else { return }
        // Quiet only over a loaded diff: during the first load the placeholder stays and this load takes its place.
        let quietly = quietly && fileDiff.value != nil
        fileTask?.cancel()
        let token = fileToken
        let ignoresSizeLimit = fileIgnoresSizeLimit
        fileLoadCount &+= 1
        let loadID = fileLoadCount
        fileTask = Task { [weak self] in
            guard let self else { return }
            do {
                let backend = try await backend()
                let loaded = try await Self.readFileDiff(
                    backend, cwd: url, target: target, ignoresSizeLimit: ignoresSizeLimit, loadID: loadID)
                try Task.checkCancellation()
                guard token == fileToken, openFile == target else { return }
                if quietly, case .unchanged = loaded.content { return closeFile() }
                fileDiff = .loaded(loaded)
            } catch {
                guard token == fileToken, openFile == target, !Self.isCancellation(error) else { return }
                // A failed quiet reload keeps the diff on screen; the next status change tries again.
                if !quietly { fileDiff = .failed(Self.message(for: error)) }
            }
        }
    }

    /// The diff of `target` with the read environment (no textconv, no external diff, no filters), off the main actor:
    /// a WIP file's unstaged and staged changes, or a commit's changes against its first parent. Each comes twice, with
    /// git's context (Diff mode) and with the whole file as context (Full file mode, and the syntax state of every
    /// line). Untracked files are read from disk.
    @concurrent
    private nonisolated static func readFileDiff(
        _ backend: Backend, cwd: URL, target: FileTarget, ignoresSizeLimit: Bool, loadID: Int
    ) async throws -> FileDiffDetail {
        if case .commit(let hash) = target.source, !GitOperations.isObjectID(hash) {
            throw CommitReadError.notACommit(hash)
        }
        let env = try await backend.readEnvironment(cwd: cwd)
        let runner = backend.runner
        let file = target.file
        let language = LanguageTable.language(forPath: file.path)
        if !ignoresSizeLimit {
            let size = await largestSize(of: target, runner: runner, cwd: cwd, env: env)
            if size > fileSizeLimit { return FileDiffDetail(loadID: loadID, content: .tooLarge(size)) }
        }
        let paths = [file.originalPath, file.path].compactMap { $0 }
        let full = fullFileContext
        switch target.source {
        case .wip where file.kind == .untracked:
            return FileDiffDetail(loadID: loadID, content: try untrackedContent(file.path, cwd: cwd, language: language))
        case .wip:
            async let unstaged = DiffReader.unstaged(runner: runner, cwd: cwd, env: env, paths: [file.path])
            async let unstagedFull = DiffReader.unstaged(
                runner: runner, cwd: cwd, env: env, paths: [file.path], context: full)
            async let staged = DiffReader.staged(runner: runner, cwd: cwd, env: env, paths: paths)
            async let stagedFull = DiffReader.staged(runner: runner, cwd: cwd, env: env, paths: paths, context: full)
            let sections = [
                DiffSection(side: .unstaged, diff: pick(try await unstaged, file), full: pick(try await unstagedFull, file),
                            language: language),
                DiffSection(side: .staged, diff: pick(try await staged, file), full: pick(try await stagedFull, file),
                            language: language),
            ]
            return FileDiffDetail(loadID: loadID, sections: sections.compactMap { $0 })
        case .commit(let hash):
            // A stash's untracked file is only in its untracked-files commit (a root commit: every line added).
            let revision = file.kind == .untracked ? "\(hash)^3" : hash
            async let diff = DiffReader.commit(revision, runner: runner, cwd: cwd, env: env, paths: paths)
            async let diffFull = DiffReader.commit(
                revision, runner: runner, cwd: cwd, env: env, paths: paths, context: full)
            let section = DiffSection(side: .commit, diff: pick(try await diff, file), full: pick(try await diffFull, file),
                                      language: language)
            return FileDiffDetail(loadID: loadID, sections: [section].compactMap { $0 })
        }
    }

    /// The diff of `file` among those git printed for its paths (a rename's old path is in the pathspec too).
    private nonisolated static func pick(_ diffs: [FileDiff], _ file: FileChange) -> FileDiff? {
        diffs.first { $0.path == file.path || $0.oldPath == file.path } ?? diffs.first
    }

    /// The largest size of the file on any side its diff reads: for a WIP file the working tree (the entry itself,
    /// never a symlink's target), the index and HEAD; for a commit, the commit and its first parent. A side that does
    /// not exist counts as 0.
    private nonisolated static func largestSize(
        of target: FileTarget, runner: GitRunner, cwd: URL, env: [String: String]
    ) async -> Int {
        let file = target.file
        let oldPath = file.originalPath ?? file.path
        var size = 0
        let objects: [String]
        switch target.source {
        case .wip:
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: cwd.appending(path: file.path, directoryHint: .notDirectory).path)
            size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            objects = [":0:\(file.path)", "HEAD:\(oldPath)"]
        case .commit(let hash):
            objects = file.kind == .untracked
                ? ["\(hash)^3:\(file.path)"] : ["\(hash):\(file.path)", "\(hash)^:\(oldPath)"]
        }
        for object in objects {
            // Exit 128: no such object on that side (an added file, a root commit, an unborn branch).
            guard let result = try? await runner.run(
                ["cat-file", "-s", object], cwd: cwd, env: env, allowedExitCodes: [0, 128]),
                result.exitCode == 0,
                let bytes = Int(result.text.trimmingCharacters(in: .whitespacesAndNewlines))
            else { continue }
            size = max(size, bytes)
        }
        return size
    }

    /// An untracked file has no git diff: its lines read from disk, all added (display only). The entry is opened
    /// without following a symlink and without blocking, and only a regular file is read, so a planted link or FIFO
    /// cannot point the read at a device; a symlink shows its target, which is what git would stage.
    private nonisolated static func untrackedContent(_ path: String, cwd: URL, language: Language?) throws
        -> FileDiffDetail.Content
    {
        let fullPath = cwd.appending(path: path, directoryHint: .notDirectory).path
        let data: Data
        let fd = open(fullPath, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd >= 0 {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .unchanged }
            data = try handle.readToEnd() ?? Data()
        } else if errno == ELOOP {
            data = Data(try FileManager.default.destinationOfSymbolicLink(atPath: fullPath).utf8)
        } else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: fullPath])
        }
        // git's own test: a NUL in the first 8000 bytes makes a file binary.
        if data.prefix(8000).contains(0) { return .binary }
        return .sections([DiffSection(untracked: data, language: language)])
    }

    // MARK: Conflict editor

    /// Opens the conflict editor on a conflicted WIP path (DEBUG `-HistqSelect conflict:<path>`) as a click on its row
    /// in the WIP panel does: through `selectFile`, so panel2 shows its placeholder in the same call.
    func selectConflict(_ path: String) {
        selectFile(FileTarget(source: .wip, file: FileChange(kind: .conflicted, path: path)))
    }

    /// Reads the open conflicted file's stages off the main actor (read environment) and builds its 3-way merge.
    private func loadConflict() {
        guard let target = openFile else { return }
        fileTask?.cancel()
        let token = fileToken
        fileLoadCount &+= 1
        let loadID = fileLoadCount
        fileTask = Task { [weak self] in
            guard let self else { return }
            do {
                let backend = try await backend()
                let loaded = try await Self.readConflict(backend, cwd: url, path: target.path, loadID: loadID)
                try Task.checkCancellation()
                guard token == fileToken, openFile == target else { return }
                conflict = .loaded(loaded)
                #if DEBUG
                runLaunchResolve()
                #endif
            } catch {
                guard token == fileToken, openFile == target, !Self.isCancellation(error) else { return }
                conflict = .failed(Self.message(for: error))
            }
        }
    }

    /// The stages of `path` (`ConflictSource.load`), the pane labels of the operation in progress and the short hashes
    /// of the commits A and B come from: HEAD, and the merged, replayed, picked or reverted commit. The merge itself
    /// is built here too, off the main actor.
    @concurrent
    private nonisolated static func readConflict(_ backend: Backend, cwd: URL, path: String, loadID: Int) async throws
        -> ConflictDocument
    {
        let env = try await backend.readEnvironment(cwd: cwd)
        let runner = backend.runner
        let state = try await RepoState.read(runner: runner, cwd: cwd, env: env)
        let incoming: String? = switch state.operation {
        case .merge: "MERGE_HEAD"
        case .rebase: "REBASE_HEAD"
        case .cherryPick: "CHERRY_PICK_HEAD"
        case .revert: "REVERT_HEAD"
        case .none: nil
        }
        async let source = ConflictSource.load(path: path, labels: state.labels, runner: runner, cwd: cwd, env: env)
        async let aCommit = shortHash("HEAD", runner: runner, cwd: cwd, env: env)
        async let bCommit = incoming == nil ? nil : shortHash(incoming ?? "", runner: runner, cwd: cwd, env: env)
        return ConflictDocument(loadID: loadID, source: try await source, aCommit: try await aCommit,
                                bCommit: try await bCommit)
    }

    /// The short hash of the commit a fixed pseudo-ref (`HEAD`, `MERGE_HEAD`) names; nil when it does not exist.
    private nonisolated static func shortHash(
        _ name: String, runner: GitRunner, cwd: URL, env: [String: String]
    ) async throws -> String? {
        let result = try await runner.run(
            ["rev-parse", "-q", "--short", "--verify", "\(name)^{commit}"], cwd: cwd, env: env, allowedExitCodes: [0, 1])
        let hash = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.exitCode == 0 && !hash.isEmpty ? hash : nil
    }

    /// Changes the loaded conflict's merge and tells the panes (`revision`).
    private func updateConflict(_ change: (inout ConflictDocument) -> Void) {
        guard case .loaded(var document) = conflict, document.merge != nil else { return }
        change(&document)
        document.revision &+= 1
        conflict = .loaded(document)
    }

    /// A line checkbox of pane A or B: ticks or unticks those lines (indices in that pane).
    func setConflictTicked(_ ticked: Bool, side: ThreeWayMerge.Side, lines: [Int]) {
        updateConflict { $0.merge?.setTicked(ticked, side: side, lines: lines) }
    }

    /// A hunk checkbox: every line of one side of conflict `k` (0-based); "conflict k of N" follows it.
    func setConflictTicked(_ ticked: Bool, side: ThreeWayMerge.Side, conflict k: Int) {
        updateConflict { document in
            guard let merge = document.merge, merge.conflictRegions.indices.contains(k) else { return }
            document.merge?.setTicked(ticked, side: side, conflict: k)
            document.current = k
        }
    }

    /// A pane header's checkbox: every conflict line of one side.
    func setConflictTickedAll(_ ticked: Bool, side: ThreeWayMerge.Side) {
        updateConflict { $0.merge?.setTickedAll(ticked, side: side) }
    }

    /// The user typed in Output: `text` becomes the manual edit of the first region of `regions`, and the other regions
    /// the edit swallowed become empty. Only regions the edit touched are changed. Returns the new merge, so Output can
    /// match it at once (the merge adds back a line break the edit removed between two regions).
    func editConflictOutput(_ text: String, regions: ClosedRange<Int>) -> ThreeWayMerge? {
        updateConflict { document in
            guard let merge = document.merge, merge.regions.indices.contains(regions.upperBound) else { return }
            document.merge?.setManualText(text, region: regions.lowerBound)
            for index in regions.dropFirst() { document.merge?.setManualText("", region: index) }
        }
        return conflict.value?.merge
    }

    /// "conflict k of N": the conflict the ▲ ▼ buttons moved to (0-based).
    func showConflict(_ k: Int) {
        guard case .loaded(var document) = conflict, let merge = document.merge,
              merge.conflictRegions.indices.contains(k)
        else { return }
        document.current = k
        conflict = .loaded(document)
    }

    /// Save: writes Output's bytes to the file, then `git add`. Only once every conflict is resolved.
    func saveConflict() {
        guard let merge = conflict.value?.merge, merge.unresolvedCount == 0 else { return }
        resolveConflict(keeping: merge.outputData, title: "Saving…")
    }

    /// Resolves the open conflicted file with `content` (Output, the version a chooser keeps), or deletes it when nil,
    /// through the write path; the status refresh after it closes the editor once git no longer lists the path.
    func resolveConflict(keeping content: Data?, title: String) {
        guard let target = openFile, target.isConflict, conflictBusy == nil else { return }
        conflictBusy = title
        conflictError = nil
        let token = fileToken
        Task { [weak self] in
            guard let self else { return }
            do {
                try await perform(.resolveConflict(path: target.path, content: content))
            } catch {
                guard token == fileToken else { return }
                conflictError = Self.message(for: error)
            }
            if token == fileToken { conflictBusy = nil }
        }
    }

    /// "Open in external merge tool": `git mergetool --no-prompt [--tool=<PrefKey.mergeTool>] -- <path>` with the write
    /// environment, as an operation (the action bar shows it running, its failure goes to the error banner). A tool
    /// name that is not a plain name is refused rather than passed to git.
    func openMergeTool() {
        guard let target = openFile, target.isConflict else { return }
        let setting = (Preferences.defaults.string(forKey: PrefKey.mergeTool.rawValue) ?? "")
            .trimmingCharacters(in: .whitespaces)
        let isPlainName = (setting.first.map { $0.isLetter || $0.isNumber } ?? true)
            && setting.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
        guard isPlainName else {
            conflictError = "The merge tool setting \"\(setting)\" is not a tool name."
            return
        }
        conflictError = nil
        let name = (target.path as NSString).lastPathComponent
        run(.mergeTool(path: target.path, tool: setting.isEmpty ? nil : setting), title: "Merge tool for \(name)")
    }

    /// Writes a resolution into the working tree: atomically (a temporary file renamed over the old one, so a crash
    /// never leaves half a file and a symlink is replaced, not followed), keeping the old file's permissions. nil
    /// deletes the file. `path` must stay inside `cwd`: no absolute path, no `..`, no folder that is a symlink out.
    private nonisolated static func writeResolution(_ content: Data?, to path: String, cwd: URL) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), parts.first != ".git",
            !parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty })
        else {
            throw ConflictWriteError.outsideRepository(path)
        }
        let file = cwd.appending(path: path, directoryHint: .notDirectory)
        // Each parent folder is checked with lstat, from the repo root down, and created when missing: a folder that
        // is a symlink (planted by an untrusted repo, or not created yet when a resolved path is checked) could
        // otherwise send the write outside the repository.
        var folder = cwd
        for part in parts.dropLast() {
            folder = folder.appending(path: String(part), directoryHint: .isDirectory)
            var info = stat()
            if lstat(folder.path, &info) != 0 {
                guard errno == ENOENT, mkdir(folder.path, 0o755) == 0 else {
                    throw ConflictWriteError.outsideRepository(path)
                }
            } else if info.st_mode & S_IFMT != S_IFDIR {
                throw ConflictWriteError.outsideRepository(path)
            }
        }
        let fm = FileManager.default
        // attributesOfItem does not follow a symlink at the file itself; the atomic write and the removal replace or
        // remove that link, never its target.
        let attributes = try? fm.attributesOfItem(atPath: file.path)
        guard let content else {
            if attributes != nil { try fm.removeItem(at: file) }
            return
        }
        try content.write(to: file, options: .atomic)
        if attributes?[.type] as? FileAttributeType == .typeRegular, let mode = attributes?[.posixPermissions] {
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        }
    }

    private enum ConflictWriteError: LocalizedError {
        case outsideRepository(String)

        var errorDescription: String? {
            switch self {
            case .outsideRepository(let path): "\(path) is not a file inside this repository."
            }
        }
    }

    #if DEBUG
    /// Whether `-HistqResolve` already ran in this launch.
    private static var launchResolveDone = false

    /// DEBUG `-HistqResolve A1,B2,AB3[,save]`: once, when the first conflict loads, ticks the named sides of conflict k
    /// (1-based) through the hunk checkboxes' path, then presses Save when `save` is listed. `keep` or `delete` presses
    /// the modify/delete chooser's Keep File or Delete File instead. A short wait lets the editor show first.
    private func runLaunchResolve() {
        guard !Self.launchResolveDone, let spec = AppState.launchFlag("-HistqResolve") else { return }
        Self.launchResolveDone = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            var save = false
            for item in spec.split(separator: ",") {
                if item == "save" {
                    save = true
                    continue
                }
                if item == "keep" || item == "delete" {
                    guard case .modifyDelete(_, let a, let b)? = conflict.value?.source.content else {
                        Self.logger.error("-HistqResolve: \(item, privacy: .public) needs a modify/delete conflict")
                        return
                    }
                    return resolveConflict(keeping: item == "keep" ? a ?? b : nil,
                                           title: item == "keep" ? "Keeping…" : "Deleting…")
                }
                let sides = item.prefix { $0 == "A" || $0 == "B" }
                guard let k = Int(item.dropFirst(sides.count)), k >= 1 else {
                    Self.logger.error("-HistqResolve: bad item \(item, privacy: .public)")
                    return
                }
                if sides.contains("A") { setConflictTicked(true, side: .a, conflict: k - 1) }
                if sides.contains("B") { setConflictTicked(true, side: .b, conflict: k - 1) }
            }
            if save { saveConflict() }
        }
    }
    #endif

    // MARK: Operation in progress

    /// A button of the operation banner.
    enum OperationStep: Sendable {
        case `continue`, abort, skip
    }

    /// The running operation's title of `step` ("Continue Merge", "Abort Rebase", "Skip Commit"): the banner finds its
    /// step in `running` by it, also when the step started from a confirmation.
    static func title(of step: OperationStep, _ operation: RepoState.Operation) -> String {
        let name = switch operation {
        case .merge: "Merge"
        case .rebase: "Rebase"
        case .cherryPick: "Cherry-pick"
        case .revert: "Revert"
        case .none: "Operation"
        }
        return switch step {
        case .continue: "Continue \(name)"
        case .abort: "Abort \(name)"
        case .skip: "Skip Commit"
        }
    }

    /// Whether one of the banner's steps is running: its buttons wait, so a second click cannot start another.
    var isOperationStepRunning: Bool {
        guard let operation = repoState?.operation, operation != .none else { return false }
        let titles = [OperationStep.continue, .abort, .skip].map { Self.title(of: $0, operation) }
        return running.contains { titles.contains($0.title) }
    }

    /// Continue needs an operation in progress and no file left with a conflict (git refuses otherwise).
    var canContinueOperation: Bool {
        guard repoState?.isOperationInProgress == true, let status = status.value else { return false }
        return status.conflicted.isEmpty && !isOperationStepRunning
    }

    /// The banner's Continue: commits the resolution (a merge, cherry-pick or revert) or goes on with the next commit
    /// of a rebase, which may stop on new conflicts. The status read after it updates the banner.
    func continueOperation() {
        guard canContinueOperation, let operation = repoState?.operation else { return }
        run(.continueOperation(operation), title: Self.title(of: .continue, operation))
    }

    /// The banner's Abort, after a confirmation: the branch, the index and the files go back to before the operation,
    /// and the resolutions made so far are lost.
    func abortOperation() {
        guard let operation = repoState?.operation, operation != .none, !isOperationStepRunning else { return }
        let noun = Self.title(of: .abort, operation).dropFirst("Abort ".count).lowercased()
        confirm("Abort the \(noun)?",
                message: "The branch and the working tree go back to how they were before the \(noun). The conflicts "
                    + "resolved so far are lost.",
                button: Self.title(of: .abort, operation), write: .abortOperation(operation),
                operation: Self.title(of: .abort, operation))
    }

    /// The banner's Skip (a rebase only), after a confirmation: the commit being replayed is left out of the branch.
    func skipOperation() {
        guard repoState?.operation == .rebase, !isOperationStepRunning else { return }
        confirm("Skip this commit?", message: "The rebased branch will not have its changes.", button: "Skip Commit",
                write: .skipOperation(.rebase), operation: Self.title(of: .skip, .rebase))
    }

    #if DEBUG
    /// DEBUG `-HistqOperation continue|abort|skip`: once the status and the operation in progress are read, presses the
    /// banner's button through the same method; a confirmation is accepted as the user would.
    private func runLaunchOperation(_ step: String) {
        switch step {
        case "continue":
            if !canContinueOperation { Self.logger.error("-HistqOperation continue: Continue is disabled") }
            continueOperation()
        case "abort": abortOperation()
        case "skip": skipOperation()
        default: Self.logger.error("-HistqOperation: unknown step \(step, privacy: .public)")
        }
        if let confirmation {
            self.confirmation = nil
            run(confirmation.write, title: confirmation.operation, key: confirmation.key)
        }
    }
    #endif

    /// "Checkout this version" of a commit's file (its diff header): `git checkout <commit> -- <path>` through the write
    /// path, after a confirmation that says what the working tree loses. A stash's untracked file comes from the
    /// stash's untracked-files commit.
    func checkoutVersion(of target: FileTarget) {
        guard case .commit(let hash) = target.source, target.file.kind != .deleted else { return }
        let file = target.file
        let revision = file.kind == .untracked ? "\(hash)^3" : hash
        let short = String(hash.prefix(7))
        let isChanged = status.value?.entries.contains { $0.path == file.path } ?? false
        confirm("Replace \(file.name) with its version from \(short)?",
                message: isChanged
                    ? "Its staged and unstaged changes are lost."
                    : "The file in the working tree and the index becomes this version.",
                button: "Checkout This Version", write: .checkoutFiles([file.path], from: revision),
                operation: "Checkout \(file.name) from \(short)", isDestructive: isChanged)
    }

    // MARK: Commit detail

    /// One commit's message, people, dates and parents (`git log -1`), then its files against its first parent
    /// (`diff-tree --name-status`; a root commit against the empty tree, a merge against its first parent, a stash
    /// adds its untracked files). Read environment, off the main actor.
    @concurrent
    private nonisolated static func readCommit(_ backend: Backend, cwd: URL, hash: String, isStash: Bool) async throws
        -> CommitDetail
    {
        guard GitOperations.isObjectID(hash) else { throw CommitReadError.notACommit(hash) }
        let env = try await backend.readEnvironment(cwd: cwd)
        let format = "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%cn%x1f%ce%x1f%ct%x1f%s%x1f%b"
        let info = try await backend.runner.run(
            ["log", "-1", "-z", "--no-show-signature", format, "--end-of-options", hash, "--"], cwd: cwd, env: env)
        var text = info.text
        while text.last == "\0" || text.last == "\n" { text.removeLast() }
        let fields = text.split(separator: "\u{1F}", maxSplits: 9, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 10 else { throw CommitReadError.notACommit(hash) }
        let parents = fields[1].split(separator: " ").map(String.init)
        let date = { (field: String) in Date(timeIntervalSince1970: TimeInterval(field) ?? 0) }

        let fileOptions = ["diff-tree", "-r", "-z", "--name-status", "-M", "--no-ext-diff", "--no-textconv",
                           "--no-commit-id"]
        let full = fields[0]
        let revisions = parents.first.map { ["--end-of-options", $0, full] } ?? ["--root", "--end-of-options", full]
        var files = parseNameStatus(
            try await backend.runner.run(fileOptions + revisions + ["--"], cwd: cwd, env: env).stdout)
        if isStash, parents.count > 2 {
            let untracked = parseNameStatus(try await backend.runner.run(
                fileOptions + ["--root", "--end-of-options", parents[2], "--"], cwd: cwd, env: env).stdout)
            let known = Set(files.map(\.path))
            files += untracked.filter { !known.contains($0.path) }.map { FileChange(kind: .untracked, path: $0.path) }
        }
        return CommitDetail(
            hash: full, parents: parents, authorName: fields[2], authorEmail: fields[3], authorDate: date(fields[4]),
            committerName: fields[5], committerEmail: fields[6], committerDate: date(fields[7]), subject: fields[8],
            body: fields[9], files: files, isStash: isStash)
    }

    /// `--name-status -z`: a status (`M`, `A`, `D`, `T`, `R100`, `C75`), then the path; renames and copies give the
    /// old path, then the new one.
    private nonisolated static func parseNameStatus(_ output: Data) -> [FileChange] {
        var fields = output.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.makeIterator()
        var files: [FileChange] = []
        while let status = fields.next(), let letter = status.first {
            guard let path = fields.next() else { break }
            if letter == "R" || letter == "C" {
                guard let newPath = fields.next() else { break }
                files.append(FileChange(letter: letter, path: newPath, originalPath: path))
            } else {
                files.append(FileChange(letter: letter, path: path))
            }
        }
        return files
    }

    private enum CommitReadError: LocalizedError {
        case notACommit(String)
        case refGone(String)

        var errorDescription: String? {
            switch self {
            case .notACommit(let text): "\(text) is not a commit."
            case .refGone(let ref): "The \(ref) no longer exists."
            }
        }
    }

    /// HEAD's message (subject, then body), for the commit box's Amend. Read environment.
    func lastCommitMessage() async throws -> (subject: String, body: String) {
        let backend = try await backend()
        guard let head = status.value?.branch.commit else { return ("", "") }
        let commit = try await Self.readCommit(backend, cwd: url, hash: head, isStash: false)
        return (commit.subject, commit.body)
    }

    // MARK: Writes

    /// Runs a user-initiated write of the WIP panel with the write environment (the login shell's PATH, for hooks
    /// and signing tools), off the main actor, then rereads the status and the refs (also when it failed: it may have
    /// done part of its work). Throws the write's error; `writeMessage(for:)` words it for the panel.
    func perform(_ write: Write) async throws {
        let backend = try await backend()
        do {
            try await Self.run(write, backend: backend, cwd: url)
        } catch {
            await refreshAfterWrite()
            throw error
        }
        await refreshAfterWrite()
    }

    private func refreshAfterWrite() async {
        refresh(scope: [.status, .refs])
        await refreshTask?.value
    }

    @concurrent
    private nonisolated static func run(_ write: Write, backend: Backend, cwd: URL) async throws {
        let base = await GitToolchain.writeBase()
        let ops = GitOperations(
            runner: backend.runner, cwd: cwd, env: GitInvocation.environment(profile: nil, base: base))
        switch write {
        case .stage(let paths): try await ops.stage(paths)
        case .stageAll: try await ops.stageAll()
        case .unstage(let paths): try await ops.unstage(paths)
        case .unstageAll: try await ops.unstageAll()
        case .discard(let paths): try await ops.discard(paths)
        case .removeUntracked(let paths): try await ops.removeUntracked(paths)
        case .discardAll(let includingUntracked): try await ops.discardAll(includingUntracked: includingUntracked)
        case .commit(let message): try await ops.commit(message: message)
        case .amend(let message): try await ops.amend(message: message)
        case .applyPatch(let patch, let action):
            // `apply` takes the runner's write lane itself, like the operations.
            try await PatchBuilder.apply(
                patch, action: action, runner: backend.runner, cwd: cwd,
                env: GitInvocation.environment(profile: nil, base: base))

        case .checkoutBranch(let name): try await ops.checkout(branch: name)
        case .checkoutTracking(let remoteBranch, let localName):
            try await ops.checkoutTracking(remoteBranch: remoteBranch, as: localName)
        case .checkoutCommit(let revision): try await ops.checkout(commit: revision)
        case .checkoutFiles(let paths, let revision): try await ops.checkoutFiles(paths, from: revision)

        case .fetchAll(let prune): try await ops.fetchAll(prune: prune)
        case .pull(let mode): try await ops.pull(mode)
        case .push(let branch, let remote, let remoteBranch, let setUpstream, let lease):
            try await ops.push(
                branch: branch, to: remote, as: remoteBranch, setUpstream: setUpstream, forceWithLease: lease)
        case .pushTag(let name, let remote): try await ops.pushTag(name, to: remote)
        case .pushMirror(let remote): try await ops.pushMirror(to: remote)
        case .deleteRemoteBranch(let name, let remote): try await ops.deleteRemoteBranch(name, on: remote)
        case .deleteRemoteTag(let name, let remote): try await ops.deleteRemoteTag(name, on: remote)

        case .createBranch(let name, let revision, let checkout):
            try await ops.createBranch(name, from: revision, checkout: checkout)
        case .renameBranch(let name, let newName): try await ops.renameBranch(name, to: newName)
        case .deleteBranch(let name, let force): try await ops.deleteBranch(name, force: force)
        case .setUpstream(let branch, let upstream): try await ops.setUpstream(of: branch, to: upstream)

        case .addRemote(let name, let url): try await ops.addRemote(name, url: url)
        case .removeRemote(let name): try await ops.removeRemote(name)
        case .renameRemote(let name, let newName): try await ops.renameRemote(name, to: newName)
        case .setRemoteURL(let name, let url): try await ops.setRemoteURL(name, url: url)

        case .merge(let revision, let checkoutFirst):
            if let checkoutFirst { try await ops.checkout(branch: checkoutFirst) }
            try await ops.merge(revision)
        case .rebase(let upstream, let checkoutFirst):
            if let checkoutFirst { try await ops.checkout(branch: checkoutFirst) }
            try await ops.rebase(onto: upstream)
        case .fastForward(let branch, let source): try await ops.fastForward(branch, to: source)
        case .cherryPick(let commit, let mainline): try await ops.cherryPick([commit], mainline: mainline)
        case .revert(let commit, let mainline): try await ops.revert(commit, mainline: mainline)
        case .reset(let revision, let mode): try await ops.reset(to: revision, mode: mode)

        case .stashPush(let message): try await ops.stashPush(message: message, includeUntracked: true)
        case .stashApply(let hash): try await ops.stashApply(try await stashIndex(hash, backend: backend, cwd: cwd))
        case .stashPop(let hash): try await ops.stashPop(try await stashIndex(hash, backend: backend, cwd: cwd))
        case .stashDrop(let hash): try await ops.stashDrop(try await stashIndex(hash, backend: backend, cwd: cwd))

        case .createTag(let name, let revision, let message):
            try await ops.createTag(name, at: revision, message: message)
        case .deleteTag(let name): try await ops.deleteTag(name)

        case .resolveConflict(let path, let content):
            try writeResolution(content, to: path, cwd: cwd)
            try await ops.stage([path])
        case .mergeTool(let path, let tool):
            let env = GitInvocation.environment(profile: nil, base: base)
            let runner = backend.runner
            let args = ["--literal-pathspecs", "mergetool", "--no-prompt"] + (tool.map { ["--tool=\($0)"] } ?? [])
                + ["--", path]
            _ = try await runner.mutate { try await runner.run(args, cwd: cwd, env: env) }

        case .continueOperation(let operation): try await ops.continueOperation(operation)
        case .abortOperation(let operation): try await ops.abortOperation(operation)
        case .skipOperation(let operation): try await ops.skipOperation(operation)
        }
    }

    /// The current `stash@{n}` of the stash whose commit is `hash` (read environment); fails when it is gone.
    private nonisolated static func stashIndex(_ hash: String, backend: Backend, cwd: URL) async throws -> Int {
        let env = try await backend.readEnvironment(cwd: cwd)
        let stashes = try await StashWorktreeReader.stashes(runner: backend.runner, cwd: cwd, env: env)
        guard let stash = stashes.first(where: { $0.hash == hash }) else { throw OperationError.stashGone }
        return stash.index
    }

    // MARK: Operations

    /// Runs a user operation (the action bar, a menu, a dialog) through `perform` without blocking: it is in `running`
    /// when this returns (with `key`, the action bar button that shows it), and a failure goes to `failure`, the
    /// error banner. A new operation clears the banner.
    func run(_ write: Write, title: String, key: ActionBarAction? = nil) {
        nextOperationID &+= 1
        let operation = RunningOperation(id: nextOperationID, title: title, key: key)
        running.append(operation)
        failure = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await perform(write)
            } catch {
                if !(error is CancellationError) {
                    failure = OperationFailure(title: title, write: write, error: error, message: Self.message(for: error))
                }
            }
            running.removeAll { $0.id == operation.id }
        }
    }

    /// Whether the action bar's `key` operation is running.
    func isRunning(_ key: ActionBarAction) -> Bool {
        running.contains { $0.key == key }
    }

    /// Asks for a confirmation before `write` (a destructive operation); `OperationDialogs` shows it, naming the
    /// target, and runs the write on confirm.
    func confirm(_ title: String, message: String, button: String, write: Write, operation: String,
                 key: ActionBarAction? = nil, isDestructive: Bool = true)
    {
        confirmation = OperationConfirmation(
            title: title, message: message, button: button, write: write, operation: operation, key: key,
            isDestructive: isDestructive)
    }

    /// The checked-out branch; nil on a detached HEAD or before the refs are read.
    var currentBranch: String? {
        switch refs.value?.head {
        case .branch(let name, _), .unborn(let name): name
        case .detached, nil: nil
        }
    }

    enum NameKind: Sendable { case branch, tag, remote }

    /// Checks a new branch, tag or remote name as the operation will (no leading `-`, `git check-ref-format`), off the
    /// main actor with the read environment. Nil when valid, else the reason.
    func validate(_ kind: NameKind, _ name: String) async -> String? {
        guard let backend = try? await backend() else { return nil }
        return await Self.validate(kind, name, backend: backend, cwd: url)
    }

    @concurrent
    private nonisolated static func validate(_ kind: NameKind, _ name: String, backend: Backend, cwd: URL) async
        -> String?
    {
        guard let env = try? await backend.readEnvironment(cwd: cwd) else { return nil }
        let ops = GitOperations(runner: backend.runner, cwd: cwd, env: env)
        do {
            switch kind {
            case .branch: try await ops.validateBranchName(name)
            case .tag: try await ops.validateTagName(name)
            case .remote: try await ops.validateRemoteName(name)
            }
            return nil
        } catch {
            return message(for: error)
        }
    }

    // MARK: Host keys

    /// Opens the host-key sheet at once (scanning), then scans the host of `failure` (named by ssh, else the remote's
    /// URL) with `HostKeyTrust`, which writes nothing. A changed key is never scanned for trust: the sheet only warns.
    func checkHostKey(for failure: OperationFailure) {
        guard let error = failure.error as? GitError else { return }
        let isChanged = HostKeyTrust.isKeyChanged(error)
        guard let host = HostKeyTrust.host(from: error) ?? remoteHost(for: failure.write) else {
            hostKeyCheck = HostKeyCheck(
                host: nil, isChanged: isChanged, state: .failed("Histq could not tell which host this is."),
                failure: failure)
            return
        }
        hostKeyCheck = HostKeyCheck(host: host, isChanged: isChanged, state: isChanged ? .changed : .scanning,
                                    failure: failure)
        guard !isChanged else { return }
        Task { [weak self] in
            let state: HostKeyCheck.State
            do {
                state = .scanned(try await Self.scan(host))
            } catch {
                state = .failed(Self.message(for: error))
            }
            guard let self, hostKeyCheck?.host == host else { return }
            hostKeyCheck?.state = state
        }
    }

    /// Appends the scanned keys to `~/.ssh/known_hosts` (only here, on the user's "Trust Host"), closes the sheet and
    /// runs the failed operation again.
    func trustHost(_ scan: HostKeyTrust.Scan) {
        guard let check = hostKeyCheck, !check.isChanged else { return }
        hostKeyCheck?.state = .trusting(scan)
        Task { [weak self] in
            do {
                try await Self.trust(scan)
                guard let self else { return }
                hostKeyCheck = nil
                run(check.failure.write, title: check.failure.title)
            } catch {
                self?.hostKeyCheck?.state = .failed(Self.message(for: error))
            }
        }
    }

    /// The ssh host of the remote `write` talks to: its own remote, else the current branch's upstream's, else the first
    /// remote with an ssh URL.
    private func remoteHost(for write: Write) -> HostKeyTrust.Host? {
        let upstreamRemote = refs.value.flatMap { refs -> String? in
            guard let upstream = refs.localBranches.first(where: \.isHead)?.upstream else { return nil }
            return refs.remoteBranches.first { $0.name == upstream }?.remote
        }
        for name in [write.remote, upstreamRemote].compactMap({ $0 }) {
            if let url = remotes.first(where: { $0.name == name })?.url,
               let host = HostKeyTrust.host(fromRemoteURL: url)
            {
                return host
            }
        }
        return remotes.lazy.compactMap { HostKeyTrust.host(fromRemoteURL: $0.url) }.first
    }

    @concurrent
    private nonisolated static func scan(_ host: HostKeyTrust.Host) async throws -> HostKeyTrust.Scan {
        try await HostKeyTrust(environment: await GitToolchain.writeBase()).scan(host)
    }

    @concurrent
    private nonisolated static func trust(_ scan: HostKeyTrust.Scan) async throws {
        try HostKeyTrust(environment: await GitToolchain.writeBase()).trust(scan)
    }

    private enum OperationError: LocalizedError {
        case stashGone

        var errorDescription: String? {
            switch self {
            case .stashGone: "That stash no longer exists."
            }
        }
    }

    /// A short message for a failed write, shown in the card that started it.
    static func writeMessage(for error: Error) -> String {
        message(for: error)
    }

    // MARK: Setup

    /// The runner and the repo's folders, set up on first use; starts the watcher once the folders are known.
    private func backend() async throws -> Backend {
        if setUpTask == nil {
            let cwd = url
            let watcher = watcher
            let onChange: @MainActor @Sendable (RefreshScope) -> Void = { [weak self] scope in
                self?.refresh(scope: scope)
            }
            setUpTask = Task.detached(priority: .userInitiated) {
                let toolchain = try await GitToolchain.resolve()
                let runner = GitRunner(executable: toolchain.executable.url)
                let env = try await GitInvocation.readEnvironment(
                    profile: nil, base: toolchain.readBase, runner: runner, cwd: cwd)
                let directories = try await RepoDirectories.resolve(runner: runner, cwd: cwd, env: env)
                watcher.start(directories, onChange: onChange)
                return Backend(runner: runner, base: toolchain.readBase, directories: directories)
            }
        }
        guard let setUpTask else { throw CancellationError() }
        // Not cancelled with the caller: another select still needs it.
        do {
            return try await setUpTask.value
        } catch {
            // A failed setup (no git, not a repo) is retried by the next load.
            if !Self.isCancellation(error), self.setUpTask == setUpTask { self.setUpTask = nil }
            throw error
        }
    }

    // MARK: Errors

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || Task.isCancelled
    }

    /// A short message for the detail's failed state.
    private nonisolated static func message(for error: Error) -> String {
        switch error {
        case GitError.other(_, let stderrTail) where stderrTail.contains("not a git repository"):
            "This folder is not a git repository."
        case let error as GitError:
            error.stderrTail.isEmpty ? "git failed." : error.stderrTail
        case DiffReadError.missingObjects:
            "This file's contents are not downloaded yet (a partial clone): fetch to see them."
        case ConflictSourceError.notConflicted:
            "This file has no conflict left."
        case let error as GitOperationError:
            switch error {
            case .invalidBranchName(let name): "\"\(name)\" is not a valid branch name."
            case .invalidTagName(let name): "\"\(name)\" is not a valid tag name."
            case .invalidRemoteName(let name): "\"\(name)\" is not a valid remote name."
            case .invalidRemoteURL: "That is not a valid remote URL."
            case .invalidObjectID(let text): "\(text) is not a commit id."
            case .noPaths: "No files were given."
            case .invalidStashIndex: "That stash no longer exists."
            case .invalidMainline(let parent): "A merge has no parent \(parent)."
            case .noOperationInProgress: "No merge, rebase, cherry-pick or revert is in progress."
            case .unsupported(let what): "Not supported: \(what)."
            }
        case let error as HostKeyTrust.TrustError:
            switch error {
            case .invalidHost(let host): "\(host) is not a host name Histq can check."
            case .invalidPort(let port): "\(port) is not a valid port."
            case .noKeys(let host): "\(host) sent no SSH host key."
            case .toolNotFound(let tool): "\(tool) was not found."
            case .fingerprintFailed(let detail): "The key could not be fingerprinted: \(detail)"
            }
        case let error as GitExecutableError:
            switch error {
            case .commandLineToolsMissing: "Git needs the Command Line Tools."
            case .notFound: "Git was not found."
            case .notExecutable(let path): "Git at \(path) cannot run."
            case .tooOld(let version): "Git \(version) is too old; Histq needs \(GitExecutable.minimumVersion)."
            case .unrecognizedVersion: "Git did not report its version."
            }
        default:
            error.localizedDescription
        }
    }
}
