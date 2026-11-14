// Settings › Integrations, per profile: the profile's GitHub account. Connect it by signing in with GitHub (OAuth
// device flow), by pasting a personal access token, or by importing the GitHub CLI's token; each token is checked
// with `GET /user` before it is saved in the login Keychain (`GitHubTokens`), and the profile keeps only the host and
// the login. Disconnect deletes the Keychain item. Tokens are never logged, shown or kept in the page's state longer
// than the check.
import AppKit
import HistqCore
import SwiftUI

struct IntegrationsSettings: View {
    /// The profile the page edits, shared with the Profiles and SSH pages; nil (or a deleted one) shows the first.
    @Binding var profileID: UUID?
    let onShowProfiles: () -> Void
    /// The window's modal (`ModalHost`) asks before a disconnect.
    @Environment(WindowModel.self) private var model
    /// The host typed for the next connection; empty = github.com.
    @State private var hostDraft = ""
    @State private var pastedToken = ""
    /// Whether the Keychain holds the shown account's token, read off the main thread at each select of the page.
    @State private var tokenStored: Loadable<Bool> = .idle
    @State private var activity: Activity = .idle
    /// The connection in flight (a check, an import, a device flow's polling); cancelled by Cancel, a profile switch
    /// and the Settings modal closing.
    @State private var connectTask: Task<Void, Never>?
    @State private var copied = false

    private enum Activity: Equatable {
        case idle
        /// Waiting on GitHub or the GitHub CLI; the text says for what.
        case working(String)
        /// The device flow's code is shown; polling until the user approves it.
        case deviceCode(GitHubDeviceFlow.DeviceCode, host: String)
        case failed(String)
    }

