// The interactive rebase and squash modals (task 9.3; in-window `ModalCard`s since 9.6). "Interactive Rebase from Here…" on a commit lists that commit
// and every later one of the current branch, oldest first (the order git replays them): each row has an action
// (pick, reword, edit, squash, fixup, drop), rows drag to a new order, and a reword row edits its message in place.
// "Squash N Commits…" on a run of selected commits shows the message the squashed commit gets (every message, oldest
// first), editable. The sheet opens in the click's frame with skeleton rows; `RebaseTodo` reads the commits off the
// main actor. Start runs the todo as a write (`RepoSession.startRebase`): a conflict or an `edit` stop leaves the rebase
// in progress, and the operation banner and the conflict editor take over.
import HistqCore
import SwiftUI

/// A rebase sheet asked for by a menu, the palette or a launch flag.
struct RebaseRequest: Identifiable {
    enum Kind: Equatable, Sendable {
        /// Every commit from this one (full id) to HEAD.
        case fromCommit(String)
        /// The selected commits (full ids), folded into the oldest.
        case squash([String])
    }

    let id = UUID()
    let kind: Kind
}

struct InteractiveRebaseView: View {
    let session: RepoSession
    let request: RebaseRequest
    let onClose: () -> Void

    @State private var todo: Loadable<RebaseTodo> = .loading
    /// The rows as the user arranged them.
    @State private var items: [RebaseTodo.Item] = []
    /// The squash sheet's message.
    @State private var message = ""

    private var isSquash: Bool {
        if case .squash = request.kind { true } else { false }
    }

    var body: some View {
        ModalCard(title: title, subtitle: subtitle, systemImage: isSquash ? "arrow.triangle.merge" : "list.bullet",
                  width: 600, takesFocus: true) {
            switch todo {
            case .idle, .loading:
                SectionCard("Commits") { RebaseSkeleton(rows: placeholderRows) }
            case .failed(let text):
                SectionCard("Commits") { ErrorText(message: text) }
            case .loaded:
                if isSquash { squashCards } else { rebaseCard }
            }
            ErrorText(message: problem)
                .padding(.horizontal, 6)
        } actions: {
            Button("Cancel", action: onClose)
                .buttonStyle(RowTextButtonStyle(formRow: true))
                .keyboardShortcut(.cancelAction)
            // Never one Return away: a rebase rewrites the branch.
            Button(isSquash ? "Squash" : "Start Rebase", action: start)
                .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
                .disabled(todo.value == nil || problem != nil)
        }
        .task { await load() }
    }

    // MARK: Content

    private var title: String {
        switch request.kind {
        case .fromCommit(let commit):
            "Interactive rebase of \(session.currentBranch ?? "HEAD") from \(commit.prefix(7))"
        case .squash(let commits):
            "Squash \(commits.count) commits"
        }
    }

    private var subtitle: String {
        isSquash
            ? "The commits become one, with the message below; the commits after them are replayed on top."
            : "Oldest first: the top row is replayed first. Drag the rows to reorder them."
    }

    private var placeholderRows: Int {
        if case .squash(let commits) = request.kind { commits.count } else { 4 }
    }

