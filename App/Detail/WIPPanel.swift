// The working tree in the detail panel, each part in its own card: the conflicted files (open the conflict editor,
// stage), the unstaged files (stage, discard), the staged files (unstage), and the commit box (summary with a 72-character counter, description, Amend, Commit / ⌘↩, and the AI buttons Explain and Generate Message).
// Every write goes through `RepoSession.perform` (write environment, off the main actor); the control that started
// it shows a spinner at once, and an error shows in its card.
import HistqCore
import SwiftUI

/// The commit box's text, kept on the session while another row is selected.
struct CommitDraft {
    var summary = ""
    var description = ""
    var amend = false
    /// What the user had typed before Amend filled in HEAD's message; restored when Amend is turned off.
    var savedSummary = ""
    var savedDescription = ""
}

/// The WIP detail, from the session's live `status`.
struct WIPPanel: View {
    let session: RepoSession
    /// The controls whose write is running.
    @State private var busy: Set<Busy> = []
    @State private var errors: [Part: String] = [:]
    /// The window's modal (`ModalHost`) asks before a discard.
    @Environment(WindowModel.self) private var model

    fileprivate enum Busy: Hashable {
        case stage(String), unstage(String), discard(String), stageAll, unstageAll, commit, amendMessage
    }

    fileprivate enum Part: Hashable {
        case conflicted, unstaged, staged, commit
    }

    var body: some View {
        let status = session.status.value
        let conflicted = status.map(Self.conflicted) ?? []
        let unstaged = status.map(Self.unstaged) ?? []
        let staged = status.map(Self.staged) ?? []
        // The panel's height is always used: a card with files scrolls inside and shares the free height equally with
        // the other cards that have files; an empty card fits its text; the commit box stays at the bottom.
        VStack(spacing: SectionCardMetrics.spacing) {
            // During an operation the card stays once its files are resolved, saying nothing is left.
            if !conflicted.isEmpty || session.repoState?.isOperationInProgress == true {
                conflictedCard(conflicted)
            }
            unstagedCard(unstaged)
            stagedCard(staged)
            if conflicted.isEmpty && unstaged.isEmpty && staged.isEmpty {
                Spacer(minLength: 0)
            }
            CommitBox(session: session, stagedCount: staged.count, changeCount: staged.count + unstaged.count,
                      busy: $busy, error: errorBinding(.commit))
        }
    }

    // MARK: Cards

    /// The files git left with conflicts (a merge, rebase, cherry-pick, revert or stash pop): a click opens the conflict
    /// editor in panel2 (`FileTarget.isConflict`); the button stages the file as it is, marking it resolved.
    private func conflictedCard(_ files: [FileChange]) -> some View {
        SectionCard("Conflicted", systemImage: "exclamationmark.triangle", count: files.count, contentPadding: 6) {
            if files.isEmpty {
                EmptyFilesText(text: "No conflicts left")
            } else {
                FilesScroll {
                    FileListView(files: files, repoURL: session.url) { file in
                        rowButton("checkmark.circle", help: "Mark as Resolved (Stage File)", busy: .stage(file.path)) {
                            run(.stage([file.path]), busy: .stage(file.path), part: .conflicted)
                        }
                    }
                    .onSelectFile(selected: openWIPPath) { file in
                        session.selectFile(FileTarget(source: .wip, file: file))
                    }
                }
            }
            ErrorText(message: errors[.conflicted])
        } accessory: {
            FileListModeToggle()
        }
    }

