import Foundation

/// The change status of a file relative to `HEAD`, as reported by
/// `git status --porcelain`.
public enum GitFileStatus: String, Sendable {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case untracked = "?"
}

/// A single changed file in the working tree, joined with its line counts.
public struct GitFileChange: Sendable, Identifiable, Hashable {
    public var id: String { path }
    /// The current path of the file (the new path for renames).
    public let path: String
    /// The original path, present only for renames.
    public let oldPath: String?
    public let status: GitFileStatus
    /// Added lines, or `-1` when the file is binary or the count is unknown.
    public let added: Int
    /// Deleted lines, or `-1` when the file is binary or the count is unknown.
    public let deleted: Int

    public init(path: String, oldPath: String?, status: GitFileStatus, added: Int, deleted: Int) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.added = added
        self.deleted = deleted
    }
}

/// A single rendered row of a unified diff.
public struct DiffRow: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case hunk
        case add
        case del
        case ctx
    }

    public let kind: Kind
    /// The line number in the old file, when applicable.
    public let oldLine: Int?
    /// The line number in the new file, when applicable.
    public let newLine: Int?
    /// The gutter mark: ASCII `+` for additions, `-` for deletions, `nil` otherwise.
    public let mark: Character?
    /// The row text (without the leading diff mark for add/del/ctx rows).
    public let text: String

    public init(kind: Kind, oldLine: Int?, newLine: Int?, mark: Character?, text: String) {
        self.kind = kind
        self.oldLine = oldLine
        self.newLine = newLine
        self.mark = mark
        self.text = text
    }
}

/// A single commit from `git log`, with its aggregate line counts.
public struct GitCommit: Sendable, Identifiable, Hashable {
    public var id: String { hash }
    public let hash: String
    public let shortHash: String
    public let message: String
    public let author: String
    public let relativeAge: String
    public let added: Int
    public let deleted: Int

    public init(
        hash: String,
        shortHash: String,
        message: String,
        author: String,
        relativeAge: String,
        added: Int,
        deleted: Int
    ) {
        self.hash = hash
        self.shortHash = shortHash
        self.message = message
        self.author = author
        self.relativeAge = relativeAge
        self.added = added
        self.deleted = deleted
    }
}

/// A structured AI-generated summary of a diff, with a plain-text fallback.
public struct GitSummary: Sendable, Hashable {
    public struct Bullet: Sendable, Hashable {
        public let path: String
        public let text: String

        public init(path: String, text: String) {
            self.path = path
            self.text = text
        }
    }

    public let headline: String
    public let bullets: [Bullet]
    public let note: String?
    /// Non-`nil` when JSON parsing failed; `headline` is empty in that case.
    public let rawFallback: String?

    public init(headline: String, bullets: [Bullet], note: String?, rawFallback: String?) {
        self.headline = headline
        self.bullets = bullets
        self.note = note
        self.rawFallback = rawFallback
    }
}

/// Pure parsers turning git command output into rendering models. No I/O.
public enum GitDiffParser {
    // MARK: Status

    /// Joins `git status --porcelain=v1 -z` with `git diff HEAD --numstat -M`.
    ///
    /// - Parameters:
    ///   - porcelainZ: NUL-separated porcelain-v1 output. Rename entries are
    ///     followed by an extra NUL-separated field holding the original path.
    ///   - numstat: `added\tdeleted\tpath` lines; `-\t-` marks binary files.
    /// - Returns: One change per porcelain entry, in porcelain order.
    public static func parseStatus(porcelainZ: String, numstat: String) -> [GitFileChange] {
        let counts = parseNumstat(numstat)

        // Split on NUL, keeping empties so we can walk fields deterministically.
        let fields = porcelainZ.split(separator: "\u{00}", omittingEmptySubsequences: false)
            .map(String.init)

        var result: [GitFileChange] = []
        var index = 0
        while index < fields.count {
            let entry = fields[index]
            index += 1
            // A trailing empty field (from a terminating NUL) is not an entry.
            guard entry.count >= 3 else { continue }

            let xy = String(entry.prefix(2))
            // Porcelain separates the XY code from the path with a single space.
            let path = String(entry.dropFirst(3))

            // Ignore ignored (`!!`) and submodule-only noise; keep real changes.
            if xy == "!!" { continue }

            let status: GitFileStatus
            var oldPath: String? = nil
            if xy == "??" {
                status = .untracked
            } else if xy.contains("R") || xy.contains("C") {
                // Renames and copies consume the next field as the original
                // path; copies only appear when detection is enabled, but
                // skipping their extra field keeps the stream aligned.
                status = .renamed
                if index < fields.count {
                    oldPath = fields[index]
                    index += 1
                }
            } else if xy.contains("D") {
                status = .deleted
            } else if xy.contains("A") {
                status = .added
            } else if xy.contains("M") {
                status = .modified
            } else {
                continue
            }

            let count = counts[path]
            result.append(
                GitFileChange(
                    path: path,
                    oldPath: oldPath,
                    status: status,
                    added: count?.added ?? 0,
                    deleted: count?.deleted ?? 0
                )
            )
        }
        return result
    }

