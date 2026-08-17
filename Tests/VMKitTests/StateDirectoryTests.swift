import Foundation
import Testing
@testable import VMKit

@Suite("VM state paths")
struct StateDirectoryTests {
    @Test("VETRO_VM_DIR overrides the shared Vetro application root")
    func environmentOverride() {
        let vmID = UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")!
        let overridden = StateDirectory(
            vmID: vmID,
            environment: ["VETRO_VM_DIR": "/tmp/vetro-test-state"],
            homeDirectory: URL(fileURLWithPath: "/tmp/vetro-home", isDirectory: true)
        )
        let standard = StateDirectory(
            vmID: vmID,
            environment: [:],
            homeDirectory: URL(fileURLWithPath: "/tmp/vetro-home", isDirectory: true)
        )

        #expect(
            overridden.rootURL.path
                == "/tmp/vetro-test-state/vm/01234567-89AB-CDEF-0123-456789ABCDEF"
        )
        #expect(overridden.imagesDirectoryURL.path == "/tmp/vetro-test-state/vm-images")
        #expect(
            standard.rootURL.path
                == "/tmp/vetro-home/Library/Application Support/Vetro/vm/01234567-89AB-CDEF-0123-456789ABCDEF"
        )
        #expect(
            standard.imagesDirectoryURL.path
                == "/tmp/vetro-home/Library/Application Support/Vetro/vm-images"
        )
        #expect(standard.baseImageURL.lastPathComponent == "debian-13-genericcloud-arm64.raw")
        #expect(standard.configurationURL.lastPathComponent == "vm.json")
        #expect(standard.goldensDirectoryURL.lastPathComponent == "goldens")
        #expect(
            standard.goldensDirectoryURL.deletingLastPathComponent().path
                == standard.imagesDirectoryURL.path
        )
        #expect(
            standard.goldenDirectoryURL(cacheKey: "abc").lastPathComponent == "abc"
        )
        #expect(
            standard.goldenDiskURL(cacheKey: "abc").lastPathComponent == "disk.img"
        )
        #expect(
            standard.goldenManifestURL(cacheKey: "abc").lastPathComponent == "manifest.json"
        )
        #expect(
            standard.goldenAccessPrivateKeyURL(cacheKey: "abc").lastPathComponent
                == "access_ed25519"
        )
        #expect(
            standard.goldenAccessPublicKeyURL(cacheKey: "abc").lastPathComponent
                == "access_ed25519.pub"
        )
    }

    @Test("VMs have isolated state and share the verified image cache")
    func multiVMLayout() {
        let first = StateDirectory(
            vmID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            environment: ["VETRO_VM_DIR": "/tmp/vetro-layout-test"],
            homeDirectory: URL(fileURLWithPath: "/unused", isDirectory: true)
        )
        let second = StateDirectory(
            vmID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            environment: ["VETRO_VM_DIR": "/tmp/vetro-layout-test"],
            homeDirectory: URL(fileURLWithPath: "/unused", isDirectory: true)
        )

        #expect(first.rootURL != second.rootURL)
        #expect(first.diskURL != second.diskURL)
        #expect(first.configurationURL != second.configurationURL)
        #expect(first.imagesDirectoryURL == second.imagesDirectoryURL)
        #expect(first.baseImageURL == second.baseImageURL)
        #expect(first.checksumsURL == second.checksumsURL)
    }
}
