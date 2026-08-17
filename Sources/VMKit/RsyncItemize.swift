public enum TransferEntryKind: Sendable, Equatable, Hashable {
    case file
    case directory
    case symlink
}

public struct TransferChange: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { path }
    public var path: String
    public var kind: TransferEntryKind

    public init(path: String, kind: TransferEntryKind) {
        self.path = path
        self.kind = kind
    }
}

public struct TransferPreview: Sendable, Equatable {
    public var adds: [TransferChange]
    public var updates: [TransferChange]
    public var deletes: [TransferChange]
    public var isEmpty: Bool { adds.isEmpty && updates.isEmpty && deletes.isEmpty }

    public init(
        adds: [TransferChange] = [],
        updates: [TransferChange] = [],
        deletes: [TransferChange] = []
    ) {
        self.adds = adds
        self.updates = updates
        self.deletes = deletes
    }
}

public enum RsyncItemize {
    public static func parse(_ text: String) -> TransferPreview {
        var adds: [TransferChange] = []
        var updates: [TransferChange] = []
        var deletes: [TransferChange] = []
        var addedPaths = Set<String>()
        var updatedPaths = Set<String>()
        var deletedPaths = Set<String>()

        for line in text.split(whereSeparator: \.isNewline) {
            let trimmedLine = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else { continue }

            if trimmedLine.hasPrefix("*deleting") {
                let remainder = String(trimmedLine.dropFirst("*deleting".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let isDirectory = remainder.hasSuffix("/")
                let rawPath = isDirectory ? String(remainder.dropLast()) : remainder
                guard let path = normalizedPath(rawPath), deletedPaths.insert(path).inserted else {
                    continue
                }
                deletes.append(
                    TransferChange(
                        path: path,
                        kind: isDirectory ? .directory : .file
                    )
                )
                continue
            }

            let fields = trimmedLine.split(
                maxSplits: 1,
                omittingEmptySubsequences: true,
                whereSeparator: { $0.isWhitespace }
            )
            let flagCount = fields.first?.count ?? 0
            guard fields.count == 2, flagCount == 9 || flagCount == 11 else { continue }

            let flags = Array(fields[0])
            guard [">", "<", "c"].contains(flags[0]) else { continue }

            let kind: TransferEntryKind
            switch flags[1] {
            case "f": kind = .file
            case "d": kind = .directory
            case "L", "l": kind = .symlink
            default: continue
            }

            guard let path = normalizedPath(String(fields[1])) else { continue }
            let changes = flags[2...]
            if changes.contains("+") {
                guard addedPaths.insert(path).inserted else { continue }
                adds.append(TransferChange(path: path, kind: kind))
            } else if [flags[2], flags[3], flags[4]].contains(where: {
                ["c", "C", "s", "S", "t", "T"].contains($0)
            }) {
                guard updatedPaths.insert(path).inserted else { continue }
                updates.append(TransferChange(path: path, kind: kind))
            }
        }

        return TransferPreview(adds: adds, updates: updates, deletes: deletes)
    }

    private static func normalizedPath(_ rawPath: String) -> String? {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.hasPrefix("./") {
            path.removeFirst(2)
        }
        if path.hasSuffix("/") {
            path.removeLast()
        }
        guard !path.isEmpty, path != "." else { return nil }
        return path
    }
}

public extension TransferPreview {
    static func parseItemizeOutput(_ text: String) -> TransferPreview {
        RsyncItemize.parse(text)
    }
}
