public import Foundation

/// The canonical on-disk locations used by one Vetro virtual machine.
///
/// Construct this value once at the composition root and pass it to VMKit
/// services so every persistent artifact resolves from the same state root.
/// Tests can use ``init(rootURL:imagesDirectoryURL:)`` to keep all I/O isolated.
public struct StateDirectory: Sendable, Equatable {
    /// The root directory containing all persistent VM state.
    public let rootURL: URL

    /// The shared directory containing verified base-image cache artifacts.
    public let imagesDirectoryURL: URL

    /// Creates state paths rooted at explicit per-VM and shared-image directories.
    ///
    /// - Parameters:
    ///   - rootURL: The directory under which VMKit stores one VM's state.
    ///   - imagesDirectoryURL: The cache shared by every Vetro VM.
    public init(rootURL: URL, imagesDirectoryURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
        self.imagesDirectoryURL = imagesDirectoryURL.standardizedFileURL
    }

    /// Creates per-VM state paths from Vetro's application-support root.
    ///
    /// `VETRO_VM_DIR` overrides the Vetro application root, not the individual
    /// VM directory. An empty override is ignored. The defaults are
    /// `~/Library/Application Support/Vetro/vm/<vm-id>/` for VM state and
    /// `~/Library/Application Support/Vetro/vm-images/` for the shared cache.
    ///
    /// - Parameters:
    ///   - vmID: The durable identifier for this VM.
    ///   - environment: The process environment used to resolve `VETRO_VM_DIR`.
    ///   - homeDirectory: The home directory used when no override is present.
    public init(
        vmID: UUID,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        let appRootURL: URL
        if let override = environment["VETRO_VM_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty
        {
            appRootURL = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            appRootURL = homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("Vetro", isDirectory: true)
        }
        self.init(
            rootURL: appRootURL
                .appendingPathComponent("vm", isDirectory: true)
                .appendingPathComponent(vmID.uuidString, isDirectory: true),
            imagesDirectoryURL: appRootURL.appendingPathComponent(
                "vm-images",
                isDirectory: true
            )
        )
    }

    /// The verified Debian 13 arm64 generic-cloud base image.
    public var baseImageURL: URL {
        imagesDirectoryURL.appendingPathComponent("debian-13-genericcloud-arm64.raw", isDirectory: false)
    }

    /// The checksum manifest used to validate the cached base image.
    public var checksumsURL: URL {
        imagesDirectoryURL.appendingPathComponent("SHA512SUMS", isDirectory: false)
    }

    /// The shared directory of captured golden-image clones.
    public var goldensDirectoryURL: URL {
        imagesDirectoryURL.appendingPathComponent("goldens", isDirectory: true)
    }

    /// The finalized golden directory for one cache key.
    public func goldenDirectoryURL(cacheKey: String) -> URL {
        goldensDirectoryURL.appendingPathComponent(cacheKey, isDirectory: true)
    }

    /// The captured golden root disk.
    public func goldenDiskURL(cacheKey: String) -> URL {
        goldenDirectoryURL(cacheKey: cacheKey)
            .appendingPathComponent("disk.img", isDirectory: false)
    }

    /// The golden capture manifest.
    public func goldenManifestURL(cacheKey: String) -> URL {
        goldenDirectoryURL(cacheKey: cacheKey)
            .appendingPathComponent("manifest.json", isDirectory: false)
    }

    /// The private Ed25519 key used to reset a clone before its own key is installed.
    public func goldenAccessPrivateKeyURL(cacheKey: String) -> URL {
        goldenDirectoryURL(cacheKey: cacheKey)
            .appendingPathComponent("access_ed25519", isDirectory: false)
    }

    /// The public Ed25519 key appended to a donor before capture.
    public func goldenAccessPublicKeyURL(cacheKey: String) -> URL {
        goldenDirectoryURL(cacheKey: cacheKey)
            .appendingPathComponent("access_ed25519.pub", isDirectory: false)
    }

    /// The writable sparse root disk attached to the VM.
    public var diskURL: URL {
        rootURL.appendingPathComponent("disk.img", isDirectory: false)
    }

    /// The persistent EFI variable store reused across VM boots.
    public var efiVariableStoreURL: URL {
        rootURL.appendingPathComponent("efi-vars.bin", isDirectory: false)
    }

    /// The rendered NoCloud seed ISO attached read-only to the VM.
    public var seedISOURL: URL {
        rootURL.appendingPathComponent("seed.iso", isDirectory: false)
    }

    /// The content digest used to decide whether the seed ISO needs rebuilding.
    public var seedHashURL: URL {
        rootURL.appendingPathComponent("seed.sha256", isDirectory: false)
    }

    /// The serial-console log written by the VM's console attachment.
    public var consoleLogURL: URL {
        rootURL.appendingPathComponent("console.log", isDirectory: false)
    }

    /// The directory containing host-side SSH identity and trust files.
    public var sshDirectoryURL: URL {
        rootURL.appendingPathComponent("ssh", isDirectory: true)
    }

    /// The private Ed25519 key used to authenticate as the guest `vetro` user.
    public var sshPrivateKeyURL: URL {
        sshDirectoryURL.appendingPathComponent("id_ed25519", isDirectory: false)
    }

    /// The public Ed25519 key injected into the guest by cloud-init.
    public var sshPublicKeyURL: URL {
        sshDirectoryURL.appendingPathComponent("id_ed25519.pub", isDirectory: false)
    }

    /// The OpenSSH known-hosts file dedicated to this VM.
    public var knownHostsURL: URL {
        rootURL.appendingPathComponent("known_hosts", isDirectory: false)
    }

    /// The persisted CPU, memory, disk, network, and first-boot settings.
    public var configurationURL: URL {
        rootURL.appendingPathComponent("vm.json", isDirectory: false)
    }
}
