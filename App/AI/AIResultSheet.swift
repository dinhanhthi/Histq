// The AI actions' result, an in-window `ModalCard` (never a native sheet), opened by the AI buttons: Generate Message
// (commit box), Explain (commit details, WIP) and Suggest Resolution (conflict editor). A click opens the card in its
// frame with a skeleton; the diff is read and the prompt built off the main actor, then the answer streams in as a
// preview (`AIPrompt.preview`). Apply uses only `AIPrompt.answer(from:)`: a commit message fills the commit box, a
// resolution replaces the current conflict region's Output as a manual edit (never saved or staged). Copy copies the
// answer; Cancel stops the stream at once and closes the card. Errors show their `description`, never a key.
import AppKit
import HistqCore
import SwiftUI

/// What an AI button asks for.
enum AIJob: Equatable, Sendable {
    case commitMessage
    /// `message`: the commit's subject and body.
    case explainCommit(hash: String, message: String)
    case explainWorkingChanges
    case resolution(AIResolutionTarget)

    var title: String {
        switch self {
        case .commitMessage: "Commit message"
        case .explainCommit(let hash, _): "Explain commit \(hash.prefix(7))"
        case .explainWorkingChanges: "Explain the uncommitted changes"
        case .resolution(let target): "Resolve conflict \(target.conflict + 1) of \(target.path)"
        }
    }

    /// The timing log's name of the job.
    var logName: String {
        switch self {
        case .commitMessage: "commit-message"
        case .explainCommit: "explain-commit"
        case .explainWorkingChanges: "explain-wip"
        case .resolution: "resolution"
        }
    }

    /// What the card says while the job's content is read.
    var preparing: String {
        switch self {
        case .commitMessage: "Reading the staged changes…"
        case .explainCommit: "Reading the commit…"
        case .explainWorkingChanges: "Reading the uncommitted changes…"
        case .resolution: "Preparing the conflict…"
        }
    }

    /// Whether the answer can be applied (an explanation is only shown and copied).
    var canApply: Bool {
        switch self {
        case .commitMessage, .resolution: true
        case .explainCommit, .explainWorkingChanges: false
        }
    }
}

/// One conflict region as it was when Suggest Resolution was clicked: Apply replaces that region only, and only while
/// the editor still shows the same load of the same file.
struct AIResolutionTarget: Equatable, Sendable {
    let path: String
    let loadID: Int
    /// "conflict k of N" (0-based).
    let conflict: Int
    /// The index of the conflict's region in `ThreeWayMerge.regions`.
    let region: Int
    /// nil for an add/add conflict, which has no base.
    let base: String?
    let a: String
    let b: String
    /// The file's line break ("\r\n" or "\n", `ThreeWayMerge.lineBreak`): the answer is converted to it.
    let lineBreak: String
    /// The region ends with a line break (`ThreeWayMerge.needsFinalBreak(region:)`); `AIPrompts.resolutionText` adds
    /// or drops the answer's final one to match.
    let needsFinalBreak: Bool
}

/// Why a job could not start; shown in the card.
enum AIJobError: Error, CustomStringConvertible {
    case nothingStaged
    case noChanges

    var description: String {
        switch self {
        case .nothingStaged: "Nothing is staged. Stage the changes the message should describe."
        case .noChanges: "There are no changes to explain (new untracked files are not included)."
        }
    }
}

/// A running or finished AI job: the prompt, the reply so far, and the outcome. The job runs in `task`, which the
/// card's Cancel, Escape, a tab or page change, closing the tab or window, a new job and the run's own deinit cancel
/// (that drops the stream and stops the request).
@Observable
@MainActor
final class AIRun: Identifiable {
    enum Phase: Equatable {
        case preparing
        case streaming
        /// The answer block, ready to apply or copy.
        case finished(String)
        case failed(String)
    }

    let id = UUID()
    let job: AIJob
    let provider: AIProvider
    let model: String
    private(set) var phase = Phase.preparing
    /// What the card shows of the reply so far (the answer block only).
    private(set) var preview = ""
    private(set) var reply = ""
    /// Not observed, so `deinit` (nonisolated) can cancel it.
    @ObservationIgnored private var task: Task<Void, Never>?

    init(job: AIJob, provider: AIProvider, model: String) {
        self.job = job
        self.provider = provider
        self.model = model
    }

    deinit {
        // The task holds only a weak reference: without this, a run dropped with its tab or window would still read
        // the key and send the content.
        task?.cancel()
    }

    var answer: String? {
        if case .finished(let answer) = phase { return answer }
        return nil
    }

    var isRunning: Bool { phase == .preparing || phase == .streaming }

