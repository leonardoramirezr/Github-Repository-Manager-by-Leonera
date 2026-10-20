import Foundation

/// A file of a commit's tree: its blob SHA, or the commit SHA of a submodule.
struct TreeFile: Equatable {
    let sha: String
    let isSubmodule: Bool
}

/// Decides whether merging `main` into a branch would conflict, the way `git merge` does.
///
/// GitHub has no dry run for merges, so the check runs on the device:
/// - a path that changed on one side only takes that side's version;
/// - a file that changed on both sides conflicts when its changes overlap or touch in the base version,
///   unless both sides end up with the same lines.
///
/// The merge endpoint still refuses a conflicting merge (HTTP 409), so a mistake here can only block a pull
/// that would have worked, or let through one that GitHub then refuses. It never leaves conflict markers.
enum MergeCheck {
    /// Largest number of inserted plus deleted lines in one file that is compared on the device.
    static let maxEditedLines = 2_000

    enum Status: Equatable {
        /// The branch already has every commit of main.
        case upToDate
        /// The merge succeeds and brings in `commits` commits. `mainSHA` is the main commit that was checked.
        case clean(commits: Int, mainSHA: String)
        /// GitHub would refuse the merge: these files changed on both sides in overlapping places.
        case conflicts(paths: [String])
        /// The check could not be finished on the device, so the pull stays disabled.
        case unverifiable(reason: String)
    }

    /// A file that changed on both sides. Its contents decide whether it conflicts.
    struct Candidate: Equatable {
        let path: String
        /// nil when the file does not exist in the base.
        let base: String?
        let ours: String
        let theirs: String
    }

    /// What comparing whole trees path by path leaves to decide.
    struct Plan: Equatable {
        /// Paths that conflict without reading any contents.
        var conflicts: [String] = []
        var candidates: [Candidate] = []
    }

    enum Verdict: Equatable {
        case clean
        case conflict
        case contents(base: String?, ours: String, theirs: String)
    }

    enum ContentResult: Equatable {
        case clean
        case conflict
        /// Too many changed lines to compare on the device.
        case tooLarge
    }

    /// Base lines `start..<end` were replaced by the lines `newStart..<newEnd` of one side.
    struct Hunk: Equatable {
        let start: Int
        let end: Int
        let newStart: Int
        let newEnd: Int
    }

    /// Compares one path across the base, ours (the branch) and theirs (main). Blob SHAs identify contents.
    static func verdict(base: TreeFile?, ours: TreeFile?, theirs: TreeFile?) -> Verdict {
        if ours == theirs || ours == base || theirs == base { return .clean }
        guard let ours, let theirs, !ours.isSubmodule, !theirs.isSubmodule, base?.isSubmodule != true else {
            return .conflict
        }
        return .contents(base: base?.sha, ours: ours.sha, theirs: theirs.sha)
    }

    /// Compares whole trees (path → file) of the base, ours and theirs.
    static func plan(base: [String: TreeFile], ours: [String: TreeFile], theirs: [String: TreeFile]) -> Plan {
        var plan = Plan()
        for path in Set(base.keys).union(ours.keys).union(theirs.keys).sorted() {
            switch verdict(base: base[path], ours: ours[path], theirs: theirs[path]) {
            case .clean:
                break
            case .conflict:
                plan.conflicts.append(path)
            case let .contents(baseSHA, oursSHA, theirsSHA):
                plan.candidates.append(Candidate(path: path, base: baseSHA, ours: oursSHA, theirs: theirsSHA))
            }
        }
        return plan
    }

    /// Whether git would report a conflict for one file that changed on both sides. `base` is nil when the file
    /// did not exist in the base. Binary files always conflict; text files are compared line by line.
    static func fileMerge(base: [UInt8]?, ours: [UInt8], theirs: [UInt8]) -> ContentResult {
        let baseBytes = base ?? []
        guard !isBinary(baseBytes), !isBinary(ours), !isBinary(theirs) else { return .conflict }

        // Equal lines get the same number, so the diffs compare integers instead of whole lines.
        var lineIDs: [[UInt8]: Int] = [:]
        func ids(_ bytes: [UInt8]) -> [Int] {
            var result: [Int] = []
            for line in lines(of: bytes) {
                let id = lineIDs[line] ?? lineIDs.count
                lineIDs[line] = id
                result.append(id)
            }
            return result
        }

        let baseIDs = ids(baseBytes)
        let oursIDs = ids(ours)
        let theirsIDs = ids(theirs)
        guard let oursHunks = diff(base: baseIDs, side: oursIDs),
              let theirsHunks = diff(base: baseIDs, side: theirsIDs) else {
            return .tooLarge
        }
        let conflict = overlapConflict(
            base: baseIDs,
            ours: oursIDs, oursHunks: oursHunks,
            theirs: theirsIDs, theirsHunks: theirsHunks
        )
        return conflict ? .conflict : .clean
    }

    /// Same rule as git: a NUL byte among the first 8000 bytes makes the file binary.
    static func isBinary(_ bytes: [UInt8]) -> Bool {
        bytes.prefix(8_000).contains(0)
    }

