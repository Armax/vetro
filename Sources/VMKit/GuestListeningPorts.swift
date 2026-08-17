import Foundation

public enum GuestListeningPorts {
    public static func parse(_ ssOutput: String) -> Set<UInt16> {
        var ports = Set<UInt16>()
        for line in ssOutput.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 5, parts[0] == "LISTEN" else { continue }
            if let port = port(fromLocalAddress: String(parts[3])) {
                ports.insert(port)
            }
        }
        return ports
    }

    /// Extracts LISTEN ports from `/proc/net/tcp` or `/proc/net/tcp6` text.
    public static func parseProcNet(_ content: String) -> Set<UInt16> {
        var ports = Set<UInt16>()
        for line in content.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 4, parts[3] == "0A" else { continue }
            let local = parts[1]
            guard let separator = local.lastIndex(of: ":") else { continue }
            let portHex = local[local.index(after: separator)...]
            guard let raw = UInt32(portHex, radix: 16),
                  let port = UInt16(exactly: raw),
                  port > 0
            else { continue }
            ports.insert(port)
        }
        return ports
    }

    private static func port(fromLocalAddress address: String) -> UInt16? {
        guard let separator = address.lastIndex(of: ":") else { return nil }
        let portText = address[address.index(after: separator)...]
        guard let port = UInt16(portText), port > 0 else { return nil }
        return port
    }
}

/// One JSON line from the guest port-event stream on vsock 1029.
public struct PortEvent: Codable, Equatable, Sendable {
    public var snapshot: [UInt16]?
    public var added: [UInt16]
    public var removed: [UInt16]
    public var refused: [UInt16]?

    public init(
        snapshot: [UInt16]? = nil,
        added: [UInt16] = [],
        removed: [UInt16] = [],
        refused: [UInt16]? = nil
    ) {
        self.snapshot = snapshot
        self.added = added
        self.removed = removed
        self.refused = refused
    }

    enum CodingKeys: String, CodingKey {
        case snapshot
        case added
        case removed
        case refused
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        snapshot = try container.decodeIfPresent([UInt16].self, forKey: .snapshot)
        added = try container.decodeIfPresent([UInt16].self, forKey: .added) ?? []
        removed = try container.decodeIfPresent([UInt16].self, forKey: .removed) ?? []
        refused = try container.decodeIfPresent([UInt16].self, forKey: .refused)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(snapshot, forKey: .snapshot)
        try container.encode(added, forKey: .added)
        try container.encode(removed, forKey: .removed)
        try container.encodeIfPresent(refused, forKey: .refused)
    }
}

public typealias PortDiff = PortEvent
