// The app entry: an AppKit delegate that owns the windows, their tabs, the main menu and the open handling.
import AppKit
import SwiftUI

/// AppKit entry point: no SwiftUI `App`, so SwiftUI is only loaded inside the windows.
@main
@MainActor
enum HistqApp {
    // NSApplication.delegate is weak; keep the delegate alive for the app lifetime.
    private static let delegate = AppDelegate()

    static func main() {
        UITiming.markLaunch()
        // Resolving git takes seconds: start it before the first repo needs it.
        GitToolchain.prepare()
        StatePaths.prepare()
        Preferences.registerDefaults()
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}

/// Whether a window shows on screen (not hidden, minimized or covered). Read it with
/// `@Environment(WindowState.self)` to pause timelines and pulses nobody sees.
@Observable
@MainActor
final class WindowState {
    var isVisible = true
}

/// Owns the windows, one `WindowModel` each, and the main menu for the app lifetime.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    /// A window with its tabs and visibility.
    private final class Entry {
        let window: NSWindow
        let model: WindowModel
        let state: WindowState

        init(window: NSWindow, model: WindowModel, state: WindowState) {
            self.window = window
            self.model = model
            self.state = state
        }
    }

    private var entries: [Entry] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppearanceMode.current.apply()
        NSApp.mainMenu = makeMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Folders given at launch (`open -a Histq <repo>`) arrive in `application(_:open:)` first and already made
        // the window.
        if entries.isEmpty { show(newWindow()) }
        if let request = AppState.launchSelection {
            // Next turn, once the launch's folders are open as tabs.
            Task { @MainActor in self.target()?.model.select(request) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { show(target() ?? newWindow()) }
        return true
    }

    /// Folders opened from Finder, the Dock or `open -a Histq <folder>…` become tabs in the key window.
    func application(_ application: NSApplication, open urls: [URL]) {
        openFolders(urls)
    }

    // MARK: Windows

    /// The window menu commands act on: the key window, else the main one, else the newest.
    private func target() -> Entry? {
        entry(for: NSApp.keyWindow) ?? entry(for: NSApp.mainWindow) ?? entries.last
    }

    private func entry(for window: NSWindow?) -> Entry? {
        guard let window else { return nil }
        return entries.first { $0.window === window }
    }

    /// Creates a window with one Welcome tab; it is not shown yet.
    private func newWindow() -> Entry {
        let model = WindowModel()
        let state = WindowState()
        let hosting = NSHostingController(
            rootView: MainView(navigation: model.navigation).environment(state).environment(model))
        // The window owns its size, not the SwiftUI content.
        hosting.sizingOptions = []
        // SwiftUI installs no toolbar or title: `MainView` draws the header row itself.
        hosting.sceneBridgingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "Histq"
        window.titleVisibility = .hidden
        // An empty compact toolbar makes the titlebar one row as tall as the header (`HeaderMetrics.height`), with
        // the traffic lights centered in it.
        let toolbar = NSToolbar(identifier: "com.math2it.histq.main")
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        // One background for the toolbar and the content, without a line between them.
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // Full size content: the background runs under the toolbar too.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.setContentSize(WindowSizing.initialSize(on: NSScreen.main))
        WindowSizing.clampMinimum(of: window)
        if AppState.isStateDirMode {
            // QA runs never read or write the user's saved frame: AppKit keeps it in the standard defaults.
            window.center()
        } else if let anchor = target()?.window {
            // A further window: same size, a step down and right from the current one.
            window.setFrame(anchor.frame, display: false)
            window.setFrameTopLeftPoint(NSPoint(x: anchor.frame.minX + 24, y: anchor.frame.maxY - 24))
        } else {
            if !window.setFrameUsingName("MainWindow") { window.center() }
            window.setFrameAutosaveName("MainWindow")
        }
        // A saved or copied frame may be smaller than today's minimum.
        WindowSizing.clampMinimum(of: window)
        window.delegate = self
        model.closeWindow = { [weak window] in window?.performClose(nil) }
        let entry = Entry(window: window, model: model, state: state)
        entries.append(entry)
        return entry
    }

    private func show(_ entry: Entry) {
        entry.window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Opens each folder as a tab in the key window (a new window if there is none); files are ignored.
    private func openFolders(_ urls: [URL]) {
        let folders = urls.filter { url in
            url.isFileURL && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        guard !folders.isEmpty else { return }
        let entry = target() ?? newWindow()
        for folder in folders { entry.model.openTab(folder) }
        show(entry)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        entries.removeAll { $0.window === window }
    }

    /// The minimum size follows the screen the window is on.
    func windowDidChangeScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, entry(for: window) != nil else { return }
        WindowSizing.clampMinimum(of: window)
    }

    /// A display was added, removed or resized: each window's minimum follows its screen again.
    func applicationDidChangeScreenParameters(_ notification: Notification) {
        for entry in entries { WindowSizing.clampMinimum(of: entry.window) }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let entry = entry(for: window) else { return }
        entry.state.isVisible = window.occlusionState.contains(.visible)
    }

    // MARK: Menu actions

    @objc func newWindowAction(_ sender: Any?) {
        show(newWindow())
    }

    @objc func newTab(_ sender: Any?) {
        guard let entry = target() else { return show(newWindow()) }
        entry.model.openTab(nil)
        show(entry)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        panel.message = "Choose one or more repositories"
        Task { @MainActor in
            guard await panel.begin() == .OK else { return }
            self.openFolders(panel.urls)
        }
    }

    /// Opens a Welcome tab, where the clone form lives.
    @objc func cloneRepository(_ sender: Any?) {
        newTab(sender)
    }

    /// Closes the key window's selected tab, and the window with its last tab.
    @objc func closeTab(_ sender: Any?) {
        guard let entry = entry(for: NSApp.keyWindow) else {
            NSApp.keyWindow?.performClose(sender)
            return
        }
        // Settings or About hides the tab: ⌘W leaves the page first, never closing a tab out of sight.
        if entry.model.navigation.page != .home {
            entry.model.navigation.page = .home
            return
        }
        if !entry.model.closeSelectedTab() { entry.window.performClose(sender) }
    }

    /// Opens the Settings page in the key window.
    @objc func showSettings() {
        let entry = target() ?? newWindow()
        entry.model.navigation.page = .settings
        show(entry)
    }

    /// Opens the About page in the key window.
    @objc func showAbout() {
        let entry = target() ?? newWindow()
        entry.model.navigation.page = .about
        show(entry)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(closeTab(_:)) { return NSApp.keyWindow != nil }
        return true
    }

    /// App menu (About, Settings, Hide, Quit), File, Edit and Window menus: without Edit, text fields lose copy and
    /// paste.
    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Histq", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Histq", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)),
                        keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Histq", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Window", action: #selector(newWindowAction(_:)), keyEquivalent: "n").target = self
        fileMenu.addItem(withTitle: "New Tab", action: #selector(newTab(_:)), keyEquivalent: "t").target = self
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o").target = self
        fileMenu.addItem(withTitle: "Clone…", action: #selector(cloneRepository(_:)), keyEquivalent: "").target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Tab", action: #selector(closeTab(_:)), keyEquivalent: "w").target = self
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
        let editMenu = NSMenu(title: "Edit")
        // No typed selectors for these: the responder chain (text views, the window's undo manager) answers them.
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu
        let mainMenu = NSMenu()
        for submenu in [appMenu, fileMenu, editMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        return mainMenu
    }
}

/// A window's size limits. Its minimum fits the repo layout's three panels at their minimums
/// (`RepoLayoutMetrics.minimumWindowSize`), but never exceeds the visible frame of the screen it is on. With a
/// full-size content view the frame and the content have the same size.
@MainActor
private enum WindowSizing {
    /// A new window's size when the screen has room for it.
    static let preferred = NSSize(width: 1200, height: 760)

    /// `preferred`, at least the minimum, at most the screen's visible frame.
    static func initialSize(on screen: NSScreen?) -> NSSize {
        let minimum = RepoLayoutMetrics.minimumWindowSize
        let size = NSSize(width: max(preferred.width, minimum.width), height: max(preferred.height, minimum.height))
        guard let visible = screen?.visibleFrame.size else { return size }
        return NSSize(width: min(size.width, visible.width), height: min(size.height, visible.height))
    }

    /// Sets the window's minimum size for its screen, and grows the window (top edge kept, inside the screen) when
    /// it is smaller than that.
    static func clampMinimum(of window: NSWindow) {
        let minimum = RepoLayoutMetrics.minimumWindowSize
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else {
            window.minSize = minimum
            return
        }
        let clamped = NSSize(width: min(minimum.width, visible.width), height: min(minimum.height, visible.height))
        window.minSize = clamped
        var frame = window.frame
        guard frame.width < clamped.width || frame.height < clamped.height else { return }
        let top = frame.maxY
        frame.size = NSSize(width: max(frame.width, clamped.width), height: max(frame.height, clamped.height))
        frame.origin.y = top - frame.height
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: window.isVisible)
    }
}
