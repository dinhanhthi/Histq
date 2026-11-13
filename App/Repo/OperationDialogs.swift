// The forms and confirmations of the repo operations: create and rename a branch, create a tag (lightweight or
// annotated), the reset mode chooser, add / rename a remote and set its URL, and the confirmation of every destructive
// operation (it names its target). A menu, the action bar or the sidebar sets `RepoSession.dialog` or
// `RepoSession.confirmation`; `operationDialogs(session:)` on the repo layout presents them. Every form runs its write
// through `RepoSession.run`, and new names are checked first as the operation checks them (`git check-ref-format`, no
// leading `-`).
import HistqCore
import SwiftUI

/// A form asked for by a menu or a button.
enum OperationDialog: Identifiable {
    /// A new branch at `revision` (a sha or `HEAD`); `label` names that place in the title.
    case createBranch(from: String, label: String)
    case renameBranch(String)
    /// A new tag at `revision`.
    case createTag(at: String, label: String)
    /// Moves `branch` (the current branch, or nil on a detached HEAD) to `revision`, `mode` preselected.
    case reset(to: String, label: String, branch: String?, mode: GitOperations.ResetMode)
    case addRemote
    case renameRemote(String)
    case setRemoteURL(String, url: String)

    var id: String {
        switch self {
        case .createBranch(let revision, _): "branch \(revision)"
        case .renameBranch(let name): "rename \(name)"
        case .createTag(let revision, _): "tag \(revision)"
        case .reset(let revision, _, _, let mode): "reset \(revision) \(mode.rawValue)"
        case .addRemote: "add remote"
        case .renameRemote(let name): "rename remote \(name)"
        case .setRemoteURL(let name, _): "url \(name)"
        }
    }
}

/// A destructive operation waiting for its confirmation: `title` names the target ("Delete branch feature?").
struct OperationConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    /// The destructive button's title.
    let button: String
    let write: RepoSession.Write
    /// The running operation's title.
    let operation: String
    let key: ActionBarAction?
    /// False for a confirmation that loses nothing (a detached checkout): its button is not red.
    let isDestructive: Bool
}

extension View {
    /// Presents the session's form (a sheet), its confirmation (a confirmation dialog) and its host-key sheet.
    func operationDialogs(session: RepoSession) -> some View {
        modifier(OperationDialogsModifier(session: session))
    }
}

private struct OperationDialogsModifier: ViewModifier {
    @Bindable var session: RepoSession

    func body(content: Content) -> some View {
        content
            .sheet(item: $session.dialog) { dialog in
                OperationDialogView(session: session, dialog: dialog)
            }
            .background {
                // A second sheet on its own view.
                Color.clear
                    .sheet(item: $session.hostKeyCheck) { check in
                        HostKeySheet(session: session, check: check)
                    }
            }
            .confirmationDialog(
                session.confirmation?.title ?? "", isPresented: confirmationIsPresented, titleVisibility: .visible,
                presenting: session.confirmation
            ) { confirmation in
                Button(confirmation.button, role: confirmation.isDestructive ? .destructive : nil) {
                    session.run(confirmation.write, title: confirmation.operation, key: confirmation.key)
                }
                Button("Cancel", role: .cancel) {}
            } message: { confirmation in
                Text(confirmation.message)
            }
    }

    private var confirmationIsPresented: Binding<Bool> {
        Binding { session.confirmation != nil } set: { if !$0 { session.confirmation = nil } }
    }
}

// MARK: - Forms

