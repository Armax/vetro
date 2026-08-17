import Foundation

public enum VetroIgnore {
    private static let maximumPatternCount = 1000

    public static func parse(_ text: String) -> [String] {
        var patterns: [String] = []
        patterns.reserveCapacity(maximumPatternCount)

        for line in text.split(whereSeparator: \.isNewline) {
            let pattern = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pattern.isEmpty, !pattern.hasPrefix("#") else { continue }
            patterns.append(pattern)
            if patterns.count == maximumPatternCount { break }
        }

        return patterns
    }
}
