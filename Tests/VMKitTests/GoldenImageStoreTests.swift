import Foundation
import Testing
@testable import VMKit

@Suite("Golden image cache", .serialized)
struct GoldenImageStoreTests {
    @Test("cache keys are deterministic, change with each input, and ignore hardware")
    func cacheKeyDeterminismAndInputs() async throws {
        let harness = try GoldenHarness()
        defer { harness.tearDown() }
        let store = harness.store()

        let agents = GoldenImageStore.Inputs(installAgents: ["grok", "claude"], customScript: nil)
        let first = try await store.cacheKey(for: agents)
        let second = try await store.cacheKey(for: agents)
        #expect(first == second)
        #expect(first.count == 64)
        #expect(first.allSatisfy { $0.isHexDigit })

        let reordered = GoldenImageStore.Inputs(
            installAgents: ["claude", "grok"],
            customScript: nil
        )
        #expect(try await store.cacheKey(for: reordered) == first)

        let differentAgents = try await store.cacheKey(
            for: GoldenImageStore.Inputs(installAgents: ["claude"], customScript: nil)
        )
        #expect(differentAgents != first)

        let withScript = try await store.cacheKey(
            for: GoldenImageStore.Inputs(
                installAgents: ["grok", "claude"],
                customScript: "#!/bin/sh\ntrue\n"
            )
        )
        #expect(withScript != first)

        try harness.writeChecksums(String(repeating: "b", count: 128))
        let differentBase = try await store.cacheKey(for: agents)
        #expect(differentBase != first)

        try harness.writeChecksums(harness.digest)
        let small = VMSettings(
            cpus: 2,
            memoryMB: 2_048,
            diskSizeGB: 16,
            macAddress: "02:00:00:00:00:01",
            installAgents: ["claude"],
            networkEnabled: false
        )
        let large = VMSettings(
            cpus: 6,
            memoryMB: 8_192,
            diskSizeGB: 64,
            macAddress: "02:00:00:00:00:02",
            installAgents: ["claude"],
            networkEnabled: true
        )
        let hardwareA = try await store.cacheKey(for: GoldenImageStore.Inputs(small))
        let hardwareB = try await store.cacheKey(for: GoldenImageStore.Inputs(large))
        #expect(hardwareA == hardwareB)
    }

    @Test("manifests round-trip through ISO-8601 JSON")
    func manifestRoundTrip() throws {
        let createdAt = ISO8601DateFormatter().date(from: "2026-08-15T12:00:00Z")!
        let manifest = GoldenImageStore.Manifest(
            schemaVersion: GoldenImageStore.schemaVersion,
            cacheKey: String(repeating: "ab", count: 32),
            baseImageSHA512: String(repeating: "cd", count: 64),
            installAgents: ["claude", "grok"],
            provisionScriptSHA256: String(repeating: "ef", count: 32),
            customScriptSHA256: "none",
            donorDiskSizeGB: 32,
            createdAt: createdAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            GoldenImageStore.Manifest.self,
            from: try encoder.encode(manifest)
        )
        #expect(decoded == manifest)
    }

