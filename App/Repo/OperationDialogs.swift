// The forms and confirmations of the repo operations: create and rename a branch, create a tag (lightweight or
// annotated), the reset mode chooser, add / rename a remote and set its URL, add a worktree, the interactive rebase and squash sheet
// (`InteractiveRebaseView`), and the confirmation of every destructive operation (it names its target). A menu, the action bar or the sidebar sets `RepoSession.dialog` or
// `RepoSession.confirmation`; `ModalHost` presents them over the window. Every form runs its write
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

/// A confirmation that is not a repo write (a profile's deletion, a WIP file's discard): `WindowModel.modal` shows it
/// like an `OperationConfirmation`.
struct ModalConfirmation {
    let title: String
    let message: String
    let button: String
    let isDestructive: Bool
    let perform: @MainActor () -> Void
}

/// A confirmation card: the title and what it does in the header, then Cancel (Escape) and the button. Return presses
/// the button only when it loses nothing; a destructive button is never one Return away.
struct ConfirmationModal: View {
    let title: String
    let message: String
    let button: String
    let isDestructive: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ModalCard(title: title, subtitle: message,
                  systemImage: isDestructive ? "exclamationmark.triangle" : "questionmark.circle", width: 420,
                  takesFocus: true) {
            EmptyView()
        } actions: {
            Button("Cancel", action: onCancel)
                .buttonStyle(RowTextButtonStyle(formRow: true))
                .keyboardShortcut(.cancelAction)
            Button(button, action: onConfirm)
                .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true, destructive: isDestructive))
                .keyboardShortcut(isDestructive ? nil : KeyboardShortcut.defaultAction)
        }
    }
}

// MARK: - Forms

/// One form: its title, fields, an inline error and Cancel / the action (⏎). The action checks new names first, then
/// runs the write and closes the form; the write's own failure goes to the error banner.
struct OperationDialogView: View {
    let session: RepoSession
    let dialog: OperationDialog
    let onClose: () -> Void
    /// The first field, focused when the form opens.
    @FocusState private var fieldFocused: Bool

    @State private var name = ""
    @State private var url = ""
    @State private var message = ""
    @State private var checkout = true
    @State private var annotated = false
    @State private var mode = GitOperations.ResetMode.mixed
    @State private var error: String?
    @State private var checking = false

    var body: some View {
        // The reset form has no text field: the card takes the focus, so arrows and ⌘Z never reach the graph.
        ModalCard(title: title, width: 440, takesFocus: !hasTextField) {
            ModalSection {
                fields
                ErrorText(message: error)
            }
        } actions: {
            Button("Cancel", action: onClose)
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
        .onAppear {
            prefill()
            // The card is installed on this turn; the field takes the focus on the next one.
            DispatchQueue.main.async { fieldFocused = true }
            #if DEBUG
            debugSubmit()
            #endif
        }
    }

    #if DEBUG
    /// DEBUG `-HistqFormName "<name>"`: types the name into the form and presses its action, as Return would, so a QA
    /// run checks the write through the modal. For fixture copies only.
    private func debugSubmit() {
        guard let value = AppState.launchFlag("-HistqFormName") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            name = value
            submit()
        }
    }
    #endif

    private var hasTextField: Bool {
        if case .reset = dialog { false } else { true }
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
                .focused($fieldFocused)
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
        onClose()
    }
}

// MARK: - Add worktree

/// The Add Worktree form asked for by a menu: from a branch or a commit (`source`, nil from the Worktrees card), named
/// `label` in its title.
struct WorktreeForm: Identifiable {
    let id = UUID()
    let source: GitOperations.WorktreeSource?
    let label: String?

    /// Where the new worktree starts, as the form has it: a local branch, or any revision (resolved to a commit id
    /// before it runs).
    enum Start: Sendable {
        case branch(String)
        case revision(String)
    }
}

/// Add Worktree: a local branch or a commit, an optional new branch, the parent folder (chosen in a folder panel) and
/// the new folder's name. Add checks it all off the main actor (the folder name, that the parent exists and the folder
/// does not, the revision resolves to a commit, the new branch name) before the write runs.
struct AddWorktreeView: View {
    let session: RepoSession
    let form: WorktreeForm
    let onClose: () -> Void

    private enum Mode: Hashable, CaseIterable {
        case branch, commit

        var title: String {
            switch self {
            case .branch: "Branch"
            case .commit: "Commit"
            }
        }
    }

    @FocusState private var nameFocused: Bool
    @State private var mode = Mode.branch
    @State private var branch = ""
    @State private var revision = ""
    @State private var newBranch = ""
    @State private var parent = ""
    @State private var name = ""
    /// The folder name as the form last proposed it: replaced when the start changes, until the user types one.
    @State private var proposedName = ""
    @State private var error: String?
    @State private var checking = false

