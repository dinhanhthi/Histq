// Settings › General: the default profile of new tabs, pulling and fetching, the external merge tool and the git
// executable. Each change is saved at once in `Preferences.defaults` (the default profile in the profile store).
import HistqCore
import SwiftUI

struct GeneralSettings: View {
    @AppStorage(PrefKey.pullMode.rawValue, store: Preferences.defaults) private var pullMode = "fastForward"
    @AppStorage(PrefKey.autoFetchMinutes.rawValue, store: Preferences.defaults) private var autoFetchMinutes = 0
    @AppStorage(PrefKey.pruneOnFetch.rawValue, store: Preferences.defaults) private var pruneOnFetch = false
    @AppStorage(PrefKey.mergeTool.rawValue, store: Preferences.defaults) private var mergeTool = ""
    @AppStorage(PrefKey.gitPath.rawValue, store: Preferences.defaults) private var gitPath = ""
    /// The git the app runs now, resolved off the main thread; `.loading` shows a skeleton in its row.
    @State private var git: Loadable<GitExecutable> = .idle
    /// "Custom" picked while no custom path is saved yet: the path row shows, git is still auto-detected.
    @State private var customPicked = false
    @State private var gitDraft = ""
    /// Why the last custom path was refused (not saved).
    @State private var gitPathError: String?
    /// Bumped to look for git again (after a change of the executable).
    @State private var gitCheck = 0

    private var library: ProfileLibrary { .shared }

