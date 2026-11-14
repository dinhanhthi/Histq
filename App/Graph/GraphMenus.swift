// The repo's context menus, built once as `MenuEntry` lists and shown both by the graph (an `NSMenu`) and by the sidebar
// and the file list (SwiftUI): the commit menu (checkout, create branch / tag here, cherry-pick, revert, reset,
// interactive rebase from here, squash the selected commits, copy),
// the WIP and stash menus, the branch, remote branch and tag menus (with Create Pull Request…), the Remote card's menus,
// the menu of a branch badge dropped on another (merge, rebase, fast-forward, create a pull request), the worktree menus
// (open in a tab, add, remove, prune), checkout file from a commit, and what a double-click checks out.
// Every action goes through `RepoSession.run`; a destructive one asks `RepoSession.confirm` first, naming its target.
import AppKit
import HistqCore
import SwiftUI

/// One item of a context menu.
struct MenuEntry {
    enum Kind {
        case action(@MainActor () -> Void)
        case submenu([MenuEntry])
        case separator
    }

    var title = ""
    var kind: Kind
    var isEnabled = true
    var isDestructive = false
    var isChecked = false
    /// Why a disabled item cannot run, shown on hover.
    var toolTip: String?

    static func action(_ title: String, enabled: Bool = true, destructive: Bool = false, checked: Bool = false,
                       toolTip: String? = nil, _ perform: @escaping @MainActor () -> Void) -> MenuEntry
    {
        MenuEntry(title: title, kind: .action(perform), isEnabled: enabled, isDestructive: destructive, isChecked: checked,
                  toolTip: toolTip)
    }

    static func submenu(_ title: String, _ entries: [MenuEntry]) -> MenuEntry {
        MenuEntry(title: title, kind: .submenu(entries), isEnabled: !entries.isEmpty)
    }

    static var separator: MenuEntry { MenuEntry(kind: .separator) }

    var isSeparator: Bool {
        if case .separator = kind { true } else { false }
    }

    /// Without leading, trailing or doubled separators.
    static func tidy(_ entries: [MenuEntry]) -> [MenuEntry] {
        var result: [MenuEntry] = []
        for entry in entries where !(entry.isSeparator && (result.last?.isSeparator ?? true)) {
            result.append(entry)
        }
        if result.last?.isSeparator == true { result.removeLast() }
        return result
    }
}

// MARK: - Rendering

