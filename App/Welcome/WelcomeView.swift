// A new tab's page: open a folder, clone a repository (streamed progress, cancel), init one, or reopen a recent one.
// When no usable git was found it explains why first, with a way to fix it without a relaunch.
import AppKit
import HistqCore
import SwiftUI

/// One Welcome tab's state, owned by `WindowModel` so a clone keeps running (and keeps its progress) while another
/// tab is shown. Every git call runs off the main actor; clone and init are user-initiated writes and use the write
/// environment. `open` opens a folder in this tab.
@Observable
@MainActor
final class WelcomeModel {
    /// Whether a usable git was found.
    enum GitCheck: Equatable {
        case checking
        case ok
        case problem(GitExecutableError)
    }

    enum CloneState: Equatable {
        case idle
        /// git's latest progress line, and its percentage when it has one.
        case running(line: String, fraction: Double?)
        case failed(String)
    }

    private(set) var gitCheck = GitCheck.checking
    /// "Install Command Line Tools" was clicked: the card says to come back once the installer is done.
    private(set) var installStarted = false
    var cloneURL = ""
    /// The folder the clone goes into, as `<cloneParent>/<repoName>`.
    private(set) var cloneParent: URL
    private(set) var clone = CloneState.idle
    private(set) var initError: String?

    @ObservationIgnored private let open: (URL) -> Void
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var cloneTask: Task<Void, Never>?
    /// Changes with every clone start or cancel, so a stale clone's progress or end is dropped.
    @ObservationIgnored private var cloneToken = 0

    init(open: @escaping (URL) -> Void) {
        self.open = open
        cloneParent = RecentRepos.shared.urls.first?.deletingLastPathComponent()
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    deinit {
        // A window closing drops its Welcome models without `cancel()`: stop the clone (git with it).
        cloneTask?.cancel()
        checkTask?.cancel()
    }

    /// The folder name a clone of `cloneURL` gets: its last path component without `.git`.
    var repoName: String {
        var text = cloneURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        let last = text.split(whereSeparator: { "/:\\".contains($0) }).last.map(String.init) ?? ""
        let name = last.hasSuffix(".git") ? String(last.dropLast(4)) : last
        return name == "." || name == ".." ? "" : name
    }

    var cloneDestination: URL? {
        repoName.isEmpty ? nil : cloneParent.appending(path: repoName, directoryHint: .isDirectory)
    }

    var isCloning: Bool {
        if case .running = clone { return true }
        return false
    }

    /// A git path is set in the preferences (not auto-detected).
    var hasGitOverride: Bool {
        !(Preferences.defaults.string(forKey: PrefKey.gitPath.rawValue) ?? "").isEmpty
    }

    // MARK: Git check

    /// Checks git once per model (the view calls it on appear).
    func checkGitIfNeeded() {
        guard checkTask == nil else { return }
        checkGit()
    }

    /// Forgets the resolved git and looks again: after "Choose git…" or a Command Line Tools install.
    func checkGitAgain() {
        GitToolchain.reset()
        checkGit()
    }

    private func checkGit() {
        checkTask?.cancel()
        gitCheck = .checking
        checkTask = Task { [weak self] in
            let result: GitCheck
            do {
                _ = try await GitToolchain.resolve()
                result = .ok
            } catch {
                result = .problem(error as? GitExecutableError ?? .notFound)
            }
            guard !Task.isCancelled, let self else { return }
            gitCheck = result
            if result == .ok { installStarted = false }
        }
    }

    /// Asks macOS to install the Command Line Tools (`xcode-select --install` shows the system installer).
    func installCommandLineTools() {
        installStarted = true
        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/xcode-select")
            process.arguments = ["--install"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            process.waitUntilExit()
        }
    }

    /// Lets the user pick a git binary, saves it as the `gitPath` preference, and checks again.
    func chooseGit() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Use This Git"
        panel.message = "Choose a git executable (2.36 or later)"
        Task { @MainActor in
            guard await panel.begin() == .OK, let url = panel.url else { return }
            Preferences.defaults.set(url.path, forKey: PrefKey.gitPath.rawValue)
            self.checkGitAgain()
        }
    }

    /// Clears the `gitPath` preference: git is auto-detected again.
    func useAutomaticGit() {
        Preferences.defaults.set("", forKey: PrefKey.gitPath.rawValue)
        checkGitAgain()
    }

    // MARK: Open and init

