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
        /// The repo's folder; nil for a Welcome tab. Its profile lives in its `RepoSession` (`profileID`), which runs
        /// the git commands that use it.
        var repoURL: URL?
        /// A restored repo whose folder is gone or no longer a git repository: the tab shows "Repo not found" (Locate,
        /// Remove) and gets no session.
        var isMissing = false

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
    /// Session restore: the saved profile and commit of restored tabs that have no session yet (sessions are made on
    /// first select), applied when it is made; until then the next save keeps them as they were.
    @ObservationIgnored private var restored: [Tab.ID: SavedTab] = [:]
    /// The page the window shows: the selected tab (`.home`), Settings or About.
    let navigation = Navigation()
    /// The Settings page's section, kept while other pages show.
    private(set) var settingsSection: SettingsSection = .general
    /// Changes with every `selectSettings`, even of the same section: the section's placeholder and content lines
    /// follow it.
    private(set) var settingsToken = 0
    /// The open command palette; nil while closed. Read only by `CommandPaletteOverlay`, so opening it redraws the
    /// overlay alone.
    private(set) var palette: CommandPaletteModel?
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
        if let existing = tabs.firstIndex(where: { $0.repoURL?.path == url.path }) {
            // A "Repo not found" tab whose folder is opened again (it is back) opens it.
            if tabs[existing].isMissing { tabs[existing].isMissing = false }
            selectedTabID = tabs[existing].id
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
        guard let index = selectedIndex, let url = tabs[index].repoURL, !tabs[index].isMissing else { return }
        let id = tabs[index].id
        let session = sessions[id] ?? makeSession(for: id, url: url)
        sessions[id] = session
        session.select(session.selection)
    }

    /// A tab's session, with the profile and commit a restored tab had in the saved session.
    private func makeSession(for id: Tab.ID, url: URL) -> RepoSession {
        let session = RepoSession(url: url)
        if let saved = restored.removeValue(forKey: id) {
            if let profile = saved.profile { session.restoreProfile(profile.profileID) }
            if let commit = saved.commit { session.restoreSelection(commit) }
        }
        return session
    }

    // MARK: Session restore

    /// Session restore: this new window's tabs become `saved` (`missing` = the folders that are gone) and the saved
    /// selected tab opens, as a click would show it. Not `openTab`: no recent-repos update, and the other tabs get their
    /// session only when selected.
    func restore(_ saved: [SavedTab], selected: Int?, missing: Set<String>) {
        guard !saved.isEmpty else { return }
        welcomes.removeAll()
        tabs = saved.map { tab in
            Tab(repoURL: tab.path.map { URL(fileURLWithPath: $0, isDirectory: true) },
                isMissing: tab.path.map(missing.contains) ?? false)
        }
        restored = Dictionary(uniqueKeysWithValues: zip(tabs.map(\.id), saved))
        let index = selected.flatMap { tabs.indices.contains($0) ? $0 : nil } ?? 0
        selectedTabID = tabs[index].id
        if let url = tabs[index].repoURL, !tabs[index].isMissing { UITiming.open(url.path) }
        activateSelectedTab()
    }

    /// The tabs as the session saves them, in order. A tab with a session saves its live profile and commit; one
    /// without keeps what it was restored with. Observable: reading it in `withObservationTracking` follows every
    /// change it depends on (tabs, their sessions' selection and profile).
    var savedTabs: [SavedTab] {
        tabs.map { tab in
            let path = tab.repoURL?.path
            guard let session = sessions[tab.id] else {
                var saved = restored[tab.id] ?? SavedTab()
                saved.path = path
                return saved
            }
            let commit: String? = if case .commit(let hash) = session.selection { hash } else { nil }
            // Before the repo's profile is resolved, its id says nothing yet: a later launch resolves it again.
            let profile = session.profileResolved ? SavedProfile(session.profileID) : nil
            return SavedTab(path: path, profile: profile, commit: commit)
        }
    }

    /// "Repo not found" › Locate…: the tab opens `url` instead (the tab that already shows it when there is one).
    func locate(_ id: Tab.ID, at url: URL) {
        let url = url.standardizedFileURL
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if let existing = tabs.first(where: { $0.id != id && $0.repoURL?.path == url.path }) {
            _ = closeTab(id: id)
            return selectTab(id: existing.id)
        }
        UITiming.open(url.path)
        RecentRepos.shared.add(url)
        tabs[index].repoURL = url
        tabs[index].isMissing = false
        if selectedTabID == id { activateSelectedTab() }
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
        restored.removeValue(forKey: id)
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

    /// Shows Settings at `section`: the path a click on a Settings sidebar row takes. The section switches in this
    /// call; a section whose data is still loading shows its placeholder in the same frame.
    func selectSettings(_ section: SettingsSection) {
        UITiming.select("settings \(section.rawValue)")
        navigation.page = .settings
        settingsSection = section
        settingsToken &+= 1
    }

    // MARK: Command palette

    /// Opens the command palette on the window's rows now (`PaletteCommands`), `query` typed; the card shows in this
    /// frame, its rows once ranked off the main actor.
    func openPalette(query: String = "") {
        UITiming.select("palette")
        palette = CommandPaletteModel(snapshot: PaletteCommands.snapshot(for: self), query: query)
    }

    /// ⌘K: opens the palette, or closes it when it is open.
    func togglePalette() {
        if palette == nil { openPalette() } else { closePalette() }
    }

    func closePalette() {
        palette = nil
    }

    /// Runs a row of the current results (Return or a click): the palette closes first, so a confirmation or form the
    /// action opens takes the focus. False when the row cannot run (disabled or stale); the palette stays open.
    @discardableResult
    func performPalette(_ item: PaletteItem) -> Bool {
        guard let action = palette?.action(for: item) else { return false }
        palette = nil
        action()
        return true
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
            guard let value = request.value else {
                navigation.page = .settings
                return
            }
            guard let section = SettingsSection(rawValue: value) else {
                Self.logger.error("-HistqSelect settings: unknown section \(value, privacy: .public)")
                navigation.page = .settings
                return
            }
            selectSettings(section)
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
