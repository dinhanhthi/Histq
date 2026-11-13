// A commit or a stash in the detail panel, its parts in cards: the commit info (subject, body, author and
// committer with their avatars, date, sha with a copy button, parents that jump to their row), then its files.
import AppKit
import Combine
import SwiftUI

struct CommitDetailPanel: View {
    let session: RepoSession
    let commit: CommitDetail

    var body: some View {
        ScrollView {
            VStack(spacing: SectionCardMetrics.spacing) {
                CommitInfoCard(session: session, commit: commit)
                SectionCard("Files", systemImage: "doc.on.doc", count: commit.files.count, contentPadding: 6) {
                    if commit.files.isEmpty {
                        Text("No file changes")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .frame(height: FileListView<EmptyView>.rowHeight)
                    } else {
                        FileListView(files: commit.files, repoURL: session.url)
                            .fileMenu { [session, commit] file in
                                // A stash's untracked files are not in its commit: no checkout from a stash.
                                commit.isStash ? [] : RepoMenus.checkoutFile(file, commit: commit.hash, session: session)
                            }
                            .onSelectFile(selected: openPath) { [session, commit] file in
                                session.selectFile(FileTarget(source: .commit(commit.hash), file: file))
                            }
                    }
                } accessory: {
                    FileListModeToggle()
                }
            }
        }
    }

    /// This commit's file whose diff panel2 shows, drawn as selected.
    private var openPath: String? {
        session.openFile?.source == .commit(commit.hash) ? session.openFile?.path : nil
    }
}

/// The skeleton of the commit detail: the info card's lines and the files card's rows.
struct CommitDetailPlaceholder: View {
    var body: some View {
        VStack(spacing: SectionCardMetrics.spacing) {
            SectionCard("Commit", systemImage: "smallcircle.filled.circle") {
                VStack(alignment: .leading, spacing: 10) {
                    SkeletonLine(fraction: 0.75, height: 16)
                    SkeletonLine(fraction: 0.5, height: 11)
                    HStack(spacing: 8) {
                        SkeletonLine(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 6) {
                            SkeletonLine(fraction: 0.45, height: 11)
                            SkeletonLine(fraction: 0.6, height: 9)
                        }
                    }
                    SkeletonLine(fraction: 0.7, height: 11)
                    SkeletonLine(fraction: 0.35, height: 11)
                }
            }
            SectionCard("Files", systemImage: "doc.on.doc", countIsLoading: true, contentPadding: 6) {
                SkeletonFileRows(fractions: [0.6, 0.45, 0.7, 0.5])
            }
        }
    }
}

/// Several graph rows selected.
struct MultipleSelectionCard: View {
    let count: Int

    var body: some View {
        SectionCard("Selection", systemImage: "square.stack.3d.up") {
            Text("\(count) commits selected")
                .font(.body.weight(.medium))
        }
    }
}

// MARK: - Info

private struct CommitInfoCard: View {
    let session: RepoSession
    let commit: CommitDetail
    @AppStorage(PrefKey.dateFormat.rawValue, store: Preferences.defaults) private var dateFormat = "MM/dd/yy @ HH:mm"

    var body: some View {
        SectionCard(commit.isStash ? "Stash" : "Commit",
                    systemImage: commit.isStash ? "archivebox" : "smallcircle.filled.circle") {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(commit.subject)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if !commit.body.isEmpty {
                        Text(commit.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .textSelection(.enabled)
                PersonRow(role: "Author", name: commit.authorName, email: commit.authorEmail,
                          date: format(commit.authorDate))
                if commit.committerName != commit.authorName || commit.committerEmail != commit.authorEmail {
                    PersonRow(role: "Committer", name: commit.committerName, email: commit.committerEmail,
                              date: format(commit.committerDate))
                }
                ShaRow(hash: commit.hash)
                parentsRow
            }
        }
    }

    /// The parents, each a link to its row; a stash shows only the commit it was made on.
    @ViewBuilder private var parentsRow: some View {
        let parents = commit.isStash ? Array(commit.parents.prefix(1)) : commit.parents
        if !parents.isEmpty {
            HStack(spacing: 8) {
                Text(commit.isStash ? "Base" : parents.count == 1 ? "Parent" : "Parents")
                    .foregroundStyle(.secondary)
                    .frame(width: InfoMetrics.labelWidth, alignment: .leading)
                ForEach(parents, id: \.self) { parent in
                    Button(String(parent.prefix(7))) {
                        session.selectGraph([.commit(parent)])
                    }
                    .buttonStyle(RowTextButtonStyle())
                    .font(.body.monospaced())
                    .help("Show \(parent)")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Locale.current.identifier)
        formatter.dateFormat = dateFormat
        return formatter.string(from: date)
    }
}

private enum InfoMetrics {
    static let labelWidth: CGFloat = 52
    static let avatar: CGFloat = 28
}

/// An avatar, the name, then the email and the date under it.
private struct PersonRow: View {
    let role: String
    let name: String
    let email: String
    let date: String

    var body: some View {
        HStack(spacing: 8) {
            AvatarImage(email: email, name: name, size: InfoMetrics.avatar)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(role.lowercased())
                        .font(.settingsCaption)
                        .foregroundStyle(.tertiary)
                }
                Text(email.isEmpty ? date : "\(email) · \(date)")
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The full sha (cut in the middle when narrow) and a copy button that shows a check for a moment.
private struct ShaRow: View {
    let hash: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text("SHA")
                .foregroundStyle(.secondary)
                .frame(width: InfoMetrics.labelWidth, alignment: .leading)
            Text(hash)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hash, forType: .string)
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(RowIconButtonStyle())
            .help("Copy SHA")
            .accessibilityLabel("Copy SHA")
            .task(id: copied) {
                guard copied, (try? await Task.sleep(for: .seconds(1.5))) != nil else { return }
                copied = false
            }
            Spacer(minLength: 0)
        }
    }
}

/// An author's avatar from `AvatarStore` (never blocks: a generated one until the real one arrives).
private struct AvatarImage: View {
    let email: String
    let name: String
    let size: CGFloat
    @State private var image: NSImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable()
            } else {
                Circle().fill(Palette.skeletonFill)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .onAppear(perform: load)
        .onChange(of: email) { load() }
        .onReceive(NotificationCenter.default.publisher(for: AvatarStore.didChange)) { note in
            if let changed = note.userInfo?[AvatarStore.emailKey] as? String,
               !AvatarStore.matches(email: email, name: name, changed: changed)
            {
                return
            }
            load()
        }
    }

    private func load() {
        image = AvatarStore.shared.avatar(email: email, name: name, pixels: Int((size * scale).rounded(.up)))
    }
}
