// One tab's repository: its git runner, what it has read (status, refs, the log and its graph layout), the selected
// detail with its loading state, and the watcher that keeps them current. Every git call runs off the main actor;
// the main actor only publishes results.
import Foundation
import HistqCore
import os

/// The git executable and the base environment, resolved off the main actor (resolving takes seconds: the login
/// shell's PATH and `git --version`) and kept, a failure too, until `reset()`. `prepare()` starts it at launch.
enum GitToolchain {
    struct Resolved: Sendable {
        let executable: GitExecutable
        /// `GitInvocation.baseEnvironment()`: what every invocation's environment starts from.
        let base: [String: String]
    }

    /// The resolution in flight or done; nil after `reset()`, until the next `resolve()` starts a new one.
    private static let current = OSAllocatedUnfairLock<Task<Resolved, Error>?>(initialState: nil)

    /// Starts resolving; call once at launch so the first repo does not wait for it.
    static func prepare() { _ = task() }

    static func resolve() async throws -> Resolved { try await task().value }

    /// Forgets the result, so the next `resolve()` looks for git again: after the `gitPath` preference changed or
    /// the Command Line Tools were installed. Sessions whose setup failed retry on their next load.
    static func reset() {
        current.withLock { $0 = nil }
    }

    private static func task() -> Task<Resolved, Error> {
        current.withLock { task in
            if let task { return task }
            let new = Task.detached(priority: .userInitiated) { () async throws -> Resolved in
                let override = Preferences.defaults.string(forKey: PrefKey.gitPath.rawValue)
                async let executable = GitExecutable.resolve(override: override)
                async let base = GitInvocation.baseEnvironment()
                return Resolved(executable: try await executable, base: await base)
            }
            task = new
            return new
        }
    }
}

/// The log of a repo with its graph rows, in `git log --all --topo-order` order.
struct LogSnapshot: Sendable {
    var commits: [Commit] = []
    var rows: [GraphRow] = []
    /// Every page has been parsed and laid out; false while only the first pages are in.
    var isComplete = false
}

/// One tab's repository. `select(_:)` switches the detail at once (`detail` becomes `.loading` in the same call)
/// and loads it in a cancellable task; a newer select cancels the older load. `refresh(scope:)` rereads status, refs
/// or the log (the watcher calls it). All git runs on `GitRunner`, with the read environment for this folder.
@Observable
@MainActor
final class RepoSession: Identifiable {
    /// What the detail area shows. Phase 5 adds the WIP and commit selections.
    enum Selection: Hashable, Sendable {
        /// The repo's overview: HEAD's branch, the commit count, the working tree counts.
        case overview
    }

    /// The loaded detail of a selection; the views read `status`, `refs` and `log` for its values.
    enum Detail: Sendable {
        case overview
    }

    let id = UUID()
    /// The folder the tab opened.
    let url: URL
    private(set) var selection: Selection = .overview
    private(set) var detail: Loadable<Detail> = .idle
    /// Changes with every `select`, even of the same selection: the placeholder logs a line per select.
    private(set) var selectToken = 0
    private(set) var status: Loadable<WorkingStatus> = .idle
    private(set) var refs: Loadable<Refs> = .idle
    private(set) var log: Loadable<LogSnapshot> = .idle

    /// The sidebar's tab, its selected row and its expanded section cards, kept per tab. A click sets them at once; the
    /// branch actions come in Phase 5.
    private(set) var sidebarTab: SidebarTab = .branches
    private(set) var sidebarSelection: SidebarItem?
    var localExpanded = true
    var remoteExpanded = true
    var tagsExpanded = true

