import CryptoKit
public import Foundation

/// Serializes the cache's verify/download/accept transaction across controllers.
/// A distinct ImageStore actor exists for every VM, while the image directory is shared.
private actor SharedImageCacheGate {
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

/// Host-side stages for preparing the shared, verified base image.
public enum VMImagePreparationState: Sendable, Equatable {
    /// Waiting for, then verifying, the shared on-disk cache.
    case checkingCache

    /// Downloading a replacement raw image after the cache did not verify.
    case downloading

    /// Verifying the downloaded raw image against Debian's checksum manifest.
    case verifying

    /// A checksum-verified image and manifest are installed in the shared cache.
    case ready
}

/// Downloads, verifies, and materializes the Debian base and writable VM disks.
///
/// A process-wide gate serializes shared-cache transactions across ImageStore
/// actors, while each actor serializes its VM's writable-disk creation. A cached
/// image is returned only after its bytes match the persisted Debian checksum
/// manifest; downloads are accepted through atomic same-directory replacement.
public actor ImageStore {
    private static let sharedCacheGate = SharedImageCacheGate()

    /// Errors raised when a remote image or local disk cannot be safely accepted.
    public enum Failure: Error, Sendable, Equatable {
        /// A download returned a non-successful HTTP status code.
        case httpStatus(Int, URL)

        /// The downloaded checksum manifest did not list the expected image.
        case checksumEntryMissing(String)

        /// The downloaded image bytes did not match the published SHA-512 digest.
        case checksumMismatch(URL)

        /// The configured disk size was invalid or smaller than the base image.
        case invalidDiskSize(gibibytes: Int, baseImageBytes: UInt64)
    }

    private let stateDirectory: StateDirectory
    private let fileManager: FileManager
    private let session: URLSession
    private let checksumsRemoteURL: URL
    private let baseImageRemoteURL: URL

    /// Creates an image store using Debian's current Trixie cloud-image endpoints.
    ///
    /// - Parameter stateDirectory: The canonical locations for cached and writable images.
    public init(stateDirectory: StateDirectory) {
        self.stateDirectory = stateDirectory
        self.fileManager = FileManager()
        self.session = URLSession(configuration: .ephemeral)
        self.checksumsRemoteURL = URL(
            string: "https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS"
        )!
        self.baseImageRemoteURL = URL(
            string: "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-arm64.raw"
        )!
    }

    /// Creates an image store with injected filesystem, network, and endpoint dependencies.
    ///
    /// - Parameters:
    ///   - stateDirectory: The canonical locations for cached and writable images.
    ///   - fileManager: The filesystem dependency used for cache operations.
    ///   - session: The URL session used for checksum and image downloads.
    ///   - checksumsRemoteURL: The remote Debian `SHA512SUMS` URL.
    ///   - baseImageRemoteURL: The remote Debian raw-image URL.
    public init(
        stateDirectory: StateDirectory,
        fileManager: FileManager,
        session: URLSession,
        checksumsRemoteURL: URL,
        baseImageRemoteURL: URL
    ) {
        self.stateDirectory = stateDirectory
        self.fileManager = fileManager
        self.session = session
        self.checksumsRemoteURL = checksumsRemoteURL
        self.baseImageRemoteURL = baseImageRemoteURL
    }

    /// Returns a checksum-verified cached image, downloading a fresh pair when needed.
    ///
    /// The state callback runs synchronously in transaction order while the
    /// process-wide cache gate is held. The progress callback receives raw-image
    /// bytes written and the expected byte count when the server supplies one;
    /// it may run on a URLSession delegate queue. Both callbacks must therefore
    /// be `Sendable`.
    ///
    /// - Parameters:
    ///   - progress: A callback for raw-image download progress.
    ///   - stateUpdate: A callback for cache-check, download, verification, and
    ///     readiness stages.
    /// - Returns: ``StateDirectory/baseImageURL`` after successful SHA-512 verification.
    /// - Throws: A network, filesystem, or ``Failure`` error.
    public func ensureBaseImage(
        progress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in },
        stateUpdate: @escaping @Sendable (VMImagePreparationState) -> Void = { _ in }
    ) async throws -> URL {
        try await Self.sharedCacheGate.acquire()
        do {
            try Task.checkCancellation()
            let imageURL = try await ensureBaseImageWhileHoldingCache(
                progress: progress,
                stateUpdate: stateUpdate
            )
            await Self.sharedCacheGate.release()
            return imageURL
        } catch {
            await Self.sharedCacheGate.release()
            throw error
        }
    }

    /// Performs one complete cache transaction while the process-wide gate is held.
    private func ensureBaseImageWhileHoldingCache(
        progress: @escaping @Sendable (Int64, Int64?) -> Void,
        stateUpdate: @escaping @Sendable (VMImagePreparationState) -> Void
    ) async throws -> URL {
        stateUpdate(.checkingCache)
        try fileManager.createDirectory(
            at: stateDirectory.imagesDirectoryURL,
            withIntermediateDirectories: true
        )

        if fileManager.fileExists(atPath: stateDirectory.baseImageURL.path),
           fileManager.fileExists(atPath: stateDirectory.checksumsURL.path),
           try verifySHA512(
               fileURL: stateDirectory.baseImageURL,
               checksumsURL: stateDirectory.checksumsURL,
               expectedFileName: stateDirectory.baseImageURL.lastPathComponent
           )
        {
            let byteCount = try fileSize(at: stateDirectory.baseImageURL)
            try Task.checkCancellation()
            progress(Int64(clamping: byteCount), Int64(clamping: byteCount))
            stateUpdate(.ready)
            return stateDirectory.baseImageURL
        }

        let identifier = UUID().uuidString
        let checksumCandidate = stateDirectory.imagesDirectoryURL
            .appendingPathComponent(".SHA512SUMS-\(identifier)", isDirectory: false)
        let imageCandidate = stateDirectory.imagesDirectoryURL
            .appendingPathComponent(".debian-image-\(identifier)", isDirectory: false)
        defer {
            try? fileManager.removeItem(at: checksumCandidate)
            try? fileManager.removeItem(at: imageCandidate)
        }

        try Task.checkCancellation()
        let (checksumData, checksumResponse) = try await session.data(from: checksumsRemoteURL)
        try validateHTTPResponse(checksumResponse, for: checksumsRemoteURL)
        try checksumData.write(to: checksumCandidate, options: .atomic)

        try Task.checkCancellation()
        stateUpdate(.downloading)
        let progressDelegate = ImageDownloadProgressDelegate(progress: progress)
        let (downloadedImageURL, imageResponse) = try await session.download(
            from: baseImageRemoteURL,
            delegate: progressDelegate
        )
        try validateHTTPResponse(imageResponse, for: baseImageRemoteURL)
        try fileManager.moveItem(at: downloadedImageURL, to: imageCandidate)
        try Task.checkCancellation()
        stateUpdate(.verifying)

        let expectedFileName = stateDirectory.baseImageURL.lastPathComponent
        guard checksumEntry(
            named: expectedFileName,
            in: try String(contentsOf: checksumCandidate, encoding: .utf8)
        ) != nil else {
            throw Failure.checksumEntryMissing(expectedFileName)
        }
        guard try verifySHA512(
            fileURL: imageCandidate,
            checksumsURL: checksumCandidate,
            expectedFileName: expectedFileName
        ) else {
            throw Failure.checksumMismatch(imageCandidate)
        }

        try Task.checkCancellation()
        try atomicallyAccept(imageCandidate, at: stateDirectory.baseImageURL)
        try atomicallyAccept(checksumCandidate, at: stateDirectory.checksumsURL)
        stateUpdate(.ready)
        return stateDirectory.baseImageURL
    }

    /// Creates the writable sparse disk by copying a verified base image once.
    ///
    /// An existing `disk.img` is always preserved. A new disk is copied to a
    /// temporary sibling, extended sparsely to the configured size, and then
    /// moved into place so an interrupted copy is never mistaken for a disk.
    ///
    /// - Parameters:
    ///   - baseImageURL: The already checksum-verified base image to copy.
    ///   - settings: The settings supplying the target disk size.
    /// - Returns: ``StateDirectory/diskURL``.
    /// - Throws: A filesystem error or ``Failure/invalidDiskSize(gibibytes:baseImageBytes:)``.
    public func ensureDisk(from baseImageURL: URL, settings: VMSettings) throws -> URL {
        try Task.checkCancellation()
        if fileManager.fileExists(atPath: stateDirectory.diskURL.path) {
            return stateDirectory.diskURL
        }

        try fileManager.createDirectory(
            at: stateDirectory.rootURL,
            withIntermediateDirectories: true
        )
        let baseImageBytes = try fileSize(at: baseImageURL)
        guard settings.diskSizeGB > 0 else {
            throw Failure.invalidDiskSize(
                gibibytes: settings.diskSizeGB,
                baseImageBytes: baseImageBytes
            )
        }
        let (targetBytes, overflow) = UInt64(settings.diskSizeGB)
            .multipliedReportingOverflow(by: 1_073_741_824)
        guard !overflow, targetBytes >= baseImageBytes else {
            throw Failure.invalidDiskSize(
                gibibytes: settings.diskSizeGB,
                baseImageBytes: baseImageBytes
            )
        }

        let candidate = stateDirectory.rootURL.appendingPathComponent(
            ".disk-\(UUID().uuidString).img",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: candidate) }
        try fileManager.copyItem(at: baseImageURL, to: candidate)
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
            return stateDirectory.diskURL
        }
        try fileManager.moveItem(at: candidate, to: stateDirectory.diskURL)
        return stateDirectory.diskURL
    }

    /// Verifies a file against one exact filename entry in a SHA512SUMS manifest.
    ///
    /// - Parameters:
    ///   - fileURL: The file whose bytes should be hashed.
    ///   - checksumsURL: A GNU-style SHA-512 checksum manifest.
    ///   - expectedFileName: The manifest filename that must match the file.
    /// - Returns: `true` only when an entry exists and its digest matches.
    /// - Throws: A filesystem read error.
    func verifySHA512(
        fileURL: URL,
        checksumsURL: URL,
        expectedFileName: String
    ) throws -> Bool {
        let manifest = try String(contentsOf: checksumsURL, encoding: .utf8)
        guard let expectedDigest = checksumEntry(named: expectedFileName, in: manifest) else {
            return false
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA512()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        let actualDigest = hasher.finalize().map(Self.twoDigitHex).joined()
        return actualDigest.caseInsensitiveCompare(expectedDigest) == .orderedSame
    }

    /// Extracts the digest belonging to one exact image filename.
    private func checksumEntry(named expectedFileName: String, in manifest: String) -> String? {
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

    /// Rejects unexpected HTTP responses while still allowing non-HTTP test URLs.
    private func validateHTTPResponse(_ response: URLResponse, for url: URL) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Failure.httpStatus(httpResponse.statusCode, url)
        }
    }

    /// Atomically installs a verified candidate while preserving same-volume semantics.
    private func atomicallyAccept(_ candidate: URL, at destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: candidate,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: candidate, to: destination)
        }
    }

    /// Returns a regular file's byte length as an unsigned value.
    private func fileSize(at url: URL) throws -> UInt64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Formats one digest byte as two lowercase hexadecimal characters.
    private static func twoDigitHex(_ byte: UInt8) -> String {
        let digits = Array("0123456789abcdef")
        return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]])
    }
}
