public import Foundation

/// Resolves a Virtualization.framework NAT guest's IPv4 address from DHCP leases.
///
/// The parser accepts the compact lease format written by macOS and normalizes
/// hex octets because `/var/db/dhcpd_leases` may omit leading zeroes from the
/// persisted hardware address.
public struct NetworkResolver: Sendable {
    private let leasesURL: URL
    private let pollInterval: Duration
    private let clock: ContinuousClock
    private let readFile: @Sendable (URL) throws -> String
    private let sleep: @Sendable (Duration) async throws -> Void

    /// Creates a resolver for the system NAT DHCP lease database.
    ///
    /// - Parameters:
    ///   - leasesURL: The lease database URL; defaults to `/var/db/dhcpd_leases`.
    ///   - pollInterval: The mandated DHCP polling interval; defaults to one second.
    public init(
        leasesURL: URL = URL(fileURLWithPath: "/var/db/dhcpd_leases", isDirectory: false),
        pollInterval: Duration = .seconds(1)
    ) {
        self.leasesURL = leasesURL
        self.pollInterval = pollInterval
        self.clock = ContinuousClock()
        self.readFile = { url in
            try String(contentsOf: url, encoding: .utf8)
        }
        self.sleep = { duration in
            try await Task.sleep(for: duration)
        }
    }

    /// Creates a resolver with injected I/O and time dependencies.
    ///
    /// - Parameters:
    ///   - leasesURL: The lease database URL passed to `readFile`.
    ///   - pollInterval: The delay between unsuccessful lease reads.
    ///   - clock: The monotonic clock used to enforce the timeout.
    ///   - readFile: The filesystem seam used to load a lease snapshot.
    ///   - sleep: The cancellable delay seam used between specified polls.
    public init(
        leasesURL: URL,
        pollInterval: Duration,
        clock: ContinuousClock,
        readFile: @escaping @Sendable (URL) throws -> String,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.leasesURL = leasesURL
        self.pollInterval = pollInterval
        self.clock = clock
        self.readFile = readFile
        self.sleep = sleep
    }

    /// Polls the DHCP database until the supplied MAC address has an IPv4 lease.
    ///
    /// Transient read errors are treated like a lease miss because the DHCP
    /// file may not exist at the beginning of boot. Cancellation is propagated.
    ///
    /// - Parameters:
    ///   - macAddress: The persisted VM MAC address.
    ///   - timeout: The maximum monotonic duration to wait.
    /// - Returns: The matching IPv4 address, or `nil` at timeout or for an invalid MAC.
    /// - Throws: `CancellationError` or an error from the injected sleep dependency.
    public func resolve(macAddress: String, timeout: Duration) async throws -> String? {
        guard normalizeMACAddress(macAddress) != nil else { return nil }
        let deadline = clock.now.advanced(by: timeout)

        while true {
            try Task.checkCancellation()
            if let contents = try? readFile(leasesURL),
               let address = ipAddress(forMACAddress: macAddress, in: contents)
            {
                return address
            }

            let now = clock.now
            guard now < deadline else { return nil }
            let remaining = now.duration(to: deadline)
            // M1 explicitly requires a one-second DHCP lease polling cadence.
            try await sleep(min(pollInterval, remaining))
        }
    }

    /// Finds the last matching IPv4 lease in a DHCP database snapshot.
    ///
    /// - Parameters:
    ///   - macAddress: A six-octet colon-separated MAC address.
    ///   - contents: The complete `/var/db/dhcpd_leases` text.
    /// - Returns: The matching `ip_address` value, or `nil` when absent.
    public func ipAddress(forMACAddress macAddress: String, in contents: String) -> String? {
        guard let targetMAC = normalizeMACAddress(macAddress) else { return nil }
        var matchingAddress: String?

        for candidate in contents.split(separator: "}", omittingEmptySubsequences: true) {
            guard let openingBrace = candidate.lastIndex(of: "{") else { continue }
            let body = candidate[candidate.index(after: openingBrace)...]
            var hardwareAddress: String?
            var ipAddress: String?

            for rawField in body.split(separator: ";", omittingEmptySubsequences: true) {
                let pair = rawField.split(
                    separator: "=",
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                )
                guard pair.count == 2 else { continue }
                let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
                switch key {
                case "hw_address":
                    hardwareAddress = value.split(
                        separator: ",",
                        maxSplits: 1,
                        omittingEmptySubsequences: false
                    ).last.map(String.init)
                case "ip_address":
                    ipAddress = value
                default:
                    break
                }
            }

            if let hardwareAddress,
               normalizeMACAddress(hardwareAddress) == targetMAC,
               let ipAddress,
               !ipAddress.isEmpty
            {
                matchingAddress = ipAddress
            }
        }
        return matchingAddress
    }

    /// Canonicalizes a MAC address to six two-digit lowercase hex octets.
    ///
    /// - Parameter macAddress: A colon-separated address whose octets may omit leading zeroes.
    /// - Returns: The canonical address, or `nil` for malformed input.
    public func normalizeMACAddress(_ macAddress: String) -> String? {
        let octets = macAddress
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard octets.count == 6 else { return nil }

        var normalized: [String] = []
        normalized.reserveCapacity(6)
        for octet in octets {
            guard (1...2).contains(octet.count), let value = UInt8(octet, radix: 16) else {
                return nil
            }
            normalized.append(Self.twoDigitHex(value))
        }
        return normalized.joined(separator: ":")
    }

    /// Formats one byte as two lowercase hexadecimal characters.
    private static func twoDigitHex(_ byte: UInt8) -> String {
        let digits = Array("0123456789abcdef")
        return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]])
    }
}
