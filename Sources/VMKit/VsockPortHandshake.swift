import Foundation

enum VsockGuestHandshake: Sendable, Equatable {
    case none
    case connect(guestPort: UInt16)
}

enum VsockPortHandshake {
    enum Response: Equatable, Sendable {
        case ok
        case error(String)
        case invalid
    }

    static func request(guestPort: UInt16) -> Data {
        Data("CONNECT \(guestPort)\n".utf8)
    }

    static func consumeResponse(from buffer: inout Data) -> Response? {
        guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
        var line = buffer[..<newline]
        if line.last == 0x0D {
            line.removeLast()
        }
        buffer.removeSubrange(...newline)
        guard let text = String(data: Data(line), encoding: .utf8) else {
            return .invalid
        }
        if text == "OK" {
            return .ok
        }
        if text.hasPrefix("ERR") {
            let reason = text.dropFirst(3).trimmingCharacters(in: .whitespaces)
            return .error(reason)
        }
        return .invalid
    }

    enum Request: Equatable, Sendable {
        case connect(guestPort: UInt16)
        case invalid
    }

    /// Parses one `CONNECT <port>\n` request. `nil` means the buffer has no complete line yet.
    static func consumeRequest(from buffer: inout Data) -> Request? {
        guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
        var line = buffer[..<newline]
        if line.last == 0x0D {
            line.removeLast()
        }
        buffer.removeSubrange(...newline)
        guard let text = String(data: Data(line), encoding: .utf8),
              text.hasPrefix("CONNECT ")
        else {
            return .invalid
        }
        let token = text.dropFirst(8).trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty,
              token.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let value = Int(token),
              value >= 1,
              value <= 65_535,
              let port = UInt16(exactly: value)
        else {
            return .invalid
        }
        return .connect(guestPort: port)
    }
}
