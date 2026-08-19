import CryptoKit
public import Foundation

/// Renders Vetro's NoCloud data and materializes the cloud-init seed ISO.
///
/// The renderer has no VM dependency, so callers can prepare or inspect the
/// exact guest configuration before constructing a virtual machine.
///
/// ```swift
/// let seed = CloudInitSeed(
///     stateDirectory: StateDirectory(
///         rootURL: stateURL,
///         imagesDirectoryURL: imagesURL
///     )
/// )
/// let rendered = try seed.render(publicKey: publicKey)
/// let isoURL = try seed.ensureSeed(publicKey: publicKey)
/// ```
public struct CloudInitSeed {
    /// The two files presented to cloud-init through its NoCloud data source.
    public struct RenderedContent: Sendable, Equatable {
        /// The rendered `#cloud-config` user-data document.
        public let userData: String

        /// The rendered NoCloud instance identity document.
        public let metaData: String

        /// Creates a pair of rendered NoCloud documents.
        ///
        /// - Parameters:
        ///   - userData: A complete `#cloud-config` document.
        ///   - metaData: A complete NoCloud metadata document.
        public init(userData: String, metaData: String) {
            self.userData = userData
            self.metaData = metaData
        }
    }

    /// The command seam used to invoke `hdiutil` after rendering.
    typealias CommandRunner = @Sendable (_ executableURL: URL, _ arguments: [String]) throws -> Void

    /// In-memory copies of the bundled guest resources.
    struct GuestResources: Sendable {
        let userDataTemplate: String
        let guestAgent: String
        let vsockSSHBridge: String
        let vsockPortBridge: String
        let vsockHostBridge: String
        let portwatch: String
        let hookPost: String
        let provisionScript: String
    }

    private enum Failure: Swift.Error, CustomStringConvertible {
        case invalidHostname(String)
        case invalidPublicKey
        case missingPlaceholder(String)
        case missingResource(String)
        case commandFailed(executable: String, status: Int32, output: String)
        case missingCommandOutput(URL)

        var description: String {
            switch self {
            case let .invalidHostname(hostname):
                "Invalid cloud-init hostname: \(hostname)"
            case .invalidPublicKey:
                "The SSH public key must be a non-empty, single-line value"
            case let .missingPlaceholder(placeholder):
                "The cloud-init template is missing placeholder \(placeholder)"
            case let .missingResource(name):
                "The VMKit resource bundle is missing Guest/\(name)"
            case let .commandFailed(executable, status, output):
                "\(executable) exited with status \(status): \(output)"
            case let .missingCommandOutput(url):
                "The seed-image command did not create \(url.path)"
            }
        }
    }

    private let stateDirectory: StateDirectory
    private let fileManager: FileManager
    private let commandRunner: CommandRunner
    private let resourceBundle: Bundle

    /// Creates a cloud-init seed service rooted in persistent VM state.
    ///
    /// - Parameters:
    ///   - stateDirectory: The canonical locations for the ISO and its content hash.
    ///   - fileManager: The filesystem dependency; tests may inject an isolated instance.
    public init(
        stateDirectory: StateDirectory,
        fileManager: FileManager = FileManager()
    ) {
        self.init(
            stateDirectory: stateDirectory,
            fileManager: fileManager,
            commandRunner: Self.runCommand,
            resourceBundle: .module
        )
    }

    /// Creates a seed service with injected process and resource dependencies.
    init(
        stateDirectory: StateDirectory,
        fileManager: FileManager,
        commandRunner: @escaping CommandRunner,
        resourceBundle: Bundle
    ) {
        self.stateDirectory = stateDirectory
        self.fileManager = fileManager
        self.commandRunner = commandRunner
        self.resourceBundle = resourceBundle
    }

    /// Renders the complete NoCloud documents without writing any files.
    ///
    /// The bundled Python and shell resources are base64 encoded before
    /// substitution, so their contents cannot alter the surrounding YAML.
    ///
    /// - Parameters:
    ///   - publicKey: A single-line OpenSSH public key for the guest `vetro` user.
    ///   - hostname: The guest hostname. The default is `vetro`.
    ///   - installAgents: Agent names written to `/etc/vetro/agents.conf`.
    ///   - customScript: Optional guest setup script embedded as `custom-setup.sh`.
    /// - Returns: The user-data and meta-data that would be included in `seed.iso`.
    /// - Throws: An error when resources, placeholders, the key, or hostname are invalid.
    public func render(
        publicKey: String,
        hostname: String = "vetro",
        installAgents: [String] = VMSettings.defaultInstallAgents,
        customScript: String? = nil,
        desktopEnabled: Bool = false,
        cuaEnabled: Bool = false
    ) throws -> RenderedContent {
        try render(
            resources: loadGuestResources(),
            publicKey: publicKey,
            hostname: hostname,
            installAgents: installAgents,
            customScript: customScript,
            desktopEnabled: desktopEnabled,
            cuaEnabled: cuaEnabled
        )
    }

