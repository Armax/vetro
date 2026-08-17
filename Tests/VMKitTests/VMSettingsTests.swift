import Foundation
import Testing
@testable import VMKit

@Suite("VM settings persistence")
struct VMSettingsTests {
    @Test("defaults prefer performance cores and enforce the M1 limits")
    func defaults() {
        let performanceCoreDefaults = VMSettings.defaults(
            performanceCoreCount: 4,
            activeProcessorCount: 12,
            macAddress: "02:11:22:33:44:55"
        )
        #expect(performanceCoreDefaults.cpus == 4)
        #expect(performanceCoreDefaults.memoryMB == 4_096)
        #expect(performanceCoreDefaults.diskSizeGB == 32)
        #expect(performanceCoreDefaults.macAddress == "02:11:22:33:44:55")
        #expect(!performanceCoreDefaults.firstBootCompleted)
        #expect(performanceCoreDefaults.installAgents == ["claude", "codex", "grok"])
        #expect(performanceCoreDefaults.customScript == nil)
        #expect(performanceCoreDefaults.idleStopMinutes == nil)
        #expect(performanceCoreDefaults.networkEnabled)
        #expect(performanceCoreDefaults.goldenCaptureCacheKey == nil)

        let activeCoreFallback = VMSettings.defaults(
            performanceCoreCount: nil,
            activeProcessorCount: 12,
            macAddress: "02:11:22:33:44:55"
        )
        #expect(activeCoreFallback.cpus == 6)

        let minimumFallback = VMSettings.defaults(
            performanceCoreCount: 0,
            activeProcessorCount: 0,
            macAddress: "02:11:22:33:44:55"
        )
        #expect(minimumFallback.cpus == 1)
    }

    @Test("vm.json round-trips and preserves its generated MAC across stores")
    func roundTripAndStableMAC() async throws {
        let fileManager = FileManager()
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "VMSettingsTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        let stateDirectory = StateDirectory(
            rootURL: temporaryRoot,
            imagesDirectoryURL: temporaryRoot.appendingPathComponent(
                "vm-images",
                isDirectory: true
            )
        )

        let creatingStore = VMSettingsStore(
            stateDirectory: stateDirectory,
            fileManager: FileManager(),
            defaultCPUCount: 5,
            macAddressGenerator: { "02:aa:bb:cc:dd:ee" }
        )
        var created = try await creatingStore.loadOrCreate()
        #expect(created == VMSettings(cpus: 5, macAddress: "02:aa:bb:cc:dd:ee"))

        created.firstBootCompleted = true
        created.memoryMB = 8_192
        created.installAgents = ["claude"]
        created.customScript = "#!/bin/sh\ntrue\n"
        created.idleStopMinutes = 15
        created.networkEnabled = false
        created.goldenCaptureCacheKey = "golden-key"
        try await creatingStore.save(created)

        let reloadingStore = VMSettingsStore(
            stateDirectory: stateDirectory,
            fileManager: FileManager(),
            defaultCPUCount: 1,
            macAddressGenerator: { "02:00:00:00:00:01" }
        )
        let reloaded = try await reloadingStore.loadOrCreate()
        #expect(reloaded == created)
        #expect(reloaded.macAddress == "02:aa:bb:cc:dd:ee")
        #expect(reloaded.firstBootCompleted)
        #expect(reloaded.memoryMB == 8_192)
        #expect(reloaded.installAgents == ["claude"])
        #expect(reloaded.customScript == "#!/bin/sh\ntrue\n")
        #expect(reloaded.idleStopMinutes == 15)
        #expect(!reloaded.networkEnabled)
        #expect(reloaded.goldenCaptureCacheKey == "golden-key")
    }

    @Test("generated MAC addresses are locally administered unicast addresses")
    func generatedMACBits() throws {
        let resolver = NetworkResolver()
        for _ in 0..<16 {
            let address = VMSettings.makeRandomMACAddress()
            #expect(resolver.normalizeMACAddress(address) == address)
            let firstOctet = try #require(UInt8(address.prefix(2), radix: 16))
            #expect(firstOctet & 0x02 == 0x02)
            #expect(firstOctet & 0x01 == 0)
        }
    }

    @Test("pre-flag vm.json decodes as an incomplete first boot")
    func decodesPreFlagSettings() throws {
        let data = Data(
            """
            {
              "cpus": 4,
              "memoryMB": 4096,
              "diskSizeGB": 32,
              "macAddress": "02:11:22:33:44:55"
            }
            """.utf8
        )
        let settings = try JSONDecoder().decode(VMSettings.self, from: data)

        #expect(settings.cpus == 4)
        #expect(!settings.firstBootCompleted)
        #expect(settings.installAgents == ["claude", "codex", "grok"])
        #expect(settings.customScript == nil)
        #expect(settings.idleStopMinutes == nil)
        #expect(settings.networkEnabled)
        #expect(settings.goldenCaptureCacheKey == nil)
    }

    @Test("vm.json without V1 fields migrates to the new defaults")
    func decodesPreV1Settings() throws {
        let data = Data(
            """
            {
              "cpus": 2,
              "memoryMB": 2048,
              "diskSizeGB": 16,
              "macAddress": "02:11:22:33:44:55",
              "firstBootCompleted": true
            }
            """.utf8
        )
        let settings = try JSONDecoder().decode(VMSettings.self, from: data)

        #expect(settings.firstBootCompleted)
        #expect(settings.installAgents == VMSettings.defaultInstallAgents)
        #expect(settings.customScript == nil)
        #expect(settings.idleStopMinutes == nil)
        #expect(settings.networkEnabled)
        #expect(settings.goldenCaptureCacheKey == nil)
    }

    @Test("goldenCaptureCacheKey decodes when present and stays optional")
    func decodesGoldenCaptureCacheKey() throws {
        let data = Data(
            """
            {
              "cpus": 2,
              "memoryMB": 2048,
              "diskSizeGB": 16,
              "macAddress": "02:11:22:33:44:55",
              "firstBootCompleted": true,
              "goldenCaptureCacheKey": "abc123"
            }
            """.utf8
        )
        let settings = try JSONDecoder().decode(VMSettings.self, from: data)
        #expect(settings.goldenCaptureCacheKey == "abc123")
    }
}
