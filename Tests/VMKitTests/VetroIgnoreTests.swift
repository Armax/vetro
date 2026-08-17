import Testing
@testable import VMKit

@Suite("Vetroignore patterns")
struct VetroIgnoreTests {
    @Test("empty and whitespace-only text is empty")
    func emptyAndWhitespace() {
        #expect(VetroIgnore.parse(" \n\t\r\n ") == [])
    }

    @Test("comments and blank lines are skipped")
    func commentsAndBlankLines() {
        #expect(VetroIgnore.parse("""
        # comment

          # another comment
        build/

        """) == ["build/"])
    }

    @Test("leading and trailing whitespace is trimmed")
    func trimsWhitespace() {
        #expect(VetroIgnore.parse("  build/  \n\t.cache\t") == ["build/", ".cache"])
    }

    @Test("valid patterns preserve order")
    func preservesOrder() {
        #expect(VetroIgnore.parse("*.log\npackages/\n!keep.log") == [
            "*.log",
            "packages/",
            "!keep.log",
        ])
    }

    @Test("a trimmed comment is skipped")
    func trimmedComment() {
        #expect(VetroIgnore.parse("  # foo\nbar") == ["bar"])
    }

    @Test("inline comments remain part of the pattern")
    func keepsInlineComment() {
        #expect(VetroIgnore.parse("build/ # keep") == ["build/ # keep"])
    }

    @Test("caps valid patterns at one thousand")
    func capsPatterns() {
        let text = (0...1000).map { "pattern-\($0)" }.joined(separator: "\n")
        let patterns = VetroIgnore.parse(text)

        #expect(patterns.count == 1000)
        #expect(patterns.first == "pattern-0")
        #expect(patterns.last == "pattern-999")
    }

    @Test("comments and blanks do not consume the pattern cap")
    func capCountsOnlyValidPatterns() {
        var lines: [String] = []
        for index in 0..<1000 {
            lines.append("")
            lines.append(" # comment \(index)")
            lines.append(" pattern-\(index) ")
        }
        lines.append("pattern-1000")

        let patterns = VetroIgnore.parse(lines.joined(separator: "\n"))

        #expect(patterns.count == 1000)
        #expect(patterns.last == "pattern-999")
    }
}
