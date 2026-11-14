// The window's modals (task 9.6): the repo operation's forms, confirmations, host-key and rebase cards
// (`RepoSession`), and the window's own (`WindowModel.modal`: a view's confirmation, Generate Key). Drawn in the window
// like the command palette, not as sheets: a scrim over the content `MainView` blurs, then the card in the middle. It
// shows in the frame that sets its state. Escape cancels; the focus moves into the card and goes back to the view
// that had it once it closes. The AppKit toolbar stays live above the scrim: a tab or page change cancels the modal.
// Settings (task 9.7) is the bottom layer: the modals it opens (Generate Key, a profile's deletion) and a form a
// toolbar action opens meanwhile stack above it, with their own scrim, while its card is blurred and disabled.
import AppKit
import SwiftUI

extension EnvironmentValues {
    /// The most height a modal's card may take in the window (`ModalHost`'s layer, less its margins); nil until laid
    /// out. A form taller than that scrolls its content and keeps its buttons in view.
    @Entry var modalAvailableHeight: CGFloat?
}

/// A modal of the window that is not a repo operation's.
enum WindowModal: Identifiable {
    case confirmation(ModalConfirmation)
    /// Settings › SSH › Generate Key… for a profile.
    case generateKey(profileID: UUID)

    var id: String {
        switch self {
        case .confirmation(let confirmation): "confirm \(confirmation.title)"
        case .generateKey(let id): "generate key \(id)"
        }
    }
}

/// The modal on screen, its own view: only this view reads the modal state, so opening one never re-evaluates
/// `MainView`.
struct ModalHost: View {
    let model: WindowModel
    /// The modal layer's height, once laid out.
    @State private var layerHeight: CGFloat?

    /// One modal at a time; a window modal first, then the shown tab's (only one of those is set in practice).
    private enum Shown {
        case window(WindowModal)
        case confirmation(RepoSession, OperationConfirmation)
        case hostKey(RepoSession, HostKeyCheck)
        case dialog(RepoSession, OperationDialog)
        case rebase(RepoSession, RebaseRequest)
        case worktree(RepoSession, WorktreeForm)
        case pullRequest(RepoSession, PullRequestForm)
        case ai(RepoSession, AIRun)

        var id: String {
            switch self {
            case .window(let modal): modal.id
            case .confirmation(_, let confirmation): "confirm \(confirmation.id)"
            case .hostKey(_, let check): "host key \(check.id)"
            case .dialog(_, let dialog): "dialog \(dialog.id)"
            case .rebase(_, let request): "rebase \(request.id)"
            case .worktree(_, let form): "worktree \(form.id)"
            case .pullRequest(_, let form): "pull request \(form.id)"
            case .ai(_, let run): "ai \(run.id)"
            }
        }

        /// A click on the scrim cancels a confirmation, which has nothing to lose; a form keeps its input.
        var closesOnScrimTap: Bool {
            switch self {
            case .window(.confirmation), .confirmation: true
            default: false
            }
        }
    }

    private var shown: Shown? {
        if let modal = model.modal { return .window(modal) }
        // Only on the tab's page: About has no repo modal.
        guard let session = model.actionSession else { return nil }
        if let confirmation = session.confirmation { return .confirmation(session, confirmation) }
        if let check = session.hostKeyCheck { return .hostKey(session, check) }
        if let dialog = session.dialog { return .dialog(session, dialog) }
        if let request = session.rebaseRequest { return .rebase(session, request) }
        if let form = session.worktreeForm { return .worktree(session, form) }
        if let form = session.pullRequestForm { return .pullRequest(session, form) }
        if let run = session.aiRun { return .ai(session, run) }
        return nil
    }

    var body: some View {
        let shown = self.shown
        // Always there (an empty stack draws nothing and takes no clicks), so a tab or page change that hides the
        // modal in the same update still reaches the `onChange`s below.
        ZStack {
            // Under the other modals, never replaced by them: its section, profile and scroll stay as they were.
            if model.isSettingsOpen {
                SettingsLayer(model: model, isCovered: shown != nil)
            }
            if let shown {
                ZStack {
                    ModalScrim { if shown.closesOnScrimTap { cancel(shown) } }
                    card(shown)
                        .environment(\.modalAvailableHeight,
                                     layerHeight.map { max(0, $0 - 2 * ModalMetrics.margin) })
                        .padding(ModalMetrics.margin)
                }
                // The scrim fills the window under the toolbar: a tall form fits its card in that (`CreatePRView`).
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { layerHeight = $0 }
                // A new view per modal: the focus to restore starts over.
                .id(shown.id)
                .modifier(RestoresFocus())
                .onExitCommand { cancel(shown) }
            }
        }
        // The toolbar stays live above the scrim: the modal acts on the tab and page it opened on, so a change of
        // either cancels it.
        .onChange(of: model.selectedTabID) { old, _ in
            if let old, let session = model.sessions[old], session.hasModal { session.closeModals() }
            if model.modal != nil { model.closeModal() }
        }
        .onChange(of: model.navigation.page) {
            if let session = model.selectedSession, session.hasModal { session.closeModals() }
            if model.modal != nil { model.closeModal() }
        }
    }

