// The window's toolbar, in the traffic-light row (house style, as EchoDiar and SegDown): at the leading edge the repo
// menu (the window's repo tabs, recent repos, Open…), the branch menu (checks out the picked branch), as in GitKraken,
// and the tab's profile chip (`ProfilePicker`); at the trailing edge capsules of Undo / Redo, Pull ▾ / Push ▾ / Fetch, Branch / Stash / Pop, then
// Terminal / Search / Settings. The set of items never changes: on a Welcome tab, Settings or About the repo actions
// are disabled, not removed.
//
// An AppKit `NSToolbar`, not a SwiftUI `.toolbar`: a bridged SwiftUI toolbar takes part in every SwiftUI update pass of
// the window (about 10 ms per tab select with these items, see docs/later), even when its items depend on nothing.
// Here the items are built once; a narrow observation of the model only sets their titles, images and enabled state,
// and each menu is filled when it opens.
import AppKit
import HistqCore
import Observation

/// One window's toolbar: the `NSToolbar` delegate, the target of its items and the delegate of its menus. The window's
/// entry keeps it alive (`NSToolbar.delegate` is weak).
@MainActor
final class HeaderToolbar: NSObject, NSToolbarDelegate, NSMenuDelegate {
    let toolbar = NSToolbar(identifier: "HeaderToolbar")
    private let model: WindowModel

    private let repoItem = NSMenuToolbarItem(itemIdentifier: ID.repo)
    private let branchItem = NSMenuToolbarItem(itemIdentifier: ID.branch)
    private let profileItem = NSMenuToolbarItem(itemIdentifier: ID.profile)
    /// The color the profile chip's dot shows ("" for no profile), so the image is only redrawn when it changes.
    private var profileDot: String?
    private let undoItem = NSToolbarItem(itemIdentifier: ID.undo)
    private let redoItem = NSToolbarItem(itemIdentifier: ID.redo)
    private let pullItem = NSMenuToolbarItem(itemIdentifier: ID.pull)
    private let pushItem = NSMenuToolbarItem(itemIdentifier: ID.push)
    private let fetchItem = NSToolbarItem(itemIdentifier: ID.fetch)
    private let createBranchItem = NSToolbarItem(itemIdentifier: ID.createBranch)
    private let stashItem = NSToolbarItem(itemIdentifier: ID.stash)
    private let popItem = NSToolbarItem(itemIdentifier: ID.pop)
    private let terminalItem = NSToolbarItem(itemIdentifier: ID.terminal)
    private let searchItem = NSToolbarItem(itemIdentifier: ID.search)
    private let settingsItem = NSToolbarItem(itemIdentifier: ID.settings)
    private var groups: [NSToolbarItem.Identifier: NSToolbarItemGroup] = [:]

    /// The repo actions' buttons, by the operation each shows.
    private var actionItems: [(item: NSToolbarItem, action: ToolbarAction)] {
        [(pullItem, .pull), (pushItem, .push), (fetchItem, .fetch), (createBranchItem, .branch), (stashItem, .stash),
         (popItem, .pop)]
    }

    private enum ID {
        static let repo = NSToolbarItem.Identifier("repo")
        static let branch = NSToolbarItem.Identifier("branch")
        static let profile = NSToolbarItem.Identifier("profile")
        static let undo = NSToolbarItem.Identifier("undo")
        static let redo = NSToolbarItem.Identifier("redo")
        static let pull = NSToolbarItem.Identifier("pull")
        static let push = NSToolbarItem.Identifier("push")
        static let fetch = NSToolbarItem.Identifier("fetch")
        static let createBranch = NSToolbarItem.Identifier("createBranch")
        static let stash = NSToolbarItem.Identifier("stash")
        static let pop = NSToolbarItem.Identifier("pop")
        static let terminal = NSToolbarItem.Identifier("terminal")
        static let search = NSToolbarItem.Identifier("search")
        static let settings = NSToolbarItem.Identifier("settings")
        static let historyGroup = NSToolbarItem.Identifier("historyGroup")
        static let syncGroup = NSToolbarItem.Identifier("syncGroup")
        static let branchGroup = NSToolbarItem.Identifier("branchGroup")
        static let toolsGroup = NSToolbarItem.Identifier("toolsGroup")
    }

    init(model: WindowModel) {
        self.model = model
        super.init()
        configureItems()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        observe()
    }

    // MARK: Items

