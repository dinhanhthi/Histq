// A file's diff in panel2, in place of the graph (Esc or the back button returns to it), each part in its own card:
// the header (back, the file, its status, +N −M, Diff / Full file), then one card per side of the change (a WIP file's
// Unstaged and Staged changes, a commit's changes), or a card that says why there are no lines (binary, too large, no
// change). The diff loads off the main actor; until then the cards are skeletons.
import HistqCore
import SwiftUI

/// A file whose diff panel2 shows: a WIP file (its unstaged and staged changes) or a file of a commit or a stash.
struct FileTarget: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case wip
        /// A commit or a stash, by its hash.
        case commit(String)
    }

    let source: Source
    let file: FileChange

    var path: String { file.path }
}

/// Hunks with git's context, or the whole file with its changes marked.
enum DiffMode: String, Hashable, Sendable, CaseIterable {
    case diff, full

    var title: String {
        switch self {
        case .diff: "Diff"
        case .full: "Full file"
        }
    }
}

/// A loaded file diff. `loadID` changes with every load, so the tables know a reload (after a stage) from a redraw.
struct FileDiffDetail: Sendable {
    enum Content: Sendable {
        /// One card per side with changes.
        case sections([DiffSection])
        case binary
        /// Over `RepoSession.fileSizeLimit`: the largest side's size in bytes.
        case tooLarge(Int)
        /// git printed no diff for the file (it has no change left).
        case unchanged
    }

    let loadID: Int
    let content: Content

    init(loadID: Int, content: Content) {
        self.loadID = loadID
        self.content = content
    }

    /// The sections with changes; a binary side makes the whole file binary.
    init(loadID: Int, sections: [DiffSection]) {
        self.loadID = loadID
        content = sections.isEmpty ? .unchanged : sections.contains(where: \.isBinary) ? .binary : .sections(sections)
    }

    var additions: Int? {
        if case .sections(let sections) = content { sections.reduce(0) { $0 + $1.additions } } else { nil }
    }

    var deletions: Int? {
        if case .sections(let sections) = content { sections.reduce(0) { $0 + $1.deletions } } else { nil }
    }
}

/// Panel2 while a file is open: the header card at once, then the diff's cards (skeletons until loaded).
struct DiffView: View {
    let session: RepoSession
    let target: FileTarget
    @Environment(WindowModel.self) private var model