/// An `NSMenu` of entries (the graph's right-click and drop menus).
@MainActor
enum MenuBuilder {
    static func menu(_ entries: [MenuEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in MenuEntry.tidy(entries) {
            switch entry.kind {
            case .separator:
                menu.addItem(.separator())
            case .action(let perform):
                let item = ActionMenuItem(title: entry.title, perform: perform)
                item.isEnabled = entry.isEnabled
                item.state = entry.isChecked ? .on : .off
                item.toolTip = entry.toolTip
                menu.addItem(item)
            case .submenu(let children):
                let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                item.submenu = Self.menu(children)
                item.isEnabled = entry.isEnabled
                menu.addItem(item)
            }
        }
        return menu
    }

    @MainActor
    private final class ActionMenuItem: NSMenuItem {
        private let perform: @MainActor () -> Void

        init(title: String, perform: @escaping @MainActor () -> Void) {
            self.perform = perform
            super.init(title: title, action: #selector(fire), keyEquivalent: "")
            target = self
        }

        @available(*, unavailable)
        nonisolated required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

        @objc private func fire() { perform() }
    }
}

/// The entries as SwiftUI menu items (a `.contextMenu` or a `Menu`).
struct MenuEntriesView: View {
    let entries: [MenuEntry]

    var body: some View {
        let entries = MenuEntry.tidy(entries)
        ForEach(entries.indices, id: \.self) { index in
            let entry = entries[index]
            switch entry.kind {
            case .separator:
                Divider()
            case .action(let perform):
                if entry.isChecked {
                    Toggle(entry.title, isOn: Binding(get: { true }, set: { _ in perform() }))
                        .disabled(!entry.isEnabled)
                } else {
                    Button(entry.title, role: entry.isDestructive ? .destructive : nil) { perform() }
                        .disabled(!entry.isEnabled)
                        .help(entry.toolTip ?? "")
                }
            case .submenu(let children):
                Menu(entry.title) { AnyView(MenuEntriesView(entries: children)) }
                    .disabled(!entry.isEnabled)
            }
        }
    }
}

// MARK: - Menus

/// The menus of the repo's commits, refs, stashes and remotes for one session.
@MainActor
enum RepoMenus {
    // MARK: Graph rows

    static func entries(for item: GraphItem, session: RepoSession) -> [MenuEntry] {
        switch item {
        case .wip: wip(session)
        case .stash(let hash): stash(hash, session)
        case .commit(let hash): commit(hash, session)
        case .worktree(let path): worktree(path, session)
        }
    }

    static func wip(_ session: RepoSession) -> [MenuEntry] {
        [
            .action("Stash All Changes") { session.run(.stashPush(message: nil), title: "Stash", key: .stash) },
            .separator,
            .action("Discard All Changes…", destructive: true) {
                session.confirm("Discard all changes in \(session.url.lastPathComponent)?",
                                message: "Every staged and unstaged change is lost, and untracked files are deleted. This cannot be undone.",
                                button: "Discard All", write: .discardAll(includingUntracked: true),
                                operation: "Discard all changes")
            },
        ]
    }

    static func stash(_ hash: String, _ session: RepoSession) -> [MenuEntry] {
        let stash = session.log.value?.stashes.first { $0.hash == hash }
        let name = stash.map { "\($0.selector) (\($0.message))" } ?? "this stash"
        return [
            .action("Apply Stash") { session.run(.stashApply(hash: hash), title: "Apply \(stash?.selector ?? "stash")") },
            .action("Pop Stash") { session.run(.stashPop(hash: hash), title: "Pop \(stash?.selector ?? "stash")") },
            .separator,
            .action("Drop Stash…", destructive: true) {
                session.confirm("Drop \(name)?", message: "Its changes are lost. This cannot be undone.",
                                button: "Drop Stash", write: .stashDrop(hash: hash),
                                operation: "Drop \(stash?.selector ?? "stash")")
            },
            .separator,
            .action("Copy SHA") { copy(hash) },
        ]
    }

    static func commit(_ hash: String, _ session: RepoSession) -> [MenuEntry] {
        let commit = session.log.value?.commits.first { $0.hash == hash }
        let short = String(hash.prefix(7))
        let refs = session.refs.value
        let current = session.currentBranch
        let isHead = refs?.head.commit == hash
        let localHere = refs?.localBranches.filter { $0.commit == hash } ?? []
        let mainline = commit?.isMerge == true ? 1 : nil

        var entries: [MenuEntry] = localHere.map { branch in
            .action("Checkout \(branch.name)", enabled: branch.name != current) { checkout(.local(branch.name), session) }
        }
        entries.append(.action("Checkout This Commit (Detached)…", enabled: !(isHead && current == nil)) {
            confirmDetached(hash, label: short, session)
        })
        entries += [
            .separator,
            .action("Create Branch Here…") { session.dialog = .createBranch(from: hash, label: short) },
            .action("Create Tag Here…") { session.dialog = .createTag(at: hash, label: short) },
            .action("Add Worktree Here…") { session.worktreeForm = WorktreeForm(source: .commit(hash), label: short) },
            .separator,
            .action(mainline == nil ? "Cherry-pick Commit" : "Cherry-pick Merge (parent 1)", enabled: !isHead) {
                session.run(.cherryPick(hash, mainline: mainline), title: "Cherry-pick \(short)")
            },
            .action(mainline == nil ? "Revert Commit" : "Revert Merge (parent 1)") {
                session.run(.revert(hash, mainline: mainline), title: "Revert \(short)")
            },
            .submenu("Reset \(current ?? "HEAD") to Here", GitOperations.ResetMode.allModes.map { mode in
                .action(mode.menuTitle + "…", destructive: mode == .hard) {
                    session.dialog = .reset(to: hash, label: short, branch: current, mode: mode)
                }
            }),
            .separator,
        ]
        // The clicked row in a multi-selection: squash the selection; the rebase sheet shows the core's own refusal
        // when the loaded log missed something.
        let squash = session.squashSelection()
        if squash.commits.count >= 2, squash.commits.contains(hash) {
            entries.append(.action("Squash \(squash.commits.count) Commits…", enabled: squash.reason == nil,
                                   toolTip: squash.reason) { session.openSquash(squash.commits) })
        }
        let rebaseReason = session.rebaseUnavailableReason(from: hash)
        entries.append(.action("Interactive Rebase from Here…", enabled: rebaseReason == nil, toolTip: rebaseReason) {
            session.openInteractiveRebase(from: hash)
        })
        // The commit's refs, also those hidden behind the badge column's "+N".
        let refEntries = refItems(at: hash, refs: refs).map { item in
            MenuEntry.submenu(item.menuTitle, self.ref(item, session))
        }
        if !refEntries.isEmpty { entries += [.separator] + refEntries }
        entries += [
            .separator,
            .action("Copy SHA") { copy(hash) },
            .action("Copy Short SHA") { copy(short) },
            .action("Copy Message", enabled: commit != nil) {
                guard let commit else { return }
                copy(commit.body.isEmpty ? commit.subject : commit.subject + "\n\n" + commit.body)
            },
        ]
        return entries
    }

    /// The local branches, remote branches and tags at `hash`, in the badge column's order.
    private static func refItems(at hash: String, refs: Refs?) -> [SidebarItem] {
        guard let refs else { return [] }
        return refs.localBranches.filter { $0.commit == hash }.map { .local($0.name) }
            + refs.remoteBranches.filter { $0.commit == hash }.map { .remote($0.name) }
            + refs.tags.filter { ($0.commit ?? $0.target) == hash }.map { .tag($0.name) }
    }

    // MARK: Refs

    static func ref(_ item: SidebarItem, _ session: RepoSession) -> [MenuEntry] {
        switch item {
        case .local(let name): local(name, session)
        case .remote(let name): remote(name, session)
        case .tag(let name): tag(name, session)
        }
    }

    private static func local(_ name: String, _ session: RepoSession) -> [MenuEntry] {
        let refs = session.refs.value
        let current = session.currentBranch
        let isCurrent = name == current
        let branch = refs?.localBranches.first { $0.name == name }
        let upstream = branch?.upstream.flatMap { upstream in refs?.remoteBranches.first { $0.name == upstream } }
        // Full refs, so a tag of the same name is never taken instead.
        let ref = "refs/heads/\(name)"
        var entries: [MenuEntry] = [
            .action("Checkout \(name)", enabled: !isCurrent) { checkout(.local(name), session) },
        ]
        if let current, !isCurrent {
            entries += [
                .action("Merge \(name) into \(current)") {
                    session.run(.merge(ref, checkoutFirst: nil), title: "Merge \(name) into \(current)")
                },
                .action("Rebase \(current) onto \(name)") {
                    session.run(.rebase(onto: ref, checkoutFirst: nil), title: "Rebase \(current) onto \(name)")
                },
            ]
        }
        let pullReason = createPullRequestUnavailableReason(head: .local(name), base: nil, session)
        entries += [
            .separator,
            .action("Push \(name)", enabled: session.pushTarget(of: name) != nil) { session.push(branch: name) },
            .action("Create Pull Request…", enabled: pullReason == nil, toolTip: pullReason) {
                openCreatePullRequest(head: .local(name), base: nil, session)
            },
            .submenu("Set Upstream", (refs?.remoteBranches ?? []).map { remote in
                .action(remote.name, checked: branch?.upstream == remote.name) {
                    session.run(.setUpstream(branch: name, upstream: remote.name),
                                title: "Set the upstream of \(name) to \(remote.name)")
                }
            }),
            .action("Add Worktree for \(name)…") {
                session.worktreeForm = WorktreeForm(source: .branch(name), label: name)
            },
            .separator,
            .action("Rename \(name)…") { session.dialog = .renameBranch(name) },
            .action("Delete \(name)…", enabled: !isCurrent, destructive: true) {
                session.confirm("Delete branch \(name)?",
                                message: "The local branch is deleted; git refuses if it has commits no other branch has.",
                                button: "Delete Branch", write: .deleteBranch(name, force: false),
                                operation: "Delete branch \(name)")
            },
        ]
        if let upstream {
            entries.append(deleteRemote(upstream, session))
        }
        entries += [.separator, .action("Copy Branch Name") { copy(name) }]
        return entries
    }

    private static func remote(_ name: String, _ session: RepoSession) -> [MenuEntry] {
        let current = session.currentBranch
        let branch = session.refs.value?.remoteBranches.first { $0.name == name }
        let ref = "refs/remotes/\(name)"
        var entries: [MenuEntry] = [
            .action("Checkout \(branch.map { localName(of: $0) } ?? name)") { checkout(.remote(name), session) },
        ]
        if let current {
            entries += [
                .action("Merge \(name) into \(current)") {
                    session.run(.merge(ref, checkoutFirst: nil), title: "Merge \(name) into \(current)")
                },
                .action("Rebase \(current) onto \(name)") {
                    session.run(.rebase(onto: ref, checkoutFirst: nil), title: "Rebase \(current) onto \(name)")
                },
            ]
        }
        // Only a branch of the GitHub remote can be a pull request's head.
        if let branch, branch.remote == session.github.api?.remote {
            let reason = createPullRequestUnavailableReason(head: .remote(name), base: nil, session)
            entries += [.separator, .action("Create Pull Request…", enabled: reason == nil, toolTip: reason) {
                openCreatePullRequest(head: .remote(name), base: nil, session)
            }]
        }
        if let branch {
            entries += [.separator, deleteRemote(branch, session)]
        }
        entries += [.separator, .action("Copy Branch Name") { copy(name) }]
        return entries
    }

    private static func deleteRemote(_ branch: RemoteBranch, _ session: RepoSession) -> MenuEntry {
        let short = localName(of: branch)
        return .action("Delete \(branch.name) from \(branch.remote)…", destructive: true) {
            session.confirm("Delete \(short) from the remote \(branch.remote)?",
                            message: "The branch is deleted on \(branch.remote) for everyone. This cannot be undone from here.",
                            button: "Delete Remote Branch", write: .deleteRemoteBranch(short, remote: branch.remote),
                            operation: "Delete \(branch.name)")
        }
    }

    private static func tag(_ name: String, _ session: RepoSession) -> [MenuEntry] {
        let remotes = session.remotes.map(\.name)
        let push: MenuEntry = remotes.count == 1
            ? .action("Push \(name) to \(remotes[0])") {
                session.run(.pushTag(name, remote: remotes[0]), title: "Push \(name) to \(remotes[0])")
            }
            : .submenu("Push \(name) to", remotes.map { remote in
                .action(remote) { session.run(.pushTag(name, remote: remote), title: "Push \(name) to \(remote)") }
            })
        var entries: [MenuEntry] = [
            push,
            .separator,
            .action("Delete \(name)…", destructive: true) {
                session.confirm("Delete tag \(name)?", message: "The local tag is deleted; remotes keep theirs.",
                                button: "Delete Tag", write: .deleteTag(name), operation: "Delete tag \(name)")
            },
        ]
        entries += remotes.map { remote in
            .action("Delete \(name) from \(remote)…", destructive: true) {
                session.confirm("Delete tag \(name) from the remote \(remote)?",
                                message: "The tag is deleted on \(remote) for everyone.", button: "Delete Remote Tag",
                                write: .deleteRemoteTag(name, remote: remote), operation: "Delete \(name) from \(remote)")
            }
        }
        entries += [.separator, .action("Copy Tag Name") { copy(name) }]
        return entries
    }

    // MARK: Remotes

    /// The Remote card's menu: Add Remote, then one submenu per remote.
    static func remotes(_ session: RepoSession) -> [MenuEntry] {
        var entries: [MenuEntry] = [.action("Add Remote…") { session.dialog = .addRemote }]
        if !session.remotes.isEmpty {
            entries.append(.separator)
            entries += session.remotes.map { remote in .submenu(remote.name, self.remote(named: remote.name, session)) }
        }
        return entries
    }

    /// One remote's actions: rename, set URL, push mirror and remove (both confirmed, naming the remote).
    static func remote(named name: String, _ session: RepoSession) -> [MenuEntry] {
        let url = session.remotes.first { $0.name == name }?.url ?? ""
        return [
            .action("Rename \(name)…") { session.dialog = .renameRemote(name) },
            .action("Set URL…") { session.dialog = .setRemoteURL(name, url: url) },
            .separator,
            .action("Push Mirror to \(name)…", destructive: true) {
                session.confirm("Push a mirror to \(name)?",
                                message: "Every branch and tag of \(name) (\(url)) is replaced by this repository's: refs that do not exist here are deleted on \(name).",
                                button: "Push Mirror", write: .pushMirror(remote: name), operation: "Push mirror to \(name)")
            },
            .action("Remove \(name)…", destructive: true) {
                session.confirm("Remove the remote \(name)?",
                                message: "Its remote-tracking branches are deleted here; the repository at \(url) is not touched.",
                                button: "Remove Remote", write: .removeRemote(name), operation: "Remove remote \(name)")
            },
            .separator,
            .action("Copy URL") { copy(url) },
        ]
    }

    // MARK: Worktrees

    /// A worktree's menu (its sidebar row, its graph row): open it in a tab, remove it (confirmed; never the main one or
    /// this tab's own; losing its changes only through its own Force Remove item), prune, copy its path.
    static func worktree(_ path: String, _ session: RepoSession) -> [MenuEntry] {
        let info = session.worktrees.value?.first { $0.path == path }
        let name = info?.name ?? URL(filePath: path).lastPathComponent
        let canOpen = info.map { !$0.isCurrent && !$0.worktree.isPrunable } ?? false
        let reason = info.flatMap(removeUnavailableReason)
        var entries: [MenuEntry] = [
            .action("Open in New Tab", enabled: canOpen) {
                session.openWorktree(path)
            },
            .separator,
            .action("Remove \(name)…", enabled: info != nil && reason == nil, destructive: true, toolTip: reason) {
                let branch = info?.worktree.branch.map { " The branch \(RefBadge.shortBranch($0)) is kept." } ?? ""
                session.confirm("Remove the worktree \(name)?",
                                message: "Its folder \(ProfileLibrary.abbreviated(path)) is deleted.\(branch) Git "
                                    + "refuses when it has uncommitted changes or untracked files.",
                                button: "Remove Worktree", write: .removeWorktree(path, force: false),
                                operation: "Remove worktree \(name)")
            },
        ]
        if let info, info.isDirty, reason == nil {
            entries.append(.action("Force Remove \(name)…", destructive: true) {
                confirmForceRemove(path, name: name, changes: info.changes?.detail, session)
            })
        }
        entries += [.separator] + worktrees(session).dropFirst()
        entries += [.separator, .action("Copy Path") { copy(path) }]
        return entries
    }

    /// The Worktrees card's menu: Add Worktree, Prune.
    static func worktrees(_ session: RepoSession) -> [MenuEntry] {
        let prunable = session.worktrees.value?.contains { $0.worktree.isPrunable } ?? false
        return [
            .action("Add Worktree…") { session.worktreeForm = WorktreeForm(source: nil, label: nil) },
            .action("Prune Worktrees", enabled: prunable,
                    toolTip: prunable ? nil : "No worktree's folder is missing: nothing to prune.") {
                session.run(.pruneWorktrees, title: "Prune worktrees")
            },
        ]
    }

    /// Why a worktree cannot be removed from this tab; nil when it can.
    private static func removeUnavailableReason(_ info: WorktreeInfo) -> String? {
        if info.worktree.isMain { return "The main worktree cannot be removed." }
        if info.isCurrent { return "This tab's own worktree: remove it from another worktree's tab." }
        if info.worktree.isPrunable { return "Its folder is gone: Prune Worktrees removes its record." }
        if info.worktree.isLocked { return "It is locked: unlock it with git worktree unlock first." }
        return nil
    }

    /// The forced removal, which deletes the worktree's changes with its folder.
    static func confirmForceRemove(_ path: String, name: String, changes: String?, _ session: RepoSession) {
        let what = changes.map { "Its uncommitted changes (\($0)), its untracked files" } ?? "Its uncommitted changes"
        session.confirm("Force remove the worktree \(name)?",
                        message: "\(what) and its folder \(ProfileLibrary.abbreviated(path)) are deleted. This "
                            + "cannot be undone.",
                        button: "Force Remove", write: .removeWorktree(path, force: true),
                        operation: "Force remove worktree \(name)")
    }

    // MARK: Drag and drop

    /// A branch badge dropped on another: merge `source` into `target`, rebase `source` onto `target`, fast-forward
    /// `target` to `source`. A branch that is not checked out is checked out first (merge into it, rebase it).
    static func drop(_ source: SidebarItem, onto target: SidebarItem, _ session: RepoSession) -> [MenuEntry] {
        guard source != target, let sourceName = source.branchName, let targetName = target.branchName,
              let sourceRef = source.refName, let targetRef = target.refName
        else { return [] }
        let current = session.currentBranch
        var entries: [MenuEntry] = []
        if case .local = target {
            entries.append(.action("Merge \(sourceName) into \(targetName)") {
                session.run(.merge(sourceRef, checkoutFirst: targetName == current ? nil : targetName),
                            title: "Merge \(sourceName) into \(targetName)")
            })
        }
        if case .local = source {
            entries.append(.action("Rebase \(sourceName) onto \(targetName)") {
                session.run(.rebase(onto: targetRef, checkoutFirst: sourceName == current ? nil : sourceName),
                            title: "Rebase \(sourceName) onto \(targetName)")
            })
        }
        if case .local = target {
            entries.append(.action("Fast-forward \(targetName) to \(sourceName)") {
                session.run(.fastForward(targetName, to: sourceRef), title: "Fast-forward \(targetName) to \(sourceName)")
            })
        }
        let pullReason = createPullRequestUnavailableReason(head: source, base: target, session)
        entries += [
            .separator,
            .action("Create Pull Request from \(sourceName) into \(targetName)…", enabled: pullReason == nil,
                    toolTip: pullReason) {
                openCreatePullRequest(head: source, base: target, session)
            },
        ]
        return entries
    }

    // MARK: Pull requests

    /// The branch on the tab's GitHub remote that `item` stands for, by its name there: a remote branch of that remote,
    /// a local branch's upstream on it, or else the remote branch of the same name. nil when it is not on that remote
    /// (or GitHub is not connected): GitHub opens a pull request only from a branch it has.
    static func gitHubBranch(of item: SidebarItem, _ session: RepoSession) -> String? {
        guard let remote = session.github.api?.remote, let refs = session.refs.value else { return nil }
        let remoteBranches = refs.remoteBranches.filter { $0.remote == remote }
        switch item {
        case .local(let name):
            let upstream = refs.localBranches.first { $0.name == name }?.upstream
            let branch = remoteBranches.first { $0.name == upstream }
                ?? remoteBranches.first { $0.name == "\(remote)/\(name)" }
            return branch.map(localName(of:))
        case .remote(let name):
            return remoteBranches.first { $0.name == name }.map(localName(of:))
        case .tag:
            return nil
        }
    }

    /// Why Create Pull Request… is disabled for `head` (into `base`, or the default branch): GitHub not connected, or a
    /// branch that is not on the GitHub remote (push it first; Histq does not push from this menu). nil when it can run.
    static func createPullRequestUnavailableReason(head: SidebarItem, base: SidebarItem?, _ session: RepoSession)
        -> String?
    {
        guard let remote = session.github.api?.remote else {
            return switch session.github.connection {
            case .resolving: "GitHub is still connecting."
            case .noRemote(let host): "No remote of this repository is on \(host)."
            case .notConnected, .connected: "Connect a GitHub account to this tab's profile in Settings › Integrations."
            }
        }
        guard let headName = head.branchName else { return "Only a branch can be a pull request's head." }
        guard let headBranch = gitHubBranch(of: head, session) else {
            return "Push \(headName) to \(remote) first: GitHub opens a pull request only from a branch it has."
        }
        guard let base else { return nil }
        guard let baseBranch = gitHubBranch(of: base, session) else {
            return "\(base.branchName ?? "The target") is not on \(remote): a pull request goes into a branch GitHub has."
        }
        return headBranch == baseBranch ? "Both are the same branch on \(remote)." : nil
    }

    /// Opens the Create Pull Request form for `head` (and `base`, else the default branch), by their names on the
    /// GitHub remote.
    static func openCreatePullRequest(head: SidebarItem, base: SidebarItem?, _ session: RepoSession) {
        guard let headBranch = gitHubBranch(of: head, session) else { return }
        session.pullRequestForm = PullRequestForm(head: headBranch, base: base.flatMap { gitHubBranch(of: $0, session) })
    }

    // MARK: Checkout

    /// A double-click on a graph row: the commit's local branch when it has exactly one, else the commit itself
    /// (detached, confirmed). WIP and stash rows do nothing.
    static func activate(_ item: GraphItem, session: RepoSession) {
        guard case .commit(let hash) = item else { return }
        let local = session.refs.value?.localBranches.filter { $0.commit == hash } ?? []
        if local.count == 1 {
            checkout(.local(local[0].name), session)
        } else if session.refs.value?.head != .detached(commit: hash) {
            confirmDetached(hash, label: String(hash.prefix(7)), session)
        }
    }

    /// Checks out a sidebar or badge ref: a local branch; a remote branch through its local branch (created tracking
    /// it when there is none); a tag as a detached HEAD (confirmed). The toolbar's branch button shows it running
    /// (`ActionBarAction.checkout`), wherever it started.
    static func checkout(_ item: SidebarItem, _ session: RepoSession) {
        let refs = session.refs.value
        switch item {
        case .local(let name):
            guard name != session.currentBranch else { return }
            checkoutAskingIfDirty(.checkoutBranch(name), name: name, session)
        case .remote(let name):
            guard let branch = refs?.remoteBranches.first(where: { $0.name == name }) else { return }
            let localName = localName(of: branch)
            if let local = refs?.localBranches.first(where: { $0.upstream == name })
                ?? refs?.localBranches.first(where: { $0.name == localName })
            {
                checkout(.local(local.name), session)
            } else {
                checkoutAskingIfDirty(.checkoutTracking(remoteBranch: name, as: localName), name: localName, session)
            }
        case .tag(let name):
            guard let tag = refs?.tags.first(where: { $0.name == name }) else { return }
            confirmDetached(tag.commit ?? tag.target, label: name, session)
        }
    }

    /// A checkout carries uncommitted changes to the other branch, or stops when they conflict with it, so a dirty
    /// working tree asks first; a clean one checks out at once.
    private static func checkoutAskingIfDirty(_ write: RepoSession.Write, name: String, _ session: RepoSession) {
        let title = "Checkout \(name)"
        guard session.status.value?.entries.isEmpty == false else {
            session.run(write, title: title, key: .checkout)
            return
        }
        session.confirm("Checkout \(name) with uncommitted changes?",
                        message: "Your changes are carried to \(name). If they conflict with it, the checkout stops "
                            + "and nothing changes.",
                        button: "Checkout", write: write, operation: title, key: .checkout, isDestructive: false)
    }

    /// The toolbar's branch menu: the local branches (the current one checked), then a Remote Branches submenu, each
    /// checked out as `checkout(_:_:)` does.
    static func branchPicker(_ session: RepoSession) -> [MenuEntry] {
        guard let refs = session.refs.value else { return [] }
        let current = session.currentBranch
        var entries: [MenuEntry] = refs.localBranches.map { branch in
            .action(branch.name, checked: branch.name == current) { checkout(.local(branch.name), session) }
        }
        if !refs.remoteBranches.isEmpty {
            entries += [.separator, .submenu("Remote Branches", refs.remoteBranches.map { branch in
                .action(branch.name) { checkout(.remote(branch.name), session) }
            })]
        }
        return entries
    }

    /// The toolbar's Pull ▾ menu: fetch all, then each pull mode.
    static func pull(_ session: RepoSession) -> [MenuEntry] {
        let enabled = session.currentBranch != nil
        return [
            .action("Fetch All") { session.fetchAll() },
            .separator,
            .action("Pull (fast-forward if possible)", enabled: enabled) { session.pull(.fastForward) },
            .action("Pull (fast-forward only)", enabled: enabled) { session.pull(.fastForwardOnly) },
            .action("Pull (rebase)", enabled: enabled) { session.pull(.rebase) },
        ]
    }

    /// The toolbar's Push ▾ menu: push, or force push with lease (confirmed).
    static func push(_ session: RepoSession) -> [MenuEntry] {
        guard let branch = session.currentBranch, let target = session.pushTarget(of: branch) else { return [] }
        return [
            .action("Push") { session.push(branch: branch, key: .push) },
            .action("Force Push (with lease)…", enabled: target.lease != nil) {
                session.push(branch: branch, force: true, key: .push)
            },
        ]
    }

    private static func confirmDetached(_ hash: String, label: String, _ session: RepoSession) {
        session.confirm("Check out \(label) as a detached HEAD?",
                        message: "No branch will be checked out; commits made there belong to no branch until you create one.",
                        button: "Checkout", write: .checkoutCommit(hash), operation: "Checkout \(label)",
                        key: .checkout, isDestructive: false)
    }

    /// "Checkout File from This Commit" in a commit's file list: confirmed when the file has local changes.
    static func checkoutFile(_ file: FileChange, commit: String, session: RepoSession) -> [MenuEntry] {
        guard file.kind != .deleted else { return [] }
        let short = String(commit.prefix(7))
        let write = RepoSession.Write.checkoutFiles([file.path], from: commit)
        return [
            .action("Checkout File from This Commit") {
                let isChanged = session.status.value?.entries.contains { $0.path == file.path } ?? false
                if isChanged {
                    session.confirm("Replace \(file.name) with its version from \(short)?",
                                    message: "Its staged and unstaged changes are lost.", button: "Checkout File",
                                    write: write, operation: "Checkout \(file.name) from \(short)")
                } else {
                    session.run(write, title: "Checkout \(file.name) from \(short)")
                }
            },
        ]
    }

    // MARK: DEBUG

    #if DEBUG
    /// DEBUG `-HistqRun "<menu>|<title>[|<title>…][;;<next>…]"`: picks menu items by title and runs them, one step after
    /// the other, as a click would (a confirmation is accepted; forms are not supported). `<menu>` is `wip`,
    /// `commit:<sha>`, `stash:<sha>`, `local:<name>`, `remote:<name>`, `tag:<name>`, `remotes`, `file:<sha>:<path>`,
    /// `drop:<local|remote>:<name>><local|remote>:<name>` or `branches` (the toolbar's branch menu). Each step's
    /// outcome goes to `operations.txt` in the state folder. For QA on fixture copies only.
    static func debugRun(_ spec: String, session: RepoSession) async {
        for step in spec.components(separatedBy: ";;") {
            guard let perform = debugAction(step, session) else {
                debugLog("missing \(step)")
                continue
            }
            perform()
            if let confirmation = session.confirmation {
                session.confirmation = nil
                session.run(confirmation.write, title: confirmation.operation, key: confirmation.key)
            }
            while !session.running.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
            debugLog(session.failure.map { "fail \(step): \($0.message)" } ?? "ok \(step)")
            session.failure = nil
            try? await Task.sleep(for: .milliseconds(300))
        }
        debugLog("done")
    }

    /// DEBUG `-HistqShow "<menu>|<title>[|<title>…]"`: picks one menu item as `-HistqRun` does and runs it, but leaves
    /// the confirmation or form it opens on screen (QA shots of the modals; `-HistqFormName` then submits a form).
    static func debugShow(_ step: String, session: RepoSession) {
        guard let perform = debugAction(step, session) else { return debugLog("missing \(step)") }
        perform()
    }

    /// The enabled action at `<menu>|<title>[|<title>…]`, through its submenus.
    private static func debugAction(_ step: String, _ session: RepoSession) -> (@MainActor () -> Void)? {
        var titles = step.components(separatedBy: "|")
        let root = titles.removeFirst()
        var entries = debugMenu(root, session)
        var found: MenuEntry?
        for (index, title) in titles.enumerated() {
            found = entries.first { $0.title == title }
            if index < titles.count - 1, case .submenu(let children)? = found?.kind { entries = children }
        }
        guard let found, case .action(let perform) = found.kind, found.isEnabled else { return nil }
        return perform
    }

    private static func debugMenu(_ root: String, _ session: RepoSession) -> [MenuEntry] {
        let parts = root.split(separator: ":", maxSplits: 1).map(String.init)
        let value = parts.count > 1 ? parts[1] : ""
        switch parts.first {
        case "wip": return wip(session)
        case "commit": return commit(value, session)
        case "stash": return stash(value, session)
        case "local": return ref(.local(value), session)
        case "remote": return ref(.remote(value), session)
        case "tag": return ref(.tag(value), session)
        case "remotes": return remotes(session)
        case "branches": return branchPicker(session)
        case "worktrees": return worktrees(session)
        case "worktree":
            // By folder name or path.
            let info = session.worktrees.value?.first { $0.name == value || $0.path == value }
            return worktree(info?.path ?? value, session)
        case "file":
            let file = value.split(separator: ":", maxSplits: 1).map(String.init)
            guard file.count == 2 else { return [] }
            return checkoutFile(FileChange(kind: .modified, path: file[1]), commit: file[0], session: session)
        case "drop":
            let ends = value.components(separatedBy: ">").map(debugItem)
            guard ends.count == 2, let source = ends[0], let target = ends[1] else { return [] }
            return drop(source, onto: target, session)
        default: return []
        }
    }

    private static func debugItem(_ text: String) -> SidebarItem? {
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return parts[0] == "local" ? .local(parts[1]) : parts[0] == "remote" ? .remote(parts[1]) : nil
    }

    /// Appends a line to `operations.txt` in the state folder (also the palette's `-HistqPaletteRun`).
    static func debugLog(_ line: String) {
        let url = StatePaths.root.appending(path: "operations.txt", directoryHint: .notDirectory)
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
    #endif

    // MARK: Helpers

    /// `origin/feature/x` → `feature/x`.
    static func localName(of branch: RemoteBranch) -> String {
        String(branch.name.dropFirst(branch.remote.count + 1))
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension RefBadge {
    /// The ref a badge stands for; nil for a detached HEAD.
    var sidebarItem: SidebarItem? {
        switch kind {
        case .branch(let isLocal, _, _): isLocal ? .local(name) : .remote(name)
        case .tag: .tag(name)
        case .head, .worktree: nil
        }
    }
}

extension RefBadge {
    /// `refs/heads/wt` → `wt`.
    static func shortBranch(_ ref: String) -> String {
        ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
    }
}

extension SidebarItem {
    /// A branch's name (`main`, `origin/main`); nil for a tag.
    var branchName: String? {
        switch self {
        case .local(let name), .remote(let name): name
        case .tag: nil
        }
    }

    /// The full ref of a branch (`refs/heads/main`, `refs/remotes/origin/main`).
    var refName: String? {
        switch self {
        case .local(let name): "refs/heads/\(name)"
        case .remote(let name): "refs/remotes/\(name)"
        case .tag: nil
        }
    }

    var menuTitle: String {
        switch self {
        case .local(let name): "Branch \(name)"
        case .remote(let name): "Remote Branch \(name)"
        case .tag(let name): "Tag \(name)"
        }
    }
}

extension GitOperations.ResetMode {
    static let allModes: [GitOperations.ResetMode] = [.soft, .mixed, .hard]

    var menuTitle: String {
        switch self {
        case .soft: "Soft"
        case .mixed: "Mixed"
        case .hard: "Hard"
        }
    }
}