    var body: some View {
        SettingsPageGate(section: .general, isLoaded: true) {
            SettingsGroup("New tabs") {
                defaultProfileRow
            }
            SettingsGroup("Pull and fetch") {
                LabeledContent {
                    Picker("Pull", selection: $pullMode) {
                        Text("Fast-forward if possible, else merge").tag("fastForward")
                        Text("Fast-forward only").tag("fastForwardOnly")
                        Text("Rebase").tag("rebase")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    Text("Pull")
                    SettingsHint("What the toolbar's Pull button does.")
                }
                SettingsDivider()
                LabeledContent {
                    CapsuleTabs(selection: $autoFetchMinutes, tabs: [0, 5, 10, 30],
                                title: { $0 == 0 ? Text("Off") : Text("\($0) min") }, compact: true)
                        .fixedSize()
                } label: {
                    Text("Fetch automatically")
                    SettingsHint("Fetches all remotes of each open tab at this interval. Off by default: a fetch runs "
                        + "the repo's own network settings (a credential helper, a local remote's upload-pack) "
                        + "without a click.")
                }
                SettingsDivider()
                SettingsSwitchRow(title: "Prune on fetch",
                                  hint: "Removes remote branches that no longer exist on their remote.",
                                  isOn: $pruneOnFetch)
            }
            SettingsGroup("Merge tool") {
                LabeledContent {
                    TextField("Merge tool", text: $mergeTool, prompt: Text("git's merge.tool"))
                        .textFieldStyle(.settings)
                        .frame(maxWidth: 220)
                        .labelsHidden()
                } label: {
                    Text("External merge tool")
                    SettingsHint("A git mergetool name (opendiff, vscode, kdiff3…) for \"Open in merge tool\". "
                        + "Empty: the tool your git config names.")
                }
            }
            gitGroup
        } skeleton: {
            EmptyView()
        }
        .task(id: gitCheck) { await checkGit() }
    }

    // MARK: Default profile

    @ViewBuilder
    private var defaultProfileRow: some View {
        LabeledContent {
            switch library.state {
            case .loaded(let store):
                Picker("Default profile", selection: Binding(
                    get: { store.defaultProfile?.id },
                    set: { library.setDefault($0) })
                ) {
                    Text("None").tag(UUID?.none)
                    ForEach(store.profiles) { profile in
                        Text(profile.name).tag(UUID?.some(profile.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            case .failed:
                Text("Unavailable").foregroundStyle(.secondary)
            case .idle, .loading:
                SkeletonLine(width: 120, height: 20)
            }
        } label: {
            Text("Default profile")
            SettingsHint("New tabs use their repo's last profile, else this one. None: git uses your own config.")
        }
    }

    // MARK: Git

    private var isCustom: Bool { !gitPath.isEmpty || customPicked }

    private var gitGroup: some View {
        SettingsGroup("Git") {
            LabeledContent {
                CapsuleTabs(selection: Binding(get: { isCustom }, set: setCustom), tabs: [false, true],
                            title: { $0 ? Text("Custom") : Text("Automatic") }, compact: true)
                    .fixedSize()
            } label: {
                Text("Git executable")
                SettingsHint("Automatic looks in /opt/homebrew/bin, /usr/local/bin and /usr/bin. Histq needs git "
                    + "\(GitExecutable.minimumVersion) or later.")
            }
            if isCustom {
                SettingsDivider()
                LabeledContent {
                    HStack(spacing: 8) {
                        TextField("Path", text: $gitDraft, prompt: Text("/path/to/git"))
                            .textFieldStyle(.settings)
                            .frame(maxWidth: 260)
                            .labelsHidden()
                            .onSubmit { useGit(at: gitDraft) }
                        Button("Choose…", action: chooseGit)
                            .buttonStyle(RowTextButtonStyle(formRow: true))
                    }
                } label: {
                    Text("Path")
                    if let gitPathError {
                        Text(gitPathError)
                            .font(.settingsCaption)
                            .foregroundStyle(.red)
                    } else {
                        SettingsHint("Press Return to use the path typed here.")
                    }
                }
            }
            SettingsDivider()
            LabeledContent {
                switch git {
                case .loaded(let executable):
                    Text("git \(executable.version.description)")
                        .monospacedDigit()
                case .failed(let message):
                    Text(message)
                        .font(.settingsCaption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.trailing)
                case .idle, .loading:
                    SkeletonLine(width: 80, height: 12)
                }
            } label: {
                Text("In use")
                if case .loaded(let executable) = git {
                    SettingsHint(executable.url.path(percentEncoded: false))
                } else {
                    SettingsHint(" ")
                }
            }
        }
        .onAppear { gitDraft = gitPath }
    }

    /// Looks for git through `GitToolchain` (off the main thread; at once when it is already resolved).
    private func checkGit() async {
        git = .loading
        do {
            git = .loaded(try await GitToolchain.resolve().executable)
        } catch is CancellationError {
            return
        } catch {
            git = .failed(Self.message(for: error))
        }
    }

    private func setCustom(_ custom: Bool) {
        gitPathError = nil
        customPicked = custom
        guard !custom, !gitPath.isEmpty else { return }
        // Back to automatic: forget the custom path, then the git resolved from it.
        gitPath = ""
        GitToolchain.reset()
        gitCheck &+= 1
    }

    private func chooseGit() {
        Task {
            guard let path = await ProfileLibrary.chooseFile(
                prompt: "Use This Git", message: "Choose a git executable (\(GitExecutable.minimumVersion) or later)",
                startingAt: "/usr/local/bin")
            else { return }
            gitDraft = path
            useGit(at: path)
        }
    }

    /// Checks the git at `text` off the main thread and saves it only when it runs and is new enough, so a typo never
    /// leaves every tab without git. Open tabs keep the git they started with; new tabs use the new one.
    private func useGit(at text: String) {
        guard let path = ProfileLibrary.absolutePath(text) else {
            gitPathError = "Enter an absolute path."
            return
        }
        gitPathError = nil
        Task {
            do {
                _ = try await Self.validate(path)
            } catch {
                gitPathError = Self.message(for: error)
                return
            }
            gitDraft = path
            gitPath = path
            GitToolchain.reset()
            gitCheck &+= 1
        }
    }

    @concurrent
    private nonisolated static func validate(_ path: String) async throws -> GitExecutable {
        try await GitExecutable.validate(at: URL(filePath: path))
    }

    private static func message(for error: Error) -> String {
        switch error as? GitExecutableError {
        case .commandLineToolsMissing: "Git needs the Command Line Tools."
        case .notFound: "Git was not found."
        case .notExecutable(let path): "Git at \(path) cannot run."
        case .tooOld(let version): "Git \(version) is too old; Histq needs \(GitExecutable.minimumVersion)."
        case .unrecognizedVersion: "That file did not report a git version."
        case nil: error.localizedDescription
        }
    }
}
