/// The ready guest address and measured M1 startup stages.
public struct VMStartResult: Sendable, Equatable {
    /// The IPv4 address selected by vsock or the NAT DHCP lease resolver.
    public let ipAddress: String

    /// The ephemeral host loopback port forwarding SSH over virtio-vsock.
    public let forwardedPort: UInt16

    /// Seconds spent verifying or downloading the base image.
    public let imageReadySeconds: Double

    /// Seconds spent preserving or materializing the writable sparse disk.
    public let diskReadySeconds: Double

    /// Seconds spent preparing the SSH identity and NoCloud seed.
    public let seedReadySeconds: Double

    /// Seconds from the VZ start request until an IP address was resolved.
    public let bootToIPSeconds: Double

    /// Seconds from IP resolution until `ssh true` succeeded.
    public let ipToSSHReadySeconds: Double

    /// Total seconds from entering
    /// ``VMController/start(imageDownloadProgress:imagePreparationUpdate:sharedDirectory:)`` to readiness.
    public let totalSeconds: Double

    /// Whether the guest root filesystem still needs to be grown to the cloned disk size.
    public let needsGrow: Bool

    /// Creates a complete startup measurement snapshot.
    ///
    /// - Parameters:
    ///   - ipAddress: The ready guest's IPv4 address.
    ///   - forwardedPort: The ephemeral host loopback SSH port.
    ///   - imageReadySeconds: Base-image preparation duration.
    ///   - diskReadySeconds: Writable-disk preparation duration.
    ///   - seedReadySeconds: SSH key and seed preparation duration.
    ///   - bootToIPSeconds: VZ boot-to-address duration.
    ///   - ipToSSHReadySeconds: Address-to-SSH duration.
    ///   - totalSeconds: End-to-end startup duration.
    ///   - needsGrow: Whether a cloned disk is larger than the donor filesystem.
    public init(
        ipAddress: String,
        forwardedPort: UInt16,
        imageReadySeconds: Double,
        diskReadySeconds: Double,
        seedReadySeconds: Double,
        bootToIPSeconds: Double,
        ipToSSHReadySeconds: Double,
        totalSeconds: Double,
        needsGrow: Bool = false
    ) {
        self.ipAddress = ipAddress
        self.forwardedPort = forwardedPort
        self.imageReadySeconds = imageReadySeconds
        self.diskReadySeconds = diskReadySeconds
        self.seedReadySeconds = seedReadySeconds
        self.bootToIPSeconds = bootToIPSeconds
        self.ipToSSHReadySeconds = ipToSSHReadySeconds
        self.totalSeconds = totalSeconds
        self.needsGrow = needsGrow
    }
}
