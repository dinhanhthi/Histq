// App-wide state locations and DEBUG test seams: where files and preferences live, every preference key with its
// default, the Keychain service, launch flags, the `-HistqSelect` request and the timing log.
import Foundation
import os

/// DEBUG launch flags and the values that depend on them. In Release every flag reads as absent, so the app always
/// uses the real Application Support folder, the standard preferences and the real Keychain service.
enum AppState {
    /// The value after `name` in the launch arguments (`-HistqStateDir /path` -> "/path"), or nil when the flag is
    /// absent or has no value. DEBUG only: always nil in Release. Later phases read their own flags through it, at
    /// their point of use (`AppState.launchFlag("-HistqAvatarMode")`).
    static func launchFlag(_ name: String) -> String? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
        #else
        return nil
        #endif
    }

    /// The folder given by DEBUG `-HistqStateDir <dir>`: automated launches keep all their state there (files,
    /// timing logs) and use the QA preferences suite and Keychain service. nil in normal runs.
    static let stateDirectory: URL? = launchFlag("-HistqStateDir").map {
        URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }

    /// Whether this launch is isolated in a state dir (automated QA run).
    static var isStateDirMode: Bool { stateDirectory != nil }

    /// The Keychain service for every item the app stores.
    static var keychainService: String { isStateDirMode ? "com.math2it.histq.qa" : "com.math2it.histq" }

    /// The DEBUG `-HistqSelect <kind>[:<value>]` request of this launch, or nil.
    static let launchSelection: SelectRequest? = launchFlag("-HistqSelect").flatMap(SelectRequest.init(parsing:))
}

/// Where the app keeps its files: `~/Library/Application Support/Histq`, or the DEBUG state dir.
enum StatePaths {
    static let root: URL = AppState.stateDirectory
        ?? URL.applicationSupportDirectory.appending(path: "Histq", directoryHint: .isDirectory)

    /// `root/<name>`, created if missing (profiles, sessions, avatar cache, undo journals).
    static func directory(_ name: String) -> URL {
        let url = root.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Creates the root folder; called once at launch.
    static func prepare() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
}

/// The preferences store every setting reads and writes, `@AppStorage` included
/// (`@AppStorage(PrefKey.rowDensity.rawValue, store: Preferences.defaults)`).
enum Preferences {
    /// Standard defaults, or the `com.math2it.histq.qa` suite in state-dir mode, so QA runs never touch the user's
    /// settings (Debug and Release share the bundle id). UserDefaults is thread-safe (documented), so the
    /// `nonisolated(unsafe)` only covers its missing Sendable mark.
    nonisolated(unsafe) static let defaults: UserDefaults = AppState.isStateDirMode
        ? UserDefaults(suiteName: "com.math2it.histq.qa") ?? .standard
        : .standard

    /// Registers every `PrefKey` default, so a read of a key never set returns its default. Called once at launch.
    static func registerDefaults() {
        defaults.register(defaults: Dictionary(uniqueKeysWithValues: PrefKey.allCases.map { ($0.rawValue, $0.defaultValue) }))
    }
}

/// Every preference key of the app, declared once with its default. The raw value is the stored key (written by
/// hand in QA runs: `defaults write com.math2it.histq.qa rowDensity -string compact`); choices are stored as
/// strings. Each consumer reads its key where it is built; the Settings pages only write them.
enum PrefKey: String, CaseIterable {
    /// Graph date column format (`DateFormatter.dateFormat`).
    case dateFormat
    /// Graph row height: "compact", "regular" or "comfortable".
    case rowDensity
    /// Commit avatars: "real" (Gravatar / GitHub), "generated" or "initials".
    case avatarMode
    /// Pull button: a `GitOperations.PullMode` case name, "fastForward" (merge if needed), "fastForwardOnly" or "rebase".
    case pullMode
    /// Auto-fetch interval in minutes; 0 = off.
    case autoFetchMinutes
    /// `fetch --prune` on every fetch.
    case pruneOnFetch
    /// `git mergetool --tool=<value>`; empty = git's configured tool.
    case mergeTool
    /// Custom git executable path; empty = auto-detect.
    case gitPath
    /// The profile new tabs use (UUID string); empty = none yet.
    case defaultProfileID
    /// App tab strip position: "top" or "left".
    case tabPosition
    /// Native window tabs in the traffic-light row (Phase 8 attempt).
    case nativeTabsOnTop
    /// Repo layout panel widths, encoded by `RepoLayoutView`; empty = the layout's defaults.
    case panelWidths
    /// Graph column widths, encoded by `GraphView` ("refs:120,graph:120,…"); empty = the graph's defaults.
    case graphColumnWidths
    /// Terminal font family; empty = the system monospaced font.
    case terminalFontName
    /// Terminal font size in points.
    case terminalFontSize
    /// Terminal shell path; empty = the user's login shell.
    case terminalShell
    /// Terminal scrollback lines.
    case terminalScrollback
    /// Terminal cursor: "block", "underline" or "bar".
    case terminalCursor
    /// Open the terminal drawer with each new tab.
    case terminalOpenWithNewTab
    /// The Welcome page's recent repositories: folder paths, most recent first (`RecentRepos`).
    case recentRepos
    /// The detail panel's file lists: "path" (one row per file) or "tree" (rows under their folders).
    case fileListMode

