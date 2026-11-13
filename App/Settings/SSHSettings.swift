// Settings › SSH, per profile: ssh-agent or one key file, the public key to copy, a new key, and the BatchMode note.
// Histq runs ssh with `BatchMode=yes`, so it never asks for a passphrase: a passphrase key must be in ssh-agent.
import AppKit
import HistqCore
import SwiftUI

struct SSHSettings: View {
    /// The profile the page edits, shared with the Profiles page; nil (or a deleted one) shows the first.
    @Binding var profileID: UUID?
    let onShowProfiles: () -> Void
    /// Opens the Generate Key modal for a profile.
    let onGenerate: (UUID) -> Void
    @Environment(WindowModel.self) private var model
    /// What is on disk at the profile's key path, read off the main thread at each select of the page and each path.
    @State private var keyFiles: Loadable<ProfileLibrary.KeyFiles> = .idle
    /// "Use ssh-agent" turned off while no key path is saved yet: the path row shows, the agent is still used.
    @State private var agentOffPicked = false
    @State private var copied = false

    private var library: ProfileLibrary { .shared }

    var body: some View {
        SettingsPageGate(section: .ssh, isLoaded: !isLoading) {
            switch library.state {
            case .loaded(let store): loaded(store)
            case .failed(let message): ProfileStoreFailedCard(message: message)
            case .idle, .loading: EmptyView()
            }
        } skeleton: {
            SettingsSkeletonGroup(rows: 1)
            SettingsSkeletonGroup(rows: 3)
            SettingsSkeletonGroup(rows: 1)
        }
        #if DEBUG
        .onChange(of: isLoading, initial: true) { debugGenerateKey() }
        #endif
    }

    #if DEBUG
    /// DEBUG `-HistqGenerateKey`: once the profiles are read, opens Generate Key for the shown profile as its button
    /// does, adding a "QA" profile first when there is none (state dir only). For QA shots.
    private func debugGenerateKey() {
        guard !isLoading, !Self.debugGenerateKeyDone, ProcessInfo.processInfo.arguments.contains("-HistqGenerateKey"),
              let store = library.store
        else { return }
        Self.debugGenerateKeyDone = true
        let id = store.profile(id: profileID ?? UUID())?.id ?? store.profiles.first?.id
            ?? library.addProfile(identity: Profile.Identity(name: "QA", email: "qa@histq.invalid"))
        if let id { onGenerate(id) }
    }

