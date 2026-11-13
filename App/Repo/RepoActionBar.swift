// The repo actions the toolbar's buttons run (`HeaderToolbar`): Pull (its menu: fetch all, pull fast-forward if
// possible, fast-forward only, rebase), Push (its menu: force with lease, confirmed), Fetch, Branch, Stash and Pop. A
// button shows its operation's progress on itself from the click's frame (`ActionBarAction`); the menus' operations
// show in `RunningStatus`. A failure shows in the error banner at the top of the repo layout, with a hint mapped from
// `GitError` (sign-in, unknown or changed host key, "Pull first", index.lock, conflicts); an unknown host key opens the
// host-key sheet, which scans the host and appends its keys to known_hosts only on "Trust Host".
import HistqCore
import SwiftUI

/// The toolbar's buttons: the key of the operation each one shows. `checkout` is the branch menu's (every checkout,
/// wherever it started); `undo` and `redo` are the history buttons' (also ⌘Z / ⇧⌘Z and the palette).
enum ActionBarAction: Hashable, Sendable {
    case pull, push, fetch, branch, stash, pop, checkout, undo, redo
}

/// The host-key sheet's state: the host, whether ssh reported a changed key (then it only warns), and the scan.
struct HostKeyCheck: Identifiable {
    enum State {
        case scanning
        /// A changed key: never scanned for trust.
        case changed
        case scanned(HostKeyTrust.Scan)
        /// Appending to known_hosts.
        case trusting(HostKeyTrust.Scan)
        case failed(String)
    }

    let id = UUID()
    let host: HostKeyTrust.Host?
    let isChanged: Bool
    var state: State
    /// The operation to run again once the host is trusted.
    let failure: OperationFailure
}

// MARK: - Actions

extension RepoSession {
    /// The remote a branch without upstream is pushed to: `origin`, else the first remote.
    var defaultRemote: String? {
        remotes.first { $0.name == "origin" }?.name ?? remotes.first?.name
    }

    /// Where `branch` pushes: its upstream's remote and branch (and the upstream's commit, the lease of a force push),
    /// else the default remote with `-u`. Nil without a remote.
    func pushTarget(of branch: String) -> (remote: String, remoteBranch: String?, setUpstream: Bool, lease: String?)? {
        let refs = refs.value
        if let upstream = refs?.localBranches.first(where: { $0.name == branch })?.upstream {
            if let tracking = refs?.remoteBranches.first(where: { $0.name == upstream }) {
                return (tracking.remote, String(upstream.dropFirst(tracking.remote.count + 1)), false, tracking.commit)
            }
            // The upstream is not fetched (or gone): its remote is the longest remote name it starts with.
            if let remote = remotes.map(\.name).filter({ upstream.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) {
                return (remote, String(upstream.dropFirst(remote.count + 1)), false, nil)
            }
        }
        return defaultRemote.map { ($0, nil, true, nil) }
    }

    /// Pushes `branch` to its upstream (or the default remote with `-u`). `force` asks for a confirmation first, then
    /// pushes with `--force-with-lease` against the remote-tracking commit.
    func push(branch: String, force: Bool = false, key: ActionBarAction? = nil) {
        guard let target = pushTarget(of: branch) else {
            failure = OperationFailure(title: "Push \(branch)", write: .push(branch: branch, remote: "", remoteBranch: nil,
                                       setUpstream: false, forceWithLease: nil),
                                       error: CocoaError(.featureUnsupported), message: "This repository has no remote. Add one first.")
            return
        }
        let destination = "\(target.remote)/\(target.remoteBranch ?? branch)"
        if force {
            guard let lease = target.lease else { return }
            confirm("Force push \(branch) to \(destination)?",
                    message: "\(destination) is overwritten if it is still at \(lease.prefix(7)). Its commits that are not on \(branch) are lost.",
                    button: "Force Push",
                    write: .push(branch: branch, remote: target.remote, remoteBranch: target.remoteBranch,
                                 setUpstream: false, forceWithLease: lease),
                    operation: "Force push \(branch)", key: key)
        } else {
            run(.push(branch: branch, remote: target.remote, remoteBranch: target.remoteBranch,
                      setUpstream: target.setUpstream, forceWithLease: nil),
                title: "Push \(branch) to \(destination)", key: key)
        }
    }

    func pull(_ mode: GitOperations.PullMode) {
        run(.pull(mode), title: "Pull", key: .pull)
    }

    func fetchAll() {
        let prune = Preferences.defaults.bool(forKey: PrefKey.pruneOnFetch.rawValue)
        run(.fetchAll(prune: prune), title: "Fetch", key: .fetch)
    }

    /// `PrefKey.pullMode` ("fastForward", "fastForwardOnly", "rebase").
    static var preferredPullMode: GitOperations.PullMode {
        switch Preferences.defaults.string(forKey: PrefKey.pullMode.rawValue) {
        case "fastForwardOnly": .fastForwardOnly
        case "rebase": .rebase
        default: .fastForward
        }
    }

    /// A short name for a commit in titles: its first branch, else its short sha.
    func label(of commit: String) -> String {
        if let branch = refs.value?.localBranches.first(where: { $0.commit == commit }) { return branch.name }
        return String(commit.prefix(7))
    }
}

// MARK: - Toolbar actions

extension RepoSession {
    /// The newest stash, the one Pop applies.
    var newestStash: Stash? { log.value?.stashes.first }

