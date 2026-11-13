// The command palette's rows for one window, copied when it opens (task 8.5): the toolbar's repo actions and their
// Pull ▾ / Push ▾ menus, "Checkout <branch>" for every local and remote branch, the window's tabs, Open Repository…,
// the Settings pages and the tab position, then the repo's menu operations (working tree, the selected commit, the
// stashes, each branch, remote branch and tag, the remotes). Every repo row runs the same `MenuEntry` or
// `ToolbarAction` the menus and buttons run, so its confirmations, forms and enabled state are theirs.
import AppKit
import HistqCore

/// The palette's groups, in the snapshot's order (the order of an empty query and of equal scores).
enum PaletteSection: String, Sendable {
    case repository = "Repository"
    case checkout = "Checkout"
    case tabs = "Tabs"
    case app = "Histq"
    case operations = "Operations"
}

/// One palette row: what the list shows and searches. A value, so the ranking runs off the main actor; its action
/// stays on the main actor in the snapshot (`PaletteSnapshot.actions`). Disabled rows show dimmed and never run.
struct PaletteItem: Identifiable, Equatable, Sendable {
    /// Its index in the snapshot.
    let id: Int
    let title: String
    /// What it acts on or where it comes from ("Branch develop", "Pull ▾"), shown after the title and searched too.
    let detail: String
    let section: PaletteSection
    let systemImage: String
    let isEnabled: Bool

    /// The lowercased texts a keyword may hit, the title first (the ranking's tie-break compares it).
    var searchKeys: [String] { [title.lowercased(), detail.lowercased()] }
}

/// The rows of one palette opening and their actions, by row id.
struct PaletteSnapshot {
    private(set) var items: [PaletteItem] = []
    private(set) var actions: [Int: @MainActor () -> Void] = [:]

    mutating func add(_ title: String, detail: String, section: PaletteSection, systemImage: String,
                      enabled: Bool = true, perform: @escaping @MainActor () -> Void)
    {
        let id = items.count
        items.append(PaletteItem(id: id, title: title, detail: detail, section: section, systemImage: systemImage,
                                 isEnabled: enabled))
        actions[id] = perform
    }

    /// A menu's actions as rows: separators dropped, a submenu's items titled "Submenu › Item" (or left out when
    /// `submenus` is false), entries whose title `skip` accepts left out (with their submenus).
    mutating func add(_ entries: [MenuEntry], detail: String, section: PaletteSection = .operations,
                      systemImage: String, submenus: Bool = true, prefix: String = "",
                      skip: (String) -> Bool = { _ in false })
    {
        for entry in entries where !skip(entry.title) {
            switch entry.kind {
            case .separator:
                continue
            case .action(let perform):
                add(prefix + entry.title, detail: detail, section: section, systemImage: systemImage,
                    enabled: entry.isEnabled, perform: perform)
            case .submenu(let children):
                guard submenus else { continue }
                add(children, detail: detail, section: section, systemImage: systemImage, submenus: true,
                    prefix: prefix + entry.title + " › ", skip: skip)
            }
        }
    }
}

@MainActor
enum PaletteCommands {
    /// The window's rows now. Repo rows only while a repo tab shows (`actionSession`, as the toolbar's buttons):
    /// on Settings or About their confirmations and forms would have no presenter.
    static func snapshot(for model: WindowModel) -> PaletteSnapshot {
        var snapshot = PaletteSnapshot()
        let session = model.actionSession
        if let session {
            repository(session, into: &snapshot)
            checkouts(session, into: &snapshot)
        }
        tabs(model, into: &snapshot)
        app(model, into: &snapshot)
        if let session { operations(session, into: &snapshot) }
        return snapshot
    }

    /// The toolbar's buttons (enabled as they are), then the Pull ▾ and Push ▾ menus.
    private static func repository(_ session: RepoSession, into snapshot: inout PaletteSnapshot) {
        for action in ToolbarAction.allCases {
            let isBusy = session.isRunning(action.key)
            snapshot.add(action.title, detail: action.help(session), section: .repository,
                         systemImage: action.systemImage, enabled: !isBusy && action.isEnabled(session)) {
                action.perform(session)
            }
        }
        snapshot.add(RepoMenus.pull(session), detail: "Pull ▾", section: .repository,
                     systemImage: ToolbarAction.pull.systemImage)
        snapshot.add(RepoMenus.push(session), detail: "Push ▾", section: .repository,
                     systemImage: ToolbarAction.push.systemImage)
    }

    /// Every local branch but the current one, then every remote branch, checked out as the sidebar's double-click
    /// does (`RepoMenus.checkout`). Disabled while a checkout runs, as the toolbar's branch menu is.
    private static func checkouts(_ session: RepoSession, into snapshot: inout PaletteSnapshot) {
        guard let refs = session.refs.value else { return }
        let enabled = !session.isRunning(.checkout)
        for branch in refs.localBranches where branch.name != session.currentBranch {
            snapshot.add("Checkout \(branch.name)", detail: "Local branch", section: .checkout,
                         systemImage: "arrow.triangle.branch", enabled: enabled) {
                RepoMenus.checkout(.local(branch.name), session)
            }
        }
        for branch in refs.remoteBranches {
            snapshot.add("Checkout \(branch.name)", detail: "Remote branch", section: .checkout, systemImage: "cloud",
                         enabled: enabled) {
                RepoMenus.checkout(.remote(branch.name), session)
            }
        }
    }