    private static var debugGenerateKeyDone = false
    #endif

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
            keyGroup(profile)
            SettingsGroup("New key") {
                LabeledContent {
                    Button("Generate Key…") { onGenerate(profile.id) }
                        .buttonStyle(RowTextButtonStyle(formRow: true))
                } label: {
                    Text("Generate an ed25519 key")
                    SettingsHint("Creates a key pair without a passphrase and uses it for this profile. It never "
                        + "replaces an existing file.")
                }
            }
            batchModeNote
        } else {
            SettingsGroup("SSH") {
                LabeledContent {
                    Button("Open Profiles", action: onShowProfiles)
                        .buttonStyle(RowTextButtonStyle(formRow: true))
                } label: {
                    Text("No profiles yet")
                    SettingsHint("SSH keys are set per profile. Without a profile, ssh uses ssh-agent and "
                        + "~/.ssh/config.")
                }
            }
            batchModeNote
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
                    Text("SSH settings of")
                }
                SettingsHint("Each profile has its own key, used by fetch, pull and push in its tabs.")
            }
        }
    }

    // MARK: Key

    private func keyGroup(_ profile: Profile) -> some View {
        let path: String? = if case .keyFile(let path) = profile.ssh { path } else { nil }
        let usesAgent = path == nil && !agentOffPicked
        return SettingsGroup("Key") {
            SettingsSwitchRow(
                title: "Use ssh-agent",
                hint: "On: the keys ssh-agent and ~/.ssh/config offer. Off: only the key file below.",
                isOn: Binding(get: { usesAgent }, set: { setAgent($0, profile: profile) }))
            if !usesAgent {
                SettingsDivider()
                KeyPathRow(title: "Private key", hint: "Its public key is the same path with .pub.",
                           path: path ?? "") { newPath in
                    library.modify(profile.id) { $0.ssh = newPath.isEmpty ? .agent : .keyFile(path: newPath) }
                }
                // A new row per profile: a draft typed for one profile is dropped, never saved into the next.
                .id(profile.id)
            }
            if let path {
                SettingsDivider()
                publicKeyRow(path: path)
            }
        }
        .task(id: KeyCheck(token: model.settingsToken, path: path)) { await readKeyFiles(path) }
        .onChange(of: profile.id) { agentOffPicked = false }
    }

    private struct KeyCheck: Equatable {
        let token: Int
        let path: String?
    }

    private func setAgent(_ on: Bool, profile: Profile) {
        agentOffPicked = !on
        if on { library.modify(profile.id) { $0.ssh = .agent } }
    }

    private func readKeyFiles(_ path: String?) async {
        copied = false
        guard let path else {
            keyFiles = .idle
            return
        }
        keyFiles = .loading
        let files = await ProfileLibrary.keyFiles(at: path)
        guard !Task.isCancelled else { return }
        keyFiles = .loaded(files)
    }

    private func publicKeyRow(path: String) -> some View {
        LabeledContent {
            switch keyFiles {
            case .loaded(let files):
                Button(copied ? "Copied" : "Copy Public Key") {
                    guard let key = files.publicKey else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key, forType: .string)
                    copied = true
                }
                .buttonStyle(RowTextButtonStyle(formRow: true))
                .disabled(files.publicKey == nil)
            default:
                SkeletonLine(width: 120, height: 20)
            }
        } label: {
            Text("Public key")
            switch keyFiles {
            case .loaded(let files):
                if let key = files.publicKey {
                    Text(key)
                        .font(.settingsCaption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    Text(files.privateExists ? "No \(ProfileLibrary.abbreviated(path)).pub next to the key."
                         : "No key at \(ProfileLibrary.abbreviated(path)).")
                        .font(.settingsCaption)
                        .foregroundStyle(.red)
                }
            default:
                SkeletonLine(width: 220, height: 11)
            }
        }
    }

    // MARK: Note

    private var batchModeNote: some View {
        SettingsGroup("Passphrases") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Histq runs ssh with BatchMode=yes and never asks for a passphrase. Keep a passphrase key in "
                    + "ssh-agent and the login Keychain once, from Terminal:")
                    .fixedSize(horizontal: false, vertical: true)
                Text("ssh-add --apple-use-keychain ~/.ssh/<key>")
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The Generate Key modal: the new key's path and comment, Generate, then the public key to copy and the passphrase
/// hint. The key is unencrypted (a passphrase given to ssh-keygen would show in its arguments); the hint says how to
/// add one.
struct GenerateKeyModal: View {
    let profileID: UUID
    let onClose: () -> Void
    @State private var path = ""
    @State private var comment = ""
    @State private var state: GenerateState = .editing
    @State private var copied = false
    @FocusState private var pathFocused: Bool
    /// The cards' height, the scroll view's cap; first about the form's.
    @State private var cardsHeight: CGFloat = 112

    private enum GenerateState {
        case editing
        case running
        case failed(String)
        case done(path: String, publicKey: String)
    }

    private var library: ProfileLibrary { .shared }

