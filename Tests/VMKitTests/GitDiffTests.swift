import Foundation
import Testing
@testable import VMKit

@Suite("Git diff parsers")
struct GitDiffTests {
    // MARK: parseStatus

    @Test("joins porcelain status with numstat across all status kinds")
    func statusJoinsCounts() {
        // XY + space + path, NUL-separated; rename consumes an extra field.
        let porcelain =
            " M src/app.swift\u{00}"
            + "A  src/new.swift\u{00}"
            + " D src/gone.swift\u{00}"
            + "R  src/renamed.swift\u{00}src/original.swift\u{00}"
            + "?? notes.txt\u{00}"
            + " M assets/logo.png\u{00}"
        let numstat = """
        5\t2\tsrc/app.swift
        10\t0\tsrc/new.swift
        0\t8\tsrc/gone.swift
        3\t1\tsrc/{original.swift => renamed.swift}
        -\t-\tassets/logo.png
        """

        let changes = GitDiffParser.parseStatus(porcelainZ: porcelain, numstat: numstat)
        #expect(changes.count == 6)

        // Porcelain order is preserved.
        #expect(changes.map(\.path) == [
            "src/app.swift",
            "src/new.swift",
            "src/gone.swift",
            "src/renamed.swift",
            "notes.txt",
            "assets/logo.png",
        ])

        let modified = changes[0]
        #expect(modified.status == .modified)
        #expect(modified.oldPath == nil)
        #expect(modified.added == 5)
        #expect(modified.deleted == 2)

        let added = changes[1]
        #expect(added.status == .added)
        #expect(added.added == 10)
        #expect(added.deleted == 0)

        let deleted = changes[2]
        #expect(deleted.status == .deleted)
        #expect(deleted.added == 0)
        #expect(deleted.deleted == 8)

        let renamed = changes[3]
        #expect(renamed.status == .renamed)
        #expect(renamed.oldPath == "src/original.swift")
        #expect(renamed.added == 3)
        #expect(renamed.deleted == 1)

        let untracked = changes[4]
        #expect(untracked.status == .untracked)
        #expect(untracked.oldPath == nil)
        // Untracked files have no numstat entry → zero counts.
        #expect(untracked.added == 0)
        #expect(untracked.deleted == 0)

        let binary = changes[5]
        #expect(binary.status == .modified)
        #expect(binary.added == -1)
        #expect(binary.deleted == -1)
    }

    @Test("ignores ignored entries and stray trailing NUL")
    func statusIgnoresNoise() {
        let porcelain = "!! build/\u{00} M keep.swift\u{00}"
        let changes = GitDiffParser.parseStatus(porcelainZ: porcelain, numstat: "1\t1\tkeep.swift")
        #expect(changes.map(\.path) == ["keep.swift"])
    }

    @Test("normalizes a plain arrow rename in numstat")
    func statusPlainArrowRename() {
        let porcelain = "R  new.swift\u{00}old.swift\u{00}"
        let numstat = "4\t2\told.swift => new.swift"
        let changes = GitDiffParser.parseStatus(porcelainZ: porcelain, numstat: numstat)
        #expect(changes.count == 1)
        #expect(changes[0].path == "new.swift")
        #expect(changes[0].oldPath == "old.swift")
        #expect(changes[0].added == 4)
        #expect(changes[0].deleted == 2)
    }

    // MARK: parseUnifiedDiff

    @Test("tracks line counters across multiple hunks with a no-newline marker")
    func unifiedDiffCounters() {
        let diff = """
        diff --git a/foo.txt b/foo.txt
        index abc1234..def5678 100644
        --- a/foo.txt
        +++ b/foo.txt
        @@ -1,4 +1,4 @@ func header
         line one
        -old two
        +new two
         line three
        @@ -10,3 +10,4 @@
         ctx ten
        +added eleven
         ctx twelve
        \\ No newline at end of file
        """

        let rows = GitDiffParser.parseUnifiedDiff(diff)

        // File-header lines are dropped; two hunk headers + 7 content rows + marker.
        #expect(rows.count == 10)

        // Hunk 1 header.
        #expect(rows[0].kind == .hunk)
        #expect(rows[0].oldLine == nil)
        #expect(rows[0].newLine == nil)
        #expect(rows[0].mark == nil)
        #expect(rows[0].text == "@@ -1,4 +1,4 @@ func header")

        // ctx "line one" → old 1 / new 1.
        #expect(rows[1].kind == .ctx)
        #expect(rows[1].oldLine == 1)
        #expect(rows[1].newLine == 1)
        #expect(rows[1].text == "line one")

        // del "old two" → old 2, new nil.
        #expect(rows[2].kind == .del)
        #expect(rows[2].oldLine == 2)
        #expect(rows[2].newLine == nil)
        #expect(rows[2].mark == "-")
        #expect(rows[2].text == "old two")

        // add "new two" → new 2, old nil.
        #expect(rows[3].kind == .add)
        #expect(rows[3].oldLine == nil)
        #expect(rows[3].newLine == 2)
        #expect(rows[3].mark == "+")
        #expect(rows[3].text == "new two")

        // ctx "line three" → old 3 / new 3.
        #expect(rows[4].kind == .ctx)
        #expect(rows[4].oldLine == 3)
        #expect(rows[4].newLine == 3)

        // Hunk 2 header resets counters to 10/10.
        #expect(rows[5].kind == .hunk)
        #expect(rows[5].text == "@@ -10,3 +10,4 @@")

        #expect(rows[6].kind == .ctx)
        #expect(rows[6].oldLine == 10)
        #expect(rows[6].newLine == 10)

        #expect(rows[7].kind == .add)
        #expect(rows[7].newLine == 11)
        #expect(rows[7].oldLine == nil)

        // "ctx twelve" follows the addition, so new counter has advanced to 12.
        #expect(rows[8].kind == .ctx)
        #expect(rows[8].oldLine == 11)
        #expect(rows[8].newLine == 12)

        // No-newline marker → ctx row with no numbers.
        #expect(rows[9].kind == .ctx)
        #expect(rows[9].oldLine == nil)
        #expect(rows[9].newLine == nil)
        #expect(rows[9].mark == nil)
        #expect(rows[9].text == "\\ No newline at end of file")
    }

    @Test("empty context lines are preserved as ctx rows")
    func unifiedDiffBlankContext() {
        let diff = """
        @@ -1,3 +1,3 @@
         first

        +added
        """
        let rows = GitDiffParser.parseUnifiedDiff(diff)
        #expect(rows.count == 4)
        #expect(rows[1].kind == .ctx)
        #expect(rows[1].oldLine == 1)
        #expect(rows[1].newLine == 1)
        // The empty line is a context line with both counters.
        #expect(rows[2].kind == .ctx)
        #expect(rows[2].text == "")
        #expect(rows[2].oldLine == 2)
        #expect(rows[2].newLine == 2)
        #expect(rows[3].kind == .add)
    }

    @Test("binary diff collapses to a single context row")
    func unifiedDiffBinary() {
        let diff = """
        diff --git a/img.png b/img.png
        index abc1234..def5678 100644
        Binary files a/img.png and b/img.png differ
        """
        let rows = GitDiffParser.parseUnifiedDiff(diff)
        #expect(rows.count == 1)
        #expect(rows[0].kind == .ctx)
        #expect(rows[0].oldLine == nil)
        #expect(rows[0].newLine == nil)
        #expect(rows[0].text == "Binary files a/img.png and b/img.png differ")
    }

    // MARK: parseLog

    @Test("parses multiple commits and sums numstat lines")
    func logParsesCommits() {
        let log =
            "\u{1e}a1b2c3d4e5f6\u{1f}a1b2c3d\u{1f}Jane Doe\u{1f}2 hours ago\u{1f}Fix parser\n\n"
            + "5\t2\tsrc/a.swift\n3\t0\tsrc/b.swift\n"
            + "\u{1e}9f8e7d6c5b4a\u{1f}9f8e7d6\u{1f}John Roe\u{1f}3 days ago\u{1f}Initial commit\n"
            + "100\t0\tREADME.md"

        let commits = GitDiffParser.parseLog(log)
        #expect(commits.count == 2)

        let first = commits[0]
        #expect(first.hash == "a1b2c3d4e5f6")
        #expect(first.shortHash == "a1b2c3d")
        #expect(first.author == "Jane Doe")
        #expect(first.relativeAge == "2 hours ago")
        #expect(first.message == "Fix parser")
        #expect(first.added == 8)
        #expect(first.deleted == 2)

        let second = commits[1]
        #expect(second.hash == "9f8e7d6c5b4a")
        #expect(second.shortHash == "9f8e7d6")
        #expect(second.author == "John Roe")
        #expect(second.relativeAge == "3 days ago")
        #expect(second.message == "Initial commit")
        #expect(second.added == 100)
        #expect(second.deleted == 0)
    }

    @Test("a commit with binary numstat lines counts them as zero")
    func logBinaryNumstat() {
        let log = "\u{1e}deadbeef\u{1f}deadbee\u{1f}A U Thor\u{1f}now\u{1f}Add asset\n-\t-\tlogo.png"
        let commits = GitDiffParser.parseLog(log)
        #expect(commits.count == 1)
        #expect(commits[0].added == 0)
        #expect(commits[0].deleted == 0)
    }

    // MARK: parseSummary

    @Test("decodes a valid JSON summary")
    func summaryValidJSON() {
        let text = #"{"headline":"Refactor parser","bullets":[{"path":"a.swift","text":"split logic"}],"note":"tests pass"}"#
        let summary = GitDiffParser.parseSummary(text)
        #expect(summary.rawFallback == nil)
        #expect(summary.headline == "Refactor parser")
        #expect(summary.bullets.count == 1)
        #expect(summary.bullets[0].path == "a.swift")
        #expect(summary.bullets[0].text == "split logic")
        #expect(summary.note == "tests pass")
    }

    @Test("decodes JSON wrapped in a Markdown code fence")
    func summaryFencedJSON() {
        let text = """
        ```json
        {"headline":"Fenced","bullets":[{"path":"b.swift","text":"tidy"}],"note":null}
        ```
        """
        let summary = GitDiffParser.parseSummary(text)
        #expect(summary.rawFallback == nil)
        #expect(summary.headline == "Fenced")
        #expect(summary.bullets.count == 1)
        #expect(summary.note == nil)
    }

    @Test("extracts JSON preceded by prose")
    func summaryProseWrapped() {
        let text = "Here is the summary you asked for:\n{\"headline\":\"Prose\",\"bullets\":[]}"
        let summary = GitDiffParser.parseSummary(text)
        #expect(summary.rawFallback == nil)
        #expect(summary.headline == "Prose")
        #expect(summary.bullets.isEmpty)
    }

    @Test("tolerates missing note and bullets keys")
    func summaryMissingKeys() {
        let text = #"{"headline":"Only headline"}"#
        let summary = GitDiffParser.parseSummary(text)
        #expect(summary.rawFallback == nil)
        #expect(summary.headline == "Only headline")
        #expect(summary.bullets.isEmpty)
        #expect(summary.note == nil)
    }

    @Test("malformed JSON falls back to the raw trimmed text")
    func summaryMalformedFallback() {
        let text = "  {this is not valid json}  "
        let summary = GitDiffParser.parseSummary(text)
        #expect(summary.headline == "")
        #expect(summary.bullets.isEmpty)
        #expect(summary.note == nil)
        #expect(summary.rawFallback == "{this is not valid json}")
    }

    @Test("text with no JSON object falls back to raw text")
    func summaryNoBraces() {
        let text = "The model refused to answer."
        let summary = GitDiffParser.parseSummary(text)
        #expect(summary.rawFallback == "The model refused to answer.")
        #expect(summary.headline == "")
    }
}