    /// The window's other tabs (selected as a click on them), then New Tab. Rows hold the model weakly: the model
    /// holds the palette, so a strong capture would keep a closed window's model and sessions alive.
    private static func tabs(_ model: WindowModel, into snapshot: inout PaletteSnapshot) {
        for tab in model.tabs where tab.id != model.selectedTabID || model.navigation.page != .home {
            let detail = tab.repoURL.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Welcome"
            snapshot.add("Switch to tab \(tab.title)", detail: detail, section: .tabs,
                         systemImage: tab.repoURL == nil ? "house" : "folder") { [weak model] in
                model?.selectTab(id: tab.id)
            }
        }
        snapshot.add("New Tab", detail: "⌘T", section: .tabs, systemImage: "plus") { [weak model] in
            model?.openTab(nil)
        }
    }

    /// Open Repository…, the Settings pages and the tab position.
    private static func app(_ model: WindowModel, into snapshot: inout PaletteSnapshot) {
        snapshot.add("Open Repository…", detail: "⌘O", section: .app, systemImage: "folder.badge.plus") {
            NSApp.sendAction(#selector(AppDelegate.openDocument(_:)), to: nil, from: nil)
        }
        for section in SettingsSection.allCases {
            snapshot.add("Settings › \(section.label.title)", detail: "Settings", section: .app,
                         systemImage: section.label.icon) { [weak model] in
                model?.selectSettings(section)
            }
        }
        // General › Tab position: the same preference that page writes; the windows follow it live.
        let onLeft = TabPosition.current == .left
        snapshot.add(onLeft ? "Move Tabs to the Top" : "Move Tabs to the Left", detail: "General › Tab position",
                     section: .app, systemImage: onLeft ? "rectangle.topthird.inset.filled" : "sidebar.left") {
            Preferences.defaults.set(onLeft ? TabPosition.top.rawValue : TabPosition.left.rawValue,
                                     forKey: PrefKey.tabPosition.rawValue)
        }
    }

    /// The repo's context menus: the working tree's (when it has changes), the selected commit's or stash's, each
    /// stash's, the current branch's, every other branch's, each remote branch's and tag's, then the Remote card's.
    /// Their "Checkout …" items are left out (the Checkout rows run the same `RepoMenus.checkout`), and so are the
    /// commit menu's ref submenus (each ref has its own rows). Only the current branch's submenus are listed (Set
    /// Upstream): another branch's would add one row per remote branch for each local branch.
    private static func operations(_ session: RepoSession, into snapshot: inout PaletteSnapshot) {
        let refs = session.refs.value
        let current = session.currentBranch
        let isCheckout: (String) -> Bool = { $0.hasPrefix("Checkout ") }

        if session.status.value?.entries.isEmpty == false {
            snapshot.add(RepoMenus.wip(session), detail: "Working tree", systemImage: "pencil")
        }
        switch session.selection {
        case .commit(let hash):
            let refMenus = Set((refs?.localBranches.map { SidebarItem.local($0.name) } ?? [])
                .map(\.menuTitle) + (refs?.remoteBranches.map { SidebarItem.remote($0.name).menuTitle } ?? [])
                + (refs?.tags.map { SidebarItem.tag($0.name).menuTitle } ?? []))
            // "Checkout <branch>" duplicates a Checkout row; the detached checkout of this commit stays.
            snapshot.add(RepoMenus.commit(hash, session), detail: "Commit \(hash.prefix(7))",
                         systemImage: "smallcircle.filled.circle") { title in
                refMenus.contains(title) || (isCheckout(title) && !title.hasSuffix("(Detached)…"))
            }
        default:
            break
        }
        for stash in session.log.value?.stashes ?? [] {
            snapshot.add(RepoMenus.stash(stash.hash, session), detail: "Stash \(stash.selector) \(stash.message)",
                         systemImage: "tray")
        }
        guard let refs else { return }
        if let current {
            snapshot.add(RepoMenus.ref(.local(current), session), detail: "Branch \(current)",
                         systemImage: "arrow.triangle.branch", skip: isCheckout)
        }
        for branch in refs.localBranches where branch.name != current {
            snapshot.add(RepoMenus.ref(.local(branch.name), session), detail: "Branch \(branch.name)",
                         systemImage: "arrow.triangle.branch", submenus: false, skip: isCheckout)
        }
        for branch in refs.remoteBranches {
            snapshot.add(RepoMenus.ref(.remote(branch.name), session), detail: "Remote branch \(branch.name)",
                         systemImage: "cloud", skip: isCheckout)
        }
        for tag in refs.tags {
            snapshot.add(RepoMenus.ref(.tag(tag.name), session), detail: "Tag \(tag.name)", systemImage: "tag")
        }
        snapshot.add(RepoMenus.remotes(session), detail: "Remotes", systemImage: "network")
    }
}