    /// `HistqGitHubClientID` from Info.plist (build setting `HISTQ_GITHUB_CLIENT_ID`); empty until an OAuth App is
    /// registered, and then "Sign in with GitHub" is replaced by a hint.
    static let clientID: String = {
        let value = (Bundle.main.object(forInfoDictionaryKey: "HistqGitHubClientID") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // An unexpanded `$(…)` would mean the build setting is missing, not a client ID.
        return value.hasPrefix("$(") ? "" : value
    }()

    private var library: ProfileLibrary { .shared }

    var body: some View {
        SettingsPageGate(section: .integrations, isLoaded: !isLoading) {
            switch library.state {
            case .loaded(let store): loaded(store)
            case .failed(let message): ProfileStoreFailedCard(message: message)
            case .idle, .loading: EmptyView()
            }
        } skeleton: {
            SettingsSkeletonGroup(rows: 1)
            SettingsSkeletonGroup(rows: 4)
        }
        .onDisappear { cancelConnection() }
        #if DEBUG
        .onChange(of: isLoading, initial: true) { debugFakeLogin() }
        #endif
    }

    private var isLoading: Bool {
        switch library.state {
        case .idle, .loading: true
        case .loaded, .failed: false
        }
    }

    @ViewBuilder
    private func loaded(_ store: ProfileStore) -> some View {
        if let profile = store.profile(id: profileID ?? UUID()) ?? store.profiles.first {
            profileGroup(store, current: profile)
            accountGroup(profile)
                .task(id: TokenCheck(token: model.settingsToken, profileID: profile.id, host: profile.github?.host)) {
                    await checkToken(profile)
                }
                .onChange(of: profile.id) {
                    cancelConnection()
                    hostDraft = ""
                    pastedToken = ""
                }
        } else {
            SettingsGroup("GitHub account") {
                LabeledContent {
                    Button("Open Profiles", action: onShowProfiles)
                        .buttonStyle(RowTextButtonStyle(formRow: true))
                } label: {
                    Text("No profiles yet")
                    SettingsHint("A GitHub account belongs to a profile. Without one, git uses your own credential "
                        + "helper.")
                }
                SettingsDivider()
                signInRow(profile: nil, host: "github.com")
            }
        }
    }

    // MARK: Profile

    private func profileGroup(_ store: ProfileStore, current: Profile) -> some View {
        SettingsGroup("Profile") {
            LabeledContent {
                CapsuleMenuPicker(label: "Profile", selection: Binding(get: { current.id }, set: { profileID = $0 }),
                                  title: Text(current.name.isEmpty ? "Unnamed" : current.name)) {
                    ForEach(store.profiles) { profile in
                        Text(profile.name.isEmpty ? "Unnamed" : profile.name).tag(profile.id)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(ProfileColors.color(current.color))
                        .frame(width: 10, height: 10)
                    Text("Integrations of")
                }
                SettingsHint("Each profile has its own GitHub account, used over HTTPS by fetch, pull, push and clone "
                    + "in its tabs.")
            }
        }
    }

    // MARK: Account

    @ViewBuilder
    private func accountGroup(_ profile: Profile) -> some View {
        if let account = profile.github {
            connectedGroup(profile, account: account)
        } else {
            if case .deviceCode(let code, let host) = activity {
                deviceCodeGroup(code, host: host)
            }
            connectGroup(profile)
        }
    }

    private struct TokenCheck: Equatable {
        let token: Int
        let profileID: UUID
        let host: String?
    }

    /// Reads whether the Keychain has the account's token (fresh, not cached: an item deleted outside Histq shows).
    private func checkToken(_ profile: Profile) async {
        guard let host = profile.github?.host else {
            tokenStored = .idle
            return
        }
        tokenStored = .loading
        do {
            let token = try await GitHubTokens.read(profileID: profile.id, host: host, refresh: true)
            guard !Task.isCancelled else { return }
            tokenStored = .loaded(token != nil)
        } catch {
            guard !Task.isCancelled else { return }
            tokenStored = .failed(String(describing: error))
        }
    }

    private func connectedGroup(_ profile: Profile, account: Profile.GitHubAccount) -> some View {
        SettingsGroup("GitHub account") {
            LabeledContent {
                Button("Disconnect…") { confirmDisconnect(profile, account: account) }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(account.login)
                        .font(.body.weight(.semibold))
                }
                SettingsHint(account.host == "github.com" ? "Connected to github.com"
                    : "Connected to GitHub Enterprise at \(account.host)")
                tokenStatus
            }
            if case .failed(let message) = activity {
                failureText(message)
            }
        }
    }

    @ViewBuilder
    private var tokenStatus: some View {
        switch tokenStored {
        case .loaded(true):
            SettingsHint("The token is in your login Keychain.")
        case .loaded(false):
            Text("The token is missing from the Keychain. Disconnect, then connect again.")
                .font(.settingsCaption)
                .foregroundStyle(.red)
        case .failed(let message):
            Text("The Keychain could not be read: \(message)")
                .font(.settingsCaption)
                .foregroundStyle(.red)
        case .idle, .loading:
            SkeletonLine(width: 200, height: 11)
        }
    }

    private func confirmDisconnect(_ profile: Profile, account: Profile.GitHubAccount) {
        model.presentModal(.confirmation(ModalConfirmation(
            title: "Disconnect \(account.login)?",
            message: "Deletes the profile's token from your login Keychain. Git then uses your own credential helper "
                + "for \(account.host). The token stays valid on GitHub until you revoke it there.",
            button: "Disconnect", isDestructive: true) { disconnect(profile.id, host: account.host) }))
    }

    private func disconnect(_ id: UUID, host: String) {
        cancelConnection()
        Task {
            do {
                try await GitHubTokens.delete(profileID: id, host: host)
                library.modify(id) { $0.github = nil }
                tokenStored = .idle
            } catch {
                activity = .failed("The token could not be deleted: \(error)")
            }
        }
    }

    // MARK: Connect

    private var isBusy: Bool {
        switch activity {
        case .working, .deviceCode: true
        case .idle, .failed: false
        }
    }

    /// The host typed in the field (github.com when empty), lowercased, or nil when it is not a host name.
    private var draftHost: String? {
        let text = hostDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return GitHubClient.validatedHost(text.isEmpty ? "github.com" : text)
    }

    private func connectGroup(_ profile: Profile) -> some View {
        SettingsGroup("GitHub account", description: "Fetch, pull, push and clone over HTTPS use the token for this "
            + "host; nothing else gets it. It is checked with GitHub, then kept in your login Keychain.") {
            LabeledContent {
                TextField("Host", text: $hostDraft, prompt: Text(verbatim: "github.com"))
                    .textFieldStyle(.settings)
                    .frame(maxWidth: 240)
                    .labelsHidden()
                    .disabled(isBusy)
            } label: {
                Text("Host")
                if draftHost == nil {
                    Text("Enter a host name such as github.example.com, without https://.")
                        .font(.settingsCaption)
                        .foregroundStyle(.red)
                } else {
                    SettingsHint("github.com, or your GitHub Enterprise Server host.")
                }
            }
            SettingsDivider()
            signInRow(profile: profile, host: draftHost)
            SettingsDivider()
            LabeledContent {
                HStack(spacing: 8) {
                    SecureField("Token", text: $pastedToken, prompt: Text(verbatim: "ghp_…"))
                        .textFieldStyle(.settings)
                        .frame(maxWidth: 240)
                        .labelsHidden()
                        .onSubmit { savePasted(profile) }
                    Button("Save") { savePasted(profile) }
                        .buttonStyle(RowTextButtonStyle(formRow: true))
                        .disabled(draftHost == nil || pastedToken.trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty)
                }
                .disabled(isBusy)
            } label: {
                Text("Personal access token")
                SettingsHint("Classic: the repo scope (and workflow to push workflow files). Fine-grained: Contents "
                    + "read and write.")
            }
            SettingsDivider()
            LabeledContent {
                Button("Import") { importFromCLI(profile) }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
                    .disabled(draftHost == nil || isBusy)
            } label: {
                Text("GitHub CLI")
                SettingsHint("Uses the token of gh auth login for this host (gh auth token --hostname "
                    + "\(draftHost ?? "<host>")).")
            }
            activityLine
        }
    }

    /// "Sign in with GitHub": the device flow's button, or the hint when this build has no OAuth App client ID.
    private func signInRow(profile: Profile?, host: String?) -> some View {
        LabeledContent {
            if !Self.clientID.isEmpty {
                Button("Sign In…") {
                    if let profile, let host { startDeviceFlow(profile, host: host) }
                }
                .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
                .disabled(profile == nil || host == nil || isBusy)
            }
        } label: {
            Text("Sign in with GitHub")
            if Self.clientID.isEmpty {
                SettingsHint("Register a GitHub OAuth App and set HISTQ_GITHUB_CLIENT_ID")
            } else {
                SettingsHint("Opens GitHub in your browser, where you enter a one-time code.")
            }
        }
    }

    @ViewBuilder
    private var activityLine: some View {
        switch activity {
        case .working(let text):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(text)
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Cancel", action: cancelConnection)
                    .buttonStyle(RowTextButtonStyle(formRow: true))
            }
            .padding(.top, 8)
        case .failed(let message):
            failureText(message)
        case .idle, .deviceCode:
            EmptyView()
        }
    }