    var body: some View {
        VStack(spacing: SectionCardMetrics.spacing) {
            DiffHeaderCard(session: session, target: target)
            Group {
                switch session.fileDiff {
                case .idle, .loading:
                    PlaceholderCard(
                        token: session.fileToken, detail: session.fileDetail,
                        isCurrent: { [model, session] in model.selectedSession === session && session.openFile != nil }
                    ) {
                        DiffPlaceholder()
                    }
                case .loaded(let detail):
                    DiffContent(session: session, detail: detail)
                        .onAppear { UITiming.content(session.fileDetail) }
                case .failed(let message):
                    DiffNoticeCard(title: "Diff", systemImage: "exclamationmark.triangle", message: message)
                        .onAppear { UITiming.content("\(session.fileDetail) failed") }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

/// Back, the file's icon, name and folder, its status, the line counts and the mode switch; a commit's file adds
/// "Checkout This Version". The counts are skeletons until the diff is in.
private struct DiffHeaderCard: View {
    let session: RepoSession
    let target: FileTarget

    var body: some View {
        @Bindable var session = session
        let file = target.file
        let detail = session.fileDiff.value
        SectionCard(nil, contentPadding: 8) {
            HStack(spacing: 8) {
                Button {
                    session.closeFile()
                } label: {
                    Image(systemName: "chevron.left")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(RowIconButtonStyle())
                .keyboardShortcut(.cancelAction)
                .help("Back to the Graph (Esc)")
                .accessibilityLabel("Back to the graph")
                .padding(.leading, 4)
                Image(systemName: file.systemImage)
                    .foregroundStyle(file.tint)
                    .accessibilityHidden(true)
                HStack(spacing: 4) {
                    Text(file.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if !file.folder.isEmpty {
                        Text(file.folder)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .help(file.originalPath.map { "\($0) → \(file.path)" } ?? file.path)
                Text(file.kindName)
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if case .commit = target.source, file.kind != .deleted {
                    Button("Checkout This Version") { session.checkoutVersion(of: target) }
                        .buttonStyle(RowTextButtonStyle())
                        .lineLimit(1)
                        .fixedSize()
                        .help("Replace the file in the working tree with this commit's version")
                }
                counts(detail)
                CapsuleTabs(selection: $session.diffMode, tabs: DiffMode.allCases, title: { Text($0.title) },
                            compact: true)
                    .fixedSize()
            }
            // As tall as the compact tabs' padded track (24 pt pills inset 4 pt), the sidebar's look.
            .frame(height: 32)
        }
    }

    @ViewBuilder private func counts(_ detail: FileDiffDetail?) -> some View {
        if let detail {
            if let additions = detail.additions, let deletions = detail.deletions {
                HStack(spacing: 6) {
                    Text("+\(additions)")
                        .foregroundStyle(Color(nsColor: Palette.diffAddedSign))
                    Text("−\(deletions)")
                        .foregroundStyle(Color(nsColor: Palette.diffRemovedSign))
                }
                .font(.callout.monospacedDigit().weight(.medium))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(additions) added, \(deletions) removed")
            }
        } else {
            SkeletonLine(width: 56, height: 11)
        }
    }
}

/// The loaded diff: a card per side (filling the panel together), or a card that says why there are no lines.
private struct DiffContent: View {
    let session: RepoSession
    let detail: FileDiffDetail

    var body: some View {
        switch detail.content {
        case .sections(let sections):
            // The cards with lines fill panel2 and share its height equally (each table scrolls); a side without
            // lines fits its text.
            VStack(spacing: SectionCardMetrics.spacing) {
                ForEach(sections) { section in
                    sectionCard(section)
                }
                if sections.allSatisfy({ $0.rows(session.diffMode).isEmpty }) {
                    Spacer(minLength: 0)
                }
            }
        case .binary:
            DiffNoticeCard(title: "Binary file", systemImage: "doc.zipper",
                           message: "Histq does not show the contents of binary files.")
        case .tooLarge(let bytes):
            DiffNoticeCard(
                title: "Large file", systemImage: "doc.badge.clock",
                message: "This file is \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)), "
                    + "over the \(ByteCountFormatter.string(fromByteCount: Int64(RepoSession.fileSizeLimit), countStyle: .file)) "
                    + "Histq shows at once."
            ) {
                Button("Load Anyway") { session.loadFileAnyway() }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
            }
        case .unchanged:
            DiffNoticeCard(title: "No changes", systemImage: "checkmark.circle",
                           message: "This file has no changes to show.")
        }
    }

    private func sectionCard(_ section: DiffSection) -> some View {
        let rows = section.rows(session.diffMode)
        return SectionCard(section.side.title, systemImage: section.side.systemImage, contentPadding: 0) {
            if rows.isEmpty {
                Text(modeOnlyText(section))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            } else {
                DiffLineTable(
                    section: section, mode: session.diffMode, loadID: detail.loadID,
                    onApply: { [session] action, lines, file in session.apply(action, lines: lines, of: file) },
                    onClose: { [session] in session.closeFile() })
                    .frame(maxHeight: .infinity)
            }
        } accessory: {
            HStack(spacing: 6) {
                Text("+\(section.additions)")
                    .foregroundStyle(Color(nsColor: Palette.diffAddedSign))
                Text("−\(section.deletions)")
                    .foregroundStyle(Color(nsColor: Palette.diffRemovedSign))
            }
            .font(.settingsCaption.monospacedDigit())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(section.additions) added, \(section.deletions) removed")
        }
    }

    /// A side without lines: a mode change, or an empty file added or deleted.
    private func modeOnlyText(_ section: DiffSection) -> String {
        if let diff = section.diff, diff.isModeChange, let old = diff.oldMode, let new = diff.newMode {
            return "Mode changed from \(old) to \(new)."
        }
        return "No line changes."
    }
}

/// A card with a message instead of lines (binary, too large, no change, a failed read), and an optional action.
private struct DiffNoticeCard<Action: View>: View {
    let title: String
    let systemImage: String
    let message: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        SectionCard(title, systemImage: systemImage) {
            VStack(alignment: .leading, spacing: 10) {
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                action()
            }
            // Fills panel2 like the line cards, no empty space below.
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private extension DiffNoticeCard where Action == EmptyView {
    init(title: String, systemImage: String, message: String) {
        self.init(title: title, systemImage: systemImage, message: message) { EmptyView() }
    }
}

/// The diff's skeleton: one card with a hunk header bar and line rows (number gutters and text capsules).
private struct DiffPlaceholder: View {
    private static let widths: [CGFloat] = [0.55, 0.7, 0.4, 0.62, 0.5, 0.75, 0.35, 0.6, 0.45, 0.66, 0.52, 0.3]

    var body: some View {
        VStack(spacing: SectionCardMetrics.spacing) {
            SectionCard("Changes", systemImage: "doc.text", countIsLoading: true, contentPadding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        SkeletonLine(fraction: 0.35, height: 10)
                        SkeletonLine(width: 72, height: 18)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: DiffLayout.hunkHeight)
                    ForEach(Self.widths.indices, id: \.self) { index in
                        HStack(spacing: 10) {
                            SkeletonLine(width: 20, height: 9)
                            SkeletonLine(width: 20, height: 9)
                            SkeletonLine(fraction: Self.widths[index], height: 10)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: DiffLayout.lineHeight)
                    }
                }
                .padding(.bottom, 8)
                // The loaded cards fill panel2: so does their skeleton.
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }
}