    private func configureItems() {
        configureMenu(repoItem, label: "Repository")
        configureMenu(branchItem, label: "Branch")
        configureMenu(profileItem, label: "Profile")
        // An icon at the left of the title, inside the button, as the profile chip has its dot. Template symbols, so
        // they take the toolbar's text color.
        repoItem.image = NSImage(systemSymbolName: "book.closed", accessibilityDescription: "Repository")
        branchItem.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Branch")
        // Kept out of the overflow menu longer than the buttons.
        repoItem.visibilityPriority = .high
        branchItem.visibilityPriority = .high
        profileItem.visibilityPriority = .high

        // Phase 9 wires Undo and Redo to the operation journal; Phase 13 opens the repo in a terminal; the Phase 8
        // palette opens from Search.
        configureButton(undoItem, label: "Undo", systemImage: "arrow.uturn.backward")
        configureButton(redoItem, label: "Redo", systemImage: "arrow.uturn.forward")
        configureButton(terminalItem, label: "Terminal", systemImage: "terminal")
        configureButton(searchItem, label: "Search", systemImage: "magnifyingglass")
        for item in [undoItem, redoItem, terminalItem, searchItem] { item.isEnabled = false }

        for (item, action) in actionItems {
            configureButton(item, label: action.title, systemImage: action.systemImage)
            item.action = selector(for: action)
        }
        // With an action, a menu item shows its menu from an arrow beside the button: Pull ▾ and Push ▾.
        for item in [pullItem, pushItem] {
            item.menu = makeMenu()
            item.showsIndicator = true
        }

        configureButton(settingsItem, label: "Settings", systemImage: "gearshape")
        settingsItem.action = #selector(toggleSettings(_:))

        groups[ID.historyGroup] = group(ID.historyGroup, [undoItem, redoItem])
        groups[ID.syncGroup] = group(ID.syncGroup, [pullItem, pushItem, fetchItem])
        groups[ID.branchGroup] = group(ID.branchGroup, [createBranchItem, stashItem, popItem])
        groups[ID.toolsGroup] = group(ID.toolsGroup, [terminalItem, searchItem, settingsItem])
    }

