// The app entry: an AppKit delegate that owns the main window, its menu and the shared state.
import AppKit
import SwiftUI

/// AppKit entry point: no SwiftUI `App`, so SwiftUI is only loaded inside the window.
@main
@MainActor
enum HistqApp {
    // NSApplication.delegate is weak; keep the delegate alive for the app lifetime.
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}

/// Whether the main window shows on screen (not hidden, minimized or covered). Read it with
/// `@Environment(WindowState.self)` to pause timelines and pulses nobody sees.
@Observable
@MainActor
final class WindowState {
    var isVisible = true
}

/// Owns the one main window, its navigation and the main menu for the app lifetime.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// The selected page; kept across window closes, so a menu can open a page before the window exists.
    let navigation = Navigation()
    let windowState = WindowState()

    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppearanceMode.current.apply()
        NSApp.mainMenu = makeMainMenu()
        showMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func showMainWindow() {
        if window == nil {
            let hosting = NSHostingController(rootView: MainView(navigation: navigation).environment(windowState))
            // The window owns its size, not the SwiftUI content.
            hosting.sizingOptions = []
            // The SwiftUI toolbar (the page tabs) becomes the window's toolbar, in the traffic-light row.
            hosting.sceneBridgingOptions = [.toolbars]
            let window = NSWindow(contentViewController: hosting)
            window.title = "Histq"
            window.titleVisibility = .hidden
            window.toolbarStyle = .unified
            // One background for the toolbar and the content, without a line between them.
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            // Full size content: the background runs under the toolbar too.
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 600, height: 420)
            window.setContentSize(NSSize(width: 640, height: 560))
            if !window.setFrameUsingName("MainWindow") { window.center() }
            window.setFrameAutosaveName("MainWindow")
            window.delegate = self
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Opens the main window on the Settings page.
    @objc func showSettings() {
        navigation.page = .settings
        showMainWindow()
    }

    /// Opens the main window on the About page.
    @objc func showAbout() {
        navigation.page = .about
        showMainWindow()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windowState.isVisible = window.occlusionState.contains(.visible)
    }

    /// App menu (About, Settings, Hide, Quit), Edit and Window menus: without them text fields lose copy and paste.
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
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu
        let mainMenu = NSMenu()
        for submenu in [appMenu, editMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        return mainMenu
    }
}
