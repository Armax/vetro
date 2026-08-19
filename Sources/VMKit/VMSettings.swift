import Foundation

/// The durable hardware and lifecycle settings stored in `vm.json`.
///
/// The MAC address is generated once by ``VMSettingsStore`` and then reused so
/// NAT lease lookup remains deterministic across application launches.
public struct VMSettings: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case cpus
        case memoryMB
        case diskSizeGB
        case macAddress
        case firstBootCompleted
        case installAgents
        case transferAuthFromMac
        case customScript
        case idleStopMinutes
        case networkEnabled
        case desktopEnabled
        case goldenCaptureCacheKey
    }

    /// Agent names installed by default when `vm.json` omits `installAgents`.
    public static let defaultInstallAgents = ["claude", "codex", "grok"]

    /// The number of virtual CPUs presented to the guest.
    public var cpus: Int

    /// The guest's configured memory size in mebibytes.
    public var memoryMB: Int

    /// The maximum sparse root-disk size in gibibytes.
    public var diskSizeGB: Int

    /// The fixed, locally administered unicast MAC address used by the guest.
    public var macAddress: String

    /// Whether the guest has reached SSH readiness at least once.
    public var firstBootCompleted: Bool

    /// Agent CLIs selected for first-boot installation.
    public var installAgents: [String]

    /// Whether to transfer this Mac's agent authentication into the guest at boot.
    public var transferAuthFromMac: Bool

    /// Optional multiline guest setup script run as the final provision phase.
    public var customScript: String?

    /// Idle minutes before the host auto-stops the VM; `nil` disables the timer.
    public var idleStopMinutes: Int?

    /// Whether the guest receives a NAT network device. SSH still rides vsock.
    public var networkEnabled: Bool

    /// Whether the guest gets a graphics stack and an XFCE desktop environment.
    public var desktopEnabled: Bool

    /// Cache key of a golden this VM should capture on the next clean stop.
    public var goldenCaptureCacheKey: String?

    /// Creates a complete set of durable VM settings.
    ///
    /// - Parameters:
    ///   - cpus: The number of virtual CPUs, which must be positive before VM configuration.
    ///   - memoryMB: Guest memory in mebibytes; defaults to 4096 MiB.
    ///   - diskSizeGB: Sparse root-disk size in gibibytes; defaults to 32 GiB.
    ///   - macAddress: A fixed locally administered unicast MAC address.
    ///   - firstBootCompleted: Whether a prior boot reached SSH readiness; defaults to `false`.
    ///   - installAgents: Selected first-boot agent names; defaults to all three.
    ///   - transferAuthFromMac: Whether to transfer host agent auth at boot; defaults to `false`.
    ///   - customScript: Optional guest setup script; defaults to `nil`.
    ///   - idleStopMinutes: Idle auto-stop window; defaults to `nil` (off).
    ///   - networkEnabled: Whether to attach NAT; defaults to `true`.
    ///   - goldenCaptureCacheKey: Pending golden-capture marker; defaults to `nil`.
    public init(
        cpus: Int,
        memoryMB: Int = 4_096,
        diskSizeGB: Int = 32,
        macAddress: String,
        firstBootCompleted: Bool = false,
        installAgents: [String] = VMSettings.defaultInstallAgents,
        transferAuthFromMac: Bool = false,
        customScript: String? = nil,
        idleStopMinutes: Int? = nil,
        networkEnabled: Bool = true,
        desktopEnabled: Bool = false,
        goldenCaptureCacheKey: String? = nil
    ) {
        self.cpus = cpus
        self.memoryMB = memoryMB
        self.diskSizeGB = diskSizeGB
        self.macAddress = macAddress
        self.firstBootCompleted = firstBootCompleted
        self.installAgents = installAgents
        self.transferAuthFromMac = transferAuthFromMac
        self.customScript = customScript
        self.idleStopMinutes = idleStopMinutes
        self.networkEnabled = networkEnabled
        self.desktopEnabled = desktopEnabled
        self.goldenCaptureCacheKey = goldenCaptureCacheKey
    }

    /// Decodes persisted settings while filling fields added after the M1 snapshot.
    ///
    /// Missing keys keep the historical defaults so older `vm.json` files load.
    ///
    /// - Parameter decoder: The decoder containing a complete hardware snapshot.
    /// - Throws: A decoding error when a required hardware field is absent or invalid.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cpus = try container.decode(Int.self, forKey: .cpus)
        memoryMB = try container.decode(Int.self, forKey: .memoryMB)
        diskSizeGB = try container.decode(Int.self, forKey: .diskSizeGB)
        macAddress = try container.decode(String.self, forKey: .macAddress)
        firstBootCompleted = try container.decodeIfPresent(
            Bool.self,
            forKey: .firstBootCompleted
        ) ?? false
        installAgents = try container.decodeIfPresent(
            [String].self,
            forKey: .installAgents
        ) ?? Self.defaultInstallAgents
        transferAuthFromMac = try container.decodeIfPresent(
            Bool.self,
            forKey: .transferAuthFromMac
        ) ?? false
        customScript = try container.decodeIfPresent(String.self, forKey: .customScript)
        idleStopMinutes = try container.decodeIfPresent(Int.self, forKey: .idleStopMinutes)
        networkEnabled = try container.decodeIfPresent(Bool.self, forKey: .networkEnabled) ?? true
        desktopEnabled = try container.decodeIfPresent(Bool.self, forKey: .desktopEnabled) ?? false
        goldenCaptureCacheKey = try container.decodeIfPresent(
            String.self,
            forKey: .goldenCaptureCacheKey
        )
    }

    /// Builds first-run settings from injected host processor information.
    ///
    /// Performance-core count is preferred when available; otherwise the
    /// active processor count is used. The result is clamped to `1...6`.
    ///
    /// - Parameters:
    ///   - performanceCoreCount: The host's performance-core count, or `nil` when unavailable.
    ///   - activeProcessorCount: The number of currently active host processors.
    ///   - macAddress: The generated, persistent guest MAC address.
    /// - Returns: Settings with the M1 memory, disk, and lifecycle defaults.
    public static func defaults(
        performanceCoreCount: Int?,
        activeProcessorCount: Int,
        macAddress: String
    ) -> VMSettings {
        let availableCPUs = performanceCoreCount.flatMap { $0 > 0 ? $0 : nil }
            ?? activeProcessorCount
        return VMSettings(
            cpus: max(1, min(availableCPUs, 6)),
            macAddress: macAddress
        )
    }

    /// Generates a lowercase, locally administered unicast MAC address.
    static func makeRandomMACAddress() -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes = (0..<6).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        bytes[0] = (bytes[0] | 0x02) & 0xFE
        return bytes.map(Self.twoDigitHex).joined(separator: ":")
    }

    /// Formats one byte without introducing locale-sensitive formatting.
    private static func twoDigitHex(_ byte: UInt8) -> String {
        let digits = Array("0123456789abcdef")
        return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]])
    }
}
