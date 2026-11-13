// Builds a patch for selected lines of a FileDiff and applies it to the index or the working tree:
// stage (`apply --cached` of an unstaged diff), unstage (`apply --cached -R` of a staged diff), discard
// (`apply -R` of an unstaged diff).
//
// The side the patch is applied to must stay exactly as git printed it, so unselected lines are rewritten
// by direction: forward (stage) drops unselected `+` lines and turns unselected `-` lines into context;
// reverse (unstage, discard) turns unselected `+` lines into context and drops unselected `-` lines.
// Within a change block the selected lines of the free side go next to the selected lines of the fixed
// side (after the last selected `-`, or before the first selected `+`), so a replaced line stays in place
// and a fixed-side line without a final newline stays last. Hunk headers are recomputed: the fixed side
// keeps its range, the other side is shifted by the size change of the hunks before it.
import Foundation

public enum PatchBuilder {
    public enum Action: Sendable, Hashable {
        /// Applies selected lines of an unstaged diff (index → working tree) to the index.
        case stage
        /// Removes selected lines of a staged diff (HEAD → index) from the index.
        case unstage
        /// Reverts selected lines of an unstaged diff in the working tree.
        case discard

        var isReverse: Bool { self != .stage }

        /// `--whitespace=nowarn`: a repo's `apply.whitespace=fix|error` must not alter or reject the patch.
        var applyArguments: [String] {
            switch self {
            case .stage: ["apply", "--cached", "--whitespace=nowarn"]
            case .unstage: ["apply", "--cached", "-R", "--whitespace=nowarn"]
            case .discard: ["apply", "-R", "--whitespace=nowarn"]
            }
        }
    }

    public enum BuildError: Error, Equatable, Sendable {
        /// Binary files have no lines to select.
        case binaryFile
        /// A merge's combined diff is read-only.
        case combinedDiff
        /// No added or removed line is selected (a mode-only change has none).
        case emptySelection
    }

    /// The patch that applies the selected added and removed lines of `file` (ids from `file.hunks`;
    /// context ids are ignored) for `action`. When every changed line is selected the file's own header is
    /// kept (so a new, deleted, renamed or mode-changed file is staged or unstaged as a whole); otherwise
    /// the header is a plain modification of the path that exists on the side being patched.
    public static func patch(for file: FileDiff, selecting selection: Set<DiffLineID>, action: Action) throws -> Data {
        if file.isCombined { throw BuildError.combinedDiff }
        if file.isBinary { throw BuildError.binaryFile }
        let reverse = action.isReverse
        var body = Data()
        var delta = 0
        for (hunkIndex, hunk) in file.hunks.enumerated() {
            guard let lines = rewrite(hunk, index: hunkIndex, selection: selection, reverse: reverse) else { continue }
            let oldCount = lines.count { $0.kind != .added }
            let newCount = lines.count { $0.kind != .removed }
            // The fixed side keeps its range; the other side's "line before the hunk" moves by `delta`.
            let (oldStart, newStart): (Int, Int)
            if reverse {
                let before = (hunk.newCount == 0 ? hunk.newStart : hunk.newStart - 1) - delta
                (oldStart, newStart) = (oldCount == 0 ? before : before + 1, hunk.newStart)
            } else {
                let before = (hunk.oldCount == 0 ? hunk.oldStart : hunk.oldStart - 1) + delta
                (oldStart, newStart) = (hunk.oldStart, newCount == 0 ? before : before + 1)
            }
            delta += newCount - oldCount
            body.append(contentsOf: Array("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\n".utf8))
            for line in lines {
                body.append(line.kind == .context ? UInt8(ascii: " ") : line.kind == .added ? UInt8(ascii: "+") : UInt8(ascii: "-"))
                body.append(line.content)
                body.append(UInt8(ascii: "\n"))
                if line.noNewlineAtEnd { body.append(contentsOf: Array("\\ No newline at end of file\n".utf8)) }
            }
        }
        if body.isEmpty { throw BuildError.emptySelection }
        let whole = Set(file.changedLineIDs).isSubset(of: selection)
        return header(for: file, whole: whole, reverse: reverse) + body
    }