    private func failureText(_ message: String) -> some View {
        Text(message)
            .font(.settingsCaption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
    }

    /// The device flow's code, big, with Copy and Open GitHub, while the app polls for the approval.
    private func deviceCodeGroup(_ code: GitHubDeviceFlow.DeviceCode, host: String) -> some View {
        SettingsGroup("Sign in with GitHub", description: "Enter this code on GitHub. Histq connects as soon as you "
            + "approve it.") {
            HStack(spacing: 12) {
                Text(code.userCode)
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                Spacer(minLength: 12)
                Button(copied ? "Copied" : "Copy Code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code.userCode, forType: .string)
                    copied = true
                }
                .buttonStyle(RowTextButtonStyle(formRow: true))
                Button("Open GitHub") { NSWorkspace.shared.open(Self.verificationURL(code, host: host)) }
                    .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
            }
            SettingsDivider()
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for the approval at \(Self.verificationURL(code, host: host).absoluteString)…")
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Cancel", action: cancelConnection)
                    .buttonStyle(RowTextButtonStyle(formRow: true))
            }
        }
    }

    /// The flow's verification URL when it is https on the flow's host and port (`host` as validated, with its port if
    /// it has one) without userinfo, else `https://<host>/login/device`: the URL comes from the server, and the browser
    /// should only ever open the host the user typed.
    private static func verificationURL(_ code: GitHubDeviceFlow.DeviceCode, host: String) -> URL {
        let hostParts = host.split(separator: ":", maxSplits: 1).map(String.init)
        if let url = URL(string: code.verificationURI), url.scheme?.lowercased() == "https",
           url.user == nil, url.password == nil,
           url.host?.lowercased() == hostParts.first, url.port == hostParts.dropFirst().first.flatMap({ Int($0) }) {
            return url
        }
        return URL(string: "https://\(host)/login/device") ?? URL(string: "https://github.com/login/device")!
    }

    private func cancelConnection() {
        connectTask?.cancel()
        connectTask = nil
        if isBusy { activity = .idle }
    }

    private func savePasted(_ profile: Profile) {
        let token = pastedToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, let host = draftHost, !isBusy else { return }
        connect(profile.id, host: host, status: "Checking the token with GitHub…") { token }
    }

    private func importFromCLI(_ profile: Profile) {
        guard let host = draftHost, !isBusy else { return }
        connect(profile.id, host: host, status: "Reading the GitHub CLI's token…") {
            try await Self.cliToken(host: host)
        }
    }

    private func startDeviceFlow(_ profile: Profile, host: String) {
        guard !isBusy else { return }
        connectTask?.cancel()
        copied = false
        activity = .working("Asking GitHub for a code…")
        let id = profile.id
        connectTask = Task {
            do {
                let flow = try GitHubDeviceFlow(host: host, clientID: Self.clientID)
                let code = try await flow.start()
                try Task.checkCancellation()
                activity = .deviceCode(code, host: host)
                let token = try await flow.waitForToken(code)
                try Task.checkCancellation()
                activity = .working("Checking the token with GitHub…")
                try await finishConnect(id, host: host, token: token)
            } catch {
                fail(error)
            }
        }
    }