    /// The runner and the folders, set up once (`backend()`).
    @ObservationIgnored private var setUpTask: Task<Backend, Error>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// The scope of the refresh in flight: a newer refresh cancels it and takes over its scope.
    @ObservationIgnored private var refreshScope: RefreshScope = []
    @ObservationIgnored private var logTask: Task<Void, Never>?
    @ObservationIgnored private let watcher = RepoWatcher()

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
    }

    deinit {
        // A window closing drops its sessions without `close()`.
        watcher.stop()
        detailTask?.cancel()
        refreshTask?.cancel()
        logTask?.cancel()
        setUpTask?.cancel()
    }

    /// Stops loading and watching; the tab closed.
    func close() {
        watcher.stop()
        detailTask?.cancel()
        refreshTask?.cancel()
        logTask?.cancel()
        setUpTask?.cancel()
    }

    // MARK: Select

    /// Switches the detail to `selection` now: `detail` is `.loading` when this returns, so the placeholder shows in
    /// the same frame as the click. The load runs in a task that a newer select cancels. Selecting the current
    /// selection again (a tab switch) reloads it.
    func select(_ selection: Selection) {
        self.selection = selection
        selectToken &+= 1
        detail = .loading
        detailTask?.cancel()
        let token = selectToken
        detailTask = Task { [weak self] in
            await self?.loadDetail(selection, token: token)
        }
    }

    private func loadDetail(_ selection: Selection, token: Int) async {
        do {
            switch selection {
            case .overview:
                let backend = try await backend()
                // The log loads once per session, beside the detail; a tab switch does not restart it.
                if log.value == nil, logTask == nil { loadLog(backend) }
                if try await readStatusAndRefs(backend, scope: [.status, .refs]) { loadLog(backend) }
            }
            guard token == selectToken else { return }
            detail = .loaded(.overview)
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

    /// Selects a branch by name (DEBUG `-HistqSelect branch:<name>`): a remote branch when the refs are in and only
    /// a remote branch has that name, else a local one (the refs may not be read yet).
    func selectBranch(named name: String) {
        let isRemote = refs.value.map { refs in
            !refs.localBranches.contains { $0.name == name } && refs.remoteBranches.contains { $0.name == name }
        } ?? false
        selectSidebarItem(isRemote ? .remote(name) : .local(name))
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
        let (newStatus, newRefs) = try await Self.read(
            backend, cwd: url, status: scope.contains(.status), refs: scope.contains(.refs))
        try Task.checkCancellation()
        if let newStatus { status = .loaded(newStatus) }
        guard let newRefs else { return false }
        let moved = refs.value.map { $0 != newRefs } ?? false
        refs = .loaded(newRefs)
        return moved
    }

    @concurrent
    private nonisolated static func read(_ backend: Backend, cwd: URL, status: Bool, refs: Bool) async throws
        -> (WorkingStatus?, Refs?)
    {
        let env = try await backend.readEnvironment(cwd: cwd)
        async let newStatus = status ? StatusReader.read(runner: backend.runner, cwd: cwd, env: env) : nil
        async let newRefs = refs ? RefReader.read(runner: backend.runner, cwd: cwd, env: env) : nil
        return (try await newStatus, try await newRefs)
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
        logTask = Task { [weak self] in
            do {
                let snapshot = try await Self.readLog(backend, cwd: cwd) { first in
                    guard isFirstLoad, !Task.isCancelled else { return }
                    await MainActor.run { self?.log = .loaded(first) }
                }
                try Task.checkCancellation()
                guard let self else { return }
                log = .loaded(snapshot)
                logTask = nil
                UITiming.logComplete(commitCount: snapshot.commits.count)
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

    /// Parses every page and lays it out, off the main actor. `firstPage` gets the first page (laid out) as soon as
    /// it is ready. Throws `CancellationError` when cancelled (the stream itself ends without an error then).
    @concurrent
    private nonisolated static func readLog(
        _ backend: Backend, cwd: URL, firstPage: @Sendable (LogSnapshot) async -> Void
    ) async throws -> LogSnapshot {
        let env = try await backend.readEnvironment(cwd: cwd)
        var layout = GraphLayout()
        var snapshot = LogSnapshot()
        var isFirst = true
        for try await page in LogReader.pages(runner: backend.runner, cwd: cwd, env: env) {
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
                    profile: nil, base: toolchain.base, runner: runner, cwd: cwd)
                let directories = try await RepoDirectories.resolve(runner: runner, cwd: cwd, env: env)
                watcher.start(directories, onChange: onChange)
                return Backend(runner: runner, base: toolchain.base, directories: directories)
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
    private static func message(for error: Error) -> String {
        switch error {
        case GitError.other(_, let stderrTail) where stderrTail.contains("not a git repository"):
            "This folder is not a git repository."
        case let error as GitError:
            error.stderrTail.isEmpty ? "git failed." : error.stderrTail
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
