// One window's tabs: each is a repo, or a Welcome tab (no repo), with the selection and the page the window shows.
import Foundation
import os

/// One window's tabs: each is a repo, or a Welcome tab (no repo). The `TabStrip` under the toolbar draws them, the
/// toolbar's repo menu lists them. A repo tab has
/// a `RepoSession`, created when the tab is opened or selected and dropped when it closes; selecting a tab goes
/// through its session's `select`, so the tab's detail shows its placeholder in the same frame.
@Observable
@MainActor
final class WindowModel {
    struct Tab: Identifiable, Equatable {
        let id = UUID()
        /// The repo's folder; nil for a Welcome tab.
        var repoURL: URL?
        /// The profile the tab's git commands use; Phase 7 fills it.
        var profileID: UUID?

        /// The repo folder's name, or "New Tab" for a Welcome tab.
        var title: String { repoURL?.lastPathComponent ?? "New Tab" }
    }

    private(set) var tabs: [Tab] = [Tab()]
    private(set) var selectedTabID: Tab.ID?
    /// The repo tabs' sessions, by tab.
    private(set) var sessions: [Tab.ID: RepoSession] = [:]
    /// The Welcome tabs' state (the clone in flight, the git check), by tab: it outlives the view across tab
    /// switches. Created on first use by `welcome(for:)`.
    @ObservationIgnored private var welcomes: [Tab.ID: WelcomeModel] = [:]
    /// The page the window shows: the selected tab (`.home`), Settings or About.
    let navigation = Navigation()
    /// Closes the window; set by the AppDelegate. Called when the tab strip closes the last tab.
    @ObservationIgnored var closeWindow: () -> Void = {}

    private static let logger = Logger(subsystem: "com.math2it.histq", category: "window")

    init() {
        selectedTabID = tabs.first?.id
    }

    var selectedIndex: Int? { tabs.firstIndex { $0.id == selectedTabID } }

    /// The selected tab's session; nil for a Welcome tab.
    var selectedSession: RepoSession? { selectedTabID.flatMap { sessions[$0] } }

    /// The selected tab's session while the tab shows (not Settings or About, where its dialogs have no presenter);
    /// nil for a Welcome tab. The toolbar's repo actions are disabled without it.
    var actionSession: RepoSession? { navigation.page == .home ? selectedSession : nil }

    /// Opens a repo in a tab and selects it: the tab that already shows it, else the selected tab if it is a
    /// Welcome tab, else a new tab. `nil` opens a new Welcome tab.
    func openTab(_ url: URL?) {
        navigation.page = .home
        guard let url = url?.standardizedFileURL else {
            let tab = Tab()
            tabs.append(tab)
            selectedTabID = tab.id
            return
        }
        UITiming.open(url.path)
        RecentRepos.shared.add(url)
        if let existing = tabs.first(where: { $0.repoURL?.path == url.path }) {
            selectedTabID = existing.id
        } else if let index = selectedIndex, tabs[index].repoURL == nil {
            tabs[index].repoURL = url
        } else {
            let tab = Tab(repoURL: url)
            tabs.append(tab)
            selectedTabID = tab.id
        }
        activateSelectedTab()
    }

    /// The Welcome tab `id`'s state, created on first use. Its Open, Clone and Init open the repo in that tab.
    func welcome(for id: Tab.ID) -> WelcomeModel {
        if let welcome = welcomes[id] { return welcome }
        let welcome = WelcomeModel { [weak self] url in self?.open(url, fromWelcome: id) }
        welcomes[id] = welcome
        return welcome
    }