    /// The rows: action, short id, subject; a reword row adds its message editor.
    private var rebaseCard: some View {
        SectionCard("Commits", systemImage: "list.bullet", count: items.count, contentPadding: 6) {
            List {
                ForEach($items) { $item in
                    RebaseRow(item: $item)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .onMove { items.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Shrinks (the list scrolls) when the window is too short for every row.
            .frame(minHeight: 76, maxHeight: listHeight)
        }
    }

    /// A row is about 38 pt, a reword row's editor adds about 80; at most 380 (the list scrolls).
    private var listHeight: CGFloat {
        let rewords = items.filter { $0.action == .reword }.count
        return min(380, CGFloat(items.count) * 38 + CGFloat(rewords) * 80 + 8)
    }

    /// The squashed commits (read only), then the message card.
    @ViewBuilder private var squashCards: some View {
        let count = squashCount
        SectionCard("Commits", systemImage: "list.bullet", count: count) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items.prefix(count)) { item in
                    HStack(spacing: 8) {
                        Text(item.commit.prefix(7))
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                        Text(item.subject)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
        SectionCard("Message", systemImage: "text.alignleft") {
            TextEditor(text: $message)
                .font(.body)
                .frame(height: 140)
                .settingsTextEditor()
        }
    }

    /// The squash todo picks the oldest and squashes the others; the commits after them stay picks.
    private var squashCount: Int {
        if case .squash(let commits) = request.kind { min(commits.count, items.count) } else { 0 }
    }

    /// What keeps Start disabled (the core refuses the same), shown under the cards.
    private var problem: String? {
        guard todo.value != nil else { return nil }
        // In both modes: the first kept row has nothing to fold into when it is a squash or a fixup.
        if let first = items.first(where: { $0.action != .drop }), [.squash, .fixup].contains(first.action) {
            return RebaseTodoError.nothingToFoldInto(first.commit).message
        }
        if isSquash {
            return message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? RebaseTodoError.emptyMessage(items.first?.commit ?? "").message : nil
        }
        if let empty = items.first(where: {
            $0.action == .reword && ($0.newMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return RebaseTodoError.emptyMessage(empty.commit).message
        }
        return nil
    }

    // MARK: Actions

    private func load() async {
        do {
            let loaded = try await session.loadRebaseTodo(request.kind)
            items = loaded.items
            message = loaded.items.first?.newMessage ?? ""
            todo = .loaded(loaded)
        } catch {
            if !(error is CancellationError) { todo = .failed(RepoSession.writeMessage(for: error)) }
        }
    }

    private func start() {
        guard var run = todo.value, problem == nil else { return }
        run.items = items
        if isSquash, !run.items.isEmpty { run.items[0].newMessage = message }
        session.startRebase(run)
        onClose()
    }
}

// MARK: - Rows

/// One commit of the todo: its action (a capsule menu), short id and subject (struck through when dropped); a reword
/// row shows its message editor under it.
private struct RebaseRow: View {
    @Binding var item: RebaseTodo.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .help("Drag to reorder")
                CapsuleMenuPicker(label: "Action", selection: action, title: Text(item.action.title)) {
                    ForEach(RebaseTodo.Action.allCases, id: \.self) { action in
                        Text(action.title).tag(action)
                    }
                }
                .help(item.action.help)
                Text(item.commit.prefix(7))
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                Text(item.subject)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .strikethrough(item.action == .drop)
                    .foregroundStyle(item.action == .drop ? .secondary : .primary)
                Spacer(minLength: 0)
            }
            if item.action == .reword {
                TextEditor(text: newMessage)
                    .font(.body)
                    .frame(height: 64)
                    .settingsTextEditor()
            }
        }
        .padding(.vertical, 2)
    }

    /// A row that becomes reword starts from its message; a row that leaves it drops the new message, which the todo
    /// would otherwise still apply to a pick.
    private var action: Binding<RebaseTodo.Action> {
        Binding {
            item.action
        } set: { action in
            item.action = action
            if action == .reword {
                if item.newMessage == nil { item.newMessage = item.message.trimmingCharacters(in: .newlines) }
            } else {
                item.newMessage = nil
            }
        }
    }

    private var newMessage: Binding<String> {
        Binding { item.newMessage ?? "" } set: { item.newMessage = $0 }
    }
}

/// The rows' shape while the commits load: action capsule, id, subject; the spinner only after 150 ms.
private struct RebaseSkeleton: View {
    let rows: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<max(rows, 1), id: \.self) { row in
                HStack(spacing: 10) {
                    SkeletonLine(width: 70, height: 14)
                    SkeletonLine(width: 52, height: 12)
                    SkeletonLine(fraction: [0.7, 0.5, 0.85, 0.6][row % 4], height: 12)
                }
            }
        }
        .padding(.vertical, 4)
        .overlay { DelayedSpinner(detail: "rebase") }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}

extension RebaseTodo.Action {
    var title: String {
        switch self {
        case .pick: "Pick"
        case .reword: "Reword"
        case .edit: "Edit"
        case .squash: "Squash"
        case .fixup: "Fixup"
        case .drop: "Drop"
        }
    }

    var help: String {
        switch self {
        case .pick: "Keep the commit as it is."
        case .reword: "Keep the commit with a new message."
        case .edit: "Stop after this commit to amend it; Continue goes on."
        case .squash: "Fold into the commit above, keeping both messages."
        case .fixup: "Fold into the commit above, keeping only its message."
        case .drop: "Leave the commit out."
        }
    }
}