    /// Picks a folder and opens it in this tab.
    func chooseFolderToOpen() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a repository"
        Task { @MainActor in
            guard await panel.begin() == .OK, let url = panel.url else { return }
            self.open(url)
        }
    }

    /// Opens a recent repository in this tab.
    func openRecent(_ url: URL) {
        open(url)
    }

    /// Picks (or creates) a folder, runs `git init` in it, and opens it in this tab.
    func chooseFolderToInit() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Create Repository"
        panel.message = "Choose the folder for the new repository"
        Task { @MainActor in
            guard await panel.begin() == .OK, let url = panel.url else { return }
            self.initError = nil
            do {
                try await Self.initRepository(at: url)
                self.open(url)
            } catch {
                self.initError = Self.message(for: error)
            }
        }
    }

    @concurrent
    private nonisolated static func initRepository(at url: URL) async throws {
        let toolchain = try await GitToolchain.resolve()
        let runner = GitRunner(executable: toolchain.executable.url)
        let writeEnv = GitInvocation.environment(profile: nil, base: await GitToolchain.writeBase(), access: .write)
        try await GitOperations.initRepository(at: url, runner: runner, env: writeEnv)
    }

    // MARK: Clone

    /// Picks the folder the clone goes into.
    func chooseCloneParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = cloneParent
        panel.prompt = "Choose"
        panel.message = "Choose where to put the clone"
        Task { @MainActor in
            guard await panel.begin() == .OK, let url = panel.url else { return }
            self.cloneParent = url
        }
    }

    /// Clones `cloneURL` into `cloneDestination`, streaming git's progress; opens the clone in this tab when done.
    func startClone() {
        guard !isCloning, let destination = cloneDestination else { return }
        let url = cloneURL.trimmingCharacters(in: .whitespacesAndNewlines)
        cloneToken &+= 1
        let token = cloneToken
        clone = .running(line: "Starting…", fraction: nil)
        // Called off the main actor for each of git's progress lines.
        let report: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor in self?.progress(line, token: token) }
        }
        cloneTask = Task { [weak self] in
            do {
                try await Self.clone(url, into: destination, progress: report)
                guard let self, token == cloneToken else { return }
                clone = .idle
                cloneURL = ""
                open(destination)
            } catch {
                guard let self, token == cloneToken else { return }
                clone = error is CancellationError || Task.isCancelled ? .idle : .failed(Self.message(for: error))
            }
        }
    }

    /// Stops the clone in flight (git removes its unfinished folder): the Cancel button.
    func cancelClone() {
        cloneTask?.cancel()
        cloneTask = nil
        cloneToken &+= 1
        if isCloning { clone = .idle }
    }

    /// Stops everything in flight: the tab closed.
    func cancel() {
        cancelClone()
        checkTask?.cancel()
    }

    private func progress(_ line: String, token: Int) {
        guard token == cloneToken, isCloning else { return }
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let percent = text.firstMatch(of: /(\d{1,3})%/).flatMap { Double($0.1) }
        clone = .running(line: text, fraction: percent.map { min($0, 100) / 100 })
    }

    @concurrent
    private nonisolated static func clone(
        _ url: String, into destination: URL, progress: @escaping @Sendable (String) -> Void
    ) async throws {
        let toolchain = try await GitToolchain.resolve()
        let runner = GitRunner(executable: toolchain.executable.url)
        let writeEnv = GitInvocation.environment(profile: nil, base: await GitToolchain.writeBase(), access: .write)
        try await GitOperations.clone(url: url, into: destination, runner: runner, env: writeEnv, progress: progress)
    }

    /// A short message for a failed clone or init: git's last error line.
    private nonisolated static func message(for error: Error) -> String {
        switch error {
        case let error as GitError:
            let lines = error.stderrTail.split(whereSeparator: \.isNewline).map(String.init)
            return lines.last { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") } ?? lines.last ?? "git failed."
        case GitOperationError.invalidRemoteURL:
            return "Enter a repository URL or path."
        case is GitExecutableError:
            return "No usable git was found."
        default:
            return error.localizedDescription
        }
    }
}

/// Sizes of the Welcome page.
private enum WelcomeMetrics {
    static let maxWidth: CGFloat = 560
}

/// The page of a tab with no repository.
struct WelcomeView: View {
    let model: WelcomeModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SectionCardMetrics.spacing) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Histq")
                        .font(.title2.weight(.semibold))
                    Text("Open, clone or create a git repository.")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, SettingsMetrics.cardPadding)
                .padding(.bottom, 8)
                if case .problem(let error) = model.gitCheck {
                    GitProblemCard(model: model, error: error)
                }
                OpenCard(model: model)
                CloneCard(model: model)
                InitCard(model: model)
                RecentCard(model: model)
            }
            .frame(maxWidth: WelcomeMetrics.maxWidth)
            .padding(SettingsMetrics.pagePadding)
            .padding(.top, SettingsMetrics.contentTopOffset)
            .frame(maxWidth: .infinity)
        }
        .labeledContentStyle(.settingsRow)
        .onAppear { model.checkGitIfNeeded() }
    }
}

/// Why git cannot run, and the ways out: install the Command Line Tools, choose a git, check again.
private struct GitProblemCard: View {
    let model: WelcomeModel
    let error: GitExecutableError