    /// Opens a repo from the Welcome tab `id`: in that tab while it is selected (as `openTab`). A clone that ends
    /// after the user switched away fills that tab without selecting it.
    private func open(_ url: URL, fromWelcome id: Tab.ID) {
        welcomes.removeValue(forKey: id)
        guard selectedTabID != id else { return openTab(url) }
        let url = url.standardizedFileURL
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].repoURL == nil,
              !tabs.contains(where: { $0.repoURL?.path == url.path })
        else { return }
        UITiming.open(url.path)
        RecentRepos.shared.add(url)
        tabs[index].repoURL = url
    }

    /// Selects the tab at `index` and shows it (leaving Settings or About): the path a click on a tab takes.
    /// The tab already selected is only shown again (its loaded detail stays); no `select` timing line then.
    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        navigation.page = .home
        guard tabs[index].id != selectedTabID else { return }
        UITiming.select("tab \(index)")
        selectedTabID = tabs[index].id
        activateSelectedTab()
    }

    /// Selects the selected repo tab's current selection again (creating its session on first use): its detail goes
    /// to the loading state now and reloads.
    private func activateSelectedTab() {
        guard let index = selectedIndex, let url = tabs[index].repoURL else { return }
        let id = tabs[index].id
        let session = sessions[id] ?? RepoSession(url: url)
        sessions[id] = session
        session.select(session.selection)
    }

    /// Selects a tab by id, through `selectTab(at:)`.
    func selectTab(id: Tab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        selectTab(at: index)
    }

    /// Closes the selected tab and selects its neighbor. Returns false when no tab is left (the window closes).
    func closeSelectedTab() -> Bool {
        guard let id = selectedTabID else { return !tabs.isEmpty }
        return closeTab(id: id)
    }

    /// Closes a tab; when it was the selected one, its neighbor is selected. Returns false when no tab is left (the
    /// caller closes the window).
    func closeTab(id: Tab.ID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return !tabs.isEmpty }
        tabs.remove(at: index)
        sessions.removeValue(forKey: id)?.close()
        welcomes.removeValue(forKey: id)?.cancel()
        if selectedTabID == id {
            selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
            activateSelectedTab()
        }
        return !tabs.isEmpty
    }

    /// Moves the tab at `source` to `destination` (its index once moved); the selection stays on the same tab.
    func moveTab(from source: Int, to destination: Int) {
        guard tabs.indices.contains(source), tabs.indices.contains(destination), source != destination else { return }
        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: destination)
    }

    /// Shows Settings, or the selected tab again when Settings is already shown.
    func toggleSettings() {
        navigation.page = navigation.page == .settings ? .home : .settings
    }

    /// Routes a DEBUG `-HistqSelect` request through the same paths a click takes.
    func select(_ request: SelectRequest) {
        switch request.kind {
        case .tab:
            guard let index = request.value.flatMap(Int.init), tabs.indices.contains(index) else {
                Self.logger.error("-HistqSelect tab: no tab \(request.value ?? "", privacy: .public)")
                return
            }
            selectTab(at: index)
        case .settings:
            UITiming.select("settings \(request.value ?? "")")
            navigation.page = .settings
        case .sidebar:
            guard let session = selectedSession, let tab = request.value.flatMap(SidebarTab.init(selectValue:)) else {
                Self.logger.error("-HistqSelect sidebar: no repo tab or unknown tab \(request.value ?? "", privacy: .public)")
                return
            }
            session.selectSidebarTab(tab)
        case .branch:
            guard let session = selectedSession, let name = request.value else {
                Self.logger.error("-HistqSelect branch: no repo tab or no branch name")
                return
            }
            session.selectBranch(named: name)
        case .wip:
            guard let session = selectedSession else {
                Self.logger.error("-HistqSelect wip: no repo tab")
                return
            }
            session.selectGraph([.wip])
        case .commit:
            guard let session = selectedSession, let hash = request.value else {
                Self.logger.error("-HistqSelect commit: no repo tab or no commit")
                return
            }
            session.selectGraph([.commit(hash)])
        case .file:
            guard let session = selectedSession, let path = request.value else {
                Self.logger.error("-HistqSelect file: no repo tab or no path")
                return
            }
            // A WIP file is clicked in the WIP panel: the WIP first, then the file once that panel is on screen, so
            // the `select file` line is timed like a user's click and not against the launch's first frames.
            session.selectGraph([.wip])
            Task { [weak session] in
                for _ in 0..<150 {
                    guard let session else { return }
                    if session.detail.value != nil { break }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                try? await Task.sleep(for: .milliseconds(100))
                session?.selectWIPFile(path)
            }
        case .conflict:
            guard let session = selectedSession, let path = request.value else {
                Self.logger.error("-HistqSelect conflict: no repo tab or no path")
                return
            }
            // As `file:`: a conflicted file is clicked in the WIP panel, so the WIP shows first and the
            // `select conflict` line is timed like a user's click.
            session.selectGraph([.wip])
            Task { [weak session] in
                for _ in 0..<150 {
                    guard let session else { return }
                    if session.detail.value != nil { break }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                try? await Task.sleep(for: .milliseconds(100))
                session?.selectConflict(path)
            }
        case .commitfile:
            // `commitfile:<sha>:<path>`: a click on the commit's row, then on the file in its file list once the
            // detail is on screen, with the `FileChange` that row holds.
            let parts = request.value?.split(separator: ":", maxSplits: 1).map(String.init) ?? []
            guard let session = selectedSession, parts.count == 2 else {
                Self.logger.error("-HistqSelect commitfile: no repo tab or not <sha>:<path>")
                return
            }
            session.selectGraph([.commit(parts[0])])
            Task { [weak session] in
                for _ in 0..<150 {
                    guard let session else { return }
                    if session.detail.value != nil { break }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                try? await Task.sleep(for: .milliseconds(100))
                guard let session, case .commit(let commit)? = session.detail.value,
                      let file = commit.files.first(where: { $0.path == parts[1] })
                else {
                    Self.logger.error("-HistqSelect commitfile: \(parts[1], privacy: .public) is not in that commit")
                    return
                }
                session.selectFile(FileTarget(source: .commit(commit.hash), file: file))
            }
        case .pr:
            // The repo session's select path routes these once it exists.
            Self.logger.notice("-HistqSelect \(request.kind.rawValue, privacy: .public): not routed yet")
        }
    }
}