    private func unstagedCard(_ files: [FileChange]) -> some View {
        SectionCard("Unstaged", systemImage: "doc.badge.ellipsis", count: files.count, contentPadding: 6) {
            if files.isEmpty {
                EmptyFilesText(text: "No unstaged changes")
            } else {
                FilesScroll {
                    FileListView(files: files, repoURL: session.url) { file in
                        HStack(spacing: 10) {
                            rowButton("arrow.uturn.backward",
                                      help: file.kind == .untracked ? "Delete File…" : "Discard Changes…",
                                      busy: .discard(file.path)) { confirmDiscard(file) }
                            rowButton("plus.circle", help: "Stage File", busy: .stage(file.path)) {
                                run(.stage([file.path]), busy: .stage(file.path), part: .unstaged)
                            }
                        }
                    }
                    .onSelectFile(selected: openWIPPath) { file in
                        session.selectFile(FileTarget(source: .wip, file: file))
                    }
                }
            }
            ErrorText(message: errors[.unstaged])
        } accessory: {
            HStack(spacing: 10) {
                FileListModeToggle()
                headerButton("Stage All", busy: .stageAll, disabled: files.isEmpty) {
                    run(.stageAll, busy: .stageAll, part: .unstaged)
                }
            }
        }
    }

    private func stagedCard(_ files: [FileChange]) -> some View {
        SectionCard("Staged", systemImage: "tray.full", count: files.count, contentPadding: 6) {
            if files.isEmpty {
                EmptyFilesText(text: "No staged changes")
            } else {
                FilesScroll {
                    FileListView(files: files, repoURL: session.url) { file in
                        rowButton("minus.circle", help: "Unstage File", busy: .unstage(file.path)) {
                            // A rename's old path too, or its deletion stays staged.
                            let paths = [file.originalPath, file.path].compactMap { $0 }
                            run(.unstage(paths), busy: .unstage(file.path), part: .staged)
                        }
                    }
                    .onSelectFile(selected: openWIPPath) { file in
                        session.selectFile(FileTarget(source: .wip, file: file))
                    }
                }
            }
            ErrorText(message: errors[.staged])
        } accessory: {
            HStack(spacing: 10) {
                FileListModeToggle()
                headerButton("Unstage All", busy: .unstageAll, disabled: files.isEmpty) {
                    run(.unstageAll, busy: .unstageAll, part: .staged)
                }
            }
        }
    }

    /// A row's icon button; a small spinner in its place while its write runs.
    private func rowButton(_ systemImage: String, help: String, busy key: Busy, action: @escaping () -> Void)
        -> some View
    {
        ZStack {
            if busy.contains(key) {
                ProgressView().controlSize(.mini)
            } else {
                Button(action: action) {
                    Image(systemName: systemImage)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(RowIconButtonStyle())
                .help(help)
                .accessibilityLabel(help)
            }
        }
        .frame(width: 16, height: 16)
    }

    private func headerButton(_ title: String, busy key: Busy, disabled: Bool, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            HStack(spacing: 4) {
                if busy.contains(key) { ProgressView().controlSize(.mini) }
                Text(title)
            }
        }
        .buttonStyle(RowTextButtonStyle())
        .disabled(disabled || busy.contains(key))
    }

    /// The WIP file whose diff panel2 shows, drawn as selected in both lists.
    private var openWIPPath: String? {
        session.openFile?.source == .wip ? session.openFile?.path : nil
    }

    // MARK: Writes

    /// Shows `key` busy now (the click's frame), then runs the write; its error goes to `part`'s card.
    private func run(_ write: RepoSession.Write, busy key: Busy, part: Part) {
        busy.insert(key)
        errors[part] = nil
        Task {
            do {
                try await session.perform(write)
            } catch {
                errors[part] = RepoSession.writeMessage(for: error)
            }
            busy.remove(key)
        }
    }

    private func discard(_ file: FileChange) {
        let write: RepoSession.Write = file.kind == .untracked ? .removeUntracked([file.path]) : .discard([file.path])
        run(write, busy: .discard(file.path), part: .unstaged)
    }

    private func confirmDiscard(_ file: FileChange) {
        model.presentModal(.confirmation(ModalConfirmation(
            title: Self.discardTitle(file), message: "This cannot be undone.",
            button: file.kind == .untracked ? "Delete" : "Discard", isDestructive: true) { discard(file) }))
    }

    private func errorBinding(_ part: Part) -> Binding<String?> {
        Binding { errors[part] } set: { errors[part] = $0 }
    }