    var body: some View {
        SectionCard(title, systemImage: "exclamationmark.triangle.fill") {
            VStack(alignment: .leading, spacing: 8) {
                Text(explanation)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.installStarted {
                    Text("When the installer has finished, click Check Again.")
                        .font(.settingsCaption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    if offersInstall {
                        Button("Install Command Line Tools") { model.installCommandLineTools() }
                            .buttonStyle(RowTextButtonStyle(prominent: true))
                    }
                    Button("Choose git…") { model.chooseGit() }
                        .buttonStyle(RowTextButtonStyle())
                    if model.hasGitOverride {
                        Button("Detect Automatically") { model.useAutomaticGit() }
                            .buttonStyle(RowTextButtonStyle())
                    }
                    Button("Check Again") { model.checkGitAgain() }
                        .buttonStyle(RowTextButtonStyle())
                }
            }
        }
    }

    /// The Command Line Tools bring a recent git.
    private var offersInstall: Bool {
        switch error {
        case .commandLineToolsMissing, .tooOld, .notFound: true
        case .notExecutable, .unrecognizedVersion: false
        }
    }

    private var title: String {
        switch error {
        case .commandLineToolsMissing: "Git needs the Command Line Tools"
        case .tooOld(let version): "Git \(version) is too old"
        case .notFound: "Git was not found"
        case .notExecutable: "The chosen git cannot run"
        case .unrecognizedVersion: "Git did not report its version"
        }
    }

    private var explanation: String {
        switch error {
        case .commandLineToolsMissing:
            "macOS provides git with Apple's Command Line Tools, which are not installed. Install them, or choose "
                + "another git."
        case .tooOld:
            "Histq needs git \(GitExecutable.minimumVersion) or later. Install the Command Line Tools or a newer "
                + "git (for example with Homebrew), or choose one."
        case .notFound:
            "No git was found on your PATH. Install the Command Line Tools, or choose a git."
        case .notExecutable(let path):
            "\(path) is not an executable git. Choose another one, or let Histq detect git automatically."
        case .unrecognizedVersion(let output):
            "Running git --version printed \"\(output)\". Choose another git."
        }
    }
}

/// Opens a folder in this tab.
private struct OpenCard: View {
    let model: WelcomeModel

    var body: some View {
        SectionCard("Open", systemImage: "folder") {
            LabeledContent {
                Button("Open…") { model.chooseFolderToOpen() }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
            } label: {
                Text("Open a repository")
                Text("A folder with a git repository on this Mac.")
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Creates a repository with `git init` and opens it in this tab.
private struct InitCard: View {
    let model: WelcomeModel

    var body: some View {
        SectionCard("Init", systemImage: "plus.rectangle.on.folder") {
            LabeledContent {
                Button("Init…") { model.chooseFolderToInit() }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
                    .disabled(isGitMissing)
            } label: {
                Text("Create a repository")
                Text(model.initError ?? "Runs git init in a folder you choose.")
                    .font(.settingsCaption)
                    .foregroundStyle(model.initError == nil ? Color.secondary : Color.red)
            }
        }
    }

    private var isGitMissing: Bool {
        if case .problem = model.gitCheck { return true }
        return false
    }
}

/// The clone form: URL, destination, then the Clone button, or git's progress with Cancel while it runs.
private struct CloneCard: View {
    @Bindable var model: WelcomeModel

    var body: some View {
        SectionCard("Clone", systemImage: "arrow.down.circle") {
            LabeledContent {
                TextField("Repository URL", text: $model.cloneURL, prompt: Text(verbatim: "https://github.com/owner/repo.git"))
                    .textFieldStyle(.settings)
                    .labelsHidden()
                    .frame(maxWidth: 300)
                    .disabled(model.isCloning)
                    .onSubmit(model.startClone)
            } label: {
                Text("URL")
            }
            SettingsDivider()
            LabeledContent {
                Button("Choose…") { model.chooseCloneParent() }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
                    .disabled(model.isCloning)
            } label: {
                Text("Destination")
                Text(model.cloneDestination?.path ?? model.cloneParent.path)
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            SettingsDivider()
            status
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.clone {
        case .running(let line, let fraction):
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if let fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text(line)
                        .font(.settingsCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Button("Cancel") { model.cancelClone() }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
            }
        case .idle, .failed:
            HStack(spacing: 12) {
                if case .failed(let message) = model.clone {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.settingsCaption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button("Clone") { model.startClone() }
                    .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
                    .disabled(model.cloneDestination == nil || isGitMissing)
            }
        }
    }

    private var isGitMissing: Bool {
        if case .problem = model.gitCheck { return true }
        return false
    }
}

/// The repositories opened lately; a click opens one in this tab.
private struct RecentCard: View {
    let model: WelcomeModel
    private var recents: RecentRepos { RecentRepos.shared }

    var body: some View {
        SectionCard("Recent", systemImage: "clock", count: recents.urls.count, contentPadding: 6) {
            if recents.urls.isEmpty {
                Text("No recent repositories yet.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(recents.urls, id: \.path) { url in
                        Button { model.openRecent(url) } label: {
                            Label {
                                HStack(spacing: 8) {
                                    Text(url.lastPathComponent)
                                        .lineLimit(1)
                                    Text(url.deletingLastPathComponent().path)
                                        .font(.settingsCaption)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            } icon: {
                                Image(systemName: "folder")
                            }
                        }
                        .buttonStyle(SidebarItemStyle(selected: false))
                        .help(url.path)
                        .contextMenu {
                            Button("Remove from Recent") { recents.remove(url) }
                        }
                    }
                }
            }
        }
    }
}
