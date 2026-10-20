import Foundation

// Expected conflicts come from `git merge-file` and `git merge-tree`, not from MergeCheck.
// Run with `make test`.

@main
struct MergeCheckTests {
    static var failures = 0

    static func expect(_ condition: Bool, _ name: String) {
        print(condition ? "✓ \(name)" : "✗ \(name)")
        if !condition { failures += 1 }
    }

    static func text(_ value: String) -> [UInt8] {
        Array(value.utf8)
    }

    /// Whether git would report a conflict for these versions of one file (nil base: the file was added).
    static func conflicts(_ base: String?, _ ours: String, _ theirs: String) -> Bool {
        MergeCheck.fileMerge(base: base.map { text($0) }, ours: text(ours), theirs: text(theirs)) == .conflict
    }

    static func blob(_ sha: String) -> TreeFile {
        TreeFile(sha: sha, isSubmodule: false)
    }

    static func submodule(_ sha: String) -> TreeFile {
        TreeFile(sha: sha, isSubmodule: true)
    }

    static func lcsLength(_ a: [Int], _ b: [Int]) -> Int {
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0..<a.count {
            for j in 0..<b.count {
                table[i + 1][j + 1] = a[i] == b[j] ? table[i][j] + 1 : max(table[i][j + 1], table[i + 1][j])
            }
        }
        return table[a.count][b.count]
    }

    /// Pairs must point at equal elements, in increasing order on both sides.
    static func isCommonSubsequence(_ pairs: [(Int, Int)], _ a: [Int], _ b: [Int]) -> Bool {
        var previous = (-1, -1)
        for (i, j) in pairs {
            guard i > previous.0, j > previous.1, a[i] == b[j] else { return false }
            previous = (i, j)
        }
        return true
    }

    static func main() {
        // Text files: the same rules as `git merge`.
        expect(conflicts("A\nB\nC\n", "A1\nB\nC\n", "A\nB1\nC\n"), "adjacent changes conflict")
        expect(!conflicts("A\nB\nC\n", "A1\nB\nC\n", "A\nB\nC1\n"), "separated changes merge")
        expect(!conflicts("A\nB\nC\n", "A\nX\nC\n", "A\nX\nC\n"), "identical change merges")
        expect(conflicts("A\nB\n", "A\nX\nB\n", "A\nY\nB\n"), "different insertions at one point conflict")
        expect(!conflicts("A\nB\n", "A\nX\nB\n", "A\nX\nB\n"), "identical insertions at one point merge")
        expect(conflicts("A\nB\n", "A\nX\nB\n", "A2\nB\n"), "insertion next to a change conflicts")
        expect(conflicts("A\nB\nC\n", "A\nC\n", "A\nB\nC1\n"), "deletion next to a change conflicts")
        expect(conflicts("A\nB\n", "A\nB\nX\n", "A\nB1\n"), "insertion at the end next to a change conflicts")
        expect(!conflicts("A\nB\nC\n", "A\nC\n", "A\nC\n"), "same deletion on both sides merges")
        expect(conflicts("A\nB\nC\n", "A\nX\nC\n", "A\nC\n"), "change against deletion conflicts")
        expect(conflicts("A\n", "A\nX\n", "A\nY\n"), "different appends conflict")
        expect(conflicts("A\nB", "A\nB1", "A\nB\n"), "missing final newline counts as a change")
        expect(conflicts("A\nB\nC\n", "A\nX\nC\n", "A\nX\nB\nC\n"), "insertion next to a replaced line conflicts")
        expect(!conflicts("A\n\nB\n\nC\n", "A\n\nB\n\nC\nD\n", "A\n\nB\nE\n\nC\n"), "changes around repeated blank lines merge")
        expect(conflicts(nil, "X\n", "Y\n"), "different files added on both sides conflict")
        expect(!conflicts(nil, "X\n", "X\n"), "same file added on both sides merges")
        expect(conflicts("bin\0ary", "bin\0ary2", "bin\0ary3"), "binary files changed on both sides conflict")

        // Trees: a path changed on one side takes that side, the rest needs its contents.
        expect(MergeCheck.verdict(base: blob("1"), ours: blob("1"), theirs: blob("2")) == .clean, "only theirs changed: clean")
        expect(MergeCheck.verdict(base: blob("1"), ours: blob("2"), theirs: blob("1")) == .clean, "only ours changed: clean")
        expect(MergeCheck.verdict(base: blob("1"), ours: blob("2"), theirs: blob("2")) == .clean, "same change on both sides: clean")
        expect(MergeCheck.verdict(base: blob("1"), ours: nil, theirs: nil) == .clean, "deleted on both sides: clean")
        expect(MergeCheck.verdict(base: blob("1"), ours: nil, theirs: blob("2")) == .conflict, "deleted on one side, changed on the other: conflict")
        expect(MergeCheck.verdict(base: blob("1"), ours: blob("2"), theirs: blob("3")) == .contents(base: "1", ours: "2", theirs: "3"), "changed differently on both sides: contents")
        expect(MergeCheck.verdict(base: nil, ours: blob("2"), theirs: blob("3")) == .contents(base: nil, ours: "2", theirs: "3"), "added differently on both sides: contents")
        expect(MergeCheck.verdict(base: submodule("1"), ours: submodule("2"), theirs: submodule("3")) == .conflict, "submodule moved on both sides: conflict")

        let plan = MergeCheck.plan(
            base: ["a": blob("1"), "b": blob("1"), "c": blob("1")],
            ours: ["a": blob("2"), "b": blob("1")],
            theirs: ["a": blob("3"), "b": blob("4"), "c": blob("5")]
        )
        expect(plan.conflicts == ["c"], "plan: c deleted here and changed there conflicts")
        expect(plan.candidates == [MergeCheck.Candidate(path: "a", base: "1", ours: "2", theirs: "3")], "plan: a changed on both sides needs its contents")

        // Diff: the pairs are a longest common subsequence.
        let pairs = MergeCheck.matchingPairs([1, 2, 3, 4], [1, 3, 4, 5]) ?? []
        expect(pairs.count == 3 && pairs[0] == (0, 0) && pairs[1] == (2, 1) && pairs[2] == (3, 2), "diff follows the common lines")

        var seed: UInt64 = 42
        func random(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(seed >> 33) % bound
        }
        var lcsMatches = true
        for _ in 0..<300 {
            let a = (0..<random(12)).map { _ in random(4) }
            let b = (0..<random(12)).map { _ in random(4) }
            guard let found = MergeCheck.matchingPairs(a, b),
                  found.count == lcsLength(a, b), isCommonSubsequence(found, a, b) else {
                lcsMatches = false
                break
            }
        }
        expect(lcsMatches, "diff is a longest common subsequence on random inputs")

        // Large files: a few changes in 2000 lines are compared; a rewrite is left to GitHub.
        let long = (0..<2_000).map { "line \($0)\n" }
        var ours = long
        ours[1_000] = "changed here\n"
        var theirs = long
        theirs[1_500] = "changed there\n"
        expect(MergeCheck.fileMerge(base: text(long.joined()), ours: text(ours.joined()), theirs: text(theirs.joined())) == .clean, "large file with separate changes merges")

        let rewritten = (0..<2_100).map { "other \($0)\n" }.joined()
        expect(MergeCheck.fileMerge(base: [], ours: text(long.joined()), theirs: text(rewritten)) == .tooLarge, "too many edits are not compared on the device")

        if failures > 0 {
            print("\(failures) test(s) failed")
            exit(1)
        }
        print("All tests passed")
    }
}