    @ViewBuilder
    private func card(_ shown: Shown) -> some View {
        switch shown {
        case .window(.confirmation(let confirmation)):
            ConfirmationModal(title: confirmation.title, message: confirmation.message, button: confirmation.button,
                              isDestructive: confirmation.isDestructive) {
                model.closeModal()
                confirmation.perform()
            } onCancel: {
                model.closeModal()
            }
        case .window(.generateKey(let profileID)):
            GenerateKeyModal(profileID: profileID) { model.closeModal() }
        case .confirmation(let session, let confirmation):
            ConfirmationModal(title: confirmation.title, message: confirmation.message, button: confirmation.button,
                              isDestructive: confirmation.isDestructive) {
                session.confirmation = nil
                session.run(confirmation.write, title: confirmation.operation, key: confirmation.key)
            } onCancel: {
                session.confirmation = nil
            }
        case .hostKey(let session, let check):
            HostKeySheet(session: session, check: check) { session.hostKeyCheck = nil }
        case .dialog(let session, let dialog):
            OperationDialogView(session: session, dialog: dialog) { session.dialog = nil }
        case .rebase(let session, let request):
            InteractiveRebaseView(session: session, request: request) { session.rebaseRequest = nil }
        case .worktree(let session, let form):
            AddWorktreeView(session: session, form: form) { session.worktreeForm = nil }
        case .pullRequest(let session, let form):
            CreatePRView(session: session, form: form) { session.pullRequestForm = nil }
        case .ai(let session, let run):
            AIResultSheet(session: session, run: run) { session.closeAI() }
        }
    }

    private func cancel(_ shown: Shown) {
        switch shown {
        case .window: model.closeModal()
        case .confirmation(let session, _): session.confirmation = nil
        case .hostKey(let session, _): session.hostKeyCheck = nil
        case .dialog(let session, _): session.dialog = nil
        case .rebase(let session, _): session.rebaseRequest = nil
        case .worktree(let session, _): session.worktreeForm = nil
        case .pullRequest(let session, _): session.pullRequestForm = nil
        case .ai(let session, _): session.closeAI()
        }
    }
}

/// The Settings modal (task 9.7) over the window content: a click on its scrim, Escape and the card's close button
/// close it. As large as the window allows (`ModalMetrics.margin` around it), up to `SettingsModalMetrics.maxWidth`.
private struct SettingsLayer: View {
    let model: WindowModel
    /// Another modal shows above it.
    let isCovered: Bool

    var body: some View {
        ZStack {
            ModalScrim { model.closeSettings() }
            SettingsModal { model.closeSettings() }
                .padding(ModalMetrics.margin)
        }
        .modifier(RestoresFocus())
        .onExitCommand { model.closeSettings() }
        // Behind a modal it opened, like the window content behind any modal.
        .modifier(ModalBackdrop(isActive: isCovered))
    }
}

/// Remembers the view that had the focus when the modal opened (not a text field's editor) and gives it the focus
/// back once the modal closes, on the next turn (Escape releases the field editor on its own turn).
private struct RestoresFocus: ViewModifier {
    @State private var previous = WeakView()

    func body(content: Content) -> some View {
        content
            .onAppear {
                if let responder = NSApp.keyWindow?.firstResponder as? NSView,
                   !((responder as? NSTextView)?.isFieldEditor ?? false)
                {
                    previous.view = responder
                }
            }
            .onDisappear {
                guard let view = previous.view else { return }
                DispatchQueue.main.async {
                    guard let window = view.window, window.isKeyWindow else { return }
                    window.makeFirstResponder(view)
                }
            }
    }

    /// Weak, so a closed tab's view is not kept alive by the modal.
    private final class WeakView {
        weak var view: NSView?
    }
}