    /// A menu whose items are built when it opens (`menuNeedsUpdate`), never on a model change.
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        return menu
    }

    private func configureMenu(_ item: NSMenuToolbarItem, label: String) {
        item.label = label
        item.paletteLabel = label
        item.menu = makeMenu()
        item.showsIndicator = true
        item.isBordered = true
        // Its state is set from the model, never validated by AppKit.
        item.autovalidates = false
    }

    private func configureButton(_ item: NSToolbarItem, label: String, systemImage: String) {
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: label)
        item.isBordered = true
        item.target = self
        // Its state is set from the model, never validated by AppKit.
        item.autovalidates = false
    }

    private func group(_ id: NSToolbarItem.Identifier, _ subitems: [NSToolbarItem]) -> NSToolbarItemGroup {
        let group = NSToolbarItemGroup(itemIdentifier: id)
        group.subitems = subitems
        group.autovalidates = false
        group.label = ""
        return group
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // On macOS 26 a fixed space starts a new capsule; before, there are no capsules to separate.
        let gap: [NSToolbarItem.Identifier] = PlatformFeatures.liquidGlass ? [.space] : []
        return [ID.repo, ID.branch, ID.profile, .flexibleSpace, ID.historyGroup] + gap + [ID.syncGroup] + gap + [ID.branchGroup]
            + gap + [ID.toolsGroup]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem?
    {
        switch itemIdentifier {
        case ID.repo: repoItem
        case ID.branch: branchItem
        case ID.profile: profileItem
        default: groups[itemIdentifier]
        }
    }

    // MARK: State

    /// Applies the model to the items, then applies it again after the next change of what it read. Only the
    /// selected tab's title, its session's refs, running operations, status, stashes, remotes and profile, the
    /// profile store, and the page are read, so other tabs and the content's own state never wake the toolbar.
    private func observe() {
        withObservationTracking {
            apply()
        } onChange: { [weak self] in
            // Called before the change lands, off any isolation: apply on the main actor once it has.
            Task { @MainActor [weak self] in self?.observe() }
        }
    }

    private func apply() {
        let selected = model.selectedIndex.map { model.tabs[$0] }
        let session = model.actionSession
        set(repoItem, title: Self.truncated(selected?.repoURL == nil ? "Histq" : selected?.title ?? "Histq", 28))
        set(repoItem, toolTip: selected?.repoURL?.path ?? "Switch repository")

        set(branchItem, hidden: session == nil)
        if let session {
            let isBusy = session.isRunning(.checkout)
            set(branchItem, title: Self.truncated(Self.branchTitle(session.refs.value?.head), 32))
            set(branchItem, enabled: !isBusy && session.refs.value != nil)
            set(branchItem, toolTip: isBusy ? "Checking out…" : "Check out another branch")
        }

        // Hidden, like the branch menu, where no repo tab shows (Welcome, Settings, About).
        set(profileItem, hidden: session == nil)
        if let session {
            let profile = session.profile
            set(profileItem, title: Self.truncated(ProfilePicker.title(profile), 24))
            set(profileItem, toolTip: ProfilePicker.toolTip(profile))
            let dot = profile?.color ?? ""
            if profileDot != dot {
                profileDot = dot
                profileItem.image = ProfilePicker.dot(hex: profile?.color)
            }
        }

        for (item, action) in actionItems {
            let isBusy = session?.isRunning(action.key) ?? false
            set(item, enabled: session.map { !isBusy && action.isEnabled($0) } ?? false)
            set(item, systemImage: isBusy ? Self.busySymbol : action.systemImage, label: action.title)
            set(item, toolTip: isBusy ? "\(action.title): running…" : session.map(action.help) ?? action.title)
        }

        let isSettings = model.navigation.page == .settings
        set(settingsItem, systemImage: isSettings ? "gearshape.fill" : "gearshape", label: "Settings")
    }

    // Each setter writes only a changed value: an unchanged write still relayouts the toolbar.

    private func set(_ item: NSToolbarItem, title: String) {
        if item.title != title { item.title = title }
    }

    private func set(_ item: NSToolbarItem, enabled: Bool) {
        if item.isEnabled != enabled { item.isEnabled = enabled }
    }

    private func set(_ item: NSToolbarItem, toolTip: String) {
        if item.toolTip != toolTip { item.toolTip = toolTip }
    }

    private func set(_ item: NSToolbarItem, hidden: Bool) {
        if item.isHidden != hidden { item.isHidden = hidden }
    }

    private var symbols: [ObjectIdentifier: String] = [:]

    private func set(_ item: NSToolbarItem, systemImage: String, label: String) {
        guard symbols[ObjectIdentifier(item)] != systemImage else { return }
        symbols[ObjectIdentifier(item)] = systemImage
        // A symbol this system lacks keeps the current icon rather than an empty button.
        if let image = NSImage(systemSymbolName: systemImage, accessibilityDescription: label) { item.image = image }
    }

    /// In place of a running action's icon (there is no spinner in a toolbar button without a custom view).
    private static let busySymbol = "progress.indicator"

    private static func branchTitle(_ head: Head?) -> String {
        switch head {
        case .branch(let name, _), .unborn(let name): name
        case .detached(let commit): "\(commit.prefix(7)) detached"
        case nil: "…"
        }
    }

    /// `text` cut with "…" after `limit` characters (a toolbar button without a view has no width limit).
    private static func truncated(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    // MARK: Actions

    // One method per action: from the overflow menu or a collapsed group the sender is not the toolbar item.
    @objc private func pull(_ sender: Any?) { perform(.pull) }
    @objc private func push(_ sender: Any?) { perform(.push) }
    @objc private func fetch(_ sender: Any?) { perform(.fetch) }
    @objc private func createBranch(_ sender: Any?) { perform(.branch) }
    @objc private func stash(_ sender: Any?) { perform(.stash) }
    @objc private func pop(_ sender: Any?) { perform(.pop) }

    private func selector(for action: ToolbarAction) -> Selector {
        switch action {
        case .pull: #selector(pull(_:))
        case .push: #selector(push(_:))
        case .fetch: #selector(fetch(_:))
        case .branch: #selector(createBranch(_:))
        case .stash: #selector(stash(_:))
        case .pop: #selector(pop(_:))
        }
    }

    private func perform(_ action: ToolbarAction) {
        guard let session = model.actionSession else { return }
        action.perform(session)
    }

    @objc private func toggleSettings(_ sender: Any?) {
        model.toggleSettings()
    }

    // MARK: Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        let entries: [MenuEntry] = switch menu {
        case repoItem.menu: repoEntries()
        case branchItem.menu: model.actionSession.map(RepoMenus.branchPicker) ?? []
        case profileItem.menu: model.actionSession.map { ProfilePicker.entries(session: $0, model: model) } ?? []
        case pullItem.menu: pullEntries()
        case pushItem.menu: pushEntries()
        default: []
        }
        let built = MenuBuilder.menu(entries)
        let items = built.items
        built.removeAllItems()
        menu.items = items
        if menu === repoItem.menu, let index = items.firstIndex(where: { $0.title == Self.recentMarker }) {
            // The recent repos under a section header.
            menu.removeItem(at: index)
            menu.insertItem(NSMenuItem.sectionHeader(title: "Recent"), at: index)
        }
        if menu === profileItem.menu { ProfilePicker.decorate(menu) }
    }

    /// Stands for the "Recent" section header in `repoEntries`, which `MenuEntry` cannot express.
    private static let recentMarker = "\u{1}recent"

    /// The window's repo tabs (the selected one checked; a pick selects that tab at once, as a click on it does), the
    /// recent repos not open here (a pick opens it as `openTab`), then Open….
    private func repoEntries() -> [MenuEntry] {
        let repoTabs = model.tabs.filter { $0.repoURL != nil }
        let openPaths = Set(repoTabs.compactMap { $0.repoURL?.path })
        let recent = RecentRepos.shared.urls.filter { !openPaths.contains($0.path) }
        var entries: [MenuEntry] = repoTabs.map { tab in
            .action(tab.title, checked: tab.id == model.selectedTabID) { [model] in model.selectTab(id: tab.id) }
        }
        if !recent.isEmpty {
            entries += [.separator, .action(Self.recentMarker, enabled: false) {}]
            entries += recent.map { url in .action(url.lastPathComponent) { [model] in model.openTab(url) } }
        }
        entries += [.separator, .action("Open…") {
            NSApp.sendAction(#selector(AppDelegate.openDocument(_:)), to: nil, from: nil)
        }]
        return entries
    }

    /// Fetch all, then each pull mode.
    private func pullEntries() -> [MenuEntry] {
        guard let session = model.actionSession else { return [] }
        let enabled = session.currentBranch != nil
        return [
            .action("Fetch All") { session.fetchAll() },
            .separator,
            .action("Pull (fast-forward if possible)", enabled: enabled) { session.pull(.fastForward) },
            .action("Pull (fast-forward only)", enabled: enabled) { session.pull(.fastForwardOnly) },
            .action("Pull (rebase)", enabled: enabled) { session.pull(.rebase) },
        ]
    }

    /// Push, or force push with lease (confirmed).
    private func pushEntries() -> [MenuEntry] {
        guard let session = model.actionSession, let branch = session.currentBranch,
              let target = session.pushTarget(of: branch) else { return [] }
        return [
            .action("Push") { session.push(branch: branch, key: .push) },
            .action("Force Push (with lease)…", enabled: target.lease != nil) {
                session.push(branch: branch, force: true, key: .push)
            },
        ]
    }
}

