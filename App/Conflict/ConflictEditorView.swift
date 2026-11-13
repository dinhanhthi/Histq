// A conflicted file in panel2, in place of the graph (GitKraken's layout), each part in its own card: the header (the
// file, its conflict count, the encoding, "Open in external merge tool", Save, close), then panes A and B side by
// side in one card (the two sides' whole files, conflict lines tinted with checkboxes) above Output (the merge,
// editable, with "conflict k of N"). A binary file or a file deleted on one side gets a chooser card instead. The
// stages load off the main actor; until then the cards are skeletons.
import HistqCore
import SwiftUI

extension FileTarget {
    /// A WIP file with unmerged index entries: it opens the conflict editor, not a diff.
    var isConflict: Bool { source == .wip && file.kind == .conflicted }
}

/// A loaded conflicted file: its stages, the merge with the resolution so far, and what the pane headers name.
struct ConflictDocument: Sendable {
    let loadID: Int
    let source: ConflictSource
    /// The 3-way merge of a text conflict, with the ticks and edits; nil for a binary or modify/delete conflict.
    var merge: ThreeWayMerge?
    /// Panes A and B's lines without their line breaks (display only).
    let aLines: [String]
    let bLines: [String]
    /// The short hashes of the commits A and B come from, when known.
    let aCommit: String?
    let bCommit: String?
    /// "UTF-8", or "Not UTF-8" when a side has bytes that are not: they show as U+FFFD, ticks save their bytes, and
    /// Output is read-only (a typed edit is saved as UTF-8).
    let encoding: String

    var isUTF8: Bool { encoding == "UTF-8" }
    /// Changes with every tick or edit, so the panes redraw.
    var revision = 0
    /// The conflict "conflict k of N" names (0-based).
    var current = 0

    nonisolated init(loadID: Int, source: ConflictSource, aCommit: String?, bCommit: String?) {
        self.loadID = loadID
        self.source = source
        self.aCommit = aCommit
        self.bCommit = bCommit
        let merge = source.merge()
        self.merge = merge
        aLines = merge?.aLines.map(Self.display) ?? []
        bLines = merge?.bLines.map(Self.display) ?? []
        let sides: [Data?] = switch source.content {
        case .text(let base, let a, let b), .binary(let base, let a, let b): [base, a, b]
        case .modifyDelete(let base, let a, let b): [base, a, b]
        }
        encoding = sides.allSatisfy { $0.map { String(data: $0, encoding: .utf8) != nil } ?? true } ? "UTF-8" : "Not UTF-8"
    }

    /// A line without its `\n` (and the `\r` of a CRLF line).
    private nonisolated static func display(_ line: String) -> String {
        var line = Substring(line)
        if line.hasSuffix("\n") { line = line.dropLast() }
        if line.hasSuffix("\r") { line = line.dropLast() }
        return String(line)
    }
}

/// Panel2 while a conflicted file is open: the header card at once, then the editor's cards (skeletons until loaded).
struct ConflictEditorView: View {
    let session: RepoSession
    let target: FileTarget
    @Environment(WindowModel.self) private var model
    /// Links the three panes' scrolling; rebuilt with the view, the panes register again.
    @State private var sync = ScrollSync()