    var body: some View {
        ModalCard(title: "Generate SSH Key", subtitle: "An ed25519 key pair for this profile, written next to your "
                  + "other keys.", systemImage: "key", width: 560) {
            // As tall as the cards, scrolling only when the window is shorter (the public key and its hint).
            ScrollView {
                cards
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { cardsHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: cardsHeight)
        } actions: {
            if case .done = state {
                Button("Done", action: onClose)
                    .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
                    .keyboardShortcut(.cancelAction)
            } else {
                Button("Cancel", action: onClose)
                    .buttonStyle(RowTextButtonStyle(formRow: true))
                    .keyboardShortcut(.cancelAction)
                Button("Generate", action: generate)
                    .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
                    .disabled(isRunning || path.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            fillDefaults()
            // The card is installed on this turn; the path field takes the focus on the next one.
            DispatchQueue.main.async { pathFocused = true }
        }
    }

    /// The form, then the new public key once generated: cards of the modal's container.
    private var cards: some View {
        VStack(alignment: .leading, spacing: PanelContainerMetrics.padding) {
            form
            if case .done(let keyPath, let publicKey) = state {
                result(path: keyPath, publicKey: publicKey)
            }
        }
        .labeledContentStyle(.settingsRow)
    }

    private var isRunning: Bool {
        if case .running = state { true } else { false }
    }

    private var form: some View {
        SettingsGroup(nil) {
            LabeledContent {
                TextField("Path", text: $path, prompt: Text("~/.ssh/id_ed25519_work"))
                    .textFieldStyle(.settings)
                    .focused($pathFocused)
                    .frame(maxWidth: 280)
                    .labelsHidden()
            } label: {
                Text("Private key")
                SettingsHint("The public key is written next to it, with .pub.")
            }
            SettingsDivider()
            LabeledContent {
                TextField("Comment", text: $comment, prompt: Text("jane@example.com"))
                    .textFieldStyle(.settings)
                    .frame(maxWidth: 280)
                    .labelsHidden()
            } label: {
                Text("Comment")
                SettingsHint("Ends the public key line; usually your email.")
            }
            switch state {
            case .failed(let message):
                Text(message)
                    .font(.settingsCaption)
                    .foregroundStyle(.red)
                    .padding(.top, 8)
            case .running:
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 8)
            case .editing, .done:
                EmptyView()
            }
        }
        .disabled(isRunning || isDone)
    }

    private var isDone: Bool {
        if case .done = state { true } else { false }
    }

    private func result(path: String, publicKey: String) -> some View {
        SettingsGroup("Public key", description: "The profile now uses this key. Add the public key to your Git "
            + "host (on GitHub: Settings › SSH and GPG keys).") {
            Text(publicKey)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            SettingsDivider()
            LabeledContent {
                Button(copied ? "Copied" : "Copy Public Key") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(publicKey, forType: .string)
                    copied = true
                }
                .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
            } label: {
                Text("Passphrase")
                SettingsHint("The key has none. To add one, then keep it in ssh-agent and the Keychain, run in "
                    + "Terminal:")
                Text("ssh-keygen -p -f \(ProfileLibrary.abbreviated(path))\nssh-add --apple-use-keychain "
                    + ProfileLibrary.abbreviated(path))
                    .font(.settingsCaption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// `~/.ssh/id_ed25519_<profile name>`, and the profile's email as the comment.
    private func fillDefaults() {
        guard path.isEmpty, let profile = library.store?.profile(id: profileID) else { return }
        let slug = profile.name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        let suffix = String(slug).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        path = "~/.ssh/id_ed25519" + (suffix.isEmpty ? "" : "_" + suffix)
        comment = profile.identity.email
    }

    /// Generates off the main thread with an expanded absolute path (ssh-keygen would take `~` literally), then sets
    /// the profile's SSH key to it.
    private func generate() {
        guard let absolute = ProfileLibrary.absolutePath(path) else {
            state = .failed("Enter a full path (starting with / or ~).")
            return
        }
        state = .running
        let comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let publicKey = try await Self.generate(at: absolute, comment: comment)
                library.modify(profileID) { $0.ssh = .keyFile(path: absolute) }
                state = .done(path: absolute, publicKey: publicKey)
            } catch {
                state = .failed(Self.message(for: error))
            }
        }
    }

    @concurrent
    private nonisolated static func generate(at path: String, comment: String) async throws -> String {
        // The fixed PATH has /usr/bin/ssh-keygen; no need to wait for the login shell.
        try await SSHKeyGenerator(environment: GitInvocation.baseEnvironment())
            .generate(privateKey: URL(filePath: path), comment: comment)
    }

    private static func message(for error: Error) -> String {
        switch error as? SSHKeyGenerator.GenerateError {
        case .invalidComment: "The comment cannot start with - or hold a line break."
        case .invalidPath: "That path cannot be used: it must be a file path whose name does not start with -."
        case .keyExists(let path): "\(ProfileLibrary.abbreviated(path)) already exists. Histq never replaces a key."
        case .toolNotFound(let tool): "\(tool) was not found."
        case .failed(let detail): "ssh-keygen failed: \(detail)"
        case nil: error.localizedDescription
        }
    }
}
