// The changed files of a commit, a stash or the working tree, as one row per path or as a folder tree (the toggle
// is saved in `PrefKey.fileListMode`). Each row has a status icon, a context menu (the caller's entries, such as
// "Checkout File from This Commit", then Copy Path and Reveal in Finder) and the caller's trailing buttons (stage,
// unstage, discard). A click on a row opens that file's diff when the caller asks for it (`onSelectFile`).
import AppKit
import SwiftUI

/// One changed file of a list.
struct FileChange: Hashable, Sendable, Identifiable {
    enum Kind: Hashable, Sendable {
        case added, modified, deleted, renamed, copied, typeChanged, untracked, conflicted
    }

    let kind: Kind
    /// Root-relative.
    let path: String
    /// The path before a rename or copy.
    var originalPath: String?

    var id: String { path }

    init(kind: Kind, path: String, originalPath: String? = nil) {
        self.kind = kind
        self.path = path
        self.originalPath = originalPath
    }

    /// From git's one-letter status (`M`, `A`, `D`, `R`, `C`, `T`, `U`; anything else reads as modified).
    init(letter: Character, path: String, originalPath: String? = nil) {
        let kind: Kind = switch letter {
        case "A": .added
        case "D": .deleted
        case "R": .renamed
        case "C": .copied
        case "T": .typeChanged
        case "U": .conflicted
        default: .modified
        }
        self.init(kind: kind, path: path, originalPath: originalPath)
    }

    var systemImage: String {
        switch kind {
        case .added: "plus.square.fill"
        case .modified, .typeChanged: "pencil.circle.fill"
        case .deleted: "minus.square.fill"
        case .renamed, .copied: "arrow.right.square.fill"
        case .untracked: "questionmark.square.fill"
        case .conflicted: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch kind {
        case .added, .untracked: Color(nsColor: Palette.graphLanes[5])
        case .modified, .typeChanged: Color(nsColor: Palette.graphLanes[0])
        case .deleted, .conflicted: Color(nsColor: Palette.graphLanes[6])
        case .renamed, .copied: Color(nsColor: Palette.graphLanes[2])
        }
    }

    var kindName: String {
        switch kind {
        case .added: "Added"
        case .modified: "Modified"
        case .typeChanged: "Type changed"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .untracked: "Untracked"
        case .conflicted: "Conflicted"
        }
    }

    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
}

/// The two ways a file list shows its rows.
enum FileListMode: String {
    case path, tree
}

/// The path / tree switch of a files card's header; every file list follows it.
struct FileListModeToggle: View {
    @AppStorage(PrefKey.fileListMode.rawValue, store: Preferences.defaults) private var mode = FileListMode.path.rawValue

    var body: some View {
        let isTree = mode == FileListMode.tree.rawValue
        Button {
            mode = isTree ? FileListMode.path.rawValue : FileListMode.tree.rawValue
        } label: {
            Image(systemName: isTree ? "list.bullet.indent" : "list.bullet")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(RowIconButtonStyle())
        .help(isTree ? "Show as Paths" : "Show as Tree")
        .accessibilityLabel(isTree ? "Show as paths" : "Show as tree")
    }
}

/// The rows of `files`, as paths (name, then its folder dimmed) or as a tree (folders, then their files, indented).
/// `trailing` adds a row's buttons. `repoURL` is the worktree, for Reveal in Finder.
struct FileListView<Trailing: View>: View {
    let files: [FileChange]
    let repoURL: URL
    @ViewBuilder let trailing: (FileChange) -> Trailing
    /// The caller's context menu entries of a row, above Copy Path and Reveal in Finder.
    var menu: (FileChange) -> [MenuEntry] = { _ in [] }
    /// The path of the row drawn as selected (the file whose diff is open).
    var selectedPath: String?
    /// A click on a row; nil leaves rows unclickable.
    var onSelect: ((FileChange) -> Void)?
    @AppStorage(PrefKey.fileListMode.rawValue, store: Preferences.defaults) private var mode = FileListMode.path.rawValue

    static var rowHeight: CGFloat { 26 }

    /// The list with `menu`'s entries in each row's context menu.
    func fileMenu(_ menu: @escaping (FileChange) -> [MenuEntry]) -> Self {
        var list = self
        list.menu = menu
        return list
    }