    var body: some View {
        VStack(spacing: SectionCardMetrics.spacing) {
            ConflictHeaderCard(session: session, target: target)
            Group {
                switch session.conflict {
                case .idle:
                    // Only while the editor closes (a select sets `.loading` at once): no placeholder, no timing line.
                    Color.clear
                case .loading:
                    PlaceholderCard(
                        token: session.fileToken, detail: session.fileDetail,
                        isCurrent: { [model, session] in model.selectedSession === session && session.openFile != nil }
                    ) {
                        ConflictPlaceholder()
                    }
                case .loaded(let document):
                    ConflictContent(session: session, document: document, sync: sync)
                        .onAppear { UITiming.content(session.fileDetail) }
                case .failed(let message):
                    SectionCard("Conflict", systemImage: "exclamationmark.triangle") {
                        Text(message)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .onAppear { UITiming.content("\(session.fileDetail) failed") }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

/// The ⚠ file name and "(N conflicts)", the encoding, the merge tool button, Save and close. The count and the
/// encoding are skeletons until the stages are in; a failed save shows under the row.
private struct ConflictHeaderCard: View {
    let session: RepoSession
    let target: FileTarget

    var body: some View {
        let document = session.conflict.value
        let isBusy = session.conflictBusy != nil
        SectionCard(nil, contentPadding: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color(nsColor: Palette.conflictB))
                        .padding(.leading, 4)
                        .accessibilityLabel("Conflicted")
                    Text(target.file.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(target.path)
                    if let document {
                        if let merge = document.merge {
                            Text(merge.conflictCount == 1 ? "(1 conflict)" : "(\(merge.conflictCount) conflicts)")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    } else {
                        SkeletonLine(width: 72, height: 11)
                    }
                    Spacer(minLength: 8)
                    if let document {
                        Text(document.encoding)
                            .font(.settingsCaption)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    } else {
                        SkeletonLine(width: 36, height: 9)
                    }
                    Button {
                        session.openMergeTool()
                    } label: {
                        Label("Open in external merge tool", systemImage: "arrow.up.forward.app")
                            .lineLimit(1)
                    }
                    .buttonStyle(RowTextButtonStyle())
                    .fixedSize()
                    .disabled(isBusy || document == nil)
                    .help("Runs git mergetool on this file (the tool set in Settings, else git's merge.tool)")
                    if document?.merge != nil {
                        Button {
                            session.saveConflict()
                        } label: {
                            Label(session.conflictBusy ?? "Save", systemImage: "square.and.arrow.down")
                                .lineLimit(1)
                        }
                        .buttonStyle(RowTextButtonStyle(prominent: true))
                        .fixedSize()
                        .disabled(isBusy || (document?.merge?.unresolvedCount ?? 1) > 0)
                        .help((document?.merge?.unresolvedCount ?? 1) > 0
                              ? "Resolve every conflict first: tick lines in A or B, or edit Output"
                              : "Save the Output and mark the file resolved (git add)")
                    }
                    Button {
                        session.closeFile()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(RowIconButtonStyle())
                    .help("Close (back to the graph; unsaved choices are lost)")
                    .accessibilityLabel("Close the conflict editor")
                    .padding(.trailing, 4)
                }
                .frame(height: 28)
                if let error = session.conflictError {
                    ErrorText(message: error)
                        .padding(.horizontal, 4)
                }
            }
        }
    }
}

/// The loaded editor: one card with A | B over Output for a text conflict, else the chooser card.
private struct ConflictContent: View {
    let session: RepoSession
    let document: ConflictDocument
    let sync: ScrollSync

    var body: some View {
        if let merge = document.merge {
            let _ = sync.merge = merge
            VStack(spacing: SectionCardMetrics.spacing) {
                // A and B in one card, side by side, split by a 1 pt line (a `Divider` in an HStack is vertical).
                SectionCard(nil, contentPadding: 0) {
                    HStack(spacing: 0) {
                        pane(.a, merge: merge)
                        Divider()
                        pane(.b, merge: merge)
                    }
                }
                .frame(maxHeight: .infinity)
                ConflictOutputCard(session: session, document: document, merge: merge, sync: sync)
                    .frame(maxHeight: .infinity)
            }
            .task(id: document.loadID) {
                // The first conflict in view in all three panes once they are laid out.
                try? await Task.sleep(for: .milliseconds(50))
                sync.jump(toConflict: document.current)
            }
        } else {
            ConflictChooserCard(session: session, document: document)
        }
    }

    /// One side's header (its tick-all checkbox, badge and title) over its lines.
    private func pane(_ side: ThreeWayMerge.Side, merge: ThreeWayMerge) -> some View {
        let isA = side == .a
        let lines = isA ? merge.conflictRegions.flatMap { Array(merge.regions[$0].a) }
            : merge.conflictRegions.flatMap { Array(merge.regions[$0].b) }
        let allTicked = !lines.isEmpty && lines.allSatisfy { merge.isTicked(side, line: $0) }
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { allTicked },
                    set: { [session] ticked in session.setConflictTickedAll(ticked, side: side) })
                ) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(lines.isEmpty || session.conflictBusy != nil)
                    .help(isA ? "Take every conflict line of A" : "Take every conflict line of B")
                SideBadge(side: side)
                PaneTitle(commit: isA ? document.aCommit : document.bCommit,
                          label: isA ? document.source.labels.a : document.source.labels.b, side: side)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            Divider()
            ConflictLinePane(
                side: side, lines: isA ? document.aLines : document.bLines, merge: merge,
                revision: document.revision, loadID: document.loadID, sync: sync,
                onTickLines: { [session] ticked, lines in session.setConflictTicked(ticked, side: side, lines: lines) },
                onTickConflict: { [session] ticked, k in session.setConflictTicked(ticked, side: side, conflict: k) })
                .frame(maxHeight: .infinity)
        }
        // Both panes get half the card, whatever their titles' widths.
        .frame(maxWidth: .infinity)
    }
}

/// "A" or "B" in a square of the side's color.
private struct SideBadge: View {
    let side: ThreeWayMerge.Side

    var body: some View {
        let color = Color(nsColor: side == .a ? Palette.conflictA : Palette.conflictB)
        Text(side == .a ? "A" : "B")
            .font(.callout.weight(.bold))
            .foregroundStyle(color)
            .frame(width: 20, height: 20)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(color, lineWidth: 1.5))
            .accessibilityLabel(side == .a ? "Side A" : "Side B")
    }
}

/// "Commit f0e8205 on main"; a label that already starts with the hash (a replayed commit's "abc1234 subject") shows
/// as "Commit abc1234 subject".
private struct PaneTitle: View {
    let commit: String?
    let label: String
    let side: ThreeWayMerge.Side

    var body: some View {
        let color = Color(nsColor: side == .a ? Palette.conflictA : Palette.conflictB)
        HStack(spacing: 4) {
            if let commit, label.hasPrefix(commit) {
                Text("Commit \(label)")
            } else {
                if let commit { Text("Commit \(commit) on") }
                Text(label)
                    .fontWeight(.semibold)
                    .italic()
                    .foregroundStyle(color)
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .help(label)
    }
}

/// Output's card: its title, "conflict k of N" with ▲ ▼ (all three panes jump there), and the editable merge.
private struct ConflictOutputCard: View {
    let session: RepoSession
    let document: ConflictDocument
    let merge: ThreeWayMerge
    let sync: ScrollSync

    var body: some View {
        let count = merge.conflictCount
        let current = min(document.current, max(0, count - 1))
        SectionCard(nil, contentPadding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("Output")
                        .font(.body.weight(.semibold))
                    Spacer(minLength: 8)
                    if count > 0 {
                        Text("conflict \(current + 1) of \(count)")
                            .monospacedDigit()
                            .foregroundStyle(Color(nsColor: Palette.conflictA))
                        if merge.unresolvedCount > 0 {
                            Text("\(merge.unresolvedCount) unresolved")
                                .font(.settingsCaption.monospacedDigit())
                                .foregroundStyle(Color(nsColor: Palette.conflictUnresolved))
                        }
                        navigationButton("chevron.up", help: "Previous conflict", to: current - 1, count: count)
                        navigationButton("chevron.down", help: "Next conflict", to: current + 1, count: count)
                    } else {
                        Text("No conflicts")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                Divider()
                ConflictOutputView(
                    merge: merge, revision: document.revision, loadID: document.loadID, sync: sync,
                    isEditable: document.isUTF8,
                    onEdit: { [session] text, regions in session.editConflictOutput(text, regions: regions) })
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private func navigationButton(_ systemImage: String, help: String, to k: Int, count: Int) -> some View {
        Button {
            session.showConflict(k)
            sync.jump(toConflict: k)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(RowIconButtonStyle())
        .disabled(k < 0 || k >= count)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A conflict without a line merge: a file deleted on one side (keep it or delete it) or a binary file (take A or B).
private struct ConflictChooserCard: View {
    let session: RepoSession
    let document: ConflictDocument

    var body: some View {
        let labels = document.source.labels
        let isBusy = session.conflictBusy != nil
        switch document.source.content {
        case .modifyDelete(_, let a, let b):
            SectionCard("Deleted on one side", systemImage: "trash.slash") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(Self.modifyDeleteText(a: a, b: b, labels: labels))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Keep File") {
                            session.resolveConflict(keeping: a ?? b, title: "Keeping…")
                        }
                        .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
                        .disabled(isBusy || (a == nil && b == nil))
                        Button("Delete File") {
                            session.resolveConflict(keeping: nil, title: "Deleting…")
                        }
                        .buttonStyle(RowTextButtonStyle(formRow: true))
                        .disabled(isBusy)
                        if let busy = session.conflictBusy {
                            Text(busy).foregroundStyle(.secondary)
                        }
                    }
                }
                // Fills panel2 like the panes it stands in for.
                .frame(maxHeight: .infinity, alignment: .topLeading)
            }
        case .binary(_, let a, let b):
            SectionCard("Binary file", systemImage: "doc.zipper") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Histq cannot merge binary files line by line. Keep one side's version.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Take A (\(labels.a))") { session.resolveConflict(keeping: a, title: "Saving…") }
                            .buttonStyle(RowTextButtonStyle(formRow: true))
                        Button("Take B (\(labels.b))") { session.resolveConflict(keeping: b, title: "Saving…") }
                            .buttonStyle(RowTextButtonStyle(formRow: true))
                    }
                    .disabled(isBusy)
                }
                .frame(maxHeight: .infinity, alignment: .topLeading)
            }
        case .text:
            EmptyView()
        }
    }

    /// Which side changed the file and which deleted it ("main modified it; feature deleted it").
    private static func modifyDeleteText(a: Data?, b: Data?, labels: ConflictLabels) -> String {
        switch (a != nil, b != nil) {
        case (true, false): "\(labels.a) changed this file; \(labels.b) deleted it. Keep it with \(labels.a)'s changes, or delete it."
        case (false, true): "\(labels.a) deleted this file; \(labels.b) changed it. Keep it with \(labels.b)'s changes, or delete it."
        default: "Both sides deleted or renamed this file."
        }
    }
}

/// The editor's skeleton: panes A and B in one card (a header with a checkbox and a title, then numbered lines) over
/// Output.
private struct ConflictPlaceholder: View {
    var body: some View {
        VStack(spacing: SectionCardMetrics.spacing) {
            SectionCard(nil, contentPadding: 0) {
                HStack(spacing: 0) {
                    paneSkeleton(titleWidth: 140)
                    Divider()
                    paneSkeleton(titleWidth: 150)
                }
            }
            .frame(maxHeight: .infinity)
            SectionCard(nil, contentPadding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        SkeletonLine(width: 52, height: 12)
                        Spacer(minLength: 8)
                        SkeletonLine(width: 96, height: 11)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    Divider()
                    lines([0.4, 0.45, 0.42, 0.5, 0.38, 0.44, 0.47, 0.41])
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func paneSkeleton(titleWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SkeletonLine(width: 14, height: 14)
                SkeletonLine(width: 20, height: 20)
                SkeletonLine(width: titleWidth, height: 11)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            Divider()
            lines([0.55, 0.6, 0.5, 0.62, 0.58, 0.52, 0.6, 0.48])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func lines(_ widths: [CGFloat]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(widths.indices, id: \.self) { index in
                HStack(spacing: 10) {
                    SkeletonLine(width: 20, height: 9)
                    SkeletonLine(fraction: widths[index], height: 10)
                }
                .padding(.horizontal, 12)
                .frame(height: ConflictLayout.lineHeight)
            }
        }
        .padding(.vertical, 4)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
