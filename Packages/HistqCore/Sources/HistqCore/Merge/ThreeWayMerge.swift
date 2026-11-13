// The model behind the conflict editor: a line-based 3-way merge of base, A (ours, stage 2) and B
// (theirs, stage 3) cut into regions that tile all four panes (A, B, base and Output). One-sided changes
// are applied; each conflict's Output comes from the ticked lines (A first, then B), a manual edit, or the
// base text marked unresolved. Lines are kept and compared as bytes, so any encoding round-trips; Strings
// are only a display view. Pure logic: no git, no I/O.
import Foundation

/// One region of a 3-way merge. Ranges are 0-based line indices; the regions tile every pane in order.
public struct MergeRegion: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// Base, A and B agree.
        case unchanged
        /// Only A changed the base: Output takes A.
        case changedInA
        /// Only B changed the base: Output takes B.
        case changedInB
        /// A and B made the same change: Output takes it.
        case changedInBoth
        /// A and B changed the base differently: Output comes from the ticked lines.
        case conflict
    }

    public let kind: Kind
    public let base: Range<Int>
    public let a: Range<Int>
    public let b: Range<Int>
    /// Where the region sits in the current Output (moves when an earlier region changes length).
    public internal(set) var output: Range<Int>
    /// A conflict with nothing ticked and no manual edit: Output shows its base text.
    public internal(set) var isUnresolved: Bool
    /// The region's Output is a manual edit.
    public internal(set) var isManual: Bool
}

/// A 3-way merge with the conflict editor's resolution state. Lines are the file's bytes split after each
/// `\n` and keep their terminator (only a file's last line can lack one), so Output is the plain
/// concatenation of its lines. Regions are found on the bytes and `outputData` keeps every base/A/B line's
/// original bytes (byte-exact for LF and CRLF files in any encoding); only a manual edit is written as UTF-8.
/// The `String` lines are a display view: invalid UTF-8 shows as U+FFFD there.
public struct ThreeWayMerge: Sendable, Hashable {
    public enum Side: Sendable, Hashable { case a, b }
    public enum Pane: Sendable, Hashable { case a, b, base, output }

    public let baseLines: [String]
    public let aLines: [String]
    public let bLines: [String]
    public private(set) var regions: [MergeRegion]
    /// Indices into `regions` of the conflicts, in file order ("conflict k of N" uses k = 0..<N here).
    public let conflictRegions: [Int]
    public private(set) var outputLines: [String] = []

    private let baseBytes: [[UInt8]]
    private let aBytes: [[UInt8]]
    private let bBytes: [[UInt8]]
    private var outputBytes: [[UInt8]] = []
    private var tickedA: Set<Int> = []
    private var tickedB: Set<Int> = []
    private var manual: [Int: [[UInt8]]] = [:]

    /// `base` is nil for an add/add conflict (no common ancestor): every line is then compared with an
    /// empty base.
    public init(base: Data?, a: Data, b: Data) {
        self.init(baseBytes: Self.byteLines(base ?? Data()), aBytes: Self.byteLines(a), bBytes: Self.byteLines(b))
    }

    public init(baseLines: [String], aLines: [String], bLines: [String]) {
        self.init(
            baseBytes: baseLines.map { Array($0.utf8) }, aBytes: aLines.map { Array($0.utf8) },
            bBytes: bLines.map { Array($0.utf8) })
    }

    private init(baseBytes: [[UInt8]], aBytes: [[UInt8]], bBytes: [[UInt8]]) {
        self.baseBytes = baseBytes
        self.aBytes = aBytes
        self.bBytes = bBytes
        baseLines = baseBytes.map(Self.display)
        aLines = aBytes.map(Self.display)
        bLines = bBytes.map(Self.display)
        let regions = Self.regions(base: baseBytes, a: aBytes, b: bBytes)
        self.regions = regions
        conflictRegions = regions.indices.filter { regions[$0].kind == .conflict }
        render()
    }

    // MARK: State

    public var conflictCount: Int { conflictRegions.count }
    public var unresolvedCount: Int { conflictRegions.count { regions[$0].isUnresolved } }
    /// Output as one string for display (the concatenation of `outputLines`).
    public var outputText: String { outputLines.joined() }
    /// Output's bytes, the content to save: base/A/B lines keep their original bytes.
    public var outputData: Data { Data(outputBytes.joined()) }