    /// Applies `patch` for `action` with git apply (patch on stdin). This is a write: `env` must be the
    /// write environment, and it takes the runner's `mutate` lane itself, so never call it from inside a
    /// `mutate` body of the same runner (that deadlocks). Throws `GitError` when the patch does not apply.
    public static func apply(
        _ patch: Data, action: Action, runner: GitRunner, cwd: URL, env: [String: String]
    ) async throws {
        _ = try await runner.mutate {
            try await runner.run(action.applyArguments, cwd: cwd, env: env, stdin: patch, timeout: .seconds(60))
        }
    }

    // MARK: Building

    private struct Line {
        var kind: DiffLine.Kind
        var content: Data
        var noNewlineAtEnd: Bool
    }

    /// The hunk's lines for the selection, or nil when no changed line of it is selected.
    private static func rewrite(_ hunk: DiffHunk, index: Int, selection: Set<DiffLineID>, reverse: Bool) -> [Line]? {
        // The fixed side is the one the patch is applied to: the old side forward, the new side in reverse.
        let fixedKind: DiffLine.Kind = reverse ? .added : .removed
        var output: [Line] = []
        var anySelected = false
        var position = 0
        while position < hunk.lines.count {
            let line = hunk.lines[position]
            guard line.isChange else {
                output.append(Line(kind: .context, content: line.content, noNewlineAtEnd: line.noNewlineAtEnd))
                position += 1
                continue
            }
            var end = position
            while end < hunk.lines.count, hunk.lines[end].isChange { end += 1 }
            var fixed: [Line] = []
            var free: [Line] = []
            var anchor: Int?
            for offset in position..<end {
                let line = hunk.lines[offset]
                let selected = selection.contains(DiffLineID(hunk: index, line: offset))
                anySelected = anySelected || selected
                if line.kind == fixedKind {
                    if selected {
                        // Forward: free lines go after the last selected `-`; reverse: before the first selected `+`.
                        if !reverse || anchor == nil { anchor = reverse ? fixed.count : fixed.count + 1 }
                    }
                    fixed.append(Line(
                        kind: selected ? line.kind : .context, content: line.content,
                        noNewlineAtEnd: line.noNewlineAtEnd))
                } else if selected {
                    free.append(Line(kind: line.kind, content: line.content, noNewlineAtEnd: line.noNewlineAtEnd))
                }
            }
            fixed.insert(contentsOf: free, at: anchor ?? 0)
            output += fixed
            position = end
        }
        guard anySelected else { return nil }
        // Only the last line of a side may lack its newline: a free line that something follows on its side
        // ends with a newline instead (the fixed side's last line keeps its marker: nothing follows it).
        var oldFollows = false
        var newFollows = false
        for offset in output.indices.reversed() {
            let onOld = output[offset].kind != .added
            let onNew = output[offset].kind != .removed
            if output[offset].noNewlineAtEnd, (onOld && oldFollows) || (onNew && newFollows) {
                output[offset].noNewlineAtEnd = false
            }
            oldFollows = oldFollows || onOld
            newFollows = newFollows || onNew
        }
        return output
    }

    private static func header(for file: FileDiff, whole: Bool, reverse: Bool) -> Data {
        if whole {
            return file.headerLines.reduce(into: Data()) { $0.append($1); $0.append(UInt8(ascii: "\n")) }
        }
        // The path that exists on the patched side: the index (forward) or the new side (reverse).
        let path = (reverse ? file.newPathBytes ?? file.oldPathBytes : file.oldPathBytes ?? file.newPathBytes) ?? Data()
        let a = PathQuoting.quoted(path, prefix: "a/")
        let b = PathQuoting.quoted(path, prefix: "b/")
        // Like git, a name with a space (quoted or not) gets a TAB after it on the `---`/`+++` lines.
        let tab = path.contains(UInt8(ascii: " ")) ? Data([0x09]) : Data()
        var header = Data("diff --git ".utf8) + a + Data(" ".utf8) + b + Data("\n".utf8)
        header += Data("--- ".utf8) + a + tab + Data("\n".utf8)
        header += Data("+++ ".utf8) + b + tab + Data("\n".utf8)
        return header
    }
}
