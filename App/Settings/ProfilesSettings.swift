// Settings › Profiles: the profile list (add, duplicate, delete, the default), then the selected profile's name and
// color, commit identity and signing, each in its own card. Every change is saved at once in the profile store.
import HistqCore
import SwiftUI

struct ProfilesSettings: View {
    /// The profile the cards edit; nil (or a deleted one) shows the first.
    @Binding var profileID: UUID?
    @State private var pendingDelete: Profile?
    @State private var importing = false
    @State private var importError: String?

    private var library: ProfileLibrary { .shared }

    var body: some View {
        SettingsPageGate(section: .profiles, isLoaded: !isLoading) {
            switch library.state {
            case .loaded(let store): loaded(store)
            case .failed(let message): ProfileStoreFailedCard(message: message)
            case .idle, .loading: EmptyView()
            }
        } skeleton: {
            SettingsSkeletonGroup(rows: 3)
            SettingsSkeletonGroup(rows: 2)
            SettingsSkeletonGroup(rows: 3)
        }
        .confirmationDialog(
            "Delete the profile \(pendingDelete?.name ?? "")?", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible, presenting: pendingDelete
        ) { profile in
            Button("Delete Profile", role: .destructive) { library.delete(profile.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Repos that used it switch to the default profile. Its SSH key files stay on disk.")
        }
    }

    private var isLoading: Bool {
        switch library.state {
        case .idle, .loading: true
        case .loaded, .failed: false
        }
    }

    @ViewBuilder
    private func loaded(_ store: ProfileStore) -> some View {
        let current = store.profile(id: profileID ?? UUID()) ?? store.profiles.first
        listGroup(store, current: current)
        if let current {
            profileGroup(current, isDefault: store.defaultProfileID == current.id)
            identityGroup(current)
            signingGroup(current)
        }
        if let saveError = library.saveError {
            Text(saveError)
                .font(.settingsCaption)
                .foregroundStyle(.red)
                .padding(.horizontal, SettingsMetrics.cardPadding)
        }
    }

    // MARK: List

    private func listGroup(_ store: ProfileStore, current: Profile?) -> some View {
        SettingsGroup("Profiles", description: "Who Histq commits as in a tab, how it signs and which SSH key it uses. "
            + "Each repo remembers its last profile. Without a profile, git uses your own config.") {
            if store.profiles.isEmpty {
                Text("No profiles yet.")
                    .foregroundStyle(.secondary)
                    .frame(minHeight: SidebarItemStyle.height)
            } else {
                VStack(alignment: .leading, spacing: SidebarItemStyle.spacing) {
                    ForEach(store.profiles) { profile in
                        ProfileRow(profile: profile, isDefault: store.defaultProfileID == profile.id,
                                   selected: profile.id == current?.id) {
                            profileID = profile.id
                        }
                    }
                }
            }
            SettingsDivider()
            HStack(spacing: 8) {
                Button("Add") { select(library.addProfile()) }
                Button("Duplicate") { current.map { select(library.duplicate($0.id)) } }
                    .disabled(current == nil)
                Button("Delete…") { pendingDelete = current }
                    .disabled(current == nil)
                Spacer(minLength: 12)
                Button(importing ? "Reading…" : "Add from Global Git Config") { importGlobal(into: nil) }
                    .disabled(importing)
            }
            .buttonStyle(RowTextButtonStyle(formRow: true))
            if let importError, current == nil {
                Text(importError)
                    .font(.settingsCaption)
                    .foregroundStyle(.red)
                    .padding(.top, 6)
            }
        }
    }

    private func select(_ id: UUID?) {
        if let id { profileID = id }
    }

    // MARK: Profile

    private func profileGroup(_ profile: Profile, isDefault: Bool) -> some View {
        SettingsGroup("Profile") {
            LabeledContent {
                TextField("Name", text: binding(profile, \.name), prompt: Text("Work"))
                    .textFieldStyle(.settings)
                    .frame(maxWidth: 220)
                    .labelsHidden()
            } label: {
                Text("Name")
                SettingsHint("Shown in the tab's profile menu.")
            }
            SettingsDivider()
            LabeledContent {
                HStack(spacing: 6) {
                    ForEach(ProfileColors.hexes, id: \.self) { hex in
                        ColorSwatch(hex: hex, selected: hex == profile.color) {
                            library.modify(profile.id) { $0.color = hex }
                        }
                    }
                }
            } label: {
                Text("Color")
                SettingsHint("Marks the tabs that use this profile.")
            }
            SettingsDivider()
            SettingsSwitchRow(
                title: "Default profile",
                hint: "New tabs whose repo has no remembered profile use it.",
                isOn: Binding(get: { isDefault }, set: { library.setDefault($0 ? profile.id : nil) }))
        }
    }

    // MARK: Identity

    private func identityGroup(_ profile: Profile) -> some View {
        SettingsGroup("Commit identity") {
            LabeledContent {
                TextField("Name", text: binding(profile, \.identity.name), prompt: Text("Jane Doe"))
                    .textFieldStyle(.settings)
                    .frame(maxWidth: 220)
                    .labelsHidden()
            } label: {
                Text("Name")
                SettingsHint("user.name of the commits made in its tabs.")
            }
            SettingsDivider()
            LabeledContent {
                TextField("Email", text: binding(profile, \.identity.email), prompt: Text("jane@example.com"))
                    .textFieldStyle(.settings)
                    .frame(maxWidth: 220)
                    .labelsHidden()
            } label: {
                Text("Email")
                SettingsHint("user.email; also the comment of a key generated for it.")
            }
            SettingsDivider()
            LabeledContent {
                Button(importing ? "Reading…" : "Import") { importGlobal(into: profile.id) }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
                    .disabled(importing)
            } label: {
                Text("Global git config")
                if let importError {
                    Text(importError)
                        .font(.settingsCaption)
                        .foregroundStyle(.red)
                } else {
                    SettingsHint("Copies user.name and user.email from git config --global.")
                }
            }
        }
    }

    /// Reads the global identity off the main thread, then fills profile `id` with it, or adds a profile from it when
    /// `id` is nil. An unset key leaves the field as it was.
    private func importGlobal(into id: UUID?) {
        importing = true
        importError = nil
        Task {
            defer { importing = false }
            let identity: Profile.Identity
            do {
                identity = try await ProfileLibrary.globalIdentity()
            } catch {
                importError = "git config could not be read: \(error.localizedDescription)"
                return
            }
            guard !identity.name.isEmpty || !identity.email.isEmpty else {
                importError = "Your global git config sets no user.name or user.email."
                return
            }
            guard let id else {
                select(library.addProfile(identity: identity))
                return
            }
            library.modify(id) { profile in
                if !identity.name.isEmpty { profile.identity.name = identity.name }
                if !identity.email.isEmpty { profile.identity.email = identity.email }
            }
        }
    }

    // MARK: Signing

    private enum SigningMethod: Hashable {
        case none, gpg, ssh
    }

    private func signingGroup(_ profile: Profile) -> some View {
        let method: SigningMethod = switch profile.signing {
        case .none: .none
        case .gpg: .gpg
        case .ssh: .ssh
        }
        return SettingsGroup("Commit signing") {
            LabeledContent {
                CapsuleTabs(selection: Binding(get: { method }, set: { setSigning($0, of: profile) }),
                            tabs: [SigningMethod.none, .gpg, .ssh],
                            title: { Text(Self.title(of: $0)) }, compact: true)
                    .fixedSize()
            } label: {
                Text("Sign with")
                SettingsHint("Passed to git for this profile's tabs only; your git config is not changed.")
            }
            switch profile.signing {
            case .none:
                EmptyView()
            case .gpg(let keyID):
                SettingsDivider()
                LabeledContent {
                    TextField("Key ID", text: Binding(
                        get: { keyID },
                        set: { value in library.modify(profile.id) { $0.signing = .gpg(keyID: value) } }),
                              prompt: Text("Key ID or fingerprint"))
                        .textFieldStyle(.settings)
                        .frame(maxWidth: 220)
                        .labelsHidden()
                } label: {
                    Text("GPG key")
                    if profile.signing.isUsable {
                        SettingsHint("Signing needs gpg and pinentry-mac; git never asks for the passphrase here.")
                    } else {
                        SigningKeyMissing()
                    }
                }
            case .ssh(let keyPath):
                SettingsDivider()
                KeyPathRow(title: "SSH signing key", hint: "A public key (.pub), or a private key ssh-agent holds.",
                           path: keyPath, emptyError: SigningKeyMissing.message) { path in
                    library.modify(profile.id) { $0.signing = .ssh(keyPath: path) }
                }
                // A new row per profile: a draft typed for one profile is dropped, never saved into the next.
                .id(profile.id)
            }
            SettingsDivider()
            // Refused without a key: git would otherwise get an empty `user.signingKey` (the environment signs nothing
            // then either, see `Profile.Signing.isUsable`).
            SettingsSwitchRow(
                title: "Sign commits by default",
                hint: "Every commit made in its tabs is signed.",
                isOn: Binding(get: { profile.signByDefault && profile.signing.isUsable },
                              set: { value in library.modify(profile.id) { $0.signByDefault = value } }))
                .disabled(!profile.signing.isUsable)
        }
    }

    private static func title(of method: SigningMethod) -> String {
        switch method {
        case .none: "None"
        case .gpg: "GPG"
        case .ssh: "SSH"
        }
    }

    /// A new method starts from what the profile already has: an SSH signing key defaults to its SSH key's `.pub`.
    private func setSigning(_ method: SigningMethod, of profile: Profile) {
        library.modify(profile.id) { profile in
            switch method {
            case .none:
                profile.signing = .none
            case .gpg:
                if case .gpg = profile.signing { return }
                profile.signing = .gpg(keyID: "")
            case .ssh:
                if case .ssh = profile.signing { return }
                if case .keyFile(let path) = profile.ssh {
                    profile.signing = .ssh(keyPath: path + ".pub")
                } else {
                    profile.signing = .ssh(keyPath: "")
                }
            }
        }
    }

    /// A text binding into the profile, saved at each keystroke.
    private func binding(_ profile: Profile, _ keyPath: WritableKeyPath<Profile, String>) -> Binding<String> {
        Binding(get: { profile[keyPath: keyPath] }, set: { value in
            library.modify(profile.id) { $0[keyPath: keyPath] = value }
        })
    }
}

/// The inline error of a GPG or SSH signing method whose key is blank: such a profile signs nothing.
private struct SigningKeyMissing: View {
    static let message = "Enter a key: without one this profile signs nothing."

    var body: some View {
        Text(Self.message)
            .font(.settingsCaption)
            .foregroundStyle(.red)
    }
}

/// A profile in the list: its color dot, name and email, and a Default badge; a click selects it.
private struct ProfileRow: View {
    let profile: Profile
    let isDefault: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                HStack(spacing: 8) {
                    Text(profile.name.isEmpty ? "Unnamed" : profile.name)
                    if !profile.identity.email.isEmpty {
                        Text(profile.identity.email)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    if isDefault {
                        Text("Default")
                            .font(.settingsCaption.weight(.medium))
                            .foregroundStyle(Palette.onAccent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor))
                    }
                }
            } icon: {
                Circle()
                    .fill(ProfileColors.color(profile.color))
                    .frame(width: 10, height: 10)
            }
        }
        .buttonStyle(SidebarItemStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A round color choice; the selected one has a ring.
private struct ColorSwatch: View {
    let hex: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(ProfileColors.color(hex))
                .frame(width: 16, height: 16)
                .padding(3)
                .overlay(Circle().strokeBorder(selected ? Color.primary : .clear, lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hex)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The profile store could not be read: its message and Try Again. Nothing is editable, so nothing overwrites the
/// file.
struct ProfileStoreFailedCard: View {
    let message: String

    var body: some View {
        SettingsGroup("Profiles") {
            LabeledContent {
                Button("Try Again") { ProfileLibrary.shared.reload() }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
            } label: {
                Text("Profiles are unavailable")
                Text(message)
                    .font(.settingsCaption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A key path row: the path in a field (saved on Return or when the field loses focus, `~` expanded, absolute only)
/// and a Choose… button. `onChange` gets the absolute path, or "" when the field is cleared. `emptyError`, when set,
/// shows in red in place of the hint while no path is saved (a required key).
struct KeyPathRow: View {
    let title: String
    let hint: String
    let path: String
    var emptyError: String?
    let onChange: (String) -> Void
    @State private var draft = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                TextField(title, text: $draft, prompt: Text("~/.ssh/id_ed25519"))
                    .textFieldStyle(.settings)
                    .frame(maxWidth: 260)
                    .labelsHidden()
                    .focused($focused)
                    .onSubmit(commit)
                Button("Choose…") {
                    Task {
                        let start = path.isEmpty ? nil : (path as NSString).deletingLastPathComponent
                        guard let chosen = await ProfileLibrary.chooseFile(
                            prompt: "Choose", message: title, startingAt: start) else { return }
                        draft = ProfileLibrary.abbreviated(chosen)
                        commit()
                    }
                }
                .buttonStyle(RowTextButtonStyle(formRow: true))
            }
        } label: {
            Text(title)
            if let error = error ?? (path.isEmpty ? emptyError : nil) {
                Text(error)
                    .font(.settingsCaption)
                    .foregroundStyle(.red)
            } else {
                SettingsHint(hint)
            }
        }
        .onChange(of: path, initial: true) { _, new in
            if !focused { draft = new.isEmpty ? "" : ProfileLibrary.abbreviated(new) }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            error = nil
            if !path.isEmpty { onChange("") }
            return
        }
        guard let absolute = ProfileLibrary.absolutePath(trimmed) else {
            error = "Enter a full path (starting with / or ~)."
            return
        }
        error = nil
        if absolute != path { onChange(absolute) }
    }
}
