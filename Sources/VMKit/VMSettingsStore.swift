import Darwin
public import Foundation

/// An actor-backed repository for the VM's durable `vm.json` settings.
///
/// All reads and writes are serialized by actor isolation. A newly generated
/// MAC address is written atomically before it is returned to the caller.
public actor VMSettingsStore {
    private let stateDirectory: StateDirectory
    private let fileManager: FileManager
    private let defaultCPUCount: Int
    private let macAddressGenerator: @Sendable () -> String

    /// Creates a production settings store using the current host's processor topology.
    ///
    /// - Parameters:
    ///   - stateDirectory: The canonical VM state paths.
    ///   - fileManager: The filesystem dependency used for persistence.
    public init(
        stateDirectory: StateDirectory,
        fileManager: FileManager = FileManager()
    ) {
        self.stateDirectory = stateDirectory
        self.fileManager = fileManager
        self.defaultCPUCount = Self.recommendedHostCPUCount()
        self.macAddressGenerator = { VMSettings.makeRandomMACAddress() }
    }

    /// Creates a settings store with deterministic defaults for tests or specialized hosts.
    ///
    /// - Parameters:
    ///   - stateDirectory: The canonical VM state paths.
    ///   - fileManager: The filesystem dependency used for persistence.
    ///   - defaultCPUCount: The CPU count assigned when `vm.json` does not exist.
    ///   - macAddressGenerator: A generator invoked only when new settings are created.
    public init(
        stateDirectory: StateDirectory,
        fileManager: FileManager,
        defaultCPUCount: Int,
        macAddressGenerator: @escaping @Sendable () -> String
    ) {
        self.stateDirectory = stateDirectory
        self.fileManager = fileManager
        self.defaultCPUCount = max(1, min(defaultCPUCount, 6))
        self.macAddressGenerator = macAddressGenerator
    }

    /// Loads the existing settings or atomically creates and persists M1 defaults.
    ///
    /// - Returns: The persisted settings. Repeated calls preserve the same MAC address.
    /// - Throws: A filesystem or JSON coding error.
    public func loadOrCreate() throws -> VMSettings {
        if fileManager.fileExists(atPath: stateDirectory.configurationURL.path) {
            let data = try Data(contentsOf: stateDirectory.configurationURL)
            return try JSONDecoder().decode(VMSettings.self, from: data)
        }

        let settings = VMSettings(
            cpus: defaultCPUCount,
            macAddress: macAddressGenerator()
        )
        try save(settings)
        return settings
    }

    /// Atomically replaces `vm.json` with the supplied settings.
    ///
    /// - Parameter settings: The complete durable settings snapshot to persist.
    /// - Throws: A directory-creation, JSON coding, or filesystem write error.
    public func save(_ settings: VMSettings) throws {
        try fileManager.createDirectory(
            at: stateDirectory.rootURL,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: stateDirectory.configurationURL, options: .atomic)
    }

    /// Resolves the M1 CPU default, preferring performance cores on Apple Silicon.
    private static func recommendedHostCPUCount() -> Int {
        let activeCount = ProcessInfo.processInfo.activeProcessorCount
        let availableCount = performanceCoreCount() ?? activeCount
        return max(1, min(availableCount, 6))
    }

    /// Reads Apple's performance-level-zero physical-core count when available.
    private static func performanceCoreCount() -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.perflevel0.physicalcpu", &value, &size, nil, 0)
        guard result == 0, value > 0 else { return nil }
        return Int(value)
    }
}
