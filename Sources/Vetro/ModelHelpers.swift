import Foundation

extension Project {
    /// Current git branch, read from .git/HEAD (cheap; no git invocation).
    var gitBranch: String? {
        guard let head = try? String(contentsOf: url.appendingPathComponent(".git/HEAD"), encoding: .utf8)
        else { return nil }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "refs/heads/") {
            return String(trimmed[range.upperBound...])
        }
        return String(trimmed.prefix(7))
    }

    /// "~/dev/vetro"-style path for display.
    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

enum RelativeTimestamp {
    /// Compact relative age: "now", "2m", "1h", "Yesterday", "3d".
    static func compact(since date: Date, now: Date = .now) -> String {
        let s = Int(now.timeIntervalSince(date))
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(s / 60)m"
        case ..<86400: return "\(s / 3600)h"
        case ..<172800: return "Yesterday"
        default: return "\(s / 86400)d"
        }
    }
}

extension Session {
    /// Compact relative age: "now", "2m", "1h", "Yesterday", "3d".
    var timeLabel: String {
        RelativeTimestamp.compact(since: createdAt)
    }
}