/// One form: its title, fields, an inline error and Cancel / the action (⏎). The action checks new names first, then
/// runs the write and closes the form; the write's own failure goes to the error banner.
private struct OperationDialogView: View {
    let session: RepoSession
    let dialog: OperationDialog
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var url = ""
    @State private var message = ""
    @State private var checkout = true
    @State private var annotated = false
    @State private var mode = GitOperations.ResetMode.mixed
    @State private var error: String?
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .truncationMode(.middle)
            fields
            ErrorText(message: error)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
                    .keyboardShortcut(.cancelAction)
                Button {
                    submit()
                } label: {
                    HStack(spacing: 6) {
                        if checking { ProgressView().controlSize(.mini) }
                        Text(actionTitle)
                    }
                }
                .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
                // A hard reset is never one Return away.
                .keyboardShortcut(isHardReset ? nil : KeyboardShortcut.defaultAction)
                .disabled(!canSubmit || checking)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear(perform: prefill)
    }

    private var isHardReset: Bool {
        if case .reset = dialog { mode == .hard } else { false }
    }

    // MARK: Content

    private var title: String {
        switch dialog {
        case .createBranch(_, let label): "Create a branch at \(label)"
        case .renameBranch(let name): "Rename branch \(name)"
        case .createTag(_, let label): "Create a tag at \(label)"
        case .reset(_, let label, let branch, _): "Reset \(branch ?? "HEAD") to \(label)"
        case .addRemote: "Add a remote"
        case .renameRemote(let name): "Rename remote \(name)"
        case .setRemoteURL(let name, _): "Set the URL of \(name)"
        }
    }

    private var actionTitle: String {
        switch dialog {
        case .createBranch: "Create Branch"
        case .renameBranch, .renameRemote: "Rename"
        case .createTag: "Create Tag"
        case .reset: "Reset"
        case .addRemote: "Add Remote"
        case .setRemoteURL: "Set URL"
        }
    }

    @ViewBuilder private var fields: some View {
        switch dialog {
        case .createBranch:
            field("Branch name") { TextField("feature/name", text: $name) }
            Toggle("Check out the new branch", isOn: $checkout)
        case .renameBranch, .renameRemote:
            field("New name") { TextField("Name", text: $name) }
        case .createTag:
            field("Tag name") { TextField("v1.0", text: $name) }
            Toggle("Annotated, with a message", isOn: $annotated)
            if annotated {
                TextEditor(text: $message)
                    .font(.body)
                    .frame(height: 80)
                    .settingsTextEditor()
            }
        case .reset(_, _, let branch, _):
            Picker("Mode", selection: $mode) {
                Text("Soft: keep the index and the files").tag(GitOperations.ResetMode.soft)
                Text("Mixed: keep the files, unstage the changes").tag(GitOperations.ResetMode.mixed)
                Text("Hard: discard every change of the index and the files").tag(GitOperations.ResetMode.hard)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if mode == .hard {
                Label("A hard reset discards the uncommitted changes of \(branch ?? "HEAD"). This cannot be undone.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.settingsCaption)
                    .foregroundStyle(Color(nsColor: Palette.graphLanes[6]))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .addRemote:
            field("Name") { TextField("origin", text: $name) }
            field("URL") { TextField("git@github.com:owner/repo.git", text: $url) }
        case .setRemoteURL:
            field("URL") { TextField("git@github.com:owner/repo.git", text: $url) }
        }
    }

    private func field<Field: View>(_ label: String, @ViewBuilder _ content: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.settingsCaption)
                .foregroundStyle(.secondary)
            content()
                .textFieldStyle(.settings)
                .autocorrectionDisabled()
                .onSubmit(submit)
        }
    }

    private func prefill() {
        switch dialog {
        case .renameBranch(let current), .renameRemote(let current): name = current
        case .setRemoteURL(_, let current): url = current
        case .reset(_, _, _, let preselected): mode = preselected
        default: break
        }
    }

    // MARK: Submit

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSubmit: Bool {
        switch dialog {
        case .createBranch, .renameBranch, .renameRemote: !trimmedName.isEmpty
        case .createTag: !trimmedName.isEmpty && (!annotated || !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        case .reset: true
        case .addRemote: !trimmedName.isEmpty && !trimmedURL.isEmpty
        case .setRemoteURL: !trimmedURL.isEmpty
        }
    }

    /// Checks the new name (off the main actor), then runs the write and closes; a bad name stays in the form.
    private func submit() {
        guard canSubmit, !checking else { return }
        error = nil
        if case .addRemote = dialog, !Self.isValidURL(trimmedURL) { return error = "That is not a valid remote URL." }
        if case .setRemoteURL = dialog, !Self.isValidURL(trimmedURL) { return error = "That is not a valid remote URL." }
        guard let kind = nameKind else { return finish() }
        checking = true
        Task {
            let reason = await session.validate(kind, trimmedName)
            checking = false
            if let reason { error = reason } else { finish() }
        }
    }

    private var nameKind: RepoSession.NameKind? {
        switch dialog {
        case .createBranch, .renameBranch: .branch
        case .createTag: .tag
        case .addRemote, .renameRemote: .remote
        case .reset, .setRemoteURL: nil
        }
    }

    private static func isValidURL(_ url: String) -> Bool {
        (try? GitOperations.validateRemoteURL(url)) != nil
    }

    private func finish() {
        let name = trimmedName
        switch dialog {
        case .createBranch(let revision, _):
            session.run(.createBranch(name, from: revision, checkout: checkout), title: "Create branch \(name)")
        case .renameBranch(let old):
            session.run(.renameBranch(old, to: name), title: "Rename \(old) to \(name)")
        case .createTag(let revision, _):
            let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
            session.run(.createTag(name, at: revision, message: annotated ? text : nil), title: "Create tag \(name)")
        case .reset(let revision, let label, let branch, _):
            session.run(.reset(to: revision, mode: mode),
                        title: "Reset \(branch ?? "HEAD") to \(label) (\(mode.rawValue))")
        case .addRemote:
            session.run(.addRemote(name, url: trimmedURL), title: "Add remote \(name)")
        case .renameRemote(let old):
            session.run(.renameRemote(old, to: name), title: "Rename remote \(old) to \(name)")
        case .setRemoteURL(let remote, _):
            session.run(.setRemoteURL(remote, url: trimmedURL), title: "Set the URL of \(remote)")
        }
        dismiss()
    }
}