    /// Opens the Create Branch form at HEAD.
    func createBranchAtHead() {
        guard let head = refs.value?.head.commit else { return }
        dialog = .createBranch(from: head, label: currentBranch ?? String(head.prefix(7)))
    }

    /// Stashes every change.
    func stashAll() {
        run(.stashPush(message: nil), title: "Stash", key: .stash)
    }

    /// Pops the newest stash.
    func popNewestStash() {
        guard let stash = newestStash else { return }
        run(.stashPop(hash: stash.hash), title: "Pop \(stash.selector)", key: .pop)
    }
}

/// The menus' operations still running (the toolbar buttons show their own): a spinner and the newest one's title.
struct RunningStatus: View {
    let session: RepoSession

    var body: some View {
        if let operation = session.running.last(where: { $0.key == nil }) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(operation.title + "…")
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.trailing, 6)
            .layoutPriority(-1)
        }
    }
}

// MARK: - Error banner

/// The last failure in its own card: what failed, git's message, a hint for the known cases and the hint's action.
struct ActionErrorBanner: View {
    let session: RepoSession
    let failure: OperationFailure

    var body: some View {
        let hint = Self.hint(for: failure)
        SectionCard(nil, contentPadding: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: hint.isWarning ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(nsColor: Palette.graphLanes[6]))
                    .font(.system(size: 16))
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(failure.title) failed")
                        .font(.body.weight(.semibold))
                    if let text = hint.text {
                        Text(text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(failure.message)
                        .font(.settingsCaption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let action = hint.action {
                        Button(action.title) { perform(action) }
                            .buttonStyle(RowTextButtonStyle())
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    session.failure = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(RowIconButtonStyle())
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
        }
    }

    /// What the hint's button does.
    enum Action {
        case checkHostKey, pull, forceDelete(String)
        /// A worktree git refused to remove for its changes: the forced removal, confirmed.
        case forceRemoveWorktree(String)

        var title: String {
            switch self {
            case .checkHostKey: "Check Host Key…"
            case .pull: "Pull"
            case .forceDelete: "Delete Anyway…"
            case .forceRemoveWorktree: "Remove Anyway…"
            }
        }
    }

    struct Hint {
        var text: String?
        var action: Action?
        /// A changed host key: a stronger icon.
        var isWarning = false
    }

    static func hint(for failure: OperationFailure) -> Hint {
        if case .deleteBranch(let name, false) = failure.write, failure.message.contains("not fully merged") {
            return Hint(text: "\(name) has commits that no other branch has.", action: .forceDelete(name))
        }
        if case .removeWorktree(let path, false) = failure.write, failure.message.contains("modified or untracked") {
            return Hint(text: "The worktree has uncommitted changes or untracked files.",
                        action: .forceRemoveWorktree(path))
        }
        guard let error = failure.error as? GitError else { return Hint() }
        switch error {
        case .auth:
            return Hint(text: "Git could not sign in to the remote. Check that your SSH key is loaded (ssh-add) or that a "
                + "credential helper knows this host.")
        case .hostKey:
            if HostKeyTrust.isKeyChanged(error) {
                return Hint(text: "The host's SSH key has changed since the last connection. Someone may be intercepting "
                    + "it. Histq will not trust the new key: check it with the host, then fix ~/.ssh/known_hosts yourself.",
                    action: .checkHostKey, isWarning: true)
            }
            return Hint(text: "This host's SSH key is not trusted yet. Compare its fingerprints before trusting it.",
                        action: .checkHostKey)
        case .nonFastForward:
            if case .push = failure.write {
                return Hint(text: "The remote has commits this branch does not have. Pull first, then push again.",
                            action: .pull)
            }
            return Hint(text: "The branches have diverged: this cannot be done as a fast-forward.")
        case .indexLock:
            return Hint(text: "Another git process holds the index (index.lock). Wait for it to finish; if no git is "
                + "running, delete .git/index.lock.")
        case .conflict:
            return Hint(text: "It stopped on conflicts. Resolve the conflicted files in the WIP panel, then commit.")
        case .timeout:
            return Hint(text: "Git took too long and was stopped.")
        case .other, .launchFailed:
            return Hint()
        }
    }

    private func perform(_ action: Action) {
        switch action {
        case .checkHostKey:
            session.checkHostKey(for: failure)
        case .pull:
            session.pull(RepoSession.preferredPullMode)
        case .forceDelete(let name):
            session.confirm("Delete branch \(name) anyway?",
                            message: "Its commits that no other branch has will be lost.", button: "Delete Branch",
                            write: .deleteBranch(name, force: true), operation: "Delete branch \(name)")
        case .forceRemoveWorktree(let path):
            let name = URL(filePath: path).lastPathComponent
            let changes = session.worktrees.value?.first { $0.path == path }?.changes?.detail
            RepoMenus.confirmForceRemove(path, name: name, changes: changes, session)
        }
    }
}

// MARK: - Host key sheet

/// The host's SHA256 fingerprints to compare, and "Trust Host", which appends them to known_hosts. A changed key gets a
/// warning and no Trust button.
struct HostKeySheet: View {
    let session: RepoSession
    let check: HostKeyCheck
    let onClose: () -> Void

    var body: some View {
        ModalCard(title: check.isChanged ? "The host key has changed" : "Unknown host",
                  systemImage: check.isChanged ? "exclamationmark.octagon.fill" : "key.horizontal", width: 480,
                  takesFocus: true) {
            ModalSection(spacing: 10) {
                if let host = check.host {
                    Text(host.knownHostsName)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
                content
            }
        } actions: {
            Button(trustable == nil ? "Close" : "Cancel", action: onClose)
                .buttonStyle(RowTextButtonStyle(formRow: true))
                .keyboardShortcut(.cancelAction)
            if let scan = trustable {
                Button {
                    session.trustHost(scan)
                } label: {
                    HStack(spacing: 6) {
                        if case .trusting = check.state { ProgressView().controlSize(.mini) }
                        Text("Trust Host")
                    }
                }
                .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
                .disabled(isTrusting)
            }
        }
    }

    /// The scan the user can trust: never for a changed key.
    private var trustable: HostKeyTrust.Scan? {
        guard !check.isChanged else { return nil }
        switch check.state {
        case .scanned(let scan), .trusting(let scan): return scan
        default: return nil
        }
    }

    private var isTrusting: Bool {
        if case .trusting = check.state { true } else { false }
    }

    @ViewBuilder private var content: some View {
        switch check.state {
        case .scanning:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading the host's keys…").foregroundStyle(.secondary)
            }
        case .changed:
            Text("ssh reports that this host now has another key than the one in ~/.ssh/known_hosts. This can mean "
                + "someone is intercepting the connection. Histq will not replace the key: confirm the new key with the "
                + "host's administrator, then remove the old line from ~/.ssh/known_hosts yourself.")
                .foregroundStyle(Color(nsColor: Palette.graphLanes[6]))
                .fixedSize(horizontal: false, vertical: true)
        case .scanned(let scan), .trusting(let scan):
            Text("Compare these fingerprints with the ones the host publishes (for GitHub: its \"SSH key fingerprints\" "
                + "page). Trusting adds these keys to ~/.ssh/known_hosts.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(scan.keys, id: \.line) { key in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(key.type).font(.settingsCaption).foregroundStyle(.secondary)
                        Text(key.fingerprint).font(.body.monospaced()).textSelection(.enabled)
                    }
                }
            }
        case .failed(let message):
            ErrorText(message: message)
        }
    }
}