    /// The paste and import paths: `source` gives the token, then it is checked and saved.
    private func connect(
        _ id: UUID, host: String, status: String, source: @escaping @Sendable () async throws -> String
    ) {
        connectTask?.cancel()
        activity = .working(status)
        connectTask = Task {
            do {
                let token = try await source()
                try Task.checkCancellation()
                activity = .working("Checking the token with GitHub…")
                try await finishConnect(id, host: host, token: token)
            } catch {
                fail(error)
            }
        }
    }

    /// Checks `token` with `GET /user`, saves it in the Keychain, then sets the profile's account (host and login).
    private func finishConnect(_ id: UUID, host: String, token: String) async throws {
        let login = try await Self.login(token: token, host: host)
        try Task.checkCancellation()
        try await GitHubTokens.save(token, profileID: id, host: host)
        library.modify(id) { $0.github = Profile.GitHubAccount(host: host, login: login) }
        pastedToken = ""
        activity = .idle
        connectTask = nil
    }

    private func fail(_ error: Error) {
        // As the header says, a token stays in the page's state no longer than its check, a failed one included.
        pastedToken = ""
        if error is CancellationError || Task.isCancelled { return }
        activity = .failed(Self.message(for: error))
        connectTask = nil
    }

    // MARK: Off the main thread

    @concurrent
    private nonisolated static func login(token: String, host: String) async throws -> String {
        try await GitHubClient(host: host, token: token).currentUser().login
    }

    enum CLIError: Error, CustomStringConvertible {
        case notFound
        case failed(String)
        case noToken

        var description: String {
            switch self {
            case .notFound: "The GitHub CLI (gh) was not found. Install it with Homebrew, then run gh auth login."
            case .failed(let detail): "gh auth token failed" + (detail.isEmpty ? "." : ": \(detail)")
            case .noToken: "gh printed no usable token."
            }
        }
    }

    /// `gh auth token --hostname <host>`, run directly (no shell) from the fixed PATH, then the login shell's. Its
    /// stdout is the token: only returned, never logged or put in an error (errors carry gh's stderr only).
    @concurrent
    private nonisolated static func cliToken(host: String) async throws -> String {
        let base = await GitToolchain.writeBase()
        let folders = (GitExecutable.fixedPath + ":" + (base["PATH"] ?? "")).split(separator: ":")
        guard let gh = folders.lazy.filter({ $0.hasPrefix("/") })
            .map({ URL(filePath: String($0), directoryHint: .isDirectory).appending(path: "gh") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
        else { throw CLIError.notFound }
        var env = base
        env["GH_PROMPT_DISABLED"] = "1"
        env["NO_COLOR"] = "1"
        // gh may wait on its own Keychain prompt; a minute, then it is stopped.
        let result = try await GitRunner(executable: gh).run(
            ["auth", "token", "--hostname", host], cwd: URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory),
            env: env, timeout: .seconds(60), allowedExitCodes: Set(0...255))
        guard result.exitCode == 0 else {
            throw CLIError.failed(result.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let token = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard GitHubClient.isUsableToken(token) else { throw CLIError.noToken }
        return token
    }

    private static func message(for error: Error) -> String {
        switch error {
        case GitHubError.unauthorized: "GitHub refused the token: it is wrong, expired or revoked."
        case GitHubError.invalidToken: "That is not a token: it has spaces or other characters a token never has."
        case GitError.timeout: "gh did not answer within a minute."
        case let error as GitHubError: String(describing: error)
        case let error as GitHubDeviceFlow.DeviceFlowError: String(describing: error)
        case let error as CLIError: error.description
        case let error as KeychainError: "The token could not be saved: \(error)"
        default: error.localizedDescription
        }
    }

    #if DEBUG
    /// DEBUG `-HistqGitHubFakeLogin <login>` with `-HistqKeychain memory` in state-dir mode: once the profiles are read,
    /// connects the shown profile (adding a "QA" profile when there is none) to github.com as `<login>` with a fake
    /// token in the in-memory Keychain, without asking GitHub. For QA shots of the connected state.
    private func debugFakeLogin() {
        guard !isLoading, !Self.debugFakeLoginDone, let login = AppState.launchFlag("-HistqGitHubFakeLogin"),
              AppState.isStateDirMode, KeychainStore.shared.isInMemory, let store = library.store
        else { return }
        Self.debugFakeLoginDone = true
        guard let id = store.profile(id: profileID ?? UUID())?.id ?? store.profiles.first?.id
            ?? library.addProfile(identity: Profile.Identity(name: "QA", email: "qa@histq.invalid"))
        else { return }
        Task {
            try? await GitHubTokens.save("histq_qa_fake_token", profileID: id, host: "github.com")
            library.modify(id) { $0.github = Profile.GitHubAccount(host: "github.com", login: login) }
        }
    }

    private static var debugFakeLoginDone = false
    #endif
}