    /// Creates or reuses `seed.iso` for the rendered cloud-init content.
    ///
    /// The SHA-256 hash beside the ISO covers both NoCloud documents. A seed is
    /// rebuilt only when the ISO is absent or that hash differs.
    ///
    /// - Parameters:
    ///   - publicKey: A single-line OpenSSH public key for the guest `vetro` user.
    ///   - hostname: The guest hostname. The default is `vetro`.
    ///   - installAgents: Agent names written to `/etc/vetro/agents.conf`.
    ///   - customScript: Optional guest setup script embedded as `custom-setup.sh`.
    /// - Returns: The persistent URL of `seed.iso`.
    /// - Throws: A rendering, filesystem, or `hdiutil` execution error.
    public func ensureSeed(
        publicKey: String,
        hostname: String = "vetro",
        installAgents: [String] = VMSettings.defaultInstallAgents,
        customScript: String? = nil,
        desktopEnabled: Bool = false,
        cuaEnabled: Bool = false
    ) throws -> URL {
        let rendered = try render(
            publicKey: publicKey,
            hostname: hostname,
            installAgents: installAgents,
            customScript: customScript,
            desktopEnabled: desktopEnabled,
            cuaEnabled: cuaEnabled
        )
        let contentHash = Self.contentHash(for: rendered)

        if fileManager.fileExists(atPath: stateDirectory.seedISOURL.path),
           let recordedHash = try? String(contentsOf: stateDirectory.seedHashURL, encoding: .utf8),
           recordedHash.trimmingCharacters(in: .whitespacesAndNewlines) == contentHash
        {
            return stateDirectory.seedISOURL
        }

        try fileManager.createDirectory(
            at: stateDirectory.rootURL,
            withIntermediateDirectories: true
        )

        let workDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("vetro-seed-\(UUID().uuidString)", isDirectory: true)
        let dataDirectory = workDirectory.appendingPathComponent("cidata", isDirectory: true)
        let builtISOURL = workDirectory.appendingPathComponent("seed.iso", isDirectory: false)
        try fileManager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: workDirectory)
        }

        try rendered.userData.write(
            to: dataDirectory.appendingPathComponent("user-data", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try rendered.metaData.write(
            to: dataDirectory.appendingPathComponent("meta-data", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        try commandRunner(
            URL(fileURLWithPath: "/usr/bin/hdiutil", isDirectory: false),
            [
                "makehybrid",
                "-iso",
                "-joliet",
                "-default-volume-name", "cidata",
                "-o", builtISOURL.path,
                dataDirectory.path,
            ]
        )

        guard fileManager.fileExists(atPath: builtISOURL.path) else {
            throw Failure.missingCommandOutput(builtISOURL)
        }

        if fileManager.fileExists(atPath: stateDirectory.seedISOURL.path) {
            try fileManager.removeItem(at: stateDirectory.seedISOURL)
        }
        try fileManager.moveItem(at: builtISOURL, to: stateDirectory.seedISOURL)
        try "\(contentHash)\n".write(
            to: stateDirectory.seedHashURL,
            atomically: true,
            encoding: .utf8
        )

        return stateDirectory.seedISOURL
    }

    /// Loads the generic vsock port-bridge script from the VMKit resource bundle.
    public static func vsockPortBridgeScript() throws -> String {
        try loadResource(
            named: "vsock-port-bridge",
            extension: "py",
            bundle: .module
        )
    }

    /// Loads the guest→host reverse-bridge script from the VMKit resource bundle.
    public static func vsockHostBridgeScript() throws -> String {
        try loadResource(
            named: "vsock-host-bridge",
            extension: "py",
            bundle: .module
        )
    }

    /// Loads the guest listen-port watcher script from the VMKit resource bundle.
    public static func portwatchScript() throws -> String {
        try loadResource(
            named: "vetro-portwatch",
            extension: "py",
            bundle: .module
        )
    }

    /// Loads the guest hook-post script from the VMKit resource bundle.
    public static func hookPostScript() throws -> String {
        try loadResource(
            named: "vetro-hook-post",
            extension: "py",
            bundle: .module
        )
    }

    /// Loads guest assets through the same SwiftPM resource path used in production.
    func loadGuestResources() throws -> GuestResources {
        GuestResources(
            userDataTemplate: try loadResource(named: "user-data.template", extension: "yaml"),
            guestAgent: try loadResource(named: "guest-agent", extension: "py"),
            vsockSSHBridge: try loadResource(named: "vsock-ssh-bridge", extension: "py"),
            vsockPortBridge: try loadResource(named: "vsock-port-bridge", extension: "py"),
            vsockHostBridge: try loadResource(named: "vsock-host-bridge", extension: "py"),
            portwatch: try loadResource(named: "vetro-portwatch", extension: "py"),
            hookPost: try loadResource(named: "vetro-hook-post", extension: "py"),
            provisionScript: try loadResource(named: "provision", extension: "sh")
        )
    }

    /// Applies validated values to an already-loaded resource set.
    func render(
        resources: GuestResources,
        publicKey: String,
        hostname: String,
        installAgents: [String] = VMSettings.defaultInstallAgents,
        customScript: String? = nil,
        desktopEnabled: Bool = false,
        cuaEnabled: Bool = false
    ) throws -> RenderedContent {
        let normalizedKey = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty,
              !normalizedKey.contains("\n"),
              !normalizedKey.contains("\r")
        else {
            throw Failure.invalidPublicKey
        }
        guard Self.isValidHostname(hostname) else {
            throw Failure.invalidHostname(hostname)
        }

        let substitutions = [
            "__VETRO_HOSTNAME__": hostname,
            "__VETRO_SSH_PUBLIC_KEY__": normalizedKey,
            "__VETRO_GUEST_AGENT_BASE64__": Data(resources.guestAgent.utf8).base64EncodedString(),
            "__VETRO_VSOCK_SSH_BRIDGE_BASE64__": Data(resources.vsockSSHBridge.utf8)
                .base64EncodedString(),
            "__VETRO_VSOCK_PORT_BRIDGE_BASE64__": Data(resources.vsockPortBridge.utf8)
                .base64EncodedString(),
            "__VETRO_VSOCK_HOST_BRIDGE_BASE64__": Data(resources.vsockHostBridge.utf8)
                .base64EncodedString(),
            "__VETRO_PORTWATCH_BASE64__": Data(resources.portwatch.utf8).base64EncodedString(),
            "__VETRO_HOOK_POST_BASE64__": Data(resources.hookPost.utf8).base64EncodedString(),
            "__VETRO_PROVISION_BASE64__": Data(resources.provisionScript.utf8).base64EncodedString(),
            "__VETRO_AGENTS_CONF__": Self.agentsManifestLine(installAgents),
            "__VETRO_DESKTOP__": desktopEnabled ? "1" : "0",
            "__VETRO_CUA__": cuaEnabled ? "1" : "0",
            "__VETRO_CUSTOM_SETUP_WRITE_FILE__": Self.customSetupWriteFile(customScript),
        ]
        var userData = resources.userDataTemplate
        for (placeholder, value) in substitutions {
            guard userData.contains(placeholder) else {
                throw Failure.missingPlaceholder(placeholder)
            }
            userData = userData.replacingOccurrences(of: placeholder, with: value)
        }

        let metaData = """
        instance-id: iid-vetro-1
        local-hostname: \(hostname)

        """
        return RenderedContent(userData: userData, metaData: metaData)
    }

    private func loadResource(named name: String, extension fileExtension: String) throws -> String {
        try Self.loadResource(named: name, extension: fileExtension, bundle: resourceBundle)
    }

    private static func loadResource(
        named name: String,
        extension fileExtension: String,
        bundle: Bundle
    ) throws -> String {
        let url = bundle.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: "Guest"
        ) ?? bundle.url(
            forResource: name,
            withExtension: fileExtension
        )
        guard let url else {
            throw Failure.missingResource("\(name).\(fileExtension)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func contentHash(for rendered: RenderedContent) -> String {
        var content = Data(rendered.userData.utf8)
        content.append(0)
        content.append(contentsOf: rendered.metaData.utf8)
        return SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
    }

    /// Space-separated agent names written as a single `/etc/vetro/agents.conf` line.
    static func agentsManifestLine(_ agents: [String]) -> String {
        agents
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// A `write_files` entry for the optional custom setup script, or empty YAML.
    static func customSetupWriteFile(_ script: String?) -> String {
        guard let script, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        return """
          - path: /usr/local/lib/vetro/custom-setup.sh
            owner: root:root
            permissions: '0755'
            encoding: b64
            content: \(Data(script.utf8).base64EncodedString())

        """
    }

    private static func isValidHostname(_ hostname: String) -> Bool {
        guard !hostname.isEmpty,
              hostname.utf8.count <= 63,
              hostname.first != "-",
              hostname.last != "-"
        else {
            return false
        }
        return hostname.utf8.allSatisfy {
            ($0 >= Character("a").asciiValue! && $0 <= Character("z").asciiValue!)
                || ($0 >= Character("A").asciiValue! && $0 <= Character("Z").asciiValue!)
                || ($0 >= Character("0").asciiValue! && $0 <= Character("9").asciiValue!)
                || $0 == Character("-").asciiValue!
        }
    }

    private static func runCommand(executableURL: URL, arguments: [String]) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw Failure.commandFailed(
                executable: executableURL.path,
                status: process.terminationStatus,
                output: String(decoding: outputData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
