// The card at the top of panel2 while a merge, rebase, cherry-pick or revert is stopped: what is in progress, how many
// files still have conflicts, and its buttons: Continue (disabled until no file is conflicted), Abort (confirmed) and,
// in a rebase, Skip (confirmed). Each runs through the session's write path; the status read after it updates the
// banner, or removes it once the operation is over.
import HistqCore
import SwiftUI

/// Nothing while no operation is in progress (`RepoSession.repoState`).
struct OperationBanner: View {
    let session: RepoSession

    var body: some View {
        if let state = session.repoState, state.isOperationInProgress {
            card(state)
        }
    }

    private func card(_ state: RepoState) -> some View {
        let conflicts = session.status.value?.conflicted.count ?? state.conflictedPaths.count
        let isBusy = session.isOperationStepRunning
        return SectionCard(nil, contentPadding: 10) {
            HStack(spacing: 10) {
                Image(systemName: Self.systemImage(state.operation))
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 16))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    // The start says what is in progress; a long commit subject at the end gives way first.
                    Text(Self.title(state))
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(Self.title(state))
                    Text(conflicts == 0
                        ? "All conflicts are resolved. Continue to finish."
                        : conflicts == 1 ? "1 conflicted file left. Resolve it to continue."
                        : "\(conflicts) conflicted files left. Resolve them to continue.")
                        .font(.settingsCaption)
                        .foregroundStyle(conflicts == 0 ? AnyShapeStyle(.secondary)
                            : AnyShapeStyle(Color(nsColor: Palette.conflictUnresolved)))
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                if state.operation == .rebase {
                    button("Skip", step: .skip, state: state) { session.skipOperation() }
                        .disabled(isBusy)
                        .help("Leave the commit being replayed out of the branch")
                }
                button("Abort", step: .abort, state: state) { session.abortOperation() }
                    .disabled(isBusy)
                    .help("Go back to before the \(Self.noun(state.operation))")
                button("Continue", step: .continue, state: state, prominent: true) { session.continueOperation() }
                    .disabled(!session.canContinueOperation)
                    .help(conflicts == 0 ? "Finish this step" : "Resolve every conflicted file first")
            }
        }
    }

    /// A banner button; a small spinner beside its title while its step runs.
    private func button(
        _ title: String, step: RepoSession.OperationStep, state: RepoState, prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let isRunning = session.running.contains { $0.title == RepoSession.title(of: step, state.operation) }
        return Button(action: action) {
            HStack(spacing: 6) {
                if isRunning { ProgressView().controlSize(.mini) }
                Text(title)
            }
        }
        .buttonStyle(RowTextButtonStyle(formRow: true, prominent: prominent))
    }

    /// "Merging feature into main", "Rebasing onto main: replaying 1a2b3c4 Fix it". The labels come from `RepoState`
    /// (pane A and pane B of the conflict editor).
    private static func title(_ state: RepoState) -> String {
        let a = state.labels.a, b = state.labels.b
        return switch state.operation {
        case .merge: "Merging \(b) into \(a)"
        case .rebase: "Rebasing onto \(a): replaying \(b)"
        case .cherryPick: "Cherry-picking \(b) onto \(a)"
        case .revert: "Reverting \(b.hasPrefix("Revert ") ? String(b.dropFirst("Revert ".count)) : b) on \(a)"
        case .none: ""
        }
    }

    private static func noun(_ operation: RepoState.Operation) -> String {
        switch operation {
        case .merge: "merge"
        case .rebase: "rebase"
        case .cherryPick: "cherry-pick"
        case .revert: "revert"
        case .none: "operation"
        }
    }

    private static func systemImage(_ operation: RepoState.Operation) -> String {
        switch operation {
        case .merge: "arrow.triangle.merge"
        case .rebase: "arrow.triangle.branch"
        case .cherryPick: "arrow.turn.down.right"
        case .revert: "arrow.uturn.backward"
        case .none: "circle"
        }
    }
}