    @Test("lookup returns nil for schema, checksum, disk, key, and corrupt failures")
    func lookupRejectsInvalidGoldens() async throws {
        let harness = try GoldenHarness()
        defer { harness.tearDown() }
        let store = harness.store()
        let inputs = GoldenImageStore.Inputs(installAgents: ["claude"])
        let key = try await store.cacheKey(for: inputs)
        let valid = try await harness.captureValidGolden(store: store, inputs: inputs, sizeGB: 1)

        var bumped = valid.manifest
        bumped.schemaVersion = GoldenImageStore.schemaVersion + 1
        try harness.writeManifest(bumped, cacheKey: key)
        #expect(try await store.lookup(inputs: inputs) == nil)

        try harness.writeManifest(valid.manifest, cacheKey: key)
        try Data("not-json".utf8).write(
            to: harness.state.goldenManifestURL(cacheKey: key)
        )
        #expect(try await store.lookup(inputs: inputs) == nil)

        try harness.writeManifest(valid.manifest, cacheKey: key)
        try FileManager.default.removeItem(at: harness.state.goldenDiskURL(cacheKey: key))
        #expect(try await store.lookup(inputs: inputs) == nil)

        try Data("disk".utf8).write(to: harness.state.goldenDiskURL(cacheKey: key))
        try FileManager.default.removeItem(
            at: harness.state.goldenAccessPrivateKeyURL(cacheKey: key)
        )
        #expect(try await store.lookup(inputs: inputs) == nil)

        try await harness.captureValidGolden(store: store, inputs: inputs, sizeGB: 1)
        try harness.writeChecksums(String(repeating: "0", count: 128))
        #expect(try await store.lookup(inputs: inputs) == nil)
        #expect(
            !FileManager.default.fileExists(
                atPath: harness.state.goldenDirectoryURL(cacheKey: key).path
            )
        )
    }

    @Test("capture then lookup is atomic and leaves no staging directory")
    func captureLookupRoundTrip() async throws {
        let harness = try GoldenHarness()
        defer { harness.tearDown() }
        let store = harness.store()
        let inputs = GoldenImageStore.Inputs(installAgents: ["codex"])
        let golden = try await harness.captureValidGolden(store: store, inputs: inputs, sizeGB: 1)
        let lookedUp = try #require(try await store.lookup(inputs: inputs))

        #expect(lookedUp.cacheKey == golden.cacheKey)
        #expect(lookedUp.manifest.donorDiskSizeGB == 1)
        #expect(lookedUp.manifest.schemaVersion == GoldenImageStore.schemaVersion)
        #expect(FileManager.default.fileExists(atPath: lookedUp.diskURL.path))
        #expect(FileManager.default.fileExists(atPath: lookedUp.accessPrivateKeyURL.path))

        let leftover = try FileManager.default.contentsOfDirectory(
            at: harness.state.goldensDirectoryURL,
            includingPropertiesForKeys: nil
        )
        #expect(leftover.allSatisfy { !$0.lastPathComponent.hasPrefix(".staging-") })
        #expect(leftover.map(\.lastPathComponent) == [golden.cacheKey])
    }

    @Test("cloneDisk grows equal and larger disks and rejects a smaller target")
    func cloneDiskSizes() async throws {
        let harness = try GoldenHarness()
        defer { harness.tearDown() }
        let store = harness.store()
        let inputs = GoldenImageStore.Inputs(installAgents: ["grok"])
        let golden = try await harness.captureValidGolden(store: store, inputs: inputs, sizeGB: 1)

        let equalRoot = harness.root.appendingPathComponent("equal", isDirectory: true)
        let equalState = StateDirectory(
            rootURL: equalRoot,
            imagesDirectoryURL: harness.state.imagesDirectoryURL
        )
        let equal = try await store.cloneDisk(
            from: golden,
            into: equalState,
            targetDiskSizeGB: 1
        )
        #expect(equal == .cloned(needsGrow: false))
        #expect(try harness.logicalSize(at: equalState.diskURL) == 1_073_741_824)

        let largerRoot = harness.root.appendingPathComponent("larger", isDirectory: true)
        let largerState = StateDirectory(
            rootURL: largerRoot,
            imagesDirectoryURL: harness.state.imagesDirectoryURL
        )
        let larger = try await store.cloneDisk(
            from: golden,
            into: largerState,
            targetDiskSizeGB: 2
        )
        #expect(larger == .cloned(needsGrow: true))
        #expect(try harness.logicalSize(at: largerState.diskURL) == 2_147_483_648)
    }

    @Test("cloneDisk reports ineligible when the target is smaller than the donor")
    func cloneDiskIneligibleWhenSmaller() async throws {
        let harness = try GoldenHarness()
        defer { harness.tearDown() }
        let store = harness.store()
        let inputs = GoldenImageStore.Inputs(installAgents: ["claude", "codex"])
        let golden = try await harness.captureValidGolden(store: store, inputs: inputs, sizeGB: 2)
        let destination = StateDirectory(
            rootURL: harness.root.appendingPathComponent("too-small", isDirectory: true),
            imagesDirectoryURL: harness.state.imagesDirectoryURL
        )
        let result = try await store.cloneDisk(
            from: golden,
            into: destination,
            targetDiskSizeGB: 1
        )
        #expect(result == .ineligible)
        #expect(!FileManager.default.fileExists(atPath: destination.diskURL.path))
    }

    @Test("exclude-path validation rejects absolute and parent-escaping paths")
    func scrubPathValidation() {
        #expect(GoldenExcludePath.validated(".codex") == ".codex")
        #expect(
            GoldenExcludePath.validated(".claude/.credentials.json") == ".claude/.credentials.json"
        )
        #expect(GoldenExcludePath.validated("  .config/vetro/env  ") == ".config/vetro/env")
        #expect(GoldenExcludePath.validated("/etc/passwd") == nil)
        #expect(GoldenExcludePath.validated("../etc/passwd") == nil)
        #expect(GoldenExcludePath.validated("foo/../bar") == nil)
        #expect(GoldenExcludePath.validated("") == nil)
        #expect(GoldenExcludePath.validated("   ") == nil)
    }

    @Test("cloneDisk throws for a non-positive target size")
    func cloneDiskRejectsInvalidSize() async throws {
        let harness = try GoldenHarness()
        defer { harness.tearDown() }
        let store = harness.store()
        let inputs = GoldenImageStore.Inputs(installAgents: ["claude"])
        let golden = try await harness.captureValidGolden(store: store, inputs: inputs, sizeGB: 1)
        let destination = StateDirectory(
            rootURL: harness.root.appendingPathComponent("invalid", isDirectory: true),
            imagesDirectoryURL: harness.state.imagesDirectoryURL
        )
        do {
            _ = try await store.cloneDisk(
                from: golden,
                into: destination,
                targetDiskSizeGB: 0
            )
            Issue.record("cloneDisk unexpectedly accepted a 0 GiB target")
        } catch GoldenImageStore.Failure.invalidTargetDiskSize(gibibytes: 0, donorBytes: _) {
        } catch {
            Issue.record("cloneDisk threw \(error) instead of invalidTargetDiskSize")
        }
    }
}