    /// Parses numstat output into a path → (added, deleted) map.
    private static func parseNumstat(_ text: String) -> [String: (added: Int, deleted: Int)] {
        var counts: [String: (added: Int, deleted: Int)] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { continue }
            let addedField = parts[0]
            let deletedField = parts[1]
            // The path may itself contain tabs; rejoin everything after the counts.
            let pathField = parts[2...].joined(separator: "\t")

            let path = normalizeNumstatPath(pathField)
            if addedField == "-" || deletedField == "-" {
                counts[path] = (-1, -1)
            } else {
                let added = Int(addedField) ?? 0
                let deleted = Int(deletedField) ?? 0
                counts[path] = (added, deleted)
            }
        }
        return counts
    }

    /// Normalizes a numstat rename path to the new path.
    ///
    /// Renames appear either as `old => new` or `prefix{old => new}suffix`.
    private static func normalizeNumstatPath(_ field: String) -> String {
        guard field.contains("=>") else { return field }

        if let braceOpen = field.range(of: "{"),
            let braceClose = field.range(of: "}"),
            braceOpen.lowerBound < braceClose.lowerBound {
            let prefix = String(field[field.startIndex..<braceOpen.lowerBound])
            let inner = String(field[braceOpen.upperBound..<braceClose.lowerBound])
            let suffix = String(field[braceClose.upperBound...])
            let newInner: String
            if let arrow = inner.range(of: "=>") {
                newInner = String(inner[arrow.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
            } else {
                newInner = inner.trimmingCharacters(in: .whitespaces)
            }
            return prefix + newInner + suffix
        }

        // Plain `old => new`.
        if let arrow = field.range(of: "=>") {
            return String(field[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return field
    }

    // MARK: Unified diff

    /// Parses a unified diff for a single file into renderable rows.
    public static func parseUnifiedDiff(_ text: String) -> [DiffRow] {
        var rows: [DiffRow] = []
        var oldCounter = 0
        var newCounter = 0

        // Split preserving empty lines so blank context rows survive.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for line in lines {
            if line.hasPrefix("diff --git")
                || line.hasPrefix("index ")
                || line.hasPrefix("--- ")
                || line.hasPrefix("+++ ")
                || line.hasPrefix("old mode ")
                || line.hasPrefix("new mode ")
                || line.hasPrefix("deleted file mode ")
                || line.hasPrefix("new file mode ")
                || line.hasPrefix("similarity index ")
                || line.hasPrefix("dissimilarity index ")
                || line.hasPrefix("rename from ")
                || line.hasPrefix("rename to ")
                || line.hasPrefix("copy from ")
                || line.hasPrefix("copy to ") {
                continue
            }

            if line.hasPrefix("Binary files ") {
                rows.append(DiffRow(kind: .ctx, oldLine: nil, newLine: nil, mark: nil, text: line))
                continue
            }

            if line.hasPrefix("@@") {
                if let (oldStart, newStart) = parseHunkHeader(line) {
                    oldCounter = oldStart
                    newCounter = newStart
                }
                rows.append(DiffRow(kind: .hunk, oldLine: nil, newLine: nil, mark: nil, text: line))
                continue
            }

            if line.hasPrefix("\\") {
                // `\ No newline at end of file` — attach to the flow with no numbers.
                rows.append(DiffRow(kind: .ctx, oldLine: nil, newLine: nil, mark: nil, text: line))
                continue
            }

            if line.hasPrefix("+") {
                let text = String(line.dropFirst())
                rows.append(DiffRow(kind: .add, oldLine: nil, newLine: newCounter, mark: "+", text: text))
                newCounter += 1
                continue
            }

            if line.hasPrefix("-") {
                let text = String(line.dropFirst())
                rows.append(DiffRow(kind: .del, oldLine: oldCounter, newLine: nil, mark: "-", text: text))
                oldCounter += 1
                continue
            }

            // Context: a line starting with a space, or an empty line.
            let text = line.hasPrefix(" ") ? String(line.dropFirst()) : line
            rows.append(DiffRow(kind: .ctx, oldLine: oldCounter, newLine: newCounter, mark: nil, text: text))
            oldCounter += 1
            newCounter += 1
        }
        return rows
    }

    /// Extracts the old/new starting line numbers from a `@@ -a,b +c,d @@` header.
    private static func parseHunkHeader(_ line: String) -> (old: Int, new: Int)? {
        // Grab the segment between the two `@@` markers.
        guard let firstRange = line.range(of: "@@") else { return nil }
        let afterFirst = line[firstRange.upperBound...]
        guard let secondRange = afterFirst.range(of: "@@") else { return nil }
        let spec = afterFirst[afterFirst.startIndex..<secondRange.lowerBound]
            .trimmingCharacters(in: .whitespaces)

        var oldStart: Int? = nil
        var newStart: Int? = nil
        for token in spec.split(separator: " ") {
            guard let sign = token.first, sign == "-" || sign == "+" else { continue }
            let body = token.dropFirst()
            let startText = body.split(separator: ",").first.map(String.init) ?? String(body)
            let value = Int(startText)
            if sign == "-" { oldStart = value } else { newStart = value }
        }
        guard let old = oldStart, let new = newStart else { return nil }
        return (old, new)
    }

    // MARK: Log

    /// Parses `git log --pretty=format:'%x1e%H%x1f%h%x1f%an%x1f%ar%x1f%s' --numstat`.
    public static func parseLog(_ text: String) -> [GitCommit] {
        var commits: [GitCommit] = []
        // Records are separated by the record-separator control character.
        let records = text.split(separator: "\u{1e}", omittingEmptySubsequences: true)
        for record in records {
            let recordText = String(record)
            // The header fields occupy the first line; numstat lines follow.
            guard let firstNewline = recordText.firstIndex(of: "\n") else {
                // A commit with no numstat body still has a header.
                if let commit = commitFromHeader(recordText, numstat: "") {
                    commits.append(commit)
                }
                continue
            }
            let header = String(recordText[recordText.startIndex..<firstNewline])
            let body = String(recordText[recordText.index(after: firstNewline)...])
            if let commit = commitFromHeader(header, numstat: body) {
                commits.append(commit)
            }
        }
        return commits
    }

    private static func commitFromHeader(_ header: String, numstat: String) -> GitCommit? {
        let fields = header.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 5 else { return nil }
        let hash = fields[0]
        let shortHash = fields[1]
        let author = fields[2]
        let relativeAge = fields[3]
        // The subject may legitimately contain the field separator collapsing;
        // rejoin any trailing pieces into the message.
        let message = fields[4...].joined(separator: "\u{1f}")

        var added = 0
        var deleted = 0
        for rawLine in numstat.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = rawLine.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }
            added += Int(parts[0]) ?? 0
            deleted += Int(parts[1]) ?? 0
        }

        return GitCommit(
            hash: hash,
            shortHash: shortHash,
            message: message,
            author: author,
            relativeAge: relativeAge,
            added: added,
            deleted: deleted
        )
    }

    // MARK: Summary

    private struct SummaryJSON: Decodable {
        struct Bullet: Decodable {
            let path: String
            let text: String
        }
        let headline: String
        let bullets: [Bullet]?
        let note: String?
    }

    /// Parses an AI summary payload, tolerating code fences and surrounding prose.
    ///
    /// Any failure yields a `GitSummary` carrying the trimmed original in
    /// `rawFallback` with an empty `headline`.
    public static func parseSummary(_ text: String) -> GitSummary {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = GitSummary(headline: "", bullets: [], note: nil, rawFallback: trimmed)

        // Strip a leading/trailing Markdown code fence if present.
        var candidate = trimmed
        if candidate.hasPrefix("```") {
            candidate = stripCodeFence(candidate)
        }

        // Take the substring from the first `{` to the last `}`.
        guard let open = candidate.firstIndex(of: "{"),
            let close = candidate.lastIndex(of: "}"),
            open < close else {
            return fallback
        }
        let jsonText = String(candidate[open...close])

        guard let data = jsonText.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(SummaryJSON.self, from: data) else {
            return fallback
        }

        let bullets = (decoded.bullets ?? []).map {
            GitSummary.Bullet(path: $0.path, text: $0.text)
        }
        return GitSummary(
            headline: decoded.headline,
            bullets: bullets,
            note: decoded.note,
            rawFallback: nil
        )
    }

    /// Removes a fenced code block wrapper (```lang\n … \n```), returning the body.
    private static func stripCodeFence(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty, lines[0].hasPrefix("```") else { return text }
        lines.removeFirst()
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }
}