    public func isTicked(_ side: Side, line: Int) -> Bool {
        side == .a ? tickedA.contains(line) : tickedB.contains(line)
    }

    /// Ticks or unticks lines of one side (line indices in that pane). Lines outside a conflict are
    /// ignored. A tick change in a region drops that region's manual edit (the user chose again); other
    /// regions keep theirs.
    public mutating func setTicked(_ ticked: Bool, side: Side, lines: some Sequence<Int>) {
        for line in lines {
            guard let region = conflictRegion(containing: line, side: side) else { continue }
            if ticked {
                if side == .a { tickedA.insert(line) } else { tickedB.insert(line) }
            } else {
                if side == .a { tickedA.remove(line) } else { tickedB.remove(line) }
            }
            manual[region] = nil
        }
        render()
    }

    /// Ticks or unticks every line of one side of conflict `k` (the per-hunk checkbox).
    public mutating func setTicked(_ ticked: Bool, side: Side, conflict k: Int) {
        let region = regions[conflictRegions[k]]
        setTicked(ticked, side: side, lines: side == .a ? region.a : region.b)
    }

    /// Ticks or unticks every conflict line of one side (the pane header's select-all checkbox).
    public mutating func setTickedAll(_ ticked: Bool, side: Side) {
        let lines = conflictRegions.flatMap { side == .a ? Array(regions[$0].a) : Array(regions[$0].b) }
        setTicked(ticked, side: side, lines: lines)
    }

    /// Replaces region `index`'s Output with `text` (split like the files; a missing final newline is
    /// added when more lines follow). nil drops the edit. Any region can be edited; an edited conflict
    /// counts as resolved.
    public mutating func setManualText(_ text: String?, region index: Int) {
        manual[index] = text.map { Self.byteLines(Data($0.utf8)) }
        render()
    }

    // MARK: Line map

    /// The region holding `line` of `pane` (a line past the end belongs to the last region; nil when the
    /// pane is empty and there are no regions).
    public func region(containing line: Int, in pane: Pane) -> Int? {
        guard !regions.isEmpty else { return nil }
        var low = 0
        var high = regions.count - 1
        while low < high { // first region whose range ends after `line`
            let mid = (low + high) / 2
            if range(of: regions[mid], in: pane).upperBound > line { high = mid } else { low = mid + 1 }
        }
        return low
    }

    /// Maps `line` of one pane to the matching line of another (scroll sync): the same offset inside the
    /// same region, clamped to that region's last line in the target pane.
    public func line(_ line: Int, in pane: Pane, to target: Pane) -> Int {
        guard let index = region(containing: line, in: pane) else { return 0 }
        let source = range(of: regions[index], in: pane)
        let destination = range(of: regions[index], in: target)
        let offset = max(0, line - source.lowerBound)
        return destination.lowerBound + min(offset, max(0, destination.count - 1))
    }

    /// The first line of conflict `k` (0-based) in `pane`.
    public func conflictStart(_ k: Int, in pane: Pane) -> Int {
        range(of: regions[conflictRegions[k]], in: pane).lowerBound
    }

    private func range(of region: MergeRegion, in pane: Pane) -> Range<Int> {
        switch pane {
        case .a: region.a
        case .b: region.b
        case .base: region.base
        case .output: region.output
        }
    }

    private func conflictRegion(containing line: Int, side: Side) -> Int? {
        let pane: Pane = side == .a ? .a : .b
        guard let index = region(containing: line, in: pane), regions[index].kind == .conflict,
            range(of: regions[index], in: pane).contains(line)
        else { return nil }
        return index
    }

    // MARK: Output