    private static func discardTitle(_ file: FileChange) -> String {
        file.kind == .untracked ? "Delete \(file.name)?" : "Discard the changes to \(file.name)?"
    }

    // MARK: Files

    /// Paths with unmerged index entries, in status order.
    private static func conflicted(_ status: WorkingStatus) -> [FileChange] {
        status.conflicted.map { FileChange(kind: .conflicted, path: $0.path) }
    }

    /// Changes in the working tree and untracked files (conflicts have their own card).
    private static func unstaged(_ status: WorkingStatus) -> [FileChange] {
        status.entries.compactMap { entry in
            switch entry.kind {
            case .untracked: FileChange(kind: .untracked, path: entry.path)
            case .unmerged, .ignored: nil
            default: entry.isUnstaged ? FileChange(letter: entry.worktree.rawValue, path: entry.path) : nil
            }
        }
    }

    private static func staged(_ status: WorkingStatus) -> [FileChange] {
        status.entries.compactMap { entry in
            entry.isStaged
                ? FileChange(letter: entry.index.rawValue, path: entry.path, originalPath: entry.originalPath) : nil
        }
    }
}

/// The skeleton of the WIP panel: the same cards with capsule rows (the Conflicted card when the last status had
/// conflicts).
struct WIPPlaceholder: View {
    var hasConflicts = false