// MARK: - Repo actions

/// A repo action of the toolbar's buttons.
private enum ToolbarAction {
    case pull, push, fetch, branch, stash, pop

    var key: ActionBarAction {
        switch self {
        case .pull: .pull
        case .push: .push
        case .fetch: .fetch
        case .branch: .branch
        case .stash: .stash
        case .pop: .pop
        }
    }

    var title: String {
        switch self {
        case .pull: "Pull"
        case .push: "Push"
        case .fetch: "Fetch"
        case .branch: "Branch"
        case .stash: "Stash"
        case .pop: "Pop"
        }
    }

    var systemImage: String {
        switch self {
        case .pull: "arrow.down.to.line"
        case .push: "arrow.up.to.line"
        case .fetch: "arrow.triangle.2.circlepath"
        case .branch: "arrow.branch"
        case .stash: "tray.and.arrow.down"
        case .pop: "tray.and.arrow.up"
        }
    }

    @MainActor func help(_ session: RepoSession) -> String {
        switch self {
        case .pull: "Pull the current branch"
        case .push: session.currentBranch.flatMap(session.pushTarget(of:)) == nil
            ? "Add a remote to push" : "Push the current branch"
        case .fetch: "Fetch all remotes"
        case .branch: "Create a branch at HEAD"
        case .stash: "Stash every change"
        case .pop: session.newestStash.map { "Pop \($0.selector): \($0.message)" } ?? "No stash to pop"
        }
    }

    @MainActor func isEnabled(_ session: RepoSession) -> Bool {
        switch self {
        case .pull: session.currentBranch != nil
        case .push: session.currentBranch.flatMap(session.pushTarget(of:)) != nil
        case .fetch: true
        case .branch: session.refs.value?.head.commit != nil
        case .stash: !(session.status.value?.entries.isEmpty ?? true)
        case .pop: session.newestStash != nil
        }
    }

    @MainActor func perform(_ session: RepoSession) {
        switch self {
        case .pull: session.pull(RepoSession.preferredPullMode)
        case .push: if let branch = session.currentBranch { session.push(branch: branch, key: .push) }
        case .fetch: session.fetchAll()
        case .branch: session.createBranchAtHead()
        case .stash: session.stashAll()
        case .pop: session.popNewestStash()
        }
    }
}