    private mutating func render() {
        var output: [[UInt8]] = []
        for index in regions.indices {
            let region = regions[index]
            var lines: [[UInt8]]
            var unresolved = false
            if let edit = manual[index] {
                lines = edit
            } else {
                switch region.kind {
                case .unchanged: lines = Array(baseBytes[region.base])
                case .changedInA, .changedInBoth: lines = Array(aBytes[region.a])
                case .changedInB: lines = Array(bBytes[region.b])
                case .conflict:
                    let a = region.a.filter { tickedA.contains($0) }.map { aBytes[$0] }
                    let b = region.b.filter { tickedB.contains($0) }.map { bBytes[$0] }
                    lines = a + b
                    if lines.isEmpty {
                        lines = Array(baseBytes[region.base])
                        unresolved = true
                    }
                }
            }
            // A line without "\n" (a file's last line) gets one when more lines follow it.
            if let last = output.indices.last, !lines.isEmpty, output[last].last != 0x0A { output[last].append(0x0A) }
            for i in lines.indices.dropLast() where lines[i].last != 0x0A { lines[i].append(0x0A) }
            let start = output.count
            output += lines
            regions[index].output = start..<output.count
            regions[index].isUnresolved = unresolved
            regions[index].isManual = manual[index] != nil
        }
        outputBytes = output
        outputLines = output.map(Self.display)
    }

    // MARK: Merge

    /// Splits bytes after each `\n` for display (each line keeps its terminator; invalid UTF-8 is replaced).
    public static func lines(_ data: Data) -> [String] {
        byteLines(data).map(display)
    }

    /// Splits bytes after each `\n` (each line keeps its terminator and its bytes).
    private static func byteLines(_ data: Data) -> [[UInt8]] {
        var lines: [[UInt8]] = []
        var start = data.startIndex
        for index in data.indices where data[index] == 0x0A {
            lines.append(Array(data[start...index]))
            start = index + 1
        }
        if start < data.endIndex { lines.append(Array(data[start...])) }
        return lines
    }

    private static func display(_ line: [UInt8]) -> String {
        String(decoding: line, as: UTF8.self)
    }

    /// For each base line, the index of the same line in `side` when `difference(from:)` keeps it.
    /// Bytes, not Strings: String equality is canonical (é == e + U+0301) and lossy for invalid UTF-8.
    private static func matches(base: [[UInt8]], side: [[UInt8]]) -> [Int?] {
        let difference = side.difference(from: base)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        let kept = side.indices.filter { !inserted.contains($0) }
        var result = [Int?](repeating: nil, count: base.count)
        var next = kept.makeIterator()
        for i in base.indices where !removed.contains(i) { result[i] = next.next() }
        return result
    }

    /// Cuts the files into regions: a run of base lines kept by both sides is `unchanged`; everything
    /// between two such runs is one chunk (so touching or same-point changes of A and B form one conflict).
    private static func regions(base: [[UInt8]], a: [[UInt8]], b: [[UInt8]]) -> [MergeRegion] {
        let inA = matches(base: base, side: a)
        let inB = matches(base: base, side: b)
        var regions: [MergeRegion] = []
        func add(_ kind: MergeRegion.Kind, _ base: Range<Int>, _ a: Range<Int>, _ b: Range<Int>) {
            regions.append(MergeRegion(kind: kind, base: base, a: a, b: b, output: 0..<0, isUnresolved: false, isManual: false))
        }
        func same(_ x: ArraySlice<[UInt8]>, _ y: ArraySlice<[UInt8]>) -> Bool { x.elementsEqual(y) }
        var (i, j, k) = (0, 0, 0)
        while i < base.count || j < a.count || k < b.count {
            if i < base.count, inA[i] == j, inB[i] == k { // stable run
                let start = (i, j, k)
                while i < base.count, inA[i] == j, inB[i] == k { (i, j, k) = (i + 1, j + 1, k + 1) }
                add(.unchanged, start.0..<i, start.1..<j, start.2..<k)
                continue
            }
            // The chunk runs to the next base line kept by both sides (or to the end).
            var next = i
            while next < base.count, inA[next] == nil || inB[next] == nil { next += 1 }
            let aEnd = next < base.count ? inA[next]! : a.count
            let bEnd = next < base.count ? inB[next]! : b.count
            let chunk = (base: i..<next, a: j..<aEnd, b: k..<bEnd)
            let kind: MergeRegion.Kind
            if same(a[chunk.a], base[chunk.base]) {
                kind = .changedInB
            } else if same(b[chunk.b], base[chunk.base]) {
                kind = .changedInA
            } else if same(a[chunk.a], b[chunk.b]) {
                kind = .changedInBoth
            } else {
                kind = .conflict
            }
            add(kind, chunk.base, chunk.a, chunk.b)
            (i, j, k) = (next, aEnd, bEnd)
        }
        return regions
    }
}
