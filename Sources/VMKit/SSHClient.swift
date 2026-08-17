public import Foundation

/// Manages the VM's host-side SSH identity and executes bounded guest commands.
public actor SSHClient {
    /// Failures specific to SSH identity preparation.
    public enum Failure: Error, Sendable, Equatable {
        /// Exactly one member of the keypair existed, so overwriting it would be unsafe.
        case incompleteKeypair

        /// `ssh-keygen` failed with its exit status and diagnostic output.
        case keyGenerationFailed(status: Int32, stderr: String)

        /// The generated public-key file was empty or malformed.
        case invalidPublicKey
    }

    private let stateDirectory: StateDirectory
    private let fileManager: FileManager
    private let runner: SubprocessRunner

    /// Creates an SSH client rooted in the VM's persistent state directory.
    ///
    /// - Parameters:
    ///   - stateDirectory: The canonical key and known-hosts locations.
    ///   - fileManager: The filesystem dependency used for key preparation.
    public init(
        stateDirectory: StateDirectory,
        fileManager: FileManager = FileManager()
    ) {
        self.stateDirectory = stateDirectory
        self.fileManager = fileManager
        self.runner = SubprocessRunner(
            temporaryDirectoryURL: fileManager.temporaryDirectory
        )
    }

    /// Creates the Ed25519 keypair when absent and returns its public key.
    ///
    /// Existing complete keypairs are reused and the private key's mode is
    /// repaired to `0600` on every call.
    ///
    /// - Returns: The single-line OpenSSH public key injected by cloud-init.
    /// - Throws: A filesystem, process-launch, or ``Failure`` error.
    public func ensureKeypair() async throws -> String {
        try fileManager.createDirectory(
            at: stateDirectory.sshDirectoryURL,
            withIntermediateDirectories: true
        )

        let hasPrivateKey = fileManager.fileExists(atPath: stateDirectory.sshPrivateKeyURL.path)
        let hasPublicKey = fileManager.fileExists(atPath: stateDirectory.sshPublicKeyURL.path)
        guard hasPrivateKey == hasPublicKey else {
            throw Failure.incompleteKeypair
        }

        if !hasPrivateKey {
            let result = try await runner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/ssh-keygen", isDirectory: false),
                arguments: [
                    "-t", "ed25519",
                    "-N", "",
                    "-C", "vetro",
                    "-f", stateDirectory.sshPrivateKeyURL.path,
                ],
                timeoutSeconds: 30
            )
            guard result.status == 0 else {
                throw Failure.keyGenerationFailed(
                    status: result.status,
                    stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }

        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stateDirectory.sshPrivateKeyURL.path
        )
        let publicKey = try String(
            contentsOf: stateDirectory.sshPublicKeyURL,
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !publicKey.isEmpty, !publicKey.contains("\n"), !publicKey.contains("\r") else {
            throw Failure.invalidPublicKey
        }
        return publicKey
    }

    /// Executes one command as `vetro` in the guest through OpenSSH.
    ///
    /// A timeout is reported as status `124`. SSH itself uses a five-second
    /// connect timeout and accepts a host key only on first contact.
    ///
    /// - Parameters:
    ///   - host: The guest IPv4 address used when `port` is `nil`.
    ///   - port: A host loopback port forwarding SSH over vsock. When present,
    ///     the destination is `127.0.0.1` with a stable guest host-key alias.
    ///   - command: The remote shell command passed as one SSH argument.
    ///   - environment: Environment variables sent within a single OpenSSH `SetEnv` option.
    ///   - timeoutSeconds: The maximum wall-clock duration of the SSH process.
    ///   - identityFile: Optional private key overriding ``StateDirectory/sshPrivateKeyURL``.
    /// - Returns: The process exit status and complete standard streams.
    /// - Throws: A process-launch or output-capture error.
    public func exec(
        host: String,
        port: UInt16? = nil,
        command: String,
        environment: [String: String] = [:],
        timeoutSeconds: Int,
        identityFile: URL? = nil
    ) async throws -> (status: Int32, stdout: String, stderr: String) {
        var invocation = destinationDescription(
            ip: host,
            port: port,
            environment: environment,
            identityFile: identityFile
        )
        let executable = URL(fileURLWithPath: invocation.removeFirst(), isDirectory: false)
        invocation.append(command)
        let result = try await runner.run(
            executableURL: executable,
            arguments: invocation,
            timeoutSeconds: timeoutSeconds
        )
        return (result.status, result.stdout, result.stderr)
    }

    /// Builds the complete SSH invocation used by future terminal panes.
    ///
    /// Environment keys are sorted for deterministic option ordering. Values
    /// that require OpenSSH configuration quoting remain one process argument;
    /// no local shell evaluates them.
    ///
    /// - Parameters:
    ///   - ip: The guest IPv4 address used when `port` is `nil`.
    ///   - port: A host loopback port forwarding SSH over vsock. When present,
    ///     the destination is `127.0.0.1` with a stable guest host-key alias.
    ///   - environment: Environment variables sent through `SetEnv`.
    ///   - identityFile: Optional private key overriding ``StateDirectory/sshPrivateKeyURL``.
    /// - Returns: An array beginning with `/usr/bin/ssh` and ending in the selected destination.
    public nonisolated func destinationDescription(
        ip: String,
        port: UInt16? = nil,
        environment: [String: String] = [:],
        identityFile: URL? = nil
    ) -> [String] {
        var arguments = [
            "/usr/bin/ssh",
            "-i", (identityFile ?? stateDirectory.sshPrivateKeyURL).path,
            // ssh splits unquoted option values on whitespace ("Application
            // Support"), silently pinning host keys into a stray file.
            "-o", "UserKnownHostsFile=\"\(stateDirectory.knownHostsURL.path)\"",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=5",
            "-o", "BatchMode=yes",
            // Reap half-dead sessions fast (e.g. sshd restarting during
            // provisioning); without keepalives a hung TCP connection can
            // stall a poll loop far beyond its intended timeout.
            "-o", "ServerAliveInterval=3",
            "-o", "ServerAliveCountMax=2",
        ]
        let destination: String
        if let port {
            arguments.append(contentsOf: [
                "-p", String(port),
                "-o", "HostKeyAlias=vetro-vm",
            ])
            destination = "127.0.0.1"
        } else {
            destination = ip
        }
        // All assignments ride ONE SetEnv option: OpenSSH honors only the
        // first -o SetEnv= on the command line and silently drops the rest,
        // but accepts multiple space-separated assignments within one option.
        let assignments = environment.keys.sorted().compactMap { key in
            environment[key].map { Self.envAssignment(key: key, value: $0) }
        }
        if !assignments.isEmpty {
            arguments.append(contentsOf: [
                "-o",
                "SetEnv=" + assignments.joined(separator: " "),
            ])
        }
        arguments.append("vetro@\(destination)")
        return arguments
    }

    /// Replaces every `SetEnv` value in an SSH argument vector with a fixed token.
    ///
    /// Keep command-line diagnostics on this representation so API keys never
    /// appear in logs or error descriptions.
    ///
    /// - Parameter invocation: A complete executable-and-arguments vector.
    /// - Returns: The same vector with environment names retained and values masked.
    nonisolated static func redactedInvocation(_ invocation: [String]) -> [String] {
        invocation.map { argument in
            let prefix = "SetEnv="
            guard argument.hasPrefix(prefix) else { return argument }
            var keys: [String] = []
            var rest = argument.dropFirst(prefix.count)[...]
            while !rest.isEmpty {
                rest = rest.drop { $0 == " " }
                guard let equals = rest.firstIndex(of: "=") else { break }
                keys.append(String(rest[..<equals]))
                rest = rest[rest.index(after: equals)...]
                if rest.first == "\"" {
                    rest = rest.dropFirst()
                    while let character = rest.first {
                        rest = rest.dropFirst()
                        if character == "\\" {
                            rest = rest.dropFirst()
                        } else if character == "\"" {
                            break
                        }
                    }
                } else {
                    rest = rest.drop { $0 != " " }
                }
            }
            guard !keys.isEmpty else { return "SetEnv=<redacted>" }
            return "SetEnv=" + keys.map { "\($0)=<redacted>" }.joined(separator: " ")
        }
    }

    /// Encodes one assignment for OpenSSH's configuration-option parser.
    private nonisolated static func envAssignment(key: String, value: String) -> String {
        let percentEscaped = value.replacingOccurrences(of: "%", with: "%%")
        let requiresQuotes = percentEscaped.contains { character in
            character.isWhitespace || character == "\"" || character == "\\"
        }
        guard requiresQuotes else {
            return "\(key)=\(percentEscaped)"
        }
        let quoted = percentEscaped
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\(key)=\"\(quoted)\""
    }
}