    /// Reads the job's content and streams the answer. `prompt` runs off the main actor (git reads, the diff budget).
    func start(prompt: @escaping @Sendable () async throws -> AIPrompt) {
        task?.cancel()
        let provider = provider
        let model = model
        task = Task { [weak self] in
            do {
                let prompt = try await prompt()
                try Task.checkCancellation()
                let client = try await AISetup.shared.makeClient(for: provider)
                // The last point before anything leaves the Mac: a run cancelled or dropped meanwhile sends nothing.
                guard self != nil, !Task.isCancelled else { return }
                self?.phase = .streaming
                var shown = ContinuousClock.now
                do {
                    for try await piece in client.stream(prompt.request(model: model)) {
                        guard let self else { return }
                        reply += piece
                        // `preview(of:)` reads the whole reply, so one call per piece is quadratic: at most ~20 a
                        // second, but at once while nothing shows (the first words' timing and the cancel seam).
                        guard preview.isEmpty || ContinuousClock.now - shown >= .milliseconds(50) else { continue }
                        preview = prompt.preview(of: reply)
                        shown = .now
                    }
                } catch {
                    // A failed stream shows what came with the error: the throttle may have held back the end.
                    if let self { preview = prompt.preview(of: reply) }
                    throw error
                }
                try Task.checkCancellation()
                guard let self else { return }
                preview = prompt.preview(of: reply)
                do {
                    phase = .finished(try prompt.answer(from: reply))
                } catch {
                    phase = .failed(String(describing: error))
                }
            } catch {
                guard !(error is CancellationError), !Task.isCancelled else { return }
                self?.phase = .failed(String(describing: error))
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// The card of an `AIRun` (`ModalHost`).
struct AIResultSheet: View {
    let session: RepoSession
    let run: AIRun
    let onClose: () -> Void
    @State private var applyError: String?
    @State private var copied = false
    /// The first words (or the outcome) showed: logged once.
    @State private var contentLogged = false
    #if DEBUG
    @Environment(WindowModel.self) private var windowModel
    #endif

    private var detail: String { "ai \(run.job.logName)" }

    var body: some View {
        ModalCard(title: run.job.title, subtitle: "\(run.provider.displayName) · \(run.model)", systemImage: "sparkles",
                  width: 560, takesFocus: true) {
            ModalSection(spacing: 8) {
                previewBox
                statusLine
            }
        } actions: {
            Button(run.isRunning ? "Cancel" : "Close", action: onClose)
                .buttonStyle(RowTextButtonStyle(formRow: true))
                .keyboardShortcut(.cancelAction)
                .help(run.isRunning ? "Stop the answer and close" : "Close")
            Button(copied ? "Copied" : "Copy", action: copy)
                .buttonStyle(RowTextButtonStyle(formRow: true))
                .disabled(run.answer == nil)
            if run.job.canApply {
                Button("Apply", action: apply)
                    .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(run.answer == nil)
                    .help(applyHelp)
            }
        }
        .onAppear {
            UITiming.placeholder(detail)
            #if DEBUG
            debugClose()
            #endif
        }
        .onChange(of: run.preview.isEmpty) { _, empty in
            if !empty { logContent() }
        }
        .onChange(of: run.phase) { _, phase in
            if !run.isRunning { logContent() }
            #if DEBUG
            debugFinished(phase)
            #endif
        }
        #if DEBUG
        .onChange(of: run.preview.count) { _, count in debugCancel(count) }
        #endif
    }

    private var applyHelp: String {
        switch run.job {
        case .commitMessage: "Fill the commit box's summary and description"
        case .resolution: "Replace this conflict's Output (not saved until you click Save)"
        default: ""
        }
    }

    private func logContent() {
        guard !contentLogged else { return }
        contentLogged = true
        UITiming.content(detail)
    }

    // MARK: Parts

    @ViewBuilder
    private var previewBox: some View {
        let text = run.answer ?? run.preview
        Group {
            if text.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SkeletonLine(fraction: 0.7, height: 12)
                    SkeletonLine(fraction: 0.9, height: 12)
                    SkeletonLine(fraction: 0.55, height: 12)
                    SkeletonLine(fraction: 0.8, height: 12)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .overlay {
                    if run.isRunning { DelayedSpinner(detail: detail) }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Waiting for the answer")
            } else {
                ScrollView {
                    previewText(text)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                }
                .defaultScrollAnchor(.bottom)
            }
        }
        .frame(height: AIResultMetrics.previewHeight)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: SettingsInputMetrics.cornerRadius, style: .continuous)
            .fill(Palette.inputSurface))
    }

    @ViewBuilder
    private func previewText(_ text: String) -> some View {
        switch run.job {
        case .resolution:
            Text(verbatim: text)
                .font(.body.monospaced())
                .textSelection(.enabled)
        case .explainCommit, .explainWorkingChanges:
            Text(Self.markdown(text))
                .textSelection(.enabled)
        case .commitMessage:
            Text(verbatim: text)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch run.phase {
        case .preparing:
            statusText(run.job.preparing)
        case .streaming:
            statusText(run.preview.isEmpty ? "Waiting for \(run.provider.displayName)…" : "Writing…")
        case .finished:
            if let applyError {
                ErrorText(message: applyError)
            } else {
                statusText(run.job.canApply ? "Review the answer, then apply it." : "Done.")
            }
        case .failed(let message):
            ErrorText(message: message)
        }
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.settingsCaption)
            .foregroundStyle(.secondary)
    }

    /// Inline markdown (bold, italic, code) with the line breaks kept; links are shown as plain text, never opened.
    private static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var styled = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        // The answer is steered by untrusted repo content (a commit message or diff can ask for a link), so no run
        // stays clickable: a link's text is kept as plain text and its target is dropped.
        for run in styled.runs where run.link != nil {
            styled[run.range].link = nil
        }
        return styled
    }

    // MARK: Actions

    private func copy() {
        guard let answer = run.answer else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
        copied = true
    }

    private func apply() {
        guard let answer = run.answer else { return }
        switch run.job {
        case .commitMessage:
            session.applyAICommitMessage(answer)
            onClose()
        case .resolution(let target):
            if let error = session.applyAIResolution(answer, to: target) {
                applyError = error
            } else {
                onClose()
            }
        case .explainCommit, .explainWorkingChanges:
            break
        }
    }

    #if DEBUG
    /// DEBUG `-HistqAI <hook>,apply`: applies the finished answer as the Apply button does; logs the outcome.
    private func debugFinished(_ phase: AIRun.Phase) {
        switch phase {
        case .finished(let answer):
            let firstLine = answer.split(separator: "\n").first.map(String.init) ?? ""
            AIStub.log("finished \(run.job.logName) chars \(answer.count) first-line \(AIStub.quoted(firstLine))")
            guard AIStub.seamOptions.contains("apply") else { return }
            let before = session.conflict.value?.merge
            apply()
            AIStub.log("apply \(run.job.logName) error \(applyError ?? "none") card-open \(session.aiRun != nil)")
            switch run.job {
            case .commitMessage:
                let draft = session.commitDraft
                AIStub.log("commit-box summary \(AIStub.quoted(draft.summary)) description "
                    + AIStub.quoted(draft.description))
            case .resolution(let target):
                guard let before, let after = session.conflict.value?.merge else { return }
                let manual = after.regions.indices.filter { after.regions[$0].isManual }
                let changed = after.regions.indices.filter {
                    after.regions[$0].isManual != before.regions[$0].isManual
                        || after.regions[$0].isUnresolved != before.regions[$0].isUnresolved
                }
                let region = after.regions[target.region]
                AIStub.log("resolution conflict \(target.conflict) region \(target.region) manual-regions \(manual) "
                    + "changed-regions \(changed) unresolved \(before.unresolvedCount)->\(after.unresolvedCount) "
                    + "line-break \(AIStub.quoted(target.lineBreak)) output \(AIStub.quoted(after.outputLines[region.output].joined()))")
            case .explainCommit, .explainWorkingChanges:
                break
            }
        case .failed(let message):
            AIStub.log("failed \(run.job.logName): \(message)")
        case .preparing, .streaming:
            break
        }
    }

    /// DEBUG `-HistqAI <hook>,close-tab|close-window`: closes the card's tab (another tab must stay open) or window
    /// while the job still reads its content, as ⌘W would; ai.log must then show no stub request.
    private func debugClose() {
        let options = AIStub.seamOptions
        let closesTab = options.contains("close-tab")
        guard closesTab || options.contains("close-window") else { return }
        AIStub.log("close-\(closesTab ? "tab" : "window") \(run.job.logName) phase "
            + (run.phase == .preparing ? "preparing" : String(describing: run.phase)))
        if closesTab {
            guard let id = windowModel.sessions.first(where: { $0.value === session })?.key else { return }
            _ = windowModel.closeTab(id: id)
        } else {
            windowModel.closeWindow()
        }
    }

    /// DEBUG `-HistqAI <hook>,cancel`: Cancel as soon as the first words show.
    private func debugCancel(_ count: Int) {
        guard count > 0, run.isRunning, AIStub.seamOptions.contains("cancel") else { return }
        AIStub.log("cancel \(run.job.logName) after reply chars \(run.reply.count)")
        onClose()
    }
    #endif
}

enum AIResultMetrics {
    /// Tall enough for a commit message or a short explanation without scrolling; fits the smallest window.
    static let previewHeight: CGFloat = 240
}

/// An AI button of a card: disabled, with a tooltip saying where to set one up, while the active provider is not set
/// up; `unavailable` disables it for a reason of its own (nothing staged). A click only opens the result card: nothing
/// is sent before it.
struct AIHookButton: View {
    let title: String
    var systemImage: String?
    var help: String
    var unavailable: String?
    /// DEBUG `-HistqAI <seam>`: the hook a QA launch clicks.
    var seam: String
    let action: () -> Void

    private var setup: AISetup { .shared }

    var body: some View {
        let reason = setup.isReady ? unavailable : AISetup.setUpHint
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .lineLimit(1)
            }
        }
        .buttonStyle(RowTextButtonStyle())
        .fixedSize()
        .disabled(reason != nil)
        .help(reason ?? help)
        .onAppear { setup.loadKeysIfNeeded() }
        #if DEBUG
        .task(id: reason == nil) {
            guard reason == nil, AIStub.takeSeam(seam) else { return }
            action()
        }
        #endif
    }
}