/// Isolated golden-store workspace with a synthetic SHA512SUMS file.
private struct GoldenHarness {
    let fileManager: FileManager
    let root: URL
    let state: StateDirectory
    let digest: String

    init() throws {
        fileManager = FileManager()
        root = fileManager.temporaryDirectory.appendingPathComponent(
            "GoldenImageStoreTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        state = StateDirectory(
            rootURL: root.appendingPathComponent("vm", isDirectory: true),
            imagesDirectoryURL: root.appendingPathComponent("vm-images", isDirectory: true)
        )
        digest = String(repeating: "a", count: 128)
        try fileManager.createDirectory(
            at: state.imagesDirectoryURL,
            withIntermediateDirectories: true
        )
        try writeChecksums(digest)
    }

    func tearDown() {
        try? fileManager.removeItem(at: root)
    }

    func store() -> GoldenImageStore {
        GoldenImageStore(stateDirectory: state, fileManager: FileManager())
    }

    func writeChecksums(_ digest: String) throws {
        try fileManager.createDirectory(
            at: state.imagesDirectoryURL,
            withIntermediateDirectories: true
        )
        try Data("\(digest)  debian-13-genericcloud-arm64.raw\n".utf8)
            .write(to: state.checksumsURL)
    }

    func writeManifest(_ manifest: GoldenImageStore.Manifest, cacheKey: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try fileManager.createDirectory(
            at: state.goldenDirectoryURL(cacheKey: cacheKey),
            withIntermediateDirectories: true
        )
        try encoder.encode(manifest).write(
            to: state.goldenManifestURL(cacheKey: cacheKey),
            options: .atomic
        )
    }

    @discardableResult
    func captureValidGolden(
        store: GoldenImageStore,
        inputs: GoldenImageStore.Inputs,
        sizeGB: Int
    ) async throws -> GoldenImageStore.ValidGolden {
        let staged = try await store.stageAccessKey(inputs: inputs)
        let donor = root.appendingPathComponent(
            "donor-\(UUID().uuidString).img",
            isDirectory: false
        )
        try Data("golden-donor".utf8).write(to: donor)
        let manifest = try await store.makeManifest(
            inputs: inputs,
            cacheKey: staged.cacheKey,
            donorDiskSizeGB: sizeGB
        )
        try await store.capture(
            cacheKey: staged.cacheKey,
            donorDiskURL: donor,
            manifest: manifest
        )
        return try #require(try await store.lookup(inputs: inputs))
    }

    func logicalSize(at url: URL) throws -> UInt64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
