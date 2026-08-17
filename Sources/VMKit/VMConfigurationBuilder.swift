public import Foundation
public import Virtualization

/// Builds and validates the headless Virtualization.framework configuration.
public struct VMConfigurationBuilder {
    /// Invalid persisted settings that cannot safely be passed to Virtualization.framework.
    public enum Failure: Error, Sendable, Equatable {
        /// The virtual CPU count was not positive.
        case invalidCPUCount(Int)

        /// The configured memory size was not a positive whole number of MiB.
        case invalidMemorySizeMB(Int)

        /// The persisted MAC was malformed or was not locally administered unicast.
        case invalidMACAddress(String)

        /// The console log could not be created at the expected persistent path.
        case unableToCreateConsoleLog(URL)
    }

    private let stateDirectory: StateDirectory
    private let fileManager: FileManager

    /// Creates a builder for already-prepared VM state artifacts.
    ///
    /// - Parameters:
    ///   - stateDirectory: The disk, seed, EFI, and console locations.
    ///   - fileManager: The filesystem dependency used for first-run setup.
    public init(
        stateDirectory: StateDirectory,
        fileManager: FileManager = FileManager()
    ) {
        self.stateDirectory = stateDirectory
        self.fileManager = fileManager
    }

    /// Builds the EFI, storage, optional NAT, entropy, balloon, vsock, and console devices.
    ///
    /// The writable disk and read-only NoCloud ISO must already exist. This
    /// method creates the persistent EFI variable store and console log when
    /// needed, then calls `validate()` before returning.
    ///
    /// - Parameters:
    ///   - settings: The persisted hardware settings and fixed MAC address.
    ///   - sharedDirectory: Optional host directory exposed as a writable virtiofs
    ///     share. `nil` leaves `directorySharingDevices` empty.
    /// - Returns: A validated headless virtual-machine configuration.
    /// - Throws: A ``Failure``, filesystem, attachment, EFI, or validation error.
    public func build(
        settings: VMSettings,
        sharedDirectory: (url: URL, tag: String)? = nil
    ) throws -> VZVirtualMachineConfiguration {
        guard settings.cpus > 0 else {
            throw Failure.invalidCPUCount(settings.cpus)
        }
        guard settings.memoryMB > 0 else {
            throw Failure.invalidMemorySizeMB(settings.memoryMB)
        }
        let (memorySize, memoryOverflow) = UInt64(settings.memoryMB)
            .multipliedReportingOverflow(by: 1_048_576)
        guard !memoryOverflow else {
            throw Failure.invalidMemorySizeMB(settings.memoryMB)
        }
        guard let macAddress = VZMACAddress(string: settings.macAddress),
              macAddress.isLocallyAdministeredAddress,
              macAddress.isUnicastAddress
        else {
            throw Failure.invalidMACAddress(settings.macAddress)
        }

        try fileManager.createDirectory(
            at: stateDirectory.rootURL,
            withIntermediateDirectories: true
        )

        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = VZGenericPlatformConfiguration()
        configuration.cpuCount = settings.cpus
        configuration.memorySize = memorySize

        let bootLoader = VZEFIBootLoader()
        if fileManager.fileExists(atPath: stateDirectory.efiVariableStoreURL.path) {
            bootLoader.variableStore = VZEFIVariableStore(
                url: stateDirectory.efiVariableStoreURL
            )
        } else {
            bootLoader.variableStore = try VZEFIVariableStore(
                creatingVariableStoreAt: stateDirectory.efiVariableStoreURL,
                options: []
            )
        }
        configuration.bootLoader = bootLoader

        let rootAttachment = try VZDiskImageStorageDeviceAttachment(
            url: stateDirectory.diskURL,
            readOnly: false,
            cachingMode: .automatic,
            synchronizationMode: .full
        )
        let rootDevice = VZVirtioBlockDeviceConfiguration(attachment: rootAttachment)
        rootDevice.blockDeviceIdentifier = "vetro-root"

        let seedAttachment = try VZDiskImageStorageDeviceAttachment(
            url: stateDirectory.seedISOURL,
            readOnly: true,
            cachingMode: .automatic,
            synchronizationMode: .full
        )
        let seedDevice = VZVirtioBlockDeviceConfiguration(attachment: seedAttachment)
        seedDevice.blockDeviceIdentifier = "vetro-cidata"
        configuration.storageDevices = [rootDevice, seedDevice]

        if settings.networkEnabled {
            let networkDevice = VZVirtioNetworkDeviceConfiguration()
            networkDevice.attachment = VZNATNetworkDeviceAttachment()
            networkDevice.macAddress = macAddress
            configuration.networkDevices = [networkDevice]
        }

        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.memoryBalloonDevices = [
            VZVirtioTraditionalMemoryBalloonDeviceConfiguration(),
        ]
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        if let sharedDirectory {
            let device = VZVirtioFileSystemDeviceConfiguration(tag: sharedDirectory.tag)
            device.share = VZSingleDirectoryShare(
                directory: VZSharedDirectory(url: sharedDirectory.url, readOnly: false)
            )
            configuration.directorySharingDevices = [device]
        }

        if !fileManager.fileExists(atPath: stateDirectory.consoleLogURL.path),
           !fileManager.createFile(atPath: stateDirectory.consoleLogURL.path, contents: nil)
        {
            throw Failure.unableToCreateConsoleLog(stateDirectory.consoleLogURL)
        }
        let consoleOutput = try FileHandle(forWritingTo: stateDirectory.consoleLogURL)
        _ = try consoleOutput.seekToEnd()
        let consoleAttachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: nil,
            fileHandleForWriting: consoleOutput
        )
        let console = VZVirtioConsoleDeviceSerialPortConfiguration()
        console.attachment = consoleAttachment
        configuration.serialPorts = [console]

        try configuration.validate()
        return configuration
    }
}
