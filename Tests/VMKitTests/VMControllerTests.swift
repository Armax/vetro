import Foundation
import Testing
@testable import VMKit

@Suite("VM lifecycle observation")
struct VMControllerTests {
    @Test("an entitlement-free controller begins stopped")
    func beginsStoppedWithoutBooting() async {
        let stateDirectory = StateDirectory(
            rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                "VMControllerTests-\(UUID().uuidString)",
                isDirectory: true
            ),
            imagesDirectoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("VMControllerTests-images", isDirectory: true)
        )
        let controller = VMController(stateDirectory: stateDirectory, hostname: "dev-vm-1")

        let currentState = await controller.currentState
        let forwardedPort = await controller.forwardedPort
        let updates = await controller.stateUpdates()
        var iterator = updates.makeAsyncIterator()
        let firstUpdate = await iterator.next()

        #expect(currentState == .stopped)
        #expect(forwardedPort == nil)
        #expect(firstUpdate == .stopped)
    }

    @Test("a canceled start exits before image or Virtualization preparation")
    func canceledStartDoesNotBoot() async {
        let fileManager = FileManager()
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "VMControllerCancellationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        let stateDirectory = StateDirectory(
            rootURL: temporaryRoot.appendingPathComponent("vm", isDirectory: true),
            imagesDirectoryURL: temporaryRoot.appendingPathComponent(
                "vm-images",
                isDirectory: true
            )
        )
        let controller = VMController(stateDirectory: stateDirectory, hostname: "dev-vm-1")

        let startTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await controller.start()
        }
        do {
            _ = try await startTask.value
            Issue.record("The canceled controller unexpectedly reached VM readiness")
        } catch is CancellationError {
            // Expected: cancellation is observed before image or VZ preparation.
        } catch {
            Issue.record("The canceled controller threw \(error) instead of CancellationError")
        }

        #expect(!fileManager.fileExists(atPath: stateDirectory.baseImageURL.path))
        #expect(!fileManager.fileExists(atPath: stateDirectory.diskURL.path))
        #expect(!fileManager.fileExists(atPath: stateDirectory.efiVariableStoreURL.path))
        let finalState = await controller.currentState
        if case .error = finalState {
            // Cancellation is surfaced through the controller's existing error state.
        } else {
            Issue.record("The canceled controller ended in unexpected state \(finalState)")
        }
    }

    @Test("guest maintenance commands require a ready VM")
    func maintenanceCommandsRequireReadyState() async {
        let stateDirectory = StateDirectory(
            rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                "VMControllerMaintenanceTests-\(UUID().uuidString)",
                isDirectory: true
            ),
            imagesDirectoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("VMControllerMaintenanceTests-images", isDirectory: true)
        )
        let controller = VMController(stateDirectory: stateDirectory, hostname: "dev-vm-1")

        do {
            _ = try await controller.updateAgent(named: "claude")
            Issue.record("updateAgent unexpectedly succeeded while stopped")
        } catch VMController.Failure.invalidState(.stopped) {
        } catch {
            Issue.record("updateAgent threw \(error) instead of invalidState")
        }

        do {
            _ = try await controller.updateAgent(named: "gemini")
            Issue.record("updateAgent unexpectedly accepted an unknown agent")
        } catch VMController.Failure.unknownAgent("gemini") {
        } catch {
            Issue.record("updateAgent threw \(error) instead of unknownAgent")
        }

        do {
            _ = try await controller.customScriptLog(maxBytes: 4_096)
            Issue.record("customScriptLog unexpectedly succeeded while stopped")
        } catch VMController.Failure.invalidState(.stopped) {
        } catch {
            Issue.record("customScriptLog threw \(error) instead of invalidState")
        }

        do {
            _ = try await controller.expandRootFilesystem()
            Issue.record("expandRootFilesystem unexpectedly succeeded while stopped")
        } catch VMController.Failure.invalidState(.stopped) {
        } catch {
            Issue.record("expandRootFilesystem threw \(error) instead of invalidState")
        }

        do {
            _ = try await controller.stageGoldenAccessKey()
            Issue.record("stageGoldenAccessKey unexpectedly succeeded while stopped")
        } catch VMController.Failure.invalidState(.stopped) {
        } catch {
            Issue.record("stageGoldenAccessKey threw \(error) instead of invalidState")
        }

        do {
            try await controller.scrubForGoldenCapture()
            Issue.record("scrubForGoldenCapture unexpectedly succeeded while stopped")
        } catch VMController.Failure.invalidState(.stopped) {
        } catch {
            Issue.record("scrubForGoldenCapture threw \(error) instead of invalidState")
        }
    }
}
