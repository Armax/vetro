import CryptoKit
public import Foundation

/// Serializes golden-image staging and capture across controllers.
/// A distinct GoldenImageStore actor exists for every VM, while goldens live
/// in the shared image directory.
private actor SharedGoldenCacheGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var isHeld = false
    private var waiters: [Waiter] = []

    func acquire() async throws {
        try Task.checkCancellation()
        if !isHeld {
            isHeld = true
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        }, onCancel: {
            Task { await self.cancelWaiter(id) }
        })
    }

    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

/// Validates a golden-exclude path that must stay under `/home/vetro`.
public enum GoldenExcludePath {
    /// Returns the relative path when it is safe to delete under `/home/vetro`.
    ///
    /// Absolute paths and any path containing `..` are rejected.
    public static func validated(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") { return nil }
        if trimmed.contains("..") { return nil }
        return trimmed
    }
}

/// Captures and clones provisioned golden disks shared by every Vetro VM.
///
/// A process-wide gate serializes staging, capture, lookup, and GC across
/// GoldenImageStore actors. A golden is accepted only after its manifest,
/// disk, and access key validate; captures land through a hidden staging
/// directory that is atomically renamed and never overwrite a valid golden.
public actor GoldenImageStore {
    private static let sharedCacheGate = SharedGoldenCacheGate()

    /// Schema version mixed into the cache key and written on every manifest.
    public static let schemaVersion = 2

    /// Errors raised when a golden cannot be staged, captured, or cloned.
    public enum Failure: Error, Sendable, Equatable {
        /// The local checksum manifest did not list the expected base image.
        case checksumEntryMissing(String)

        /// The bundled provision script could not be loaded from the module bundle.
        case missingProvisionScript

        /// The configured disk size was invalid or smaller than the golden disk.
        case invalidTargetDiskSize(gibibytes: Int, donorBytes: UInt64)

        /// `ssh-keygen` failed with its exit status and diagnostic output.
        case keyGenerationFailed(status: Int32, stderr: String)

        /// The generated public-key file was empty or malformed.
        case invalidPublicKey

        /// Exactly one member of the golden access keypair existed.
        case incompleteKeypair

        /// Capture was asked for a cache key that has no staged access key.
        case missingAccessKey(String)

        /// The donor disk was missing or empty.
        case missingDonorDisk(URL)
    }

    /// Inputs that participate in the golden cache key.
    ///
    /// CPU, memory, disk size, MAC address, and network are intentionally
    /// excluded so hardware-only differences reuse the same golden. Desktop is
    /// included because it installs XFCE packages into the guest.
    public struct Inputs: Sendable, Equatable {
        /// Agent CLIs selected for first-boot installation.
        public var installAgents: [String]

        /// Optional guest setup script; `nil` or whitespace hashes as `none`.
        public var customScript: String?

        /// Whether the guest provisions the XFCE desktop environment.
        public var desktopEnabled: Bool

        /// Creates cache-key inputs from the provision-affecting settings.
        public init(
            installAgents: [String],
            customScript: String? = nil,
            desktopEnabled: Bool = false
        ) {
            self.installAgents = installAgents
            self.customScript = customScript
            self.desktopEnabled = desktopEnabled
        }

        /// Creates cache-key inputs from persisted VM settings.
        public init(_ settings: VMSettings) {
            self.init(
                installAgents: settings.installAgents,
                customScript: settings.customScript,
                desktopEnabled: settings.desktopEnabled
            )
        }
    }

    /// On-disk description of one captured golden.
    public struct Manifest: Codable, Sendable, Equatable {
        public var schemaVersion: Int
        public var cacheKey: String
        public var baseImageSHA512: String
        public var installAgents: [String]
        public var provisionScriptSHA256: String
        public var customScriptSHA256: String
        public var desktopEnabled: Bool
        public var donorDiskSizeGB: Int
        public var createdAt: Date

        public init(
            schemaVersion: Int,
            cacheKey: String,
            baseImageSHA512: String,
            installAgents: [String],
            provisionScriptSHA256: String,
            customScriptSHA256: String,
            desktopEnabled: Bool = false,
            donorDiskSizeGB: Int,
            createdAt: Date
        ) {
            self.schemaVersion = schemaVersion
            self.cacheKey = cacheKey
            self.baseImageSHA512 = baseImageSHA512
            self.installAgents = installAgents
            self.provisionScriptSHA256 = provisionScriptSHA256
            self.customScriptSHA256 = customScriptSHA256
            self.desktopEnabled = desktopEnabled
            self.donorDiskSizeGB = donorDiskSizeGB
            self.createdAt = createdAt
        }
    }

    /// A golden that passed lookup validation.
    public struct ValidGolden: Sendable, Equatable {
        public var cacheKey: String
        public var manifest: Manifest
        public var diskURL: URL
        public var accessPrivateKeyURL: URL
    }

    /// Access key staged for a donor that has not been captured yet.
    public struct StagedAccessKey: Sendable, Equatable {
        public var cacheKey: String
        public var publicKey: String
    }

    /// Outcome of copying a golden into a per-VM disk.
    public enum CloneDiskResult: Sendable, Equatable {
        /// The golden was copied; `needsGrow` is true when the target is larger.
        case cloned(needsGrow: Bool)
        /// The target disk is smaller than the donor, so the caller should fall back.
        case ineligible
    }

    private let stateDirectory: StateDirectory
    private let fileManager: FileManager
    private let runner: SubprocessRunner
    private let resourceBundle: Bundle

    /// Creates a golden store rooted in the shared image directory.
    ///
    /// - Parameters:
    ///   - stateDirectory: The canonical locations for cached images and goldens.
    ///   - fileManager: The filesystem dependency used for staging and capture.
    public init(
        stateDirectory: StateDirectory,
        fileManager: FileManager = FileManager()
    ) {
        self.init(
            stateDirectory: stateDirectory,
            fileManager: fileManager,
            resourceBundle: .module
        )
    }

    /// Creates a golden store with an injected resource bundle for tests.
    init(
        stateDirectory: StateDirectory,
        fileManager: FileManager,
        resourceBundle: Bundle
    ) {
        self.stateDirectory = stateDirectory
        self.fileManager = fileManager
        self.runner = SubprocessRunner(
            temporaryDirectoryURL: fileManager.temporaryDirectory
        )
        self.resourceBundle = resourceBundle
    }

    /// Returns a validated golden for `inputs`, or `nil` when none is usable.
    ///
    /// Best-effort GC removes goldens whose `baseImageSHA512` no longer
    /// matches the current `SHA512SUMS` entry for the base image.
    ///
    /// - Parameter inputs: The provision-affecting settings to look up.
    /// - Returns: A validated golden, or `nil` on miss or validation failure.
    public func lookup(inputs: Inputs) async throws -> ValidGolden? {
        try await Self.sharedCacheGate.acquire()
        do {
            let golden = try lookupWhileHoldingCache(inputs: inputs)
            await Self.sharedCacheGate.release()
            return golden
        } catch {
            await Self.sharedCacheGate.release()
            throw error
        }
    }

    /// Generates the golden-access keypair in the staging area.
    ///
    /// Existing complete staging keypairs are reused. A valid finalized
    /// golden is left untouched and its public key is returned instead.
    ///
    /// - Parameter inputs: The provision-affecting settings that form the cache key.
    /// - Returns: The OpenSSH public key and the cache key it belongs to.
    /// - Throws: A filesystem, process-launch, or ``Failure`` error.
    public func stageAccessKey(inputs: Inputs) async throws -> StagedAccessKey {
        try await Self.sharedCacheGate.acquire()
        do {
            let staged = try await stageAccessKeyWhileHoldingCache(inputs: inputs)
            await Self.sharedCacheGate.release()
            return staged
        } catch {
            await Self.sharedCacheGate.release()
            throw error
        }
    }

    /// Clonefile-copies the donor disk into staging and atomically finalizes.
    ///
    /// A valid golden at the destination is left untouched. Staging leftovers
    /// from a successful finalize are removed.
    ///
    /// - Parameters:
    ///   - cacheKey: The cache key whose staging directory holds the access key.
    ///   - donorDiskURL: The stopped donor VM's `disk.img`.
    ///   - manifest: The complete manifest written beside the captured disk.
    /// - Throws: A filesystem error or ``Failure``.
    public func capture(
        cacheKey: String,
        donorDiskURL: URL,
        manifest: Manifest
    ) async throws {
        try await Self.sharedCacheGate.acquire()
        do {
            try captureWhileHoldingCache(
                cacheKey: cacheKey,
                donorDiskURL: donorDiskURL,
                manifest: manifest
            )
            await Self.sharedCacheGate.release()
        } catch {
            await Self.sharedCacheGate.release()
            throw error
        }
    }

    /// Copies a golden disk into a VM state directory the way ``ImageStore/ensureDisk`` does.
    ///
    /// An existing `disk.img` is preserved. A new disk is copied to a temporary
    /// sibling, extended sparsely to the target size, and moved into place.
    ///
    /// - Parameters:
    ///   - golden: A previously validated golden.
    ///   - stateDirectory: The destination VM's state paths.
    ///   - targetDiskSizeGB: The new VM's configured sparse disk size.
    /// - Returns: ``CloneDiskResult/cloned(needsGrow:)`` or ``CloneDiskResult/ineligible``.
    /// - Throws: A filesystem error or ``Failure/invalidTargetDiskSize``.
    public func cloneDisk(
        from golden: ValidGolden,
        into stateDirectory: StateDirectory,
        targetDiskSizeGB: Int
    ) async throws -> CloneDiskResult {
        try await Self.sharedCacheGate.acquire()
        do {
            let result = try cloneDiskWhileHoldingCache(
                from: golden,
                into: stateDirectory,
                targetDiskSizeGB: targetDiskSizeGB
            )
            await Self.sharedCacheGate.release()
            return result
        } catch {
            await Self.sharedCacheGate.release()
            throw error
        }
    }

    /// SHA-256 hex of the canonical cache-key document for `inputs`.
    public func cacheKey(for inputs: Inputs) throws -> String {
        let document = try cacheKeyDocument(for: inputs)
        return Self.sha256Hex(Data(document.utf8))
    }

    /// Builds a capture manifest from the current base checksum and provision script.
    public func makeManifest(
        inputs: Inputs,
        cacheKey: String,
        donorDiskSizeGB: Int,
        createdAt: Date = Date()
    ) throws -> Manifest {
        try Manifest(
            schemaVersion: Self.schemaVersion,
            cacheKey: cacheKey,
            baseImageSHA512: currentBaseImageSHA512(),
            installAgents: Self.normalizedAgents(inputs.installAgents),
            provisionScriptSHA256: provisionScriptSHA256(),
            customScriptSHA256: Self.customScriptSHA256(inputs.customScript),
            desktopEnabled: inputs.desktopEnabled,
            donorDiskSizeGB: donorDiskSizeGB,
            createdAt: createdAt
        )
    }

    /// Reads the current base-image digest from the cached `SHA512SUMS` file.
    func currentBaseImageSHA512() throws -> String {
        let expectedFileName = stateDirectory.baseImageURL.lastPathComponent
        guard fileManager.fileExists(atPath: stateDirectory.checksumsURL.path) else {
            throw Failure.checksumEntryMissing(expectedFileName)
        }
        let manifest = try String(
            contentsOf: stateDirectory.checksumsURL,
            encoding: .utf8
        )
        guard let digest = Self.checksumEntry(named: expectedFileName, in: manifest) else {
            throw Failure.checksumEntryMissing(expectedFileName)
        }
        return digest
    }

    /// SHA-256 hex of the bundled `provision.sh`.
    func provisionScriptSHA256() throws -> String {
        Self.sha256Hex(try loadProvisionScript())
    }

    /// Performs lookup and stale-golden GC while the process-wide gate is held.
    private func lookupWhileHoldingCache(inputs: Inputs) throws -> ValidGolden? {
        try Task.checkCancellation()
        let currentBaseSHA = try? currentBaseImageSHA512()
        if let currentBaseSHA {
            garbageCollectStaleGoldens(currentBaseSHA: currentBaseSHA)
        }
        guard let currentBaseSHA else { return nil }

        let key = try cacheKey(for: inputs)
        return validatedGolden(cacheKey: key, currentBaseSHA: currentBaseSHA)
    }

    /// Stages or reuses the access keypair while the process-wide gate is held.
    private func stageAccessKeyWhileHoldingCache(
        inputs: Inputs
    ) async throws -> StagedAccessKey {
        try Task.checkCancellation()
        let key = try cacheKey(for: inputs)
        if let existing = validatedGolden(
            cacheKey: key,
            currentBaseSHA: try currentBaseImageSHA512()
        ) {
            let publicKey = try readPublicKey(at: stateDirectory.goldenAccessPublicKeyURL(cacheKey: key))
            return StagedAccessKey(cacheKey: existing.cacheKey, publicKey: publicKey)
        }

        try fileManager.createDirectory(
            at: stateDirectory.goldensDirectoryURL,
            withIntermediateDirectories: true
        )
        let staging = stagingDirectoryURL(cacheKey: key)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        let privateKeyURL = staging.appendingPathComponent("access_ed25519", isDirectory: false)
        let publicKeyURL = staging.appendingPathComponent("access_ed25519.pub", isDirectory: false)
        let hasPrivateKey = fileManager.fileExists(atPath: privateKeyURL.path)
        let hasPublicKey = fileManager.fileExists(atPath: publicKeyURL.path)
        guard hasPrivateKey == hasPublicKey else {
            throw Failure.incompleteKeypair
        }

        if !hasPrivateKey {
            let result = try await runner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/ssh-keygen", isDirectory: false),
                arguments: [
                    "-t", "ed25519",
                    "-N", "",
                    "-C", "vetro-golden",
                    "-f", privateKeyURL.path,
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
            ofItemAtPath: privateKeyURL.path
        )
        let publicKey = try readPublicKey(at: publicKeyURL)
        return StagedAccessKey(cacheKey: key, publicKey: publicKey)
    }

    /// Copies the donor disk and finalizes the golden while the gate is held.
    private func captureWhileHoldingCache(
        cacheKey: String,
        donorDiskURL: URL,
        manifest: Manifest
    ) throws {
        try Task.checkCancellation()
        let destination = stateDirectory.goldenDirectoryURL(cacheKey: cacheKey)
        if validatedGolden(
            cacheKey: cacheKey,
            currentBaseSHA: (try? currentBaseImageSHA512()) ?? manifest.baseImageSHA512
        ) != nil {
            return
        }

        let donorBytes = (try? fileSize(at: donorDiskURL)) ?? 0
        guard fileManager.fileExists(atPath: donorDiskURL.path), donorBytes > 0 else {
            throw Failure.missingDonorDisk(donorDiskURL)
        }

        let staging = stagingDirectoryURL(cacheKey: cacheKey)
        let stagedPrivateKey = staging.appendingPathComponent(
            "access_ed25519",
            isDirectory: false
        )
        let stagedPublicKey = staging.appendingPathComponent(
            "access_ed25519.pub",
            isDirectory: false
        )
        guard fileManager.fileExists(atPath: stagedPrivateKey.path),
              fileManager.fileExists(atPath: stagedPublicKey.path)
        else {
            throw Failure.missingAccessKey(cacheKey)
        }

        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let stagedDisk = staging.appendingPathComponent("disk.img", isDirectory: false)
        if fileManager.fileExists(atPath: stagedDisk.path) {
            try fileManager.removeItem(at: stagedDisk)
        }
        try fileManager.copyItem(at: donorDiskURL, to: stagedDisk)
        try Task.checkCancellation()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(
            to: staging.appendingPathComponent("manifest.json", isDirectory: false),
            options: .atomic
        )

        try Task.checkCancellation()
        if validatedGolden(
            cacheKey: cacheKey,
            currentBaseSHA: manifest.baseImageSHA512
        ) != nil {
            try? fileManager.removeItem(at: staging)
            return
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: staging, to: destination)
    }

    /// Materializes a per-VM disk from a golden while the gate is held.
    private func cloneDiskWhileHoldingCache(
        from golden: ValidGolden,
        into stateDirectory: StateDirectory,
        targetDiskSizeGB: Int
    ) throws -> CloneDiskResult {
        try Task.checkCancellation()
        if fileManager.fileExists(atPath: stateDirectory.diskURL.path) {
            return .cloned(needsGrow: targetDiskSizeGB > golden.manifest.donorDiskSizeGB)
        }

        let donorBytes = try fileSize(at: golden.diskURL)
        guard targetDiskSizeGB > 0 else {
            throw Failure.invalidTargetDiskSize(
                gibibytes: targetDiskSizeGB,
                donorBytes: donorBytes
            )
        }
        let (targetBytes, overflow) = UInt64(targetDiskSizeGB)
            .multipliedReportingOverflow(by: 1_073_741_824)
        guard !overflow else {
            throw Failure.invalidTargetDiskSize(
                gibibytes: targetDiskSizeGB,
                donorBytes: donorBytes
            )
        }
        if targetDiskSizeGB < golden.manifest.donorDiskSizeGB || targetBytes < donorBytes {
            return .ineligible
        }

        try fileManager.createDirectory(
            at: stateDirectory.rootURL,
            withIntermediateDirectories: true
        )
        let candidate = stateDirectory.rootURL.appendingPathComponent(
            ".disk-\(UUID().uuidString).img",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: candidate) }
        try fileManager.copyItem(at: golden.diskURL, to: candidate)
        try Task.checkCancellation()

        let handle = try FileHandle(forWritingTo: candidate)
        do {
            try handle.truncate(atOffset: targetBytes)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        try Task.checkCancellation()
        if fileManager.fileExists(atPath: stateDirectory.diskURL.path) {
            return .cloned(needsGrow: targetDiskSizeGB > golden.manifest.donorDiskSizeGB)
        }
        try fileManager.moveItem(at: candidate, to: stateDirectory.diskURL)
        return .cloned(needsGrow: targetDiskSizeGB > golden.manifest.donorDiskSizeGB)
    }

    /// Deletes goldens whose recorded base digest no longer matches `SHA512SUMS`.
    private func garbageCollectStaleGoldens(currentBaseSHA: String) {
        let goldens = stateDirectory.goldensDirectoryURL
        guard let contents = try? fileManager.contentsOfDirectory(
            at: goldens,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let decoder = Self.manifestDecoder()
        for url in contents {
            let manifestURL = url.appendingPathComponent("manifest.json", isDirectory: false)
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? decoder.decode(Manifest.self, from: data)
            else {
                continue
            }
            if manifest.baseImageSHA512.caseInsensitiveCompare(currentBaseSHA) != .orderedSame {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    /// Returns a golden only when schema, base digest, disk, and access key check out.
    private func validatedGolden(cacheKey: String, currentBaseSHA: String) -> ValidGolden? {
        let directory = stateDirectory.goldenDirectoryURL(cacheKey: cacheKey)
        let diskURL = stateDirectory.goldenDiskURL(cacheKey: cacheKey)
        let manifestURL = stateDirectory.goldenManifestURL(cacheKey: cacheKey)
        let privateKeyURL = stateDirectory.goldenAccessPrivateKeyURL(cacheKey: cacheKey)
        let publicKeyURL = stateDirectory.goldenAccessPublicKeyURL(cacheKey: cacheKey)

        guard fileManager.fileExists(atPath: directory.path),
              fileManager.fileExists(atPath: diskURL.path),
              fileManager.fileExists(atPath: privateKeyURL.path),
              fileManager.fileExists(atPath: publicKeyURL.path),
              let diskBytes = try? fileSize(at: diskURL),
              diskBytes > 0,
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? Self.manifestDecoder().decode(Manifest.self, from: data),
              manifest.schemaVersion == Self.schemaVersion,
              manifest.cacheKey == cacheKey,
              manifest.baseImageSHA512.caseInsensitiveCompare(currentBaseSHA) == .orderedSame
        else {
            return nil
        }
        return ValidGolden(
            cacheKey: cacheKey,
            manifest: manifest,
            diskURL: diskURL,
            accessPrivateKeyURL: privateKeyURL
        )
    }

    /// Canonical newline-joined document hashed to produce the cache key.
    private func cacheKeyDocument(for inputs: Inputs) throws -> String {
        let lines = [
            String(Self.schemaVersion),
            try currentBaseImageSHA512(),
            Self.normalizedAgents(inputs.installAgents).joined(separator: ","),
            try provisionScriptSHA256(),
            Self.customScriptSHA256(inputs.customScript),
            inputs.desktopEnabled ? "desktop" : "headless",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// Hidden sibling of `goldens/<cacheKey>` used for atomic capture.
    private func stagingDirectoryURL(cacheKey: String) -> URL {
        stateDirectory.goldensDirectoryURL.appendingPathComponent(
            ".staging-\(cacheKey)",
            isDirectory: true
        )
    }

    /// Loads `provision.sh` through the same Bundle.module path CloudInitSeed uses.
    private func loadProvisionScript() throws -> Data {
        let url = resourceBundle.url(
            forResource: "provision",
            withExtension: "sh",
            subdirectory: "Guest"
        ) ?? resourceBundle.url(
            forResource: "provision",
            withExtension: "sh"
        )
        guard let url else {
            throw Failure.missingProvisionScript
        }
        return try Data(contentsOf: url)
    }

    /// Reads one OpenSSH public key and rejects empty or multiline files.
    private func readPublicKey(at url: URL) throws -> String {
        let publicKey = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !publicKey.isEmpty, !publicKey.contains("\n"), !publicKey.contains("\r") else {
            throw Failure.invalidPublicKey
        }
        return publicKey
    }

    /// Returns a regular file's byte length as an unsigned value.
    private func fileSize(at url: URL) throws -> UInt64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Sorted, trimmed agent names used in cache keys and manifests.
    private static func normalizedAgents(_ agents: [String]) -> [String] {
        agents
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
    }

    /// SHA-256 of the custom script, or `none` when it would not run.
    static func customScriptSHA256(_ script: String?) -> String {
        guard let script, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "none"
        }
        return sha256Hex(Data(script.utf8))
    }

    /// Extracts the digest belonging to one exact image filename.
    private static func checksumEntry(named expectedFileName: String, in manifest: String) -> String? {
        for line in manifest.split(whereSeparator: \.isNewline) {
            let fields = line.split(
                maxSplits: 1,
                omittingEmptySubsequences: true,
                whereSeparator: \.isWhitespace
            )
            guard fields.count == 2 else { continue }
            let digest = String(fields[0])
            guard digest.count == 128, digest.allSatisfy(\.isHexDigit) else { continue }

            var filename = fields[1].trimmingCharacters(in: .whitespaces)
            if filename.first == "*" {
                filename.removeFirst()
            }
            if filename.hasPrefix("./") {
                filename.removeFirst(2)
            }
            if filename == expectedFileName {
                return digest.lowercased()
            }
        }
        return nil
    }

    private static func manifestDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map(twoDigitHex).joined()
    }

    private static func twoDigitHex(_ byte: UInt8) -> String {
        let digits = Array("0123456789abcdef")
        return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]])
    }
}