    var body: some View {
        // The loaded panel's shape: the file cards share the height (no scroll views here, the placeholder stays
        // cheap in the click's frame), the commit box at the bottom.
        VStack(spacing: SectionCardMetrics.spacing) {
            if hasConflicts {
                SectionCard("Conflicted", systemImage: "exclamationmark.triangle", countIsLoading: true, contentPadding: 6) {
                    SkeletonFileRows(fractions: [0.45, 0.6])
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            SectionCard("Unstaged", systemImage: "doc.badge.ellipsis", countIsLoading: true, contentPadding: 6) {
                SkeletonFileRows(fractions: [0.55, 0.4, 0.65, 0.5])
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            SectionCard("Staged", systemImage: "tray.full", countIsLoading: true, contentPadding: 6) {
                SkeletonFileRows(fractions: [0.5, 0.35])
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            SectionCard("Commit", systemImage: "checkmark.circle") {
                VStack(alignment: .leading, spacing: 10) {
                    SkeletonLine(fraction: 1, height: 28)
                    SkeletonLine(fraction: 1, height: 64)
                    HStack {
                        SkeletonLine(width: 80, height: 14)
                        Spacer()
                        SkeletonLine(width: 120, height: 24)
                    }
                }
            }
        }
    }
}

// MARK: - Commit box

private struct CommitBox: View {
    let session: RepoSession
    let stagedCount: Int
    /// Staged and unstaged files: Explain needs at least one.
    let changeCount: Int
    @Binding var busy: Set<WIPPanel.Busy>
    @Binding var error: String?

    static let summaryLimit = 72

    var body: some View {
        @Bindable var session = session
        let draft = session.commitDraft
        let count = draft.summary.count
        SectionCard("Commit", systemImage: "checkmark.circle") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Summary", text: $session.commitDraft.summary)
                        .textFieldStyle(.settings)
                    Text("\(count)/\(Self.summaryLimit)")
                        .font(.settingsCaption)
                        .monospacedDigit()
                        .foregroundStyle(count > Self.summaryLimit ? Color(nsColor: Palette.graphLanes[6]) : .secondary)
                        .help("Keep the summary within \(Self.summaryLimit) characters")
                }
                TextEditor(text: $session.commitDraft.description)
                    .font(.body)
                    .settingsTextEditor()
                    .frame(height: 72)
                    .overlay(alignment: .topLeading) {
                        if draft.description.isEmpty {
                            Text("Description")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                HStack(spacing: 8) {
                    Toggle("Amend", isOn: amendBinding)
                        .toggleStyle(CompactSwitch())
                        .disabled(busy.contains(.commit))
                    Text("Amend")
                        .foregroundStyle(.secondary)
                    if busy.contains(.amendMessage) { ProgressView().controlSize(.mini) }
                    Spacer(minLength: 8)
                    Button(action: commit) {
                        HStack(spacing: 6) {
                            if busy.contains(.commit) { ProgressView().controlSize(.mini) }
                            Text(draft.amend ? "Amend Commit" : commitTitle)
                        }
                    }
                    .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canCommit)
                    .help("Commit (⌘↩)")
                }
                ErrorText(message: error)
            }
        } accessory: {
            // AI (task 12.3): each opens the result card; nothing is sent before the click.
            HStack(spacing: 6) {
                AIHookButton(title: "Explain", help: "Explain the uncommitted changes with AI",
                             unavailable: changeCount == 0 ? "No changes to explain" : nil, seam: "explain-wip") {
                    session.startAI(.explainWorkingChanges)
                }
                AIHookButton(title: "Generate Message", systemImage: "sparkles",
                             help: "Write a commit message for the staged changes with AI",
                             unavailable: stagedCount == 0 ? "Stage changes first" : nil, seam: "generate") {
                    session.startAI(.commitMessage)
                }
            }
        }
    }

    private var commitTitle: String {
        stagedCount == 1 ? "Commit 1 File" : "Commit \(stagedCount) Files"
    }

    private var canCommit: Bool {
        let draft = session.commitDraft
        let hasSummary = !draft.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasSummary && (draft.amend || stagedCount > 0) && !busy.contains(.commit)
            && !busy.contains(.amendMessage)
    }

    /// The summary, a blank line and the description (when there is one).
    private var message: String {
        let draft = session.commitDraft
        let summary = draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? summary : summary + "\n\n" + description
    }

    /// On: keeps what was typed and loads HEAD's message into the fields. Off: puts the typed text back.
    private var amendBinding: Binding<Bool> {
        Binding { session.commitDraft.amend } set: { isOn in
            guard isOn != session.commitDraft.amend else { return }
            session.commitDraft.amend = isOn
            if isOn {
                session.commitDraft.savedSummary = session.commitDraft.summary
                session.commitDraft.savedDescription = session.commitDraft.description
                loadLastMessage()
            } else {
                busy.remove(.amendMessage)
                session.commitDraft.summary = session.commitDraft.savedSummary
                session.commitDraft.description = session.commitDraft.savedDescription
            }
        }
    }

    private func loadLastMessage() {
        busy.insert(.amendMessage)
        error = nil
        Task {
            do {
                let (subject, body) = try await session.lastCommitMessage()
                if session.commitDraft.amend, busy.contains(.amendMessage) {
                    session.commitDraft.summary = subject
                    session.commitDraft.description = body
                }
            } catch {
                self.error = RepoSession.writeMessage(for: error)
            }
            busy.remove(.amendMessage)
        }
    }

    private func commit() {
        guard canCommit else { return }
        let write: RepoSession.Write = session.commitDraft.amend ? .amend(message: message) : .commit(message: message)
        busy.insert(.commit)
        error = nil
        Task {
            do {
                try await session.perform(write)
                session.commitDraft = CommitDraft()
            } catch {
                self.error = RepoSession.writeMessage(for: error)
            }
            busy.remove(.commit)
        }
    }
}

// MARK: - Small parts

/// A files card's rows in their own scroll view, so the card takes its share of the panel's height and scrolls inside
/// instead of the whole panel scrolling.
private struct FilesScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            content()
        }
        .frame(maxHeight: .infinity)
    }
}

private struct EmptyFilesText: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: FileListView<EmptyView>.rowHeight)
    }
}

/// A write's error under a card's content; nothing when nil.
struct ErrorText: View {
    let message: String?

    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.settingsCaption)
                .foregroundStyle(Color(nsColor: Palette.graphLanes[6]))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.top, 4)
        }
    }
}