    var body: some View {
        ModalCard(title: form.label.map { "Add a worktree for \($0)" } ?? "Add a worktree", width: 460) {
            ModalSection {
                CapsuleTabs(selection: $mode, tabs: Mode.allCases, title: { Text($0.title) }, compact: true)
                switch mode {
                case .branch:
                    field("Branch") {
                        if branches.isEmpty {
                            Text("No local branch")
                                .foregroundStyle(.secondary)
                        } else {
                            CapsuleMenuPicker(label: "Branch", selection: $branch, title: Text(branchTitle(branch))) {
                                ForEach(branches, id: \.self) { Text(branchTitle($0)).tag($0) }
                            }
                        }
                    }
                case .commit:
                    field("Commit") {
                        TextField("sha, tag or HEAD~2", text: $revision)
                            .textFieldStyle(.settings)
                            .autocorrectionDisabled()
                            .onSubmit(submit)
                    }
                }
                field(mode == .branch ? "New branch from it (optional)" : "New branch (optional, else detached)") {
                    TextField("feature/name", text: $newBranch)
                        .textFieldStyle(.settings)
                        .autocorrectionDisabled()
                        .onSubmit(submit)
                }
                field("Location") {
                    HStack(spacing: 8) {
                        Text(parent.isEmpty ? "No folder chosen" : ProfileLibrary.abbreviated(parent))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(parent.isEmpty ? .secondary : .primary)
                            .help(parent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose…", action: chooseParent)
                            .buttonStyle(RowTextButtonStyle(formRow: true))
                    }
                }
                field("Folder name") {
                    TextField("repo-branch", text: $name)
                        .textFieldStyle(.settings)
                        .autocorrectionDisabled()
                        .focused($nameFocused)
                        .onSubmit(submit)
                }
                ErrorText(message: error)
            }
        } actions: {
            Button("Cancel", action: onClose)
                .buttonStyle(RowTextButtonStyle(formRow: true))
                .keyboardShortcut(.cancelAction)
            Button {
                submit()
            } label: {
                HStack(spacing: 6) {
                    if checking { ProgressView().controlSize(.mini) }
                    Text("Add Worktree")
                }
            }
            .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
            .keyboardShortcut(.defaultAction)
            .disabled(!canSubmit || checking)
        }
        .onAppear {
            prefill()
            DispatchQueue.main.async { nameFocused = true }
            #if DEBUG
            debugSubmit()
            #endif
        }
        .onChange(of: mode) { proposeName() }
        .onChange(of: branch) { proposeName() }
        .onChange(of: newBranch) { proposeName() }
    }

    #if DEBUG
    /// DEBUG `-HistqWorktreeFolder "<parent>"` with `-HistqFormName "<folder name>"`: fills the location (a folder panel
    /// cannot be driven) and the name, then presses Add, as Return would. For fixture copies only.
    private func debugSubmit() {
        guard let folder = AppState.launchFlag("-HistqWorktreeFolder"), let value = AppState.launchFlag("-HistqFormName")
        else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            parent = folder
            name = value
            submit()
        }
    }
    #endif

    /// The local branches; one checked out in a worktree is listed too (it can start a new branch).
    private var branches: [String] {
        session.refs.value?.localBranches.map(\.name) ?? []
    }

    /// The worktree that has `branch` checked out, by folder name.
    private func checkedOut(_ branch: String) -> String? {
        session.worktrees.value?.first { $0.worktree.branch == "refs/heads/\(branch)" }?.name
    }

    private func branchTitle(_ branch: String) -> String {
        checkedOut(branch).map { "\(branch) (in \($0))" } ?? branch
    }

    private func field<Field: View>(_ label: String, @ViewBuilder _ content: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.settingsCaption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    /// The start the menu asked for, else the first branch not checked out anywhere; the repo's own parent folder.
    private func prefill() {
        switch form.source {
        case .branch(let name)?:
            mode = .branch
            branch = name
        case .commit(let id)?:
            mode = .commit
            revision = id
            branch = branches.first { checkedOut($0) == nil } ?? branches.first ?? ""
        case nil:
            branch = branches.first { checkedOut($0) == nil } ?? branches.first ?? ""
        }
        let main = session.worktrees.value?.first { $0.worktree.isMain }.map { URL(filePath: $0.path) } ?? session.url
        parent = main.deletingLastPathComponent().path(percentEncoded: false)
        if parent.count > 1, parent.hasSuffix("/") { parent.removeLast() }
        proposeName()
    }

    /// `<repo>-<branch>` (or `-<short sha>`), with `/` made `-`, while the name is still the proposed one.
    private func proposeName() {
        guard name == proposedName else { return }
        let repo = session.url.lastPathComponent
        let start = newBranch.trimmingCharacters(in: .whitespaces).isEmpty
            ? (mode == .branch ? branch : String(revision.trimmingCharacters(in: .whitespaces).prefix(7)))
            : newBranch.trimmingCharacters(in: .whitespaces)
        let proposed = start.isEmpty ? repo + "-worktree" : repo + "-" + start.replacingOccurrences(of: "/", with: "-")
        proposedName = proposed
        name = proposed
    }

    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "The folder the new worktree's folder is created in"
        if !parent.isEmpty { panel.directoryURL = URL(filePath: parent, directoryHint: .isDirectory) }
        Task {
            guard await panel.begin() == .OK, let path = panel.url?.path(percentEncoded: false) else { return }
            parent = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }
    }

    private var trimmedNewBranch: String? {
        let text = newBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private var canSubmit: Bool {
        let hasStart = mode == .branch ? !branch.isEmpty : !revision.trimmingCharacters(in: .whitespaces).isEmpty
        return hasStart && !parent.isEmpty && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Checks the form off the main actor, then runs the write and closes; a problem stays in the form.
    private func submit() {
        guard canSubmit, !checking else { return }
        error = nil
        if mode == .branch, trimmedNewBranch == nil, let other = checkedOut(branch) {
            return error = "\(branch) is checked out in \(other): name a new branch to start from it."
        }
        let start: WorktreeForm.Start = mode == .branch ? .branch(branch) : .revision(revision)
        let folderName = name.trimmingCharacters(in: .whitespaces)
        checking = true
        Task {
            let result = await session.addWorktreeWrite(
                parent: parent, name: folderName, start: start, newBranch: trimmedNewBranch)
            checking = false
            switch result {
            case .success(let write):
                session.run(write, title: "Add worktree \(folderName)")
                onClose()
            case .failure(let problem):
                error = problem.message
            }
        }
    }
}