    /// The list with clickable rows: a click calls `action` at once (the diff's placeholder shows in that frame), and
    /// the row of `selected` is drawn as selected.
    func onSelectFile(selected: String?, _ action: @escaping (FileChange) -> Void) -> Self {
        var list = self
        list.selectedPath = selected
        list.onSelect = action
        return list
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if mode == FileListMode.tree.rawValue {
                ForEach(FileTree.rows(for: files)) { row in
                    switch row.content {
                    case .folder(let name):
                        FolderRow(name: name, depth: row.depth)
                    case .file(let file):
                        FileRow(file: file, repoURL: repoURL, depth: row.depth, showsFolder: false, trailing: trailing,
                                menu: menu, isSelected: file.path == selectedPath, onSelect: onSelect)
                    }
                }
            } else {
                ForEach(files) { file in
                    FileRow(file: file, repoURL: repoURL, depth: 0, showsFolder: true, trailing: trailing, menu: menu,
                            isSelected: file.path == selectedPath, onSelect: onSelect)
                }
            }
        }
    }
}

extension FileListView where Trailing == EmptyView {
    init(files: [FileChange], repoURL: URL) {
        self.init(files: files, repoURL: repoURL) { _ in EmptyView() }
    }
}

/// A file list's placeholder rows: an icon circle and a name capsule of the given widths.
struct SkeletonFileRows: View {
    var fractions: [CGFloat] = [0.6, 0.45, 0.7]

    var body: some View {
        ForEach(fractions.indices, id: \.self) { index in
            HStack(spacing: 8) {
                SkeletonLine(width: 14, height: 14)
                SkeletonLine(fraction: fractions[index], height: 11)
            }
            .padding(.horizontal, 6)
            .frame(height: FileListView<EmptyView>.rowHeight)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Rows

private struct FileRow<Trailing: View>: View {
    let file: FileChange
    let repoURL: URL
    let depth: Int
    let showsFolder: Bool
    let trailing: (FileChange) -> Trailing
    let menu: (FileChange) -> [MenuEntry]
    let isSelected: Bool
    let onSelect: ((FileChange) -> Void)?
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: file.systemImage)
                .foregroundStyle(file.tint)
                .help(file.kindName)
                .accessibilityLabel(file.kindName)
            HStack(spacing: 4) {
                Text(file.name)
                    .lineLimit(1)
                if showsFolder, !file.folder.isEmpty {
                    Text(file.folder)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .truncationMode(.middle)
            Spacer(minLength: 4)
            trailing(file)
        }
        .padding(.leading, 6 + CGFloat(depth) * 14)
        .padding(.trailing, 6)
        .frame(height: FileListView<EmptyView>.rowHeight)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isSelected ? Palette.selectedFill : hovered ? Palette.hoverFill : .clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        // A single tap only (no double-tap on the row), so the click acts at mouse-up without a wait; the row's
        // buttons keep their own clicks.
        .onTapGesture { onSelect?(file) }
        .accessibilityAddTraits(onSelect == nil ? [] : .isButton)
        .help(file.originalPath.map { "\($0) → \(file.path)" } ?? file.path)
        .contextMenu {
            let entries = menu(file)
            if !entries.isEmpty {
                MenuEntriesView(entries: entries)
                Divider()
            }
            Button("Copy Path") { Self.copy(file.path) }
            Button("Reveal in Finder") { Self.reveal(file, in: repoURL) }
        }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The file in Finder; its nearest existing folder when it is gone (a deleted file).
    private static func reveal(_ file: FileChange, in repoURL: URL) {
        var url = repoURL.appending(path: file.path, directoryHint: .notDirectory)
        while !FileManager.default.fileExists(atPath: url.path), url.path.count > repoURL.path.count {
            url = url.deletingLastPathComponent()
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private struct FolderRow: View {
    let name: String
    let depth: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
            Text(name)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, 6 + CGFloat(depth) * 14)
        .frame(height: FileListView<EmptyView>.rowHeight)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Tree

/// The tree view's rows: each folder once (a chain of single-child folders joined as `a/b/c`), then its files, sorted
/// folders first and by name.
private enum FileTree {
    struct Row: Identifiable {
        enum Content {
            case folder(String)
            case file(FileChange)
        }

        let id: String
        let depth: Int
        let content: Content
    }

    private final class Node {
        var folders: [String: Node] = [:]
        var files: [FileChange] = []
    }

    static func rows(for files: [FileChange]) -> [Row] {
        let root = Node()
        for file in files {
            var node = root
            for part in file.folder.split(separator: "/") {
                let key = String(part)
                if let next = node.folders[key] {
                    node = next
                } else {
                    let next = Node()
                    node.folders[key] = next
                    node = next
                }
            }
            node.files.append(file)
        }
        var rows: [Row] = []
        append(root, path: "", depth: 0, to: &rows)
        return rows
    }

    private static func append(_ node: Node, path: String, depth: Int, to rows: inout [Row]) {
        for name in node.folders.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            var child = node.folders[name]!
            var label = name
            while child.files.isEmpty, child.folders.count == 1, let (next, grandchild) = child.folders.first {
                label += "/" + next
                child = grandchild
            }
            let folderPath = path.isEmpty ? label : path + "/" + label
            rows.append(Row(id: "dir:" + folderPath, depth: depth, content: .folder(label)))
            append(child, path: folderPath, depth: depth + 1, to: &rows)
        }
        let files = node.files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for file in files {
            rows.append(Row(id: file.path, depth: depth, content: .file(file)))
        }
    }
}