    /// Lines keep their "\n", so a last line without one differs from the same text followed by a newline.
    static func lines(of bytes: [UInt8]) -> [[UInt8]] {
        var result: [[UInt8]] = []
        var start = 0
        for (index, byte) in bytes.enumerated() where byte == 0x0A {
            result.append(Array(bytes[start...index]))
            start = index + 1
        }
        if start < bytes.count {
            result.append(Array(bytes[start...]))
        }
        return result
    }

    /// The changed regions between `base` and `side`, in order. Nil when there are more than `maxEditedLines` edits.
    static func diff(base: [Int], side: [Int]) -> [Hunk]? {
        guard let pairs = matchingPairs(base, side) else { return nil }
        var hunks: [Hunk] = []
        var baseNext = 0
        var sideNext = 0
        for (baseIndex, sideIndex) in pairs + [(base.count, side.count)] {
            if baseIndex > baseNext || sideIndex > sideNext {
                hunks.append(Hunk(start: baseNext, end: baseIndex, newStart: sideNext, newEnd: sideIndex))
            }
            baseNext = baseIndex + 1
            sideNext = sideIndex + 1
        }
        return hunks
    }

    /// Pairs `(i, j)` with `a[i] == b[j]` along a shortest edit script (Myers, 1986), in order.
    /// Nil when the script needs more than `maxEditedLines` insertions and deletions.
    static func matchingPairs(_ a: [Int], _ b: [Int]) -> [(Int, Int)]? {
        let limit = min(a.count + b.count, maxEditedLines)
        // furthest[offset + k] is the furthest x reached on diagonal k (x - y == k).
        let offset = limit + 1
        var furthest = [Int](repeating: 0, count: 2 * limit + 3)
        // rounds[d][k + d] is `furthest` on diagonal k before round d, kept for the backtracking.
        var rounds: [[Int]] = []
        for d in 0...limit {
            rounds.append(Array(furthest[(offset - d)...(offset + d)]))
            for k in stride(from: -d, through: d, by: 2) {
                let down = k == -d || (k != d && furthest[offset + k - 1] < furthest[offset + k + 1])
                var x = down ? furthest[offset + k + 1] : furthest[offset + k - 1] + 1
                var y = x - k
                while x < a.count, y < b.count, a[x] == b[y] {
                    x += 1
                    y += 1
                }
                furthest[offset + k] = x
                if x >= a.count, y >= b.count {
                    return backtrack(rounds, n: a.count, m: b.count)
                }
            }
        }
        return nil
    }

    private static func backtrack(_ rounds: [[Int]], n: Int, m: Int) -> [(Int, Int)] {
        var pairs: [(Int, Int)] = []
        var x = n
        var y = m
        for d in stride(from: rounds.count - 1, through: 1, by: -1) {
            let round = rounds[d]
            let k = x - y
            let previousK = (k == -d || (k != d && round[k - 1 + d] < round[k + 1 + d])) ? k + 1 : k - 1
            let previousX = round[previousK + d]
            let previousY = previousX - previousK
            // Diagonal run of equal lines that this round followed.
            while x > previousX, y > previousY {
                x -= 1
                y -= 1
                pairs.append((x, y))
            }
            (x, y) = (previousX, previousY)
        }
        // The run from the start of both sides, followed by round 0.
        while x > 0, y > 0 {
            x -= 1
            y -= 1
            pairs.append((x, y))
        }
        return pairs.reversed()
    }

    /// Whether the changes of both sides conflict. Changes that overlap or touch in the base conflict too,
    /// unless the region they cover ends up with the same lines on both sides.
    static func overlapConflict(
        base: [Int],
        ours: [Int], oursHunks: [Hunk],
        theirs: [Int], theirsHunks: [Hunk]
    ) -> Bool {
        struct SideHunk {
            let hunk: Hunk
            let isOurs: Bool
        }
        let sideHunks = oursHunks.map { SideHunk(hunk: $0, isOurs: true) }
            + theirsHunks.map { SideHunk(hunk: $0, isOurs: false) }
        let ordered = sideHunks.sorted { ($0.hunk.start, $0.hunk.end) < ($1.hunk.start, $1.hunk.end) }

        var index = 0
        while index < ordered.count {
            let start = ordered[index].hunk.start
            var end = ordered[index].hunk.end
            var next = index + 1
            while next < ordered.count, ordered[next].hunk.start <= end {
                end = max(end, ordered[next].hunk.end)
                next += 1
            }
            let group = ordered[index..<next]
            let oursGroup = group.filter { $0.isOurs }.map { $0.hunk }
            let theirsGroup = group.filter { !$0.isOurs }.map { $0.hunk }
            if !oursGroup.isEmpty, !theirsGroup.isEmpty,
               applying(oursGroup, to: ours, base: base, from: start, to: end)
                != applying(theirsGroup, to: theirs, base: base, from: start, to: end) {
                return true
            }
            index = next
        }
        return false
    }

    /// The lines `start..<end` of `base` after applying one side's hunks (sorted, not overlapping).
    private static func applying(_ hunks: [Hunk], to side: [Int], base: [Int], from start: Int, to end: Int) -> [Int] {
        var result: [Int] = []
        var cursor = start
        for hunk in hunks {
            result += base[cursor..<hunk.start]
            result += side[hunk.newStart..<hunk.newEnd]
            cursor = hunk.end
        }
        result += base[cursor..<end]
        return result
    }
}