    /// The value a key has until the user sets it.
    var defaultValue: Any {
        switch self {
        case .dateFormat: "MM/dd/yy @ HH:mm"
        case .rowDensity: "regular"
        case .avatarMode: "generated"
        case .pullMode: "fastForward"
        case .autoFetchMinutes: 0
        case .pruneOnFetch: false
        case .mergeTool: ""
        case .gitPath: ""
        case .defaultProfileID: ""
        case .tabPosition: "top"
        case .nativeTabsOnTop: false
        case .panelWidths: ""
        case .graphColumnWidths: ""
        case .terminalFontName: ""
        case .terminalFontSize: 12.0
        case .terminalShell: ""
        case .terminalScrollback: 10_000
        case .terminalCursor: "block"
        case .terminalOpenWithNewTab: false
        case .recentRepos: [String]()
        case .fileListMode: "path"
        }
    }
}

/// A DEBUG `-HistqSelect <kind>[:<value>]` request (`tab:1`, `wip`, `commit:<sha>`, `file:src/app.swift`,
/// `settings:profiles`). The window routes it through the same `select` path a click takes.
struct SelectRequest: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case tab, wip, commit, branch, file, conflict, commitfile, settings, sidebar, pr
    }

    let kind: Kind
    /// The text after the first colon (paths and refs may hold more colons), or nil.
    let value: String?

    /// Parses `kind[:value]`; an unknown kind is logged and gives nil.
    init?(parsing text: String) {
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let kind = Kind(rawValue: String(parts[0])) else {
            Logger(subsystem: "com.math2it.histq", category: "launch")
                .error("-HistqSelect: unknown kind in \(text, privacy: .public), ignored")
            return nil
        }
        self.kind = kind
        value = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
    }
}

/// DEBUG timing log for the click-first checks: each line is `<ms since launch> <event> <detail>`, appended to
/// `<stateDir>/timing.log` (`refresh` lines to `<stateDir>/refresh.log`) when `-HistqStateDir` is set, and mirrored
/// to the unified log (category "timing", `.notice`). Callable from any thread; every function is a no-op in
/// Release, so call sites need no `#if DEBUG`.
enum UITiming {
    /// A repo was opened in a tab.
    static func open(_ detail: String) { record("open", detail) }
    /// The selection changed (`select tab 1`, `select commit <sha>`).
    static func select(_ detail: String) { record("select", detail) }
    /// The detail's placeholder is on screen.
    static func placeholder(_ detail: String) { record("placeholder", detail) }
    /// The delayed spinner faded in (the load took over ~150 ms).
    static func spinner(_ detail: String) { record("spinner", detail) }
    /// The detail's content is on screen.
    static func content(_ detail: String) { record("content", detail) }
    /// A repo's whole log has been parsed and laid out: `content log-complete <commit count>`.
    static func logComplete(commitCount: Int) { record("content", "log-complete \(commitCount)") }
    /// The repo watcher triggered a refresh (`status`, `refs`, `log`, `status+refs`); goes to `refresh.log`.
    static func refresh(_ scope: String) { record("refresh", scope, file: "refresh.log") }

    #if DEBUG
    /// The launch origin, in uptime nanoseconds; set by `markLaunch()` at the top of `main()`.
    nonisolated(unsafe) private static var launchNanos = DispatchTime.now().uptimeNanoseconds
    private static let logger = Logger(subsystem: "com.math2it.histq", category: "timing")
    /// Writes in call order without blocking the caller.
    private static let queue = DispatchQueue(label: "com.math2it.histq.timing")
    #endif

    /// Sets the "ms since launch" origin. Call once, first thing in `main()`, before any other thread exists.
    static func markLaunch() {
        #if DEBUG
        launchNanos = DispatchTime.now().uptimeNanoseconds
        #endif
    }

    private static func record(_ event: String, _ detail: String, file: String = "timing.log") {
        #if DEBUG
        let ms = Double(DispatchTime.now().uptimeNanoseconds &- launchNanos) / 1_000_000
        let line = String(format: "%.1f", ms) + " \(event) \(detail)"
        logger.notice("\(line, privacy: .public)")
        guard let directory = AppState.stateDirectory else { return }
        let path = directory.appending(path: file).path
        queue.async {
            // Opened per line with O_APPEND: the file may be truncated by a test while the app runs, and the app
            // may be killed at any moment.
            let fd = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else { return }
            let bytes = Array((line + "\n").utf8)
            _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            Darwin.close(fd)
        }
        #endif
    }
}
