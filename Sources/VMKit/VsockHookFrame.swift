import Foundation

enum VsockHookFrame {
    static let maxLineBytes = 16_384

    struct Event: Equatable, Sendable {
        var sessionID: UUID?
        var name: String
        var payload: String
    }

    enum Outcome: Equatable, Sendable {
        case event(Event)
        case ignored
        case needMore
        case overflow
    }

    static func consume(from buffer: inout Data) -> Outcome {
        guard let newline = buffer.firstIndex(of: 0x0A) else {
            return buffer.count > maxLineBytes ? .overflow : .needMore
        }
        var line = buffer[..<newline]
        buffer.removeSubrange(...newline)
        if line.count > maxLineBytes {
            return .ignored
        }
        if line.last == 0x0D {
            line.removeLast()
        }
        guard let text = String(data: Data(line), encoding: .utf8) else {
            return .ignored
        }
        let parts = text.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return .ignored }
        let name = String(parts[1])
        guard !name.isEmpty else { return .ignored }
        return .event(
            Event(
                sessionID: UUID(uuidString: String(parts[0])),
                name: name,
                payload: parts.count >= 3 ? String(parts[2]) : ""
            )
        )
    }
}
