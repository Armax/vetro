import AppKit
import CryptoKit
import Darwin
import Foundation
import Observation
import VMKit

struct VM: Identifiable, Hashable {
    enum State: String, Sendable {
        case downloading
        case provisioning
        case starting
        case ready
        case stopped
        case error
    }

    let id: UUID
    var name: String
    let createdAt: Date
    var state: State
    var ip: String
    var uptime: String
    var cpu: Int
    var ram: String
    var diskUsedGB: Double
    var diskMaxGB: Double
    var agents: [VMAgent]
    var downloadProgress: Double
    var downloadedImageBytes: Int64
    var expectedImageBytes: Int64?
    var isVerifyingImage: Bool
    var phases: [VMPhase]
    var updateState: VMUpdateState
    var errorMessage: String?
    var idleStopMinutes: Int?
    var networkEnabled: Bool
    var networkChangePending: Bool
    var pendingFilesystemGrow: Bool
    var customScriptFailed: Bool
    var hasCustomScript: Bool

    var chipLabel: String {
        switch state {
        case .ready: "Ready"
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .provisioning: "Provisioning"
        case .downloading: "Downloading"
        case .error: "Error"
        }
    }
}

struct VMPhase: Identifiable, Hashable, Sendable {
    enum State: String, Hashable, Sendable {
        case pending
        case running
        case done
        case failed
        case skipped
    }

    let id: String
    var label: String
    var state: State
}

enum VMUpdateState: String, Hashable, Sendable {
    case idle
    case running
    case partial
    case done
}

struct VMAgent: Identifiable, Hashable, Sendable {
    enum Status: String, Hashable, Sendable {
        case ok
        case updating
        case updated
        case failed
    }

    var id: String { name }
    var name: String
    var version: String
    var status: Status
}

enum ProjectVMState: String, Codable, Sendable {
    case importing
    case starting
    case ready
    case error
    case settingUp
}

struct ProjectVMAttachment: Hashable, Sendable {
    let vmID: UUID
    var guestPath: String
    var state: ProjectVMState
    var importProgress: Double
    var lastImport: Date?
    var lastExport: Date?
    var excludedMirrorPorts: [UInt16] = []
    var mirrorRemaps: [UInt16: UInt16] = [:]
    var hostMirrorPorts: [UInt16] = []
    var dismissedHostMirrorPorts: [UInt16] = []
    var removedHostMirrorPorts: [UInt16] = []

    func lastTransferLabel(now: Date = .now) -> String? {
        let verb: String
        let date: Date
        switch (lastImport, lastExport) {
        case let (imported?, exported?) where exported > imported:
            verb = "exported"
            date = exported
        case let (imported?, _):
            verb = "imported"
            date = imported
        case let (nil, exported?):
            verb = "exported"
            date = exported
        case (nil, nil):
            return nil
        }
        let age = RelativeTimestamp.compact(since: date, now: now)
        if age == "now" { return "\(verb) now" }
        if age == "Yesterday" { return "\(verb) yesterday" }
        return "\(verb) \(age) ago"
    }
}

enum TransferDirection: Sendable, Equatable {
    case exportToMac
    case importFromMac
}

enum PendingTransferPhase: Sendable, Equatable {
    case comparing
    case awaitingConfirm
}

struct PendingTransfer: Sendable {
    let projectID: UUID
    let direction: TransferDirection
    var phase: PendingTransferPhase
    var preview: TransferPreview?
}

struct NewVMConfiguration: Sendable, Equatable {
    var name: String
    var cpus: Int
    var memoryMB: Int
    var diskSizeGB: Int
    var agents: [String]
    var transferAuth: Bool
    var customScript: String?

    static func defaults(name: String) -> NewVMConfiguration {
        let settings = VMSettings.defaults(
            performanceCoreCount: nil,
            activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount,
            macAddress: "02:00:00:00:00:00"
        )
        return NewVMConfiguration(
            name: name,
            cpus: settings.cpus,
            memoryMB: settings.memoryMB,
            diskSizeGB: settings.diskSizeGB,
            agents: VMSettings.defaultInstallAgents,
            transferAuth: true,
            customScript: nil
        )
    }
}

private enum VMOperationError: LocalizedError, Sendable {
    case vmNotFound
    case vmBusy
    case vmNotReady
    case vmNotStopped
    case cannotShrinkDisk
    case unknownAgent(String)
    case attachmentNotFound
    case noAttachedProject
    case terminalSessionFailed
    case unsafeGuestPath(String)
    case commandFailed(command: String, status: Int32, output: String)
    case terminating

    var errorDescription: String? {
        switch self {
        case .vmNotFound:
            "The virtual machine no longer exists."
        case .vmBusy:
            "The virtual machine is already running another operation."
        case .vmNotReady:
            "The virtual machine did not become ready."
        case .vmNotStopped:
            "The virtual machine must be stopped to change resources."
        case .cannotShrinkDisk:
            "Disk size can only be increased."
        case let .unknownAgent(name):
            "Unknown agent \(name)."
        case .attachmentNotFound:
            "The project is not attached to a virtual machine."
        case .noAttachedProject:
            "The VM has no attached project."
        case .terminalSessionFailed:
            "The terminal session could not be opened."
        case let .unsafeGuestPath(path):
            "Refusing to modify the unexpected guest path \(path)."
        case let .commandFailed(command, status, output):
            output.isEmpty
                ? "\(command) exited with status \(status)."
                : "\(command) exited with status \(status): \(output)"
        case .terminating:
            "Vetro is shutting down."
        }
    }
}

enum MirrorPortStatus: Equatable, Sendable {
    case active
    case conflict
}

struct HostMirrorSuggestion: Equatable, Hashable, Sendable {
    let vmID: UUID
    let port: UInt16
}

private struct HostMirrorCooldownKey: Hashable, Sendable {
    let vmID: UUID
    let port: UInt16
}

@MainActor
private final class VMRuntime {
    let stateDirectory: StateDirectory
    let hostname: String
    let sshClient: SSHClient
    var controller: VMController?
    var startTask: Task<VMStartResult, any Error>?
    var monitorTask: Task<Void, Never>?
    var startedAt: Date?
    var forwardedPort: UInt16?
    var busy = false
    var creating = false
    var updateBaseline: VMProvisioningStatus?
    var sawFreshUpdateStatus = false
    var lastBusy = Date.now
    var bootedNetworkEnabled: Bool?
    var memoryReclaimed = false
    var mirroredPorts: Set<UInt16> = []
    var conflictPorts: Set<UInt16> = []
    var remaps: [UInt16: UInt16] = [:]
    var lastPortSnapshot: Set<UInt16> = []
    var postReadyTask: Task<Void, Never>?

    init(stateDirectory: StateDirectory, hostname: String) {
        self.stateDirectory = stateDirectory
        self.hostname = hostname
        self.sshClient = SSHClient(stateDirectory: stateDirectory)
    }

    func controllerInstance() -> VMController {
        if let controller { return controller }
        let controller = VMController(stateDirectory: stateDirectory, hostname: hostname)
        self.controller = controller
        return controller
    }
}

private struct RsyncResult: Sendable {
    let status: Int32
    let outputTail: String
}

private struct RsyncPreviewResult: Sendable {
    let status: Int32
    let stdout: String
    let stderrTail: String
}

private struct ActiveTransfer: Sendable {
    let token: UUID
    let vmID: UUID
}

private final class RsyncProgressCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let progress: @Sendable (Double) -> Void
    private var scanBuffer = ""
    private var outputTail = ""
    private var lastPercent = -1
    private let parsePercentages: Bool

    init(
        parsePercentages: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) {
        self.parsePercentages = parsePercentages
        self.progress = progress
    }

    func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        let text = String(decoding: data, as: UTF8.self)
        var percentages: [Double] = []

        lock.lock()
        let combined = scanBuffer + text
        var digits = ""
        if parsePercentages {
            for character in combined {
                if character.isNumber {
                    digits.append(character)
                    if digits.count > 3 { digits.removeFirst() }
                } else {
                    if character == "%", let percent = Int(digits),
                       (0...100).contains(percent), percent > lastPercent
                    {
                        lastPercent = percent
                        percentages.append(Double(percent))
                    }
                    digits = ""
                }
            }
        }
        scanBuffer = String(combined.suffix(16))
        outputTail = String((outputTail + text).suffix(16_384))
        lock.unlock()

        for percentage in percentages {
            progress(percentage)
        }
    }

    func tail() -> String {
        lock.lock()
        defer { lock.unlock() }
        return outputTail.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
@Observable
final class VMStore {
    private struct PersistedState: Codable {
        struct Record: Codable {
            let id: UUID
            var name: String
            let createdAt: Date
            var pendingFilesystemGrow: Bool?
        }

        struct Attachment: Codable {
            let vmID: UUID
            let guestPath: String
            var lastImport: Date?
            var lastExport: Date?
            var forwardedPorts: [UInt16]?
            var excludedMirrorPorts: [UInt16]?
            var mirrorRemaps: [String: UInt16]?
            var hostMirrorPorts: [UInt16]?
            var dismissedHostMirrorPorts: [UInt16]?
            var removedHostMirrorPorts: [UInt16]?
        }

        var vms: [Record]
        var attachments: [String: Attachment]
    }

    private(set) var vms: [VM] = []
    var selectedVMID: UUID?
    private(set) var attachments: [UUID: ProjectVMAttachment] = [:]
    private(set) var pendingTransfer: PendingTransfer?
    private(set) var lastError: String?
    private(set) var portMirrorEpoch: UInt = 0
    private(set) var hostMirrorSuggestions: [HostMirrorSuggestion] = []

    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let environment: [String: String]
    @ObservationIgnored private let homeDirectory: URL
    @ObservationIgnored private let credentialsStore: any VMAgentCredentialsStoring
    @ObservationIgnored private let applicationRootURL: URL
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var runtimes: [UUID: VMRuntime] = [:]
    @ObservationIgnored private var activeTransfers: [UUID: ActiveTransfer] = [:]
    @ObservationIgnored private var pendingTransferConnection: ReadyConnection?
    @ObservationIgnored private var pendingTransferProject: Project?
    @ObservationIgnored private var startInProgress = false
    @ObservationIgnored private var startWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var isTerminating = false
    @ObservationIgnored private var liveLoginMirrors: [UUID: (vmID: UUID, guestPort: UInt16)] = [:]
    @ObservationIgnored private var refusedHostMirrorCooldowns: [HostMirrorCooldownKey: Date] = [:]

    private static let transferExcludes = [
        "node_modules/",
        ".venv/",
        "venv/",
        "target/",
        "build/",
        "dist/",
        ".next/",
        ".turbo/",
        "__pycache__/",
        ".DS_Store",
    ]

    private static let defaultHostMirrorPorts: Set<UInt16> = [
        27_017, 5_432, 6_379, 3_306,
    ]

    init(
        fileManager: FileManager = FileManager(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        credentialsStore: any VMAgentCredentialsStoring = KeychainAgentCredentialsStore()
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.credentialsStore = credentialsStore
        if let override = environment["VETRO_VM_DIR"]?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !override.isEmpty {
            self.applicationRootURL = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            self.applicationRootURL = homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("Vetro", isDirectory: true)
        }
        self.fileURL = applicationRootURL.appendingPathComponent(
            "vms.json",
            isDirectory: false
        )

        do {
            try fileManager.createDirectory(
                at: applicationRootURL,
                withIntermediateDirectories: true
            )
            try load()
        } catch {
            lastError = Self.describe(error)
        }
        Task { [credentialsStore] in
            try? await credentialsStore.deleteLegacyAPIKeys()
        }
        startIdleWatch()
    }

    func vm(_ id: UUID?) -> VM? {
        guard let id else { return nil }
        return vms.first { $0.id == id }
    }

    func uptimeLabel(for vmID: UUID, at date: Date = .now) -> String {
        guard let startedAt = runtimes[vmID]?.startedAt else {
            return vm(vmID)?.uptime ?? "—"
        }
        let minutes = max(0, Int(date.timeIntervalSince(startedAt) / 60))
        let days = minutes / (24 * 60)
        let hours = (minutes / 60) % 24
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes % 60)m" }
        return "\(minutes)m"
    }

    func attachment(
        for projectID: UUID
    ) -> (vm: VM, state: ProjectVMState, importProgress: Double, guestPath: String)? {
        guard let attachment = attachments[projectID], let vm = vm(attachment.vmID) else {
            return nil
        }
        return (
            vm,
            attachment.state,
            attachment.importProgress,
            attachment.guestPath
        )
    }

    func attachmentTransferLabel(for projectID: UUID, now: Date = .now) -> String? {
        attachments[projectID]?.lastTransferLabel(now: now)
    }

    func mirrorRows(
        for vmID: UUID
    ) -> [(guest: UInt16, host: UInt16, status: MirrorPortStatus)] {
        _ = portMirrorEpoch
        guard let runtime = runtimes[vmID] else { return [] }
        var rows: [(guest: UInt16, host: UInt16, status: MirrorPortStatus)] = []
        for port in runtime.mirroredPorts {
            rows.append((guest: port, host: hostPort(for: port, runtime: runtime, vmID: vmID), status: .active))
        }
        for port in runtime.conflictPorts where !runtime.mirroredPorts.contains(port) {
            rows.append((guest: port, host: hostPort(for: port, runtime: runtime, vmID: vmID), status: .conflict))
        }
        return rows.sorted { $0.guest < $1.guest }
    }

    func excludedMirrorPorts(for vmID: UUID) -> [UInt16] {
        excludedMirrorPortSet(for: vmID).sorted()
    }

    func hostMirrorPorts(for vmID: UUID) -> [UInt16] {
        hostMirrorPortSet(for: vmID).sorted()
    }

    func sharedHostPorts(for vmID: UUID) -> [UInt16] {
        hostMirrorPortSet(for: vmID).sorted()
    }

    func dismissedHostMirrorPorts(for vmID: UUID) -> [UInt16] {
        dismissedHostMirrorPortSet(for: vmID).sorted()
    }

    func removeHostMirrorPort(vmID: UUID, port: UInt16) {
        var ports = hostMirrorPorts(for: vmID)
        ports.removeAll { $0 == port }
        setHostMirrorPorts(vmID: vmID, ports)
        // Removal is not a dismissal: the next refused connect should prompt
        // again, so the port goes to the re-add pool and its cooldown resets.
        persistRemovedHostMirrorPort(port, for: vmID)
        refusedHostMirrorCooldowns[HostMirrorCooldownKey(vmID: vmID, port: port)] = nil
    }

    func reAddCandidates(for vmID: UUID) -> [UInt16] {
        Self.defaultHostMirrorPorts
            .union(dismissedHostMirrorPortSet(for: vmID))
            .union(removedHostMirrorPortSet(for: vmID))
            .subtracting(hostMirrorPortSet(for: vmID))
            .sorted()
    }

    func acceptHostMirrorSuggestion(vmID: UUID, port: UInt16) {
        guard hostMirrorSuggestions.contains(HostMirrorSuggestion(vmID: vmID, port: port)) else {
            return
        }
        clearHostMirrorSuggestion(vmID: vmID, port: port)
        var ports = hostMirrorPorts(for: vmID)
        if !ports.contains(port) {
            ports.append(port)
        }
        setHostMirrorPorts(vmID: vmID, ports)
    }

    func dismissHostMirrorSuggestion(vmID: UUID, port: UInt16) {
        guard hostMirrorSuggestions.contains(HostMirrorSuggestion(vmID: vmID, port: port)) else {
            return
        }
        clearHostMirrorSuggestion(vmID: vmID, port: port)
        refusedHostMirrorCooldowns[HostMirrorCooldownKey(vmID: vmID, port: port)] = .now
        persistDismissedHostMirrorPort(port, for: vmID)
    }

    func remapConflict(vmID: UUID, guestPort: UInt16, to hostPort: UInt16) async {
        guard hostPort > 0, let runtime = runtimes[vmID] else { return }
        if runtime.mirroredPorts.contains(guestPort) || runtime.conflictPorts.contains(guestPort) {
            await runtime.controller?.stopMirror(guestPort: guestPort)
            runtime.mirroredPorts.remove(guestPort)
            runtime.conflictPorts.remove(guestPort)
        }
        for (guest, host) in persistedRemaps(for: vmID) where runtime.remaps[guest] == nil {
            runtime.remaps[guest] = host
        }
        runtime.remaps[guestPort] = hostPort
        persistRemaps(runtime.remaps, for: vmID)
        guard let controller = runtime.controller else {
            runtime.conflictPorts.insert(guestPort)
            notePortMirrorsChanged()
            return
        }
        do {
            try await controller.startMirror(guestPort: guestPort, hostPort: hostPort)
            runtime.mirroredPorts.insert(guestPort)
            runtime.conflictPorts.remove(guestPort)
        } catch {
            if Self.isAddressInUse(error) {
                runtime.conflictPorts.insert(guestPort)
            }
        }
        notePortMirrorsChanged()
    }

    func setPortExcluded(attachmentID: UUID, port: UInt16, excluded: Bool) async {
        mutateAttachment(attachmentID) { attachment in
            if excluded {
                if !attachment.excludedMirrorPorts.contains(port) {
                    attachment.excludedMirrorPorts.append(port)
                    attachment.excludedMirrorPorts.sort()
                }
            } else {
                attachment.excludedMirrorPorts.removeAll { $0 == port }
            }
        }
        persistAttachmentsOrRecord()
        guard let vmID = attachments[attachmentID]?.vmID else { return }
        await applyExclusion(vmID: vmID, port: port, excluded: excluded)
    }

    func setHostMirrorPorts(attachmentID: UUID, _ ports: [UInt16]) {
        let unique = Array(Set(ports)).sorted()
        let uniqueSet = Set(unique)
        mutateAttachment(attachmentID) {
            $0.hostMirrorPorts = unique
            $0.dismissedHostMirrorPorts.removeAll { uniqueSet.contains($0) }
            $0.removedHostMirrorPorts.removeAll { uniqueSet.contains($0) }
        }
        persistAttachmentsOrRecord()
        if let vmID = attachments[attachmentID]?.vmID {
            clearHostMirrorSuggestions(vmID: vmID, ports: uniqueSet)
        }
        guard let vmID = attachments[attachmentID]?.vmID, vm(vmID)?.state == .ready else {
            return
        }
        Task {
            await self.removeMirrorsForHostPorts(of: vmID)
            await self.ensureHostBridge(of: vmID)
        }
    }

    func setHostMirrorPorts(vmID: UUID, _ ports: [UInt16]) {
        let unique = Array(Set(ports)).sorted()
        let uniqueSet = Set(unique)
        for (projectID, attachment) in attachments where attachment.vmID == vmID {
            mutateAttachment(projectID) {
                $0.hostMirrorPorts = unique
                $0.dismissedHostMirrorPorts.removeAll { uniqueSet.contains($0) }
                $0.removedHostMirrorPorts.removeAll { uniqueSet.contains($0) }
            }
        }
        persistAttachmentsOrRecord()
        clearHostMirrorSuggestions(vmID: vmID, ports: uniqueSet)
        guard vm(vmID)?.state == .ready else { return }
        Task {
            await self.removeMirrorsForHostPorts(of: vmID)
            await self.ensureHostBridge(of: vmID)
        }
    }

    func openInBrowser(hostPort: UInt16) {
        guard let url = URL(string: "http://localhost:\(hostPort)") else { return }
        NSWorkspace.shared.open(url)
    }

    func attachedProjects(of vmID: UUID, in projects: [Project]) -> [Project] {
        projects.filter { attachments[$0.id]?.vmID == vmID }
    }

    @discardableResult
    func createVM(attaching project: Project? = nil) async -> VM? {
        await createConfiguredVM(configuration: nil, attaching: project)
    }

    @discardableResult
    func createVM(
        configuration: NewVMConfiguration,
        attaching project: Project? = nil
    ) async -> VM? {
        await createConfiguredVM(configuration: configuration, attaching: project)
    }

    @discardableResult
    private func createConfiguredVM(
        configuration: NewVMConfiguration?,
        attaching project: Project?
    ) async -> VM? {
        guard !isTerminating else {
            record(error: VMOperationError.terminating)
            return nil
        }
        if let project,
           activeTransfers[project.id] != nil || pendingTransfer?.projectID == project.id
        {
            record(error: VMOperationError.vmBusy)
            return nil
        }

        let id = UUID()
        let trimmedName = configuration?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = trimmedName.isEmpty ? nextVMName() : trimmedName
        let previousSelection = selectedVMID
        let previousAttachment = project.flatMap { attachments[$0.id] }
        let model = makeVM(id: id, name: name, createdAt: .now, state: .starting)
        vms.append(model)
        selectedVMID = id
        runtimes[id] = makeRuntime(for: id, hostname: Self.slug(name, fallback: "vetro"))

        if let project {
            attachments[project.id] = ProjectVMAttachment(
                vmID: id,
                guestPath: availableGuestPath(for: project, on: id),
                state: .settingUp,
                importProgress: 0
            )
        }

        do {
            try save()
            if let configuration {
                try await persistCreationSettings(id, configuration)
            }
            refreshSettings(id)
        } catch {
            vms.removeAll { $0.id == id }
            runtimes.removeValue(forKey: id)
            selectedVMID = previousSelection
            if let project {
                if let previousAttachment {
                    attachments[project.id] = previousAttachment
                } else {
                    attachments.removeValue(forKey: project.id)
                }
            }
            self.record(error: error)
            return nil
        }

        do {
            try await bootAndProvision(id, creating: true)
            if let project {
                await importProject(project)
            }
            return vm(id)
        } catch {
            failVM(id, error: error)
            if let project {
                mutateAttachment(project.id) { $0.state = .error }
            }
            return vm(id)
        }
    }

    func startVM(_ id: UUID) async {
        guard let current = vm(id) else {
            record(error: VMOperationError.vmNotFound)
            return
        }
        guard current.state == .stopped || current.state == .error else { return }

        do {
            if current.state == .error,
               let runtime = runtimes[id],
               let controller = runtime.controller,
               await controller.currentState != .stopped
            {
                _ = try await controller.stop()
                runtime.startedAt = nil
                runtime.forwardedPort = nil
            }
            try await bootAndProvision(id, creating: false)
        } catch {
            failVM(id, error: error)
        }
    }

    func startVM(_ vm: VM) async {
        await startVM(vm.id)
    }

    func stopVM(_ id: UUID) async {
        if isTransferBusy(vmID: id) {
            record(error: VMOperationError.vmBusy)
            return
        }
        guard let runtime = runtimes[id], let controller = runtime.controller else {
            runtimes[id]?.forwardedPort = nil
            if let runtime = runtimes[id] {
                clearLiveForwards(runtime, vmID: id)
            }
            mutateVM(id) {
                $0.state = .stopped
                $0.ip = "—"
                $0.uptime = "—"
            }
            return
        }
        guard !runtime.busy else {
            record(error: VMOperationError.vmBusy)
            return
        }

        runtime.busy = true
        defer { runtime.busy = false }
        do {
            let settingsStore = VMSettingsStore(stateDirectory: runtime.stateDirectory)
            let settings = try? await settingsStore.loadOrCreate()
            let shouldCapture = settings?.goldenCaptureCacheKey != nil
            if shouldCapture {
                try? await controller.scrubForGoldenCapture()
            }
            let clean = try await controller.stop()
            if clean, shouldCapture {
                try? await controller.captureGolden()
                try? await updateSettings(for: id) { $0.goldenCaptureCacheKey = nil }
            }
            runtime.startedAt = nil
            runtime.forwardedPort = nil
            clearLiveForwards(runtime, vmID: id)
            mutateVM(id) {
                $0.state = .stopped
                $0.ip = "—"
                $0.uptime = "—"
                $0.errorMessage = nil
            }
        } catch {
            failVM(id, error: error)
        }
    }

    func stopVM(_ vm: VM) async {
        await stopVM(vm.id)
    }

    func attach(project: Project, to vmID: UUID) async {
        guard activeTransfers[project.id] == nil,
              pendingTransfer?.projectID != project.id
        else {
            record(error: VMOperationError.vmBusy)
            return
        }
        guard let target = vm(vmID) else {
            record(error: VMOperationError.vmNotFound)
            return
        }

        let attachmentState: ProjectVMState = switch target.state {
        case .ready: .importing
        case .stopped, .error, .starting: .starting
        case .downloading, .provisioning: .settingUp
        }
        let previousAttachment = attachments[project.id]
        attachments[project.id] = ProjectVMAttachment(
            vmID: vmID,
            guestPath: availableGuestPath(for: project, on: vmID),
            state: attachmentState,
            importProgress: 0
        )

        do {
            try save()
        } catch {
            if let previousAttachment {
                attachments[project.id] = previousAttachment
            } else {
                attachments.removeValue(forKey: project.id)
            }
            record(error: error)
            return
        }

        switch target.state {
        case .ready:
            break
        case .stopped, .error:
            await startVM(vmID)
        case .downloading, .provisioning, .starting:
            await waitUntilSettled(vmID)
        }

        guard vm(vmID)?.state == .ready else {
            mutateAttachment(project.id) { $0.state = .error }
            return
        }
        await importProject(project)
    }

    func previewExport(_ project: Project) async throws -> TransferPreview {
        try await previewTransfer(project, direction: .exportToMac)
    }

    func previewImport(_ project: Project) async throws -> TransferPreview {
        try await previewTransfer(project, direction: .importFromMac)
    }

    func confirmPendingTransfer() async {
        guard let pendingTransfer,
              pendingTransfer.phase == .awaitingConfirm
        else {
            return
        }

        guard let project = pendingTransferProject,
              let token = activeTransfers[pendingTransfer.projectID]?.token
        else {
            cancelPendingTransfer()
            return
        }

        let direction = pendingTransfer.direction
        let reusedConnection = pendingTransferConnection
        pendingTransferConnection = nil
        pendingTransferProject = nil
        self.pendingTransfer = nil

        defer {
            if activeTransfers[project.id]?.token == token {
                activeTransfers.removeValue(forKey: project.id)
            }
            if let vmID = attachments[project.id]?.vmID {
                runtimes[vmID]?.lastBusy = .now
            }
        }

        do {
            switch direction {
            case .exportToMac:
                try await performExport(
                    project,
                    reusedConnection: reusedConnection
                )
            case .importFromMac:
                try await performImport(
                    project,
                    reusedConnection: reusedConnection,
                    token: token
                )
            }
        } catch {
            switch direction {
            case .exportToMac:
                mutateAttachment(project.id) { $0.state = .ready }
            case .importFromMac:
                mutateAttachment(project.id) { $0.state = .error }
            }
            record(error: error)
        }
    }

    func cancelPendingTransfer() {
        guard let pendingTransfer else {
            pendingTransferConnection = nil
            pendingTransferProject = nil
            return
        }
        activeTransfers.removeValue(forKey: pendingTransfer.projectID)
        pendingTransferConnection = nil
        pendingTransferProject = nil
        self.pendingTransfer = nil
        if let vmID = attachments[pendingTransfer.projectID]?.vmID {
            runtimes[vmID]?.lastBusy = .now
        }
    }

    func importProject(_ project: Project) async {
        guard let initialAttachment = attachments[project.id] else {
            record(error: VMOperationError.attachmentNotFound)
            return
        }
        guard activeTransfers[project.id] == nil,
              pendingTransfer?.projectID != project.id
        else {
            return
        }
        let token = UUID()
        activeTransfers[project.id] = ActiveTransfer(
            token: token,
            vmID: initialAttachment.vmID
        )
        runtimes[initialAttachment.vmID]?.lastBusy = .now
        defer {
            if activeTransfers[project.id]?.token == token {
                activeTransfers.removeValue(forKey: project.id)
            }
            runtimes[initialAttachment.vmID]?.lastBusy = .now
        }

        do {
            try await performImport(
                project,
                reusedConnection: nil,
                token: token
            )
        } catch {
            mutateAttachment(project.id) { $0.state = .error }
            record(error: error)
        }
    }

    func exportProject(_ project: Project) async {
        guard let initialAttachment = attachments[project.id] else {
            record(error: VMOperationError.attachmentNotFound)
            return
        }
        guard activeTransfers[project.id] == nil,
              pendingTransfer?.projectID != project.id
        else {
            return
        }
        let token = UUID()
        activeTransfers[project.id] = ActiveTransfer(
            token: token,
            vmID: initialAttachment.vmID
        )
        runtimes[initialAttachment.vmID]?.lastBusy = .now
        defer {
            if activeTransfers[project.id]?.token == token {
                activeTransfers.removeValue(forKey: project.id)
            }
            runtimes[initialAttachment.vmID]?.lastBusy = .now
        }

        do {
            try await performExport(
                project,
                reusedConnection: nil
            )
        } catch {
            mutateAttachment(project.id) { $0.state = .ready }
            record(error: error)
        }
    }

    private func previewTransfer(
        _ project: Project,
        direction: TransferDirection
    ) async throws -> TransferPreview {
        guard let attachment = attachments[project.id] else {
            let error = VMOperationError.attachmentNotFound
            record(error: error)
            throw error
        }
        // VM-only projects are never attached, so this is unreachable for them;
        // the guard keeps the optional `path` type-safe.
        guard let projectPath = project.path else {
            let error = VMOperationError.attachmentNotFound
            record(error: error)
            throw error
        }

        if let pendingTransfer {
            guard pendingTransfer.projectID == project.id,
                  pendingTransfer.phase == .awaitingConfirm
            else {
                let error = VMOperationError.vmBusy
                record(error: error)
                throw error
            }
            cancelPendingTransfer()
        }
        guard activeTransfers[project.id] == nil,
              pendingTransfer?.projectID != project.id
        else {
            let error = VMOperationError.vmBusy
            record(error: error)
            throw error
        }

        let token = UUID()
        activeTransfers[project.id] = ActiveTransfer(token: token, vmID: attachment.vmID)
        pendingTransfer = PendingTransfer(
            projectID: project.id,
            direction: direction,
            phase: .comparing,
            preview: nil
        )
        pendingTransferConnection = nil
        pendingTransferProject = project
        runtimes[attachment.vmID]?.lastBusy = .now

        do {
            let connection = try await readyConnection(
                for: project,
                startingIfNeeded: true,
                announceStart: false
            )
            let arguments: [String]
            switch direction {
            case .exportToMac:
                arguments = rsyncArguments(
                    runtime: connection.runtime,
                    port: connection.port,
                    source: "\(connection.destination):\(connection.attachment.guestPath)/",
                    destination: Self.withTrailingSlash(projectPath),
                    projectRoot: URL(fileURLWithPath: projectPath),
                    preview: true
                )
            case .importFromMac:
                arguments = rsyncArguments(
                    runtime: connection.runtime,
                    port: connection.port,
                    source: Self.withTrailingSlash(projectPath),
                    destination: "\(connection.destination):\(connection.attachment.guestPath)/",
                    projectRoot: URL(fileURLWithPath: projectPath),
                    preview: true
                )
            }
            let result = try await Self.runRsyncPreview(arguments: arguments)
            guard result.status == 0 else {
                throw VMOperationError.commandFailed(
                    command: direction == .exportToMac ? "rsync export preview" : "rsync import preview",
                    status: result.status,
                    output: result.stderrTail
                )
            }
            let preview = RsyncItemize.parse(result.stdout)
            guard activeTransfers[project.id]?.token == token,
                  pendingTransfer?.projectID == project.id,
                  pendingTransfer?.phase == .comparing
            else {
                throw CancellationError()
            }
            guard !preview.isEmpty else {
                clearPendingTransfer(projectID: project.id, token: token)
                return preview
            }

            pendingTransferConnection = connection
            pendingTransfer = PendingTransfer(
                projectID: project.id,
                direction: direction,
                phase: .awaitingConfirm,
                preview: preview
            )
            runtimes[connection.attachment.vmID]?.lastBusy = .now
            return preview
        } catch {
            if activeTransfers[project.id]?.token == token {
                clearPendingTransfer(projectID: project.id, token: token)
                record(error: error)
            }
            throw error
        }
    }

    private func clearPendingTransfer(projectID: UUID, token: UUID) {
        guard pendingTransfer?.projectID == projectID,
              activeTransfers[projectID]?.token == token
        else {
            return
        }
        activeTransfers.removeValue(forKey: projectID)
        pendingTransferConnection = nil
        pendingTransferProject = nil
        pendingTransfer = nil
        if let vmID = attachments[projectID]?.vmID {
            runtimes[vmID]?.lastBusy = .now
        }
    }

    private func performImport(
        _ project: Project,
        reusedConnection: ReadyConnection?,
        token: UUID
    ) async throws {
        // VM-only projects are never attached, so import is unreachable for them.
        guard let projectPath = project.path else {
            throw VMOperationError.attachmentNotFound
        }
        let connection = try await transferConnection(
            for: project,
            reusing: reusedConnection
        )
        mutateAttachment(project.id) {
            $0.state = .importing
            $0.importProgress = 0
        }

        let mkdir = try await connection.runtime.sshClient.exec(
            host: "127.0.0.1",
            port: connection.port,
            command: "mkdir -p -- \(Self.shellQuote(connection.attachment.guestPath))",
            timeoutSeconds: 30
        )
        guard mkdir.status == 0 else {
            throw VMOperationError.commandFailed(
                command: "mkdir",
                status: mkdir.status,
                output: mkdir.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let arguments = rsyncArguments(
            runtime: connection.runtime,
            port: connection.port,
            source: Self.withTrailingSlash(projectPath),
            destination: "\(connection.destination):\(connection.attachment.guestPath)/",
            projectRoot: URL(fileURLWithPath: projectPath)
        )
        let result = try await Self.runRsync(arguments: arguments) { [weak self] percent in
            Task { @MainActor [weak self] in
                guard let self, self.activeTransfers[project.id]?.token == token else { return }
                self.mutateAttachment(project.id) {
                    $0.state = .importing
                    $0.importProgress = max($0.importProgress, percent)
                }
            }
        }
        guard result.status == 0 else {
            throw VMOperationError.commandFailed(
                command: "rsync import",
                status: result.status,
                output: result.outputTail
            )
        }

        mutateAttachment(project.id) {
            $0.state = .ready
            $0.importProgress = 100
            $0.lastImport = .now
        }
        persistAttachmentsOrRecord()
        refreshDiskUsage(connection.attachment.vmID)
    }

    private func performExport(
        _ project: Project,
        reusedConnection: ReadyConnection?
    ) async throws {
        // VM-only projects are never attached, so export is unreachable for them.
        guard let projectPath = project.path else {
            throw VMOperationError.attachmentNotFound
        }
        let connection = try await transferConnection(
            for: project,
            reusing: reusedConnection
        )
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: projectPath),
            withIntermediateDirectories: true
        )
        let arguments = rsyncArguments(
            runtime: connection.runtime,
            port: connection.port,
            source: "\(connection.destination):\(connection.attachment.guestPath)/",
            destination: Self.withTrailingSlash(projectPath),
            projectRoot: URL(fileURLWithPath: projectPath)
        )
        let result = try await Self.runRsync(arguments: arguments) { _ in }
        guard result.status == 0 else {
            throw VMOperationError.commandFailed(
                command: "rsync export",
                status: result.status,
                output: result.outputTail
            )
        }
        mutateAttachment(project.id) {
            $0.state = .ready
            $0.lastExport = .now
        }
        persistAttachmentsOrRecord()
    }

    func detach(project: Project, deleteGuestCopy: Bool) async {
        guard let attachment = attachments[project.id] else { return }
        guard activeTransfers[project.id] == nil,
              pendingTransfer?.projectID != project.id
        else {
            record(error: VMOperationError.vmBusy)
            return
        }

        var deletionConnection: ReadyConnection?
        if deleteGuestCopy {
            guard Self.isSafeGuestPath(attachment.guestPath) else {
                record(error: VMOperationError.unsafeGuestPath(attachment.guestPath))
                return
            }
            do {
                deletionConnection = try await readyConnection(
                    for: project,
                    startingIfNeeded: true
                )
            } catch {
                attachments[project.id] = attachment
                record(error: error)
                return
            }
        }

        attachments.removeValue(forKey: project.id)
        do {
            try save()
        } catch {
            attachments[project.id] = attachment
            record(error: error)
            return
        }

        if let connection = deletionConnection {
            do {
                let result = try await connection.runtime.sshClient.exec(
                    host: "127.0.0.1",
                    port: connection.port,
                    command: "rm -rf -- \(Self.shellQuote(attachment.guestPath))",
                    timeoutSeconds: 60
                )
                guard result.status == 0 else {
                    throw VMOperationError.commandFailed(
                        command: "remove guest project",
                        status: result.status,
                        output: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
            } catch {
                attachments[project.id] = attachment
                do {
                    try save()
                    record(error: error)
                } catch let persistenceError {
                    // The persisted detach is authoritative if rollback cannot
                    // itself be saved; keep memory aligned with disk.
                    attachments.removeValue(forKey: project.id)
                    record(error: persistenceError)
                }
            }
        }
    }

    func updateAgents(on vmID: UUID) async {
        guard let current = vm(vmID), current.state == .ready,
              let runtime = runtimes[vmID], let controller = runtime.controller
        else {
            record(error: VMOperationError.vmNotReady)
            return
        }
        guard current.updateState != .running else { return }
        guard !runtime.busy else {
            record(error: VMOperationError.vmBusy)
            return
        }
        let updating = Set(current.agents.map(\.name))
        runtime.busy = true
        runtime.updateBaseline = try? await controller.provisioningStatus()
        runtime.sawFreshUpdateStatus = false
        defer {
            runtime.busy = false
            runtime.updateBaseline = nil
            runtime.sawFreshUpdateStatus = false
            runtime.lastBusy = .now
        }

        mutateVM(vmID) {
            $0.updateState = .running
            for index in $0.agents.indices {
                $0.agents[index].status = .updating
            }
        }

        let poller = Task { [weak self] in
            while !Task.isCancelled {
                if let status = try? await controller.provisioningStatus(),
                   !Task.isCancelled,
                   status.operation == .update
                {
                    if runtime.updateBaseline == nil || status != runtime.updateBaseline {
                        runtime.sawFreshUpdateStatus = true
                    }
                    if runtime.sawFreshUpdateStatus,
                       self?.vm(vmID)?.updateState == .running
                    {
                        self?.applyAgentUpdate(status, to: vmID, updating: updating)
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        defer { poller.cancel() }

        do {
            let status = try await controller.updateAgents()
            runtime.sawFreshUpdateStatus = true
            applyAgentUpdate(status, to: vmID, updating: updating)
            await refreshAgentVersions(vmID, runtime: runtime)
            mutateVM(vmID) { vm in
                vm.updateState = vm.agents.contains(where: { $0.status == .failed })
                    ? .partial
                    : .done
            }
        } catch {
            if let status = try? await controller.provisioningStatus(),
               status.operation == .update,
               runtime.sawFreshUpdateStatus || runtime.updateBaseline == nil
                    || status != runtime.updateBaseline
            {
                runtime.sawFreshUpdateStatus = true
                applyAgentUpdate(status, to: vmID, updating: updating)
            }
            mutateVM(vmID) { vm in
                vm.updateState = .partial
                for index in vm.agents.indices where vm.agents[index].status == .updating {
                    vm.agents[index].status = .failed
                }
            }
            record(error: error)
        }

        switch await controller.currentState {
        case .stopped:
            runtime.startedAt = nil
            runtime.forwardedPort = nil
            clearLiveForwards(runtime, vmID: vmID)
            mutateVM(vmID) {
                $0.state = .stopped
                $0.ip = "—"
                $0.uptime = "—"
            }
        case let .error(reason):
            failVM(vmID, message: reason)
        case .starting, .provisioning, .ready, .stopping:
            break
        }
    }

    func updateAgents(on vm: VM) async {
        await updateAgents(on: vm.id)
    }

    func updateAgent(_ agentName: String, on vm: VM) async {
        await updateAgent(agentName, on: vm.id)
    }

    func updateAgent(_ agentName: String, on vmID: UUID) async {
        guard let current = vm(vmID), current.state == .ready,
              let runtime = runtimes[vmID], let controller = runtime.controller
        else {
            record(error: VMOperationError.vmNotReady)
            return
        }
        guard current.agents.contains(where: { $0.name == agentName }) else {
            record(error: VMOperationError.unknownAgent(agentName))
            return
        }
        guard current.updateState != .running, !runtime.busy else {
            record(error: VMOperationError.vmBusy)
            return
        }

        let updating = Set([agentName])
        runtime.busy = true
        runtime.updateBaseline = try? await controller.provisioningStatus()
        runtime.sawFreshUpdateStatus = false
        defer {
            runtime.busy = false
            runtime.updateBaseline = nil
            runtime.sawFreshUpdateStatus = false
            runtime.lastBusy = .now
        }

        mutateVM(vmID) {
            $0.updateState = .running
            if let index = $0.agents.firstIndex(where: { $0.name == agentName }) {
                $0.agents[index].status = .updating
            }
        }

        let poller = Task { [weak self] in
            while !Task.isCancelled {
                if let status = try? await controller.provisioningStatus(),
                   !Task.isCancelled,
                   status.operation == .update
                {
                    if runtime.updateBaseline == nil || status != runtime.updateBaseline {
                        runtime.sawFreshUpdateStatus = true
                    }
                    if runtime.sawFreshUpdateStatus,
                       self?.vm(vmID)?.updateState == .running
                    {
                        self?.applyAgentUpdate(status, to: vmID, updating: updating)
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        defer { poller.cancel() }

        do {
            let status = try await controller.updateAgent(named: agentName)
            runtime.sawFreshUpdateStatus = true
            applyAgentUpdate(status, to: vmID, updating: updating)
            await refreshAgentVersions(vmID, runtime: runtime)
            mutateVM(vmID) { vm in
                vm.updateState = vm.agents.contains(where: { $0.status == .failed })
                    ? .partial
                    : .done
            }
        } catch {
            if let status = try? await controller.provisioningStatus(),
               status.operation == .update,
               runtime.sawFreshUpdateStatus || runtime.updateBaseline == nil
                    || status != runtime.updateBaseline
            {
                runtime.sawFreshUpdateStatus = true
                applyAgentUpdate(status, to: vmID, updating: updating)
            }
            mutateVM(vmID) { vm in
                vm.updateState = .partial
                if let index = vm.agents.firstIndex(where: { $0.name == agentName }),
                   vm.agents[index].status == .updating
                {
                    vm.agents[index].status = .failed
                }
            }
            record(error: error)
        }

        switch await controller.currentState {
        case .stopped:
            runtime.startedAt = nil
            runtime.forwardedPort = nil
            clearLiveForwards(runtime, vmID: vmID)
            mutateVM(vmID) {
                $0.state = .stopped
                $0.ip = "—"
                $0.uptime = "—"
            }
        case let .error(reason):
            failVM(vmID, message: reason)
        case .starting, .provisioning, .ready, .stopping:
            break
        }
    }

    func updateResources(
        on vm: VM,
        cpus: Int? = nil,
        memoryMB: Int? = nil,
        diskSizeGB: Int? = nil
    ) async {
        await updateResources(on: vm.id, cpus: cpus, memoryMB: memoryMB, diskSizeGB: diskSizeGB)
    }

    func updateResources(
        on vmID: UUID,
        cpus: Int? = nil,
        memoryMB: Int? = nil,
        diskSizeGB: Int? = nil
    ) async {
        guard let current = vm(vmID) else {
            record(error: VMOperationError.vmNotFound)
            return
        }
        guard current.state == .stopped else {
            record(error: VMOperationError.vmNotStopped)
            return
        }
        guard cpus != nil || memoryMB != nil || diskSizeGB != nil else { return }

        do {
            let settingsStore = VMSettingsStore(stateDirectory: stateDirectory(for: vmID))
            var settings = try await settingsStore.loadOrCreate()
            if let cpus, cpus > 0 {
                settings.cpus = cpus
            }
            if let memoryMB, memoryMB > 0 {
                settings.memoryMB = memoryMB
            }
            var grewExistingDisk = false
            if let diskSizeGB, diskSizeGB > 0 {
                guard diskSizeGB >= settings.diskSizeGB else {
                    record(error: VMOperationError.cannotShrinkDisk)
                    return
                }
                if diskSizeGB > settings.diskSizeGB {
                    let diskURL = stateDirectory(for: vmID).diskURL
                    if fileManager.fileExists(atPath: diskURL.path) {
                        try growDiskImage(at: diskURL, toGigabytes: diskSizeGB)
                        grewExistingDisk = true
                    }
                    settings.diskSizeGB = diskSizeGB
                }
            }
            try await settingsStore.save(settings)
            if grewExistingDisk {
                mutateVM(vmID) { $0.pendingFilesystemGrow = true }
                try save()
            }
            refreshSettings(vmID)
        } catch {
            record(error: error)
        }
    }

    func setIdleStop(minutes: Int?, on vm: VM) async {
        await setIdleStop(minutes: minutes, on: vm.id)
    }

    func setIdleStop(minutes: Int?, on vmID: UUID) async {
        guard vm(vmID) != nil else {
            record(error: VMOperationError.vmNotFound)
            return
        }
        let normalized = minutes.flatMap { $0 > 0 ? $0 : nil }
        do {
            try await updateSettings(for: vmID) { $0.idleStopMinutes = normalized }
            mutateVM(vmID) { $0.idleStopMinutes = normalized }
            runtimes[vmID]?.lastBusy = .now
        } catch {
            record(error: error)
        }
    }

    func setNetworkEnabled(_ on: Bool, on vm: VM) async {
        await setNetworkEnabled(on, on: vm.id)
    }

    func setNetworkEnabled(_ on: Bool, on vmID: UUID) async {
        guard let current = vm(vmID) else {
            record(error: VMOperationError.vmNotFound)
            return
        }
        do {
            try await updateSettings(for: vmID) { $0.networkEnabled = on }
            let running: Bool = switch current.state {
            case .ready, .starting, .provisioning, .downloading: true
            case .stopped, .error: false
            }
            let booted = runtimes[vmID]?.bootedNetworkEnabled
            mutateVM(vmID) {
                $0.networkEnabled = on
                $0.networkChangePending = running && booted != nil && booted != on
            }
        } catch {
            record(error: error)
        }
    }

    func customScriptLog(for vm: VM) async -> String {
        await customScriptLog(for: vm.id)
    }

    func customScriptLog(for vmID: UUID) async -> String {
        guard let runtime = runtimes[vmID], let controller = runtime.controller else {
            return ""
        }
        do {
            return try await controller.customScriptLog(maxBytes: 65_536)
        } catch {
            record(error: error)
            return ""
        }
    }

    func deleteVM(_ id: UUID) async {
        guard vm(id) != nil else { return }
        if isTransferBusy(vmID: id) {
            record(error: VMOperationError.vmBusy)
            return
        }
        if let runtime = runtimes[id], runtime.busy {
            record(error: VMOperationError.vmBusy)
            return
        }

        if vm(id)?.state != .stopped {
            await stopVM(id)
            guard vm(id)?.state == .stopped else { return }
        }

        let stateURL = stateDirectory(for: id).rootURL
        let tombstoneURL = stateURL.deletingLastPathComponent().appendingPathComponent(
            ".deleting-\(id.uuidString)-\(UUID().uuidString)",
            isDirectory: true
        )
        var movedState = false
        do {
            movedState = try await Task.detached(priority: .utility) {
                let fileManager = FileManager()
                guard fileManager.fileExists(atPath: stateURL.path) else { return false }
                try fileManager.moveItem(at: stateURL, to: tombstoneURL)
                return true
            }.value
        } catch {
            record(error: error)
            return
        }

        let previousVMs = vms
        let previousAttachments = attachments
        let previousSelection = selectedVMID
        vms.removeAll { $0.id == id }
        attachments = attachments.filter { $0.value.vmID != id }
        if selectedVMID == id { selectedVMID = vms.first?.id }
        do {
            try save()
        } catch {
            vms = previousVMs
            attachments = previousAttachments
            selectedVMID = previousSelection
            if movedState {
                try? await Task.detached(priority: .utility) {
                    try FileManager().moveItem(at: tombstoneURL, to: stateURL)
                }.value
            }
            record(error: error)
            return
        }

        runtimes[id]?.monitorTask?.cancel()
        runtimes.removeValue(forKey: id)
        if movedState {
            do {
                try await Task.detached(priority: .utility) {
                    try FileManager().removeItem(at: tombstoneURL)
                }.value
            } catch {
                record(error: error)
            }
        }
    }

    func deleteVM(_ vm: VM) async {
        await deleteVM(vm.id)
    }

    func renameVM(_ id: UUID, to proposedName: String) async {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, vm(id) != nil else { return }
        let previousName = vm(id)?.name
        mutateVM(id) { $0.name = name }
        do {
            try save()
        } catch {
            if let previousName { mutateVM(id) { $0.name = previousName } }
            record(error: error)
        }
    }

    func renameVM(_ vm: VM, to name: String) async {
        await renameVM(vm.id, to: name)
    }

    /// Stops every created controller before allowing the app-quit handshake to finish.
    ///
    /// Startup tasks are canceled as a group before waiting so a VM queued behind
    /// another start cannot prevent the active start from being unwound.
    func stopAll() async -> Bool {
        isTerminating = true
        idleWatchTask?.cancel()

        let controllers = runtimes.compactMap { id, runtime in
            runtime.controller.map { (id, runtime, $0) }
        }
        for runtime in runtimes.values {
            runtime.startTask?.cancel()
        }

        var stopFailures: [UUID: String] = [:]
        for (id, _, controller) in controllers {
            do {
                _ = try await controller.stop()
            } catch {
                stopFailures[id] = Self.describe(error)
            }
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while runtimes.values.contains(where: \.busy), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }

        // A start can be between controller preparation and VZ runtime creation
        // when the first stop runs. Stop once more after startup has unwound.
        for (id, _, controller) in controllers {
            do {
                _ = try await controller.stop()
                stopFailures.removeValue(forKey: id)
            } catch {
                stopFailures[id] = Self.describe(error)
            }
        }

        var allStopped = true
        for model in vms {
            guard let runtime = runtimes[model.id], let controller = runtime.controller else {
                runtimes[model.id]?.forwardedPort = nil
                if let runtime = runtimes[model.id] {
                    clearLiveForwards(runtime, vmID: model.id)
                }
                mutateVM(model.id) {
                    $0.state = .stopped
                    $0.ip = "—"
                    $0.uptime = "—"
                }
                continue
            }
            let controllerState = await controller.currentState
            guard controllerState == .stopped else {
                allStopped = false
                let message = stopFailures[model.id]
                    ?? "The virtual machine did not stop before the shutdown deadline."
                failVM(model.id, message: message)
                continue
            }
            runtime.startedAt = nil
            runtime.forwardedPort = nil
            clearLiveForwards(runtime, vmID: model.id)
            mutateVM(model.id) {
                $0.state = .stopped
                $0.ip = "—"
                $0.uptime = "—"
            }
        }

        if !allStopped {
            isTerminating = false
            startIdleWatch()
        }
        return allStopped
    }

    /// Resolves a project ID to its model; wired by the app at launch.
    @ObservationIgnored var projectResolver: ((UUID) -> Project?)?

    /// Guest paths occupied by VM-only projects on a given VM; wired at launch.
    /// Keeps `availableGuestPath` from colliding a later attach with them.
    @ObservationIgnored var vmOnlyGuestPathsProvider: ((UUID) -> [String])?

    /// Presents a refused or failed operation to the user (e.g. as a toast).
    @ObservationIgnored var errorPresenter: ((String) -> Void)?

    /// Open terminal-session count for a project; wired by the app at launch.
    @ObservationIgnored var openSessionsProvider: ((_ projectID: UUID) -> Int)?

    /// Open project-free environment-session count for a VM; wired by the app at launch.
    @ObservationIgnored var openVMSessionsProvider: ((_ vmID: UUID) -> Int)?

    /// Currently selected session's project; wired by the app at launch.
    @ObservationIgnored var selectedProjectProvider: (() -> UUID?)?

    /// Most recently activated project among the supplied IDs; wired by the app at launch.
    @ObservationIgnored var recentSessionProjectProvider: ((Set<UUID>) -> UUID?)?

    /// Starts a project terminal session with an optional remote command.
    @ObservationIgnored var sessionLaunchProvider:
        (@MainActor (Project, String, String) async -> UUID?)?

    @ObservationIgnored var hookEventHandler: (@Sendable (UUID?, String, String) -> Void)? {
        didSet {
            for (vmID, runtime) in runtimes {
                guard let controller = runtime.controller else { continue }
                Task { await self.configureController(controller, vmID: vmID) }
            }
        }
    }

    @ObservationIgnored private var idleWatchTask: Task<Void, Never>?

    func transferAuth(vmID: UUID) async {
        await ensureAgentAuth(of: vmID, force: true)
    }

    func handleSessionEnd(_ sessionID: UUID) {
        guard let mirror = liveLoginMirrors.removeValue(forKey: sessionID),
              let controller = runtimes[mirror.vmID]?.controller
        else {
            return
        }
        Task { await controller.stopMirror(guestPort: mirror.guestPort) }
    }

    func loginCodex(vmID: UUID) async {
        guard let model = vm(vmID), model.state == .ready,
              let runtime = runtimes[vmID],
              let controller = runtime.controller
        else {
            record(error: VMOperationError.vmNotReady)
            return
        }

        do {
            try await controller.startMirror(guestPort: 1455)
        } catch {
            record(error: error)
            return
        }

        guard let project = attachedProject(of: vmID) else {
            await controller.stopMirror(guestPort: 1455)
            record(error: VMOperationError.noAttachedProject)
            return
        }
        guard let launch = sessionLaunchProvider else {
            await controller.stopMirror(guestPort: 1455)
            record(error: VMOperationError.terminalSessionFailed)
            return
        }
        guard let sessionID = await launch(project, "codex login", "Codex login") else {
            await controller.stopMirror(guestPort: 1455)
            record(error: VMOperationError.terminalSessionFailed)
            return
        }
        liveLoginMirrors[sessionID] = (vmID, 1455)
    }

    func loginGrok(vmID: UUID) async {
        guard let model = vm(vmID), model.state == .ready else {
            record(error: VMOperationError.vmNotReady)
            return
        }
        guard let project = attachedProject(of: vmID) else {
            record(error: VMOperationError.noAttachedProject)
            return
        }
        guard let launch = sessionLaunchProvider else {
            record(error: VMOperationError.terminalSessionFailed)
            return
        }
        guard await launch(project, "grok login --device-auth", "Grok login") != nil else {
            record(error: VMOperationError.terminalSessionFailed)
            return
        }
    }

    private func attachedProject(of vmID: UUID) -> Project? {
        attachments
            .filter { $0.value.vmID == vmID }
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .compactMap { projectResolver?($0.key) }
            .first
    }

    /// Re-imports any attachment of this VM whose guest copy is missing
    /// (e.g. an import that never completed before a crash or failed start).
    private func healAttachments(of vmID: UUID) {
        guard let model = vm(vmID), model.state == .ready else { return }
        let checkRuntime = runtime(
            for: model.id,
            hostname: Self.slug(model.name, fallback: "vetro")
        )
        guard let forwardedPort = checkRuntime.forwardedPort else { return }
        for (projectID, attachment) in attachments where attachment.vmID == vmID {
            guard let project = projectResolver?(projectID) else { continue }
            Task {
                if let check = try? await checkRuntime.sshClient.exec(
                    host: "127.0.0.1",
                    port: forwardedPort,
                    command: "test -d \(Self.shellQuote(attachment.guestPath))",
                    timeoutSeconds: 8
                ), check.status != 0 {
                    await self.importProject(project)
                }
            }
        }
    }

    private func ensurePortBridge(of vmID: UUID) async {
        guard vm(vmID)?.state == .ready,
              let runtime = runtimes[vmID],
              let sshPort = runtime.forwardedPort,
              let script = try? CloudInitSeed.vsockPortBridgeScript()
        else {
            return
        }
        let hash = SHA256.hash(data: Data(script.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let scriptB64 = Data(script.utf8).base64EncodedString()
        let unitB64 = Data(Self.portBridgeUnit.utf8).base64EncodedString()
        let command = """
        set -e
        want=\(hash)
        have=""
        if [ -r /usr/local/lib/vetro/vsock-port-bridge.py ]; then
          have=$(sha256sum /usr/local/lib/vetro/vsock-port-bridge.py | awk '{print $1}')
        fi
        unit_ok=0
        if [ -r /etc/systemd/system/vetro-vsock-port.service ] \
           && grep -Fq 'ExecStart=/usr/bin/python3 /usr/local/lib/vetro/vsock-port-bridge.py' \
                /etc/systemd/system/vetro-vsock-port.service; then
          unit_ok=1
        fi
        active=0
        if systemctl is-active --quiet vetro-vsock-port.service; then
          active=1
        fi
        if [ "$have" = "$want" ] && [ "$unit_ok" = 1 ] && [ "$active" = 1 ]; then
          exit 0
        fi
        sudo install -d -m 0755 /usr/local/lib/vetro
        if [ "$have" != "$want" ]; then
          printf '%s' '\(scriptB64)' | base64 -d | sudo tee /usr/local/lib/vetro/vsock-port-bridge.py >/dev/null
          sudo chmod 0755 /usr/local/lib/vetro/vsock-port-bridge.py
          sudo chown root:root /usr/local/lib/vetro/vsock-port-bridge.py
        fi
        if [ "$unit_ok" != 1 ]; then
          printf '%s' '\(unitB64)' | base64 -d | sudo tee /etc/systemd/system/vetro-vsock-port.service >/dev/null
          sudo chmod 0644 /etc/systemd/system/vetro-vsock-port.service
          sudo chown root:root /etc/systemd/system/vetro-vsock-port.service
        fi
        sudo systemctl daemon-reload
        sudo systemctl enable --now vetro-vsock-port.service
        sudo systemctl restart vetro-vsock-port.service
        """
        _ = try? await runtime.sshClient.exec(
            host: "127.0.0.1",
            port: sshPort,
            command: command,
            timeoutSeconds: 30
        )
    }

    private func ensurePortWatch(of vmID: UUID) async {
        guard vm(vmID)?.state == .ready,
              let runtime = runtimes[vmID],
              let sshPort = runtime.forwardedPort,
              let script = try? CloudInitSeed.portwatchScript()
        else {
            return
        }
        let hash = SHA256.hash(data: Data(script.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let scriptB64 = Data(script.utf8).base64EncodedString()
        let unitB64 = Data(Self.portwatchUnit.utf8).base64EncodedString()
        let command = """
        set -e
        # VMs provisioned before nftables joined the base packages need it for
        # refused-connect detection; the daemon retries its rule until this lands.
        if ! command -v nft >/dev/null 2>&1; then
          sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nftables >/dev/null 2>&1 \
            || { sudo apt-get update -qq >/dev/null 2>&1 \
                 && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nftables >/dev/null 2>&1; } \
            || true
        fi
        want=\(hash)
        have=""
        if [ -r /usr/local/lib/vetro/vetro-portwatch.py ]; then
          have=$(sha256sum /usr/local/lib/vetro/vetro-portwatch.py | awk '{print $1}')
        fi
        unit_ok=0
        if [ -r /etc/systemd/system/vetro-portwatch.service ] \
           && grep -Fq 'ExecStart=/usr/bin/python3 /usr/local/lib/vetro/vetro-portwatch.py' \
                /etc/systemd/system/vetro-portwatch.service; then
          unit_ok=1
        fi
        active=0
        if systemctl is-active --quiet vetro-portwatch.service; then
          active=1
        fi
        if [ "$have" = "$want" ] && [ "$unit_ok" = 1 ] && [ "$active" = 1 ]; then
          exit 0
        fi
        sudo install -d -m 0755 /usr/local/lib/vetro
        if [ "$have" != "$want" ]; then
          printf '%s' '\(scriptB64)' | base64 -d | sudo tee /usr/local/lib/vetro/vetro-portwatch.py >/dev/null
          sudo chmod 0755 /usr/local/lib/vetro/vetro-portwatch.py
          sudo chown root:root /usr/local/lib/vetro/vetro-portwatch.py
        fi
        if [ "$unit_ok" != 1 ]; then
          printf '%s' '\(unitB64)' | base64 -d | sudo tee /etc/systemd/system/vetro-portwatch.service >/dev/null
          sudo chmod 0644 /etc/systemd/system/vetro-portwatch.service
          sudo chown root:root /etc/systemd/system/vetro-portwatch.service
        fi
        sudo systemctl daemon-reload
        sudo systemctl enable --now vetro-portwatch.service
        sudo systemctl restart vetro-portwatch.service
        """
        _ = try? await runtime.sshClient.exec(
            host: "127.0.0.1",
            port: sshPort,
            command: command,
            timeoutSeconds: 30
        )
    }

    private func removeMirrorsForHostPorts(of vmID: UUID) async {
        guard let runtime = runtimes[vmID] else { return }
        let hostPorts = hostMirrorPortSet(for: vmID)
        let tracked = runtime.mirroredPorts.union(runtime.conflictPorts)
        let dropped = tracked.intersection(hostPorts)
        guard !dropped.isEmpty else { return }
        for port in dropped {
            await runtime.controller?.stopMirror(guestPort: port)
            runtime.mirroredPorts.remove(port)
            runtime.conflictPorts.remove(port)
        }
        notePortMirrorsChanged()
    }

    private func ensureHostBridge(of vmID: UUID) async {
        guard vm(vmID)?.state == .ready,
              let runtime = runtimes[vmID],
              let sshPort = runtime.forwardedPort,
              let script = try? CloudInitSeed.vsockHostBridgeScript()
        else {
            return
        }
        let ports = hostMirrorPortSet(for: vmID)
        if let controller = runtime.controller {
            await controller.setHostMirrorAllowlist(ports)
        }
        let portsText = ports.sorted().map(String.init).joined(separator: "\n")
        let portsBody = portsText.isEmpty ? "" : portsText + "\n"
        let hash = SHA256.hash(data: Data(script.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let portsHash = SHA256.hash(data: Data(portsBody.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let scriptB64 = Data(script.utf8).base64EncodedString()
        let unitB64 = Data(Self.hostBridgeUnit.utf8).base64EncodedString()
        let portsB64 = Data(portsBody.utf8).base64EncodedString()
        let command = """
        set -e
        want=\(hash)
        have=""
        if [ -r /usr/local/lib/vetro/vsock-host-bridge.py ]; then
          have=$(sha256sum /usr/local/lib/vetro/vsock-host-bridge.py | awk '{print $1}')
        fi
        unit_ok=0
        if [ -r /etc/systemd/system/vetro-vsock-host.service ] \
           && grep -Fq 'ExecStart=/usr/bin/python3 /usr/local/lib/vetro/vsock-host-bridge.py' \
                /etc/systemd/system/vetro-vsock-host.service; then
          unit_ok=1
        fi
        active=0
        if systemctl is-active --quiet vetro-vsock-host.service; then
          active=1
        fi
        ports_want=\(portsHash)
        ports_have=""
        if [ -r /etc/vetro/host-mirror.ports ]; then
          ports_have=$(sha256sum /etc/vetro/host-mirror.ports | awk '{print $1}')
        fi
        if [ "$have" = "$want" ] && [ "$unit_ok" = 1 ] && [ "$active" = 1 ] \
           && [ "$ports_have" = "$ports_want" ]; then
          exit 0
        fi
        sudo install -d -m 0755 /usr/local/lib/vetro
        sudo install -d -m 0755 /etc/vetro
        if [ "$have" != "$want" ]; then
          printf '%s' '\(scriptB64)' | base64 -d | sudo tee /usr/local/lib/vetro/vsock-host-bridge.py >/dev/null
          sudo chmod 0755 /usr/local/lib/vetro/vsock-host-bridge.py
          sudo chown root:root /usr/local/lib/vetro/vsock-host-bridge.py
        fi
        if [ "$unit_ok" != 1 ]; then
          printf '%s' '\(unitB64)' | base64 -d | sudo tee /etc/systemd/system/vetro-vsock-host.service >/dev/null
          sudo chmod 0644 /etc/systemd/system/vetro-vsock-host.service
          sudo chown root:root /etc/systemd/system/vetro-vsock-host.service
        fi
        if [ "$ports_have" != "$ports_want" ]; then
          printf '%s' '\(portsB64)' | base64 -d | sudo tee /etc/vetro/host-mirror.ports >/dev/null
          sudo chmod 0644 /etc/vetro/host-mirror.ports
        fi
        sudo systemctl daemon-reload
        sudo systemctl enable --now vetro-vsock-host.service
        sudo systemctl restart vetro-vsock-host.service
        """
        _ = try? await runtime.sshClient.exec(
            host: "127.0.0.1",
            port: sshPort,
            command: command,
            timeoutSeconds: 30
        )
    }

    private func ensureGuestHooks(of vmID: UUID) async {
        guard vm(vmID)?.state == .ready,
              let runtime = runtimes[vmID],
              let sshPort = runtime.forwardedPort,
              let script = try? CloudInitSeed.hookPostScript()
        else {
            return
        }
        let hash = SHA256.hash(data: Data(script.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let scriptB64 = Data(script.utf8).base64EncodedString()
        let command = """
        set -e
        want=\(hash)
        have=""
        if [ -r /usr/local/lib/vetro/vetro-hook-post.py ]; then
          have=$(sha256sum /usr/local/lib/vetro/vetro-hook-post.py | awk '{print $1}')
        fi
        sudo install -d -m 0755 /usr/local/lib/vetro
        if [ "$have" != "$want" ]; then
          printf '%s' '\(scriptB64)' | base64 -d | sudo tee /usr/local/lib/vetro/vetro-hook-post.py >/dev/null
          sudo chmod 0755 /usr/local/lib/vetro/vetro-hook-post.py
          sudo chown root:root /usr/local/lib/vetro/vetro-hook-post.py
        fi
        for ev in prompt-submit stop notification session-end; do
          sudo ln -sfn vetro-hook-post.py /usr/local/lib/vetro/vetro-hook-$ev
        done
        sudo -H -u vetro /usr/bin/python3 /usr/local/lib/vetro/vetro-hook-post.py --install
        """
        _ = try? await runtime.sshClient.exec(
            host: "127.0.0.1",
            port: sshPort,
            command: command,
            timeoutSeconds: 30
        )
    }

    private func ensureCredentials(of vmID: UUID, force: Bool = false) async {
        guard vm(vmID)?.state == .ready,
              let runtime = runtimes[vmID],
              let sshPort = runtime.forwardedPort,
              var credentials = try? await credentialsStore.guestCredentials()
        else {
            return
        }

        // When the VM opts into Mac auth transfer, fill any git fields the
        // Keychain lacks with values detected fresh from this Mac. Claude's
        // OAuth token is handled separately by `ensureAgentAuth`. Detection
        // failures leave a field nil, and the detected values feed the content
        // version below so a change re-pushes.
        let settingsStore = VMSettingsStore(stateDirectory: stateDirectory(for: vmID))
        if (try? await settingsStore.loadOrCreate())?.transferAuthFromMac == true {
            let detected = await Task.detached(priority: .userInitiated) {
                HostGitAuthReader.detect()
            }.value
            if credentials.githubToken == nil {
                credentials.githubToken = detected.githubToken
            }
            if credentials.gitUserName == nil {
                credentials.gitUserName = detected.gitUserName
            }
            if credentials.gitUserEmail == nil {
                credentials.gitUserEmail = detected.gitUserEmail
            }
        }

        guard credentials.claudeOAuthToken != nil
                || credentials.githubToken != nil
                || credentials.gitUserName != nil
                || credentials.gitUserEmail != nil
        else {
            return
        }

        let acceptEnv = "AcceptEnv CLAUDE_CODE_OAUTH_TOKEN GH_TOKEN GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL VETRO_CRED_VERSION\n"
        let acceptEnvHash = SHA256.hash(data: Data(acceptEnv.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let acceptEnvB64 = Data(acceptEnv.utf8).base64EncodedString()
        let acceptEnvCommand = """
        set -e
        want=\(acceptEnvHash)
        have=""
        if [ -r /etc/ssh/sshd_config.d/99-vetro-env.conf ]; then
          have=$(sha256sum /etc/ssh/sshd_config.d/99-vetro-env.conf | awk '{print $1}')
        fi
        if [ "$have" = "$want" ]; then
          exit 0
        fi
        printf '%s' '\(acceptEnvB64)' | base64 -d | sudo tee /etc/ssh/sshd_config.d/99-vetro-env.conf >/dev/null
        sudo chmod 0644 /etc/ssh/sshd_config.d/99-vetro-env.conf
        sudo chown root:root /etc/ssh/sshd_config.d/99-vetro-env.conf
        if ! sudo systemctl reload ssh; then
          sudo systemctl reload sshd
        fi
        """
        _ = try? await runtime.sshClient.exec(
            host: "127.0.0.1",
            port: sshPort,
            command: acceptEnvCommand,
            timeoutSeconds: 30
        )

        let version = contentVersion(credentials)
        if !force,
           let result = try? await runtime.sshClient.exec(
               host: "127.0.0.1",
               port: sshPort,
               command: "cat ~/.config/vetro/credentials-version 2>/dev/null",
               timeoutSeconds: 8
           ),
           result.status == 0,
           result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == version
        {
            return
        }

        let guestPaths = attachments
            .filter { $0.value.vmID == vmID }
            .map(\.value.guestPath)
            .sorted()
        let guestPathArguments = guestPaths.map(Self.shellQuote).joined(separator: " ")
        var environment: [String: String] = ["VETRO_CRED_VERSION": version]
        if let value = credentials.claudeOAuthToken, !value.isEmpty {
            environment["CLAUDE_CODE_OAUTH_TOKEN"] = value
        }
        if let value = credentials.githubToken, !value.isEmpty {
            environment["GH_TOKEN"] = value
        }
        if let value = credentials.gitUserName, !value.isEmpty {
            environment["GIT_AUTHOR_NAME"] = value
        }
        if let value = credentials.gitUserEmail, !value.isEmpty {
            environment["GIT_AUTHOR_EMAIL"] = value
        }

        let command = """
        set -euo pipefail
        mkdir -p -m 0700 "$HOME/.config/vetro"
        python3 - <<'ENVPY'
        import os
        from pathlib import Path

        def quote(value):
            return "'" + value.replace("'", "'\\\\''") + "'"

        path = Path.home() / ".config" / "vetro" / "env"
        lines = []
        for name in (
            "CLAUDE_CODE_OAUTH_TOKEN",
            "GH_TOKEN",
            "GIT_AUTHOR_NAME",
            "GIT_AUTHOR_EMAIL",
        ):
            value = os.environ.get(name)
            if value:
                lines.append(f"export {name}={quote(value)}")
        path.write_text(("\\n".join(lines) + "\\n") if lines else "", encoding="utf-8")
        os.chmod(path, 0o600)
        ENVPY
        profile="$HOME/.profile"
        profile_line='[ -r "$HOME/.config/vetro/env" ] && . "$HOME/.config/vetro/env"'
        if [ ! -e "$profile" ]; then
          : >"$profile"
        fi
        chmod 0644 "$profile"
        if ! grep -Fqx "$profile_line" "$profile" 2>/dev/null; then
          printf '%s\\n' "$profile_line" >>"$profile"
        fi
        if [ -n "${GH_TOKEN:-}" ]; then
          printf '%s\\n' "https://x-access-token:${GH_TOKEN}@github.com" >"$HOME/.git-credentials"
          chmod 0600 "$HOME/.git-credentials"
          git config --global credential.helper store
          if [ -n "${GIT_AUTHOR_NAME:-}" ]; then
            git config --global user.name "$GIT_AUTHOR_NAME"
          fi
          if [ -n "${GIT_AUTHOR_EMAIL:-}" ]; then
            git config --global user.email "$GIT_AUTHOR_EMAIL"
          fi
        fi
        python3 - \(guestPathArguments) <<'PYTHON'
        import json
        import os
        import sys

        path = os.path.expanduser("~/.claude.json")
        try:
            with open(path, "r", encoding="utf-8") as handle:
                existing = handle.read()
        except OSError:
            existing = ""
        try:
            parsed = json.loads(existing) if existing.strip() else {}
        except (TypeError, ValueError):
            parsed = {}
        root = parsed if isinstance(parsed, dict) else {}
        root["hasCompletedOnboarding"] = True
        guest_paths = sys.argv[1:]
        if guest_paths:
            projects = root.get("projects")
            if not isinstance(projects, dict):
                projects = {}
            for guest_path in guest_paths:
                project = projects.get(guest_path)
                if not isinstance(project, dict):
                    project = {}
                project["hasTrustDialogAccepted"] = True
                projects[guest_path] = project
            root["projects"] = projects
        encoded = json.dumps(root, indent=2, sort_keys=True, separators=(",", ": "))
        encoded = encoded.replace("\\/", "/") + "\\n"
        changed = True
        try:
            with open(path, "r", encoding="utf-8") as handle:
                changed = handle.read() != encoded
        except OSError:
            pass
        if changed:
            directory = os.path.dirname(path)
            if directory:
                os.makedirs(directory, exist_ok=True)
            temporary = path + ".tmp"
            with open(temporary, "w", encoding="utf-8") as handle:
                handle.write(encoded)
            os.chmod(temporary, 0o600)
            os.replace(temporary, path)
        os.chmod(path, 0o600)
        PYTHON
        printf '%s\\n' "$VETRO_CRED_VERSION" >"$HOME/.config/vetro/credentials-version"
        chmod 0644 "$HOME/.config/vetro/credentials-version"
        """
        _ = try? await runtime.sshClient.exec(
            host: "127.0.0.1",
            port: sshPort,
            command: command,
            environment: environment,
            timeoutSeconds: 30
        )
    }

    private func ensureAgentAuth(of vmID: UUID, force: Bool = false) async {
        guard vm(vmID)?.state == .ready,
              let runtime = runtimes[vmID],
              let sshPort = runtime.forwardedPort
        else {
            return
        }
        let settingsStore = VMSettingsStore(stateDirectory: stateDirectory(for: vmID))
        guard let settings = try? await settingsStore.loadOrCreate(),
              settings.transferAuthFromMac
        else {
            return
        }
        let bundle = HostAgentAuthReader.bundle(
            forAgents: Self.normalizedAgents(settings.installAgents)
        )
        guard !bundle.isEmpty else { return }

        let acceptEnv = "AcceptEnv VETRO_AUTH_CLAUDE VETRO_AUTH_CODEX VETRO_AUTH_GROK VETRO_AUTH_GROK_ID VETRO_AUTH_VERSION\n"
        let acceptEnvHash = SHA256.hash(data: Data(acceptEnv.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let acceptEnvB64 = Data(acceptEnv.utf8).base64EncodedString()
        let acceptEnvCommand = """
        set -e
        want=\(acceptEnvHash)
        have=""
        if [ -r /etc/ssh/sshd_config.d/98-vetro-auth.conf ]; then
          have=$(sha256sum /etc/ssh/sshd_config.d/98-vetro-auth.conf | awk '{print $1}')
        fi
        if [ "$have" = "$want" ]; then
          exit 0
        fi
        printf '%s' '\(acceptEnvB64)' | base64 -d | sudo tee /etc/ssh/sshd_config.d/98-vetro-auth.conf >/dev/null
        sudo chmod 0644 /etc/ssh/sshd_config.d/98-vetro-auth.conf
        sudo chown root:root /etc/ssh/sshd_config.d/98-vetro-auth.conf
        if ! sudo systemctl reload ssh; then
          sudo systemctl reload sshd
        fi
        """
        _ = try? await runtime.sshClient.exec(
            host: "127.0.0.1",
            port: sshPort,
            command: acceptEnvCommand,
            timeoutSeconds: 30
        )

        let version = authContentVersion(bundle)
        if !force,
           let result = try? await runtime.sshClient.exec(
               host: "127.0.0.1",
               port: sshPort,
               command: "cat ~/.config/vetro/agent-auth-version 2>/dev/null",
               timeoutSeconds: 8
           ),
           result.status == 0,
           result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == version
        {
            return
        }

        var environment: [String: String] = ["VETRO_AUTH_VERSION": version]
        if let value = bundle.claudeCredentialsJSON {
            environment["VETRO_AUTH_CLAUDE"] = Data(value.utf8).base64EncodedString()
        }
        if let value = bundle.codexAuthJSON {
            environment["VETRO_AUTH_CODEX"] = Data(value.utf8).base64EncodedString()
        }
        if let value = bundle.grokAuthJSON {
            environment["VETRO_AUTH_GROK"] = Data(value.utf8).base64EncodedString()
        }
        if let value = bundle.grokAgentID {
            environment["VETRO_AUTH_GROK_ID"] = Data(value.utf8).base64EncodedString()
        }

        let command = """
        set -euo pipefail
        mkdir -p -m 0700 "$HOME/.config/vetro"
        python3 - <<'AUTHPY'
        import base64
        import os
        from pathlib import Path

        home = Path.home()
        targets = [
            ("VETRO_AUTH_CLAUDE", home / ".claude" / ".credentials.json"),
            ("VETRO_AUTH_CODEX", home / ".codex" / "auth.json"),
            ("VETRO_AUTH_GROK", home / ".grok" / "auth.json"),
            ("VETRO_AUTH_GROK_ID", home / ".grok" / "agent_id"),
        ]
        for name, path in targets:
            encoded = os.environ.get(name)
            if not encoded:
                continue
            data = base64.b64decode(encoded)
            path.parent.mkdir(parents=True, exist_ok=True)
            os.chmod(path.parent, 0o700)
            temporary = str(path) + ".tmp"
            with open(temporary, "wb") as handle:
                handle.write(data)
            os.chmod(temporary, 0o600)
            os.replace(temporary, path)

        version = os.environ.get("VETRO_AUTH_VERSION", "")
        marker = home / ".config" / "vetro" / "agent-auth-version"
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text(version + "\\n", encoding="utf-8")
        os.chmod(marker, 0o644)
        AUTHPY
        """
        _ = try? await runtime.sshClient.exec(
            host: "127.0.0.1",
            port: sshPort,
            command: command,
            environment: environment,
            timeoutSeconds: 30
        )
    }

    private func configureController(_ controller: VMController, vmID: UUID) async {
        await controller.setHookEventHandler(hookEventHandler)
        await controller.setPortEventHandler { [weak self] snapshot, added, removed, refused in
            Task { @MainActor in
                await self?.applyPortEvent(
                    vmID: vmID,
                    snapshot: snapshot,
                    added: added,
                    removed: removed,
                    refused: refused
                )
            }
        }
    }

    private func applyPortEvent(
        vmID: UUID,
        snapshot: [UInt16]?,
        added: [UInt16],
        removed: [UInt16],
        refused: [UInt16] = []
    ) async {
        guard let runtime = runtimes[vmID] else { return }
        for (guest, host) in persistedRemaps(for: vmID) where runtime.remaps[guest] == nil {
            runtime.remaps[guest] = host
        }

        let incomingAdded: [UInt16]
        let incomingRemoved: [UInt16]
        if let snapshot {
            let snap = Set(snapshot)
            runtime.lastPortSnapshot = snap
            incomingAdded = snapshot.filter {
                !snapIgnoredPorts(vmID: vmID, runtime: runtime).contains($0)
            }
            incomingRemoved = Array(
                runtime.mirroredPorts.union(runtime.conflictPorts).subtracting(snap)
            )
        } else {
            runtime.lastPortSnapshot.formUnion(added)
            runtime.lastPortSnapshot.subtract(Set(removed))
            incomingAdded = added
            incomingRemoved = removed
        }

        for port in incomingRemoved {
            await runtime.controller?.stopMirror(guestPort: port)
            runtime.mirroredPorts.remove(port)
            runtime.conflictPorts.remove(port)
        }

        let ignored = snapIgnoredPorts(vmID: vmID, runtime: runtime)
        for port in incomingAdded where !ignored.contains(port) {
            await startTrackedMirror(vmID: vmID, runtime: runtime, guestPort: port)
        }
        notePortMirrorsChanged()

        if !refused.isEmpty {
            await considerRefusedHostPorts(vmID: vmID, ports: refused)
        }
    }

    private func considerRefusedHostPorts(vmID: UUID, ports: [UInt16]) async {
        let alreadyMirrored = hostMirrorPortSet(for: vmID)
        let dismissed = dismissedHostMirrorPortSet(for: vmID)
        let owned = liveHostListenerPorts()
        let now = Date.now
        for port in ports {
            if alreadyMirrored.contains(port) || dismissed.contains(port) {
                continue
            }
            if hostMirrorSuggestions.contains(where: { $0.vmID == vmID && $0.port == port }) {
                continue
            }
            if owned.contains(port) {
                continue
            }
            let key = HostMirrorCooldownKey(vmID: vmID, port: port)
            if let last = refusedHostMirrorCooldowns[key], now.timeIntervalSince(last) < 20 {
                continue
            }
            let listening = await Task.detached(priority: .utility) {
                Self.hostListensOnLoopback(port)
            }.value
            guard listening,
                  !hostMirrorPortSet(for: vmID).contains(port),
                  !dismissedHostMirrorPortSet(for: vmID).contains(port),
                  !hostMirrorSuggestions.contains(where: { $0.vmID == vmID && $0.port == port }),
                  !liveHostListenerPorts().contains(port)
            else {
                continue
            }
            presentHostMirrorSuggestion(vmID: vmID, port: port)
        }
    }

    private func liveHostListenerPorts() -> Set<UInt16> {
        var ports = Set<UInt16>()
        for runtime in runtimes.values {
            if let forwardedPort = runtime.forwardedPort {
                ports.insert(forwardedPort)
            }
            for guestPort in runtime.mirroredPorts {
                ports.insert(runtime.remaps[guestPort] ?? guestPort)
            }
        }
        for mirror in liveLoginMirrors.values {
            let host = runtimes[mirror.vmID]?.remaps[mirror.guestPort] ?? mirror.guestPort
            ports.insert(host)
        }
        return ports
    }

    private func presentHostMirrorSuggestion(vmID: UUID, port: UInt16) {
        let suggestion = HostMirrorSuggestion(vmID: vmID, port: port)
        guard !hostMirrorSuggestions.contains(suggestion) else { return }
        if hostMirrorSuggestions.count >= 4 {
            hostMirrorSuggestions.removeFirst()
        }
        hostMirrorSuggestions.append(suggestion)
        AgentNotifier.shared.notifyPortMirror(vmName: vm(vmID)?.name ?? "VM", port: port)
    }

    private func clearHostMirrorSuggestion(vmID: UUID, port: UInt16) {
        hostMirrorSuggestions.removeAll { $0.vmID == vmID && $0.port == port }
    }

    private func clearHostMirrorSuggestions(vmID: UUID, ports: Set<UInt16>) {
        hostMirrorSuggestions.removeAll { $0.vmID == vmID && ports.contains($0.port) }
    }

    private func clearHostMirrorSuggestions(for vmID: UUID) {
        hostMirrorSuggestions.removeAll { $0.vmID == vmID }
    }

    private func persistRemovedHostMirrorPort(_ port: UInt16, for vmID: UUID) {
        let projectIDs = attachments
            .compactMap { $0.value.vmID == vmID ? $0.key : nil }
            .sorted { $0.uuidString < $1.uuidString }
        guard let primary = projectIDs.first else { return }
        mutateAttachment(primary) { attachment in
            if !attachment.removedHostMirrorPorts.contains(port) {
                attachment.removedHostMirrorPorts.append(port)
                attachment.removedHostMirrorPorts.sort()
            }
        }
        persistAttachmentsOrRecord()
    }

    private func persistDismissedHostMirrorPort(_ port: UInt16, for vmID: UUID) {
        let projectIDs = attachments
            .compactMap { $0.value.vmID == vmID ? $0.key : nil }
            .sorted { $0.uuidString < $1.uuidString }
        guard let primary = projectIDs.first else { return }
        mutateAttachment(primary) { attachment in
            if !attachment.dismissedHostMirrorPorts.contains(port) {
                attachment.dismissedHostMirrorPorts.append(port)
                attachment.dismissedHostMirrorPorts.sort()
            }
        }
        persistAttachmentsOrRecord()
    }

    nonisolated private static func hostListensOnLoopback(_ port: UInt16) -> Bool {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        let flags = Darwin.fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            return false
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pollFD = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard Darwin.poll(&pollFD, 1, 200) > 0 else { return false }

        var errorCode: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        let option = withUnsafeMutablePointer(to: &errorCode) { errorPointer in
            Darwin.getsockopt(descriptor, SOL_SOCKET, SO_ERROR, errorPointer, &length)
        }
        return option == 0 && errorCode == 0
    }

    private func startTrackedMirror(vmID: UUID, runtime: VMRuntime, guestPort: UInt16) async {
        guard let controller = runtime.controller else { return }
        let host = hostPort(for: guestPort, runtime: runtime, vmID: vmID)
        do {
            try await controller.startMirror(guestPort: guestPort, hostPort: host)
            runtime.mirroredPorts.insert(guestPort)
            runtime.conflictPorts.remove(guestPort)
        } catch {
            if Self.isAddressInUse(error) {
                runtime.conflictPorts.insert(guestPort)
            }
        }
    }

    private func applyExclusion(vmID: UUID, port: UInt16, excluded: Bool) async {
        guard let runtime = runtimes[vmID] else { return }
        if excluded {
            if runtime.mirroredPorts.contains(port) || runtime.conflictPorts.contains(port) {
                await runtime.controller?.stopMirror(guestPort: port)
                runtime.mirroredPorts.remove(port)
                runtime.conflictPorts.remove(port)
                notePortMirrorsChanged()
            }
            return
        }
        guard runtime.lastPortSnapshot.contains(port),
              !runtime.mirroredPorts.contains(port),
              !runtime.conflictPorts.contains(port),
              !Self.reservedMirrorPorts.contains(port),
              !loginMirrorPorts(for: vmID).contains(port)
        else {
            return
        }
        await startTrackedMirror(vmID: vmID, runtime: runtime, guestPort: port)
        notePortMirrorsChanged()
    }

    private func snapIgnoredPorts(vmID: UUID, runtime: VMRuntime) -> Set<UInt16> {
        Self.reservedMirrorPorts
            .union(excludedMirrorPortSet(for: vmID))
            .union(hostMirrorPortSet(for: vmID))
            .union(runtime.mirroredPorts)
            .union(runtime.conflictPorts)
            .union(loginMirrorPorts(for: vmID))
    }

    private static let reservedMirrorPorts: Set<UInt16> = [
        22, 1_024, 1_025, 1_026, 1_027, 1_028, 1_029,
    ]

    private func loginMirrorPorts(for vmID: UUID) -> Set<UInt16> {
        Set(liveLoginMirrors.values.compactMap { $0.vmID == vmID ? $0.guestPort : nil })
    }

    private func excludedMirrorPortSet(for vmID: UUID) -> Set<UInt16> {
        var ports = Set<UInt16>()
        for attachment in attachments.values where attachment.vmID == vmID {
            ports.formUnion(attachment.excludedMirrorPorts)
        }
        return ports
    }

    private func hostMirrorPortSet(for vmID: UUID) -> Set<UInt16> {
        var ports = Set<UInt16>()
        for attachment in attachments.values where attachment.vmID == vmID {
            ports.formUnion(attachment.hostMirrorPorts)
        }
        return ports
    }

    private func removedHostMirrorPortSet(for vmID: UUID) -> Set<UInt16> {
        var ports = Set<UInt16>()
        for attachment in attachments.values where attachment.vmID == vmID {
            ports.formUnion(attachment.removedHostMirrorPorts)
        }
        return ports
    }

    private func dismissedHostMirrorPortSet(for vmID: UUID) -> Set<UInt16> {
        var ports = Set<UInt16>()
        for attachment in attachments.values where attachment.vmID == vmID {
            ports.formUnion(attachment.dismissedHostMirrorPorts)
        }
        return ports
    }

    private func persistedRemaps(for vmID: UUID) -> [UInt16: UInt16] {
        var remaps: [UInt16: UInt16] = [:]
        for attachment in attachments.values where attachment.vmID == vmID {
            remaps.merge(attachment.mirrorRemaps) { _, new in new }
        }
        return remaps
    }

    private func hostPort(for guest: UInt16, runtime: VMRuntime, vmID: UUID) -> UInt16 {
        runtime.remaps[guest] ?? persistedRemaps(for: vmID)[guest] ?? guest
    }

    private func persistRemaps(_ remaps: [UInt16: UInt16], for vmID: UUID) {
        for (projectID, attachment) in attachments where attachment.vmID == vmID {
            mutateAttachment(projectID) { $0.mirrorRemaps = remaps }
        }
        persistAttachmentsOrRecord()
    }

    private func notePortMirrorsChanged() {
        portMirrorEpoch &+= 1
    }

    private static func isAddressInUse(_ error: any Error) -> Bool {
        String(describing: error) == "addressInUse"
    }

    private static func remapsForPersistence(_ remaps: [UInt16: UInt16]) -> [String: UInt16]? {
        guard !remaps.isEmpty else { return nil }
        return Dictionary(uniqueKeysWithValues: remaps.map { (String($0.key), $0.value) })
    }

    private static func remapsFromPersistence(_ remaps: [String: UInt16]?) -> [UInt16: UInt16] {
        guard let remaps else { return [:] }
        var result: [UInt16: UInt16] = [:]
        for (key, value) in remaps {
            guard let guest = UInt16(key) else { continue }
            result[guest] = value
        }
        return result
    }

    private func clearLiveForwards(_ runtime: VMRuntime, vmID: UUID) {
        let loginSessions = liveLoginMirrors
            .filter { $0.value.vmID == vmID }
            .map(\.key)
        for sessionID in loginSessions {
            handleSessionEnd(sessionID)
        }
        runtime.postReadyTask?.cancel()
        runtime.postReadyTask = nil
        runtime.mirroredPorts.removeAll()
        runtime.conflictPorts.removeAll()
        runtime.remaps.removeAll()
        runtime.lastPortSnapshot.removeAll()
        clearHostMirrorSuggestions(for: vmID)
        notePortMirrorsChanged()
    }

    private static let portBridgeUnit = """
    [Unit]
    Description=Vetro vsock port bridge
    After=network.target

    [Service]
    Type=simple
    ExecStart=/usr/bin/python3 /usr/local/lib/vetro/vsock-port-bridge.py
    Restart=always
    RestartSec=2

    [Install]
    WantedBy=multi-user.target

    """

    private static let portwatchUnit = """
    [Unit]
    Description=Vetro port watcher
    After=network.target

    [Service]
    Type=simple
    ExecStart=/usr/bin/python3 /usr/local/lib/vetro/vetro-portwatch.py
    Restart=always
    RestartSec=2

    [Install]
    WantedBy=multi-user.target

    """

    private static let hostBridgeUnit = """
    [Unit]
    Description=Vetro vsock host bridge
    After=network.target

    [Service]
    Type=simple
    ExecStart=/usr/bin/python3 /usr/local/lib/vetro/vsock-host-bridge.py
    Restart=always
    RestartSec=2

    [Install]
    WantedBy=multi-user.target

    """

    func prepareTerminalLaunch(
        for project: Project,
        sessionID: UUID,
        remoteCommand: String? = nil
    ) async -> VMTerminalLaunchDecision {
        if let origin = project.vmOrigin {
            return await prepareVMOnlyLaunch(
                origin: origin,
                sessionID: sessionID,
                remoteCommand: remoteCommand
            )
        }
        guard let initialAttachment = attachments[project.id] else { return .local }
        guard initialAttachment.state == .ready else {
            return .unavailable(message: "The project import is not ready yet.")
        }
        guard let model = vm(initialAttachment.vmID) else {
            return .unavailable(message: "The attached VM no longer exists.")
        }

        switch model.state {
        case .ready:
            runtimes[model.id]?.lastBusy = .now
            await restoreMemoryIfReclaimed(model.id)
        case .stopped, .error:
            await startVM(model.id)
        case .downloading, .provisioning, .starting:
            await waitUntilSettled(model.id)
        }

        guard let currentAttachment = attachments[project.id],
              currentAttachment.vmID == initialAttachment.vmID,
              currentAttachment.state == .ready,
              let currentVM = vm(currentAttachment.vmID),
              currentVM.state == .ready,
              let command = terminalCommand(
                  for: project,
                  sessionID: sessionID,
                  remoteCommand: remoteCommand
              )
        else {
            return .unavailable(message: "The attached VM could not be started.")
        }

        // A restored attachment can claim "ready" while the guest copy is
        // missing (e.g. the original import never completed). Verify before
        // dropping a session into a nonexistent directory, and self-heal by
        // importing.
        let checkRuntime = runtime(
            for: currentVM.id,
            hostname: Self.slug(currentVM.name, fallback: "vetro")
        )
        guard let forwardedPort = checkRuntime.forwardedPort else {
            return .unavailable(message: "The attached VM could not be started.")
        }
        if let check = try? await checkRuntime.sshClient.exec(
            host: "127.0.0.1",
            port: forwardedPort,
            command: "test -d \(Self.shellQuote(currentAttachment.guestPath))",
            timeoutSeconds: 8
        ), check.status != 0 {
            Task { await self.importProject(project) }
            return .unavailable(
                message: "\(project.name) is being imported into \(currentVM.name). Open the chat again when the import finishes."
            )
        }
        return .remote(command: command)
    }

    /// Builds the Ghostty command used to open a VM session.
    /// Agents receive credentials from ~/.config/vetro/env sourced by .profile;
    /// this command never contains credential values.
    func terminalCommand(
        for project: Project,
        sessionID: UUID,
        remoteCommand: String? = nil
    ) -> String? {
        guard let attachment = attachments[project.id], attachment.state == .ready,
              let vm = vm(attachment.vmID)
        else {
            return nil
        }
        return remoteShellCommand(
            vmID: vm.id,
            guestPath: attachment.guestPath,
            sessionID: sessionID,
            remoteCommand: remoteCommand
        )
    }

    /// Builds the Ghostty SSH invocation that lands in `guestPath` on `vmID`,
    /// independent of any rsync attachment (works for VM-only projects too).
    private func remoteShellCommand(
        vmID: UUID,
        guestPath: String,
        sessionID: UUID,
        remoteCommand: String?
    ) -> String? {
        guard let vm = vm(vmID), vm.state == .ready, !vm.ip.isEmpty, vm.ip != "—" else {
            return nil
        }

        let runtime = runtime(for: vm.id, hostname: Self.slug(vm.name, fallback: "vetro"))
        guard let forwardedPort = runtime.forwardedPort else { return nil }
        var invocation = runtime.sshClient.destinationDescription(
            ip: "127.0.0.1",
            port: forwardedPort
        )
        guard !invocation.isEmpty else { return nil }
        invocation.insert("-t", at: invocation.index(before: invocation.endIndex))
        let shellCommand = if let remoteCommand {
            "cd \(Self.shellQuote(guestPath)) && exec \"$SHELL\" -lc \(Self.shellQuote(remoteCommand))"
        } else {
            "cd \(Self.shellQuote(guestPath)) && exec \"$SHELL\" -l"
        }
        invocation.append(
            // TERM: the guest has no xterm-ghostty terminfo, which breaks
            // clear/less; xterm-256color is always installed.
            "export VETRO_SESSION_ID=\(Self.shellQuote(sessionID.uuidString)); "
                + "export TERM=xterm-256color; \(shellCommand)"
        )
        return invocation.map(Self.shellQuote).joined(separator: " ")
    }

    /// Project-free launch for a VM-only project: boots the VM on demand and
    /// lands in the project's guest path. Never touches rsync/import machinery.
    func prepareVMOnlyLaunch(
        origin: VMOrigin,
        sessionID: UUID,
        remoteCommand: String?
    ) async -> VMTerminalLaunchDecision {
        guard let model = vm(origin.vmID) else {
            return .unavailable(message: "The VM no longer exists.")
        }
        switch model.state {
        case .ready:
            runtimes[model.id]?.lastBusy = .now
            await restoreMemoryIfReclaimed(model.id)
        case .stopped, .error:
            await startVM(model.id)
        case .downloading, .provisioning, .starting:
            await waitUntilSettled(model.id)
        }
        guard let currentVM = vm(origin.vmID), currentVM.state == .ready,
              let command = remoteShellCommand(
                  vmID: origin.vmID,
                  guestPath: origin.guestPath,
                  sessionID: sessionID,
                  remoteCommand: remoteCommand
              )
        else {
            return .unavailable(message: "The VM could not be started.")
        }
        return .remote(command: command)
    }

    /// Project-free launch into a VM's guest `$HOME` (Environments section).
    func prepareEnvironmentLaunch(vmID: UUID, sessionID: UUID) async -> VMTerminalLaunchDecision {
        guard let model = vm(vmID) else {
            return .unavailable(message: "The VM no longer exists.")
        }

        switch model.state {
        case .ready:
            runtimes[model.id]?.lastBusy = .now
            await restoreMemoryIfReclaimed(model.id)
        case .stopped, .error:
            await startVM(model.id)
        case .downloading, .provisioning, .starting:
            await waitUntilSettled(model.id)
        }

        guard let currentVM = vm(vmID), currentVM.state == .ready,
              let command = environmentCommand(vmID: vmID, sessionID: sessionID)
        else {
            return .unavailable(message: "The VM could not be started.")
        }
        return .remote(command: command)
    }

    /// Builds the Ghostty command for a project-free VM session, landing at
    /// the guest `$HOME` (no `cd`).
    func environmentCommand(vmID: UUID, sessionID: UUID) -> String? {
        guard let vm = vm(vmID), vm.state == .ready, !vm.ip.isEmpty, vm.ip != "—" else {
            return nil
        }

        let runtime = runtime(for: vm.id, hostname: Self.slug(vm.name, fallback: "vetro"))
        guard let forwardedPort = runtime.forwardedPort else { return nil }
        var invocation = runtime.sshClient.destinationDescription(
            ip: "127.0.0.1",
            port: forwardedPort
        )
        guard !invocation.isEmpty else { return nil }
        invocation.insert("-t", at: invocation.index(before: invocation.endIndex))
        invocation.append(
            "export VETRO_SESSION_ID=\(Self.shellQuote(sessionID.uuidString)); "
                + "export TERM=xterm-256color; exec \"$SHELL\" -l"
        )
        return invocation.map(Self.shellQuote).joined(separator: " ")
    }

    // MARK: - Lifecycle

    private func bootAndProvision(_ id: UUID, creating: Bool) async throws {
        guard !isTerminating else { throw VMOperationError.terminating }
        guard let runtime = runtimes[id] ?? vm(id).map({
            runtime(for: $0.id, hostname: Self.slug($0.name, fallback: "vetro"))
        }) else {
            throw VMOperationError.vmNotFound
        }
        guard !runtime.busy else { throw VMOperationError.vmBusy }

        runtime.busy = true
        runtime.creating = creating
        runtime.forwardedPort = nil
        defer {
            runtime.busy = false
            runtime.creating = false
        }

        // Computed outside mutateVM: the phase helpers read `vms`, which
        // would overlap the in-progress element mutation and trap exclusivity.
        let creationPhases = creating ? pendingProvisioningPhases(for: id) : nil
        mutateVM(id) {
            $0.state = .starting
            $0.downloadProgress = creating ? 0 : $0.downloadProgress
            $0.downloadedImageBytes = creating ? 0 : $0.downloadedImageBytes
            $0.expectedImageBytes = creating ? nil : $0.expectedImageBytes
            $0.isVerifyingImage = false
            $0.errorMessage = nil
            $0.networkChangePending = false
            $0.customScriptFailed = false
            if let creationPhases { $0.phases = creationPhases }
        }
        runtime.bootedNetworkEnabled = vm(id)?.networkEnabled ?? true

        let controller = controller(for: id, runtime: runtime)
        await configureController(controller, vmID: id)
        await acquireStartSlot()
        let result: VMStartResult
        do {
            guard !isTerminating else { throw VMOperationError.terminating }
            try await ensureUniqueSettings(for: id)
            let startTask = Task { [self] in
                try await controller.start(
                    imageDownloadProgress: { [weak self] downloaded, expected in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.runtimes[id]?.startTask != nil
                            else {
                                return
                            }
                            let percent: Double
                            if let expected, expected > 0 {
                                percent = min(
                                    100,
                                    Double(downloaded) / Double(expected) * 100
                                )
                            } else {
                                percent = 0
                            }
                            self.mutateVM(id) {
                                $0.downloadProgress = percent
                                $0.downloadedImageBytes = max(0, downloaded)
                                $0.expectedImageBytes = expected.flatMap { $0 > 0 ? $0 : nil }
                            }
                        }
                    },
                    imagePreparationUpdate: { [weak self] stage in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.runtimes[id]?.startTask != nil
                            else {
                                return
                            }
                            self.mutateVM(id) { vm in
                                switch stage {
                                case .checkingCache:
                                    vm.state = .starting
                                    vm.isVerifyingImage = false
                                case .downloading:
                                    vm.state = .downloading
                                    vm.downloadProgress = 0
                                    vm.downloadedImageBytes = 0
                                    vm.expectedImageBytes = nil
                                    vm.isVerifyingImage = false
                                case .verifying:
                                    vm.state = .downloading
                                    vm.isVerifyingImage = true
                                case .ready:
                                    vm.state = creating ? .provisioning : .starting
                                    vm.isVerifyingImage = false
                                }
                            }
                        }
                    }
                )
            }
            runtime.startTask = startTask
            result = try await startTask.value
            runtime.startTask = nil
            releaseStartSlot()
        } catch {
            runtime.startTask = nil
            releaseStartSlot()
            throw error
        }

        if isTerminating {
            _ = try? await controller.stop()
            runtime.forwardedPort = nil
            throw VMOperationError.terminating
        }
        runtime.startedAt = .now
        runtime.forwardedPort = result.forwardedPort
        runtime.lastBusy = .now
        if result.needsGrow {
            mutateVM(id) { $0.pendingFilesystemGrow = true }
            try? save()
        }
        mutateVM(id) {
            $0.ip = result.ipAddress
            $0.uptime = "0m"
            $0.isVerifyingImage = false
            $0.state = creating ? .provisioning : .starting
            $0.networkChangePending = $0.networkEnabled != (runtime.bootedNetworkEnabled ?? $0.networkEnabled)
        }
        refreshSettings(id)
        refreshDiskUsage(id)

        do {
            let initialStatus = try await controller.provisioningStatus()
            if initialStatus.state(for: .all) != .done {
                let initialPhases = provisioningPhases(from: initialStatus, for: id)
                mutateVM(id) {
                    $0.state = .provisioning
                    $0.phases = initialPhases
                    $0.customScriptFailed = initialStatus.customScriptFailed
                }
                // Cloud-init only launches provision.sh on the very first
                // boot; if that run was interrupted (e.g. the VM stopped
                // mid-provisioning), nothing in the guest restarts it. Kick
                // it here — the script is idempotent and flock-guarded, so
                // this is safe even when a run is already in flight.
                _ = try? await runtime.sshClient.exec(
                    host: "127.0.0.1",
                    port: result.forwardedPort,
                    command: "sudo sh -c 'nohup /usr/local/lib/vetro/provision.sh >/dev/null 2>&1 &'",
                    timeoutSeconds: 15
                )
                let finalStatus = try await controller.waitForProvisioned(
                    pollSeconds: 2,
                    statusUpdate: { [weak self] status in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  status.operation == .provisioning,
                                  self.vm(id)?.state == .provisioning
                            else {
                                return
                            }
                            let phases = self.provisioningPhases(from: status, for: id)
                            self.mutateVM(id) {
                                $0.state = .provisioning
                                $0.phases = phases
                                $0.customScriptFailed = status.customScriptFailed
                            }
                        }
                    }
                )
                let finalPhases = provisioningPhases(from: finalStatus, for: id)
                mutateVM(id) {
                    $0.phases = finalPhases
                    $0.customScriptFailed = finalStatus.customScriptFailed
                }
                if creating {
                    // Credentials push runs per-clone in postReadyTask; scrub
                    // removes /var/lib/vetro/golden-exclude paths so no rotating
                    // agent tokens or injected secrets can be captured.
                    if !(await controller.hasGolden()) {
                        if let cacheKey = try? await controller.stageGoldenAccessKey() {
                            try? await updateSettings(for: id) {
                                $0.goldenCaptureCacheKey = cacheKey
                            }
                        }
                    }
                }
            } else {
                mutateVM(id) { $0.customScriptFailed = initialStatus.customScriptFailed }
            }

            guard !isTerminating else {
                _ = try? await controller.stop()
                throw VMOperationError.terminating
            }
            mutateVM(id) {
                $0.state = .ready
                $0.ip = result.ipAddress
                $0.uptime = "0m"
                $0.errorMessage = nil
            }
            runtime.lastBusy = .now
            // Best-effort follow-ups must not extend the busy window: the VM
            // is usable now, and one wedged probe would otherwise leave Stop
            // refusing with vmBusy for the rest of the boot.
            runtime.postReadyTask?.cancel()
            runtime.postReadyTask = Task { [weak self] in
                guard let self else { return }
                await self.refreshAgentVersions(id, runtime: runtime)
                if self.vm(id)?.pendingFilesystemGrow == true {
                    _ = try? await controller.expandRootFilesystem()
                    self.mutateVM(id) { $0.pendingFilesystemGrow = false }
                    try? self.save()
                }
                self.healAttachments(of: id)
                runtime.remaps = self.persistedRemaps(for: id)
                await self.ensurePortBridge(of: id)
                await self.ensurePortWatch(of: id)
                await self.ensureHostBridge(of: id)
                await self.ensureGuestHooks(of: id)
                await self.ensureCredentials(of: id)
                await self.ensureAgentAuth(of: id)
            }
        } catch {
            _ = try? await controller.stop()
            runtime.startedAt = nil
            runtime.forwardedPort = nil
            throw error
        }
    }

    private func waitUntilSettled(_ id: UUID) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1_800))
        while let state = vm(id)?.state,
              state == .downloading || state == .provisioning || state == .starting,
              ContinuousClock.now < deadline
        {
            guard !Task.isCancelled else { return }
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
        }
    }

    private func controller(for id: UUID, runtime: VMRuntime) -> VMController {
        let controller = runtime.controllerInstance()
        if runtime.monitorTask == nil {
            runtime.monitorTask = Task { [weak self] in
                let updates = await controller.stateUpdates()
                for await state in updates {
                    guard !Task.isCancelled else { return }
                    self?.handleControllerState(state, vmID: id)
                }
            }
        }
        return controller
    }

    private func handleControllerState(_ state: VMController.State, vmID: UUID) {
        guard let runtime = runtimes[vmID] else { return }
        switch state {
        case .stopped:
            guard !runtime.busy else { return }
            runtime.startedAt = nil
            runtime.forwardedPort = nil
            clearLiveForwards(runtime, vmID: vmID)
            mutateVM(vmID) {
                $0.state = .stopped
                $0.ip = "—"
                $0.uptime = "—"
            }
        case let .error(reason):
            runtime.forwardedPort = nil
            failVM(vmID, message: reason)
        case .starting, .provisioning, .ready, .stopping:
            break
        }
    }

    private func acquireStartSlot() async {
        if !startInProgress {
            startInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    private func releaseStartSlot() {
        if startWaiters.isEmpty {
            startInProgress = false
        } else {
            startWaiters.removeFirst().resume()
        }
    }

    // MARK: - Transfers

    private struct ReadyConnection {
        let attachment: ProjectVMAttachment
        let runtime: VMRuntime
        let port: UInt16
        let destination: String
    }

    private func readyConnection(
        for project: Project,
        startingIfNeeded: Bool,
        announceStart: Bool = true
    ) async throws -> ReadyConnection {
        guard var attachment = attachments[project.id] else {
            throw VMOperationError.attachmentNotFound
        }
        guard let model = vm(attachment.vmID) else { throw VMOperationError.vmNotFound }

        if startingIfNeeded, model.state == .stopped || model.state == .error {
            if announceStart {
                mutateAttachment(project.id) { $0.state = .starting }
            }
            await startVM(model.id)
        } else if startingIfNeeded,
                  model.state == .downloading || model.state == .provisioning || model.state == .starting
        {
            await waitUntilSettled(model.id)
        }

        guard let readyVM = vm(attachment.vmID), readyVM.state == .ready,
              !readyVM.ip.isEmpty, readyVM.ip != "—"
        else {
            throw VMOperationError.vmNotReady
        }
        attachment = attachments[project.id] ?? attachment
        let runtime = runtime(
            for: readyVM.id,
            hostname: Self.slug(readyVM.name, fallback: "vetro")
        )
        guard let forwardedPort = runtime.forwardedPort else {
            throw VMOperationError.vmNotReady
        }
        let invocation = runtime.sshClient.destinationDescription(
            ip: "127.0.0.1",
            port: forwardedPort
        )
        guard let destination = invocation.last else { throw VMOperationError.vmNotReady }
        return ReadyConnection(
            attachment: attachment,
            runtime: runtime,
            port: forwardedPort,
            destination: destination
        )
    }

    private func transferConnection(
        for project: Project,
        reusing connection: ReadyConnection?
    ) async throws -> ReadyConnection {
        if let connection,
           let currentAttachment = attachments[project.id],
           currentAttachment.vmID == connection.attachment.vmID,
           currentAttachment.guestPath == connection.attachment.guestPath,
           let currentVM = vm(currentAttachment.vmID),
           currentVM.state == .ready,
           !currentVM.ip.isEmpty,
           currentVM.ip != "—",
           runtimes[currentAttachment.vmID] === connection.runtime,
           connection.runtime.forwardedPort == connection.port
        {
            return ReadyConnection(
                attachment: currentAttachment,
                runtime: connection.runtime,
                port: connection.port,
                destination: connection.destination
            )
        }
        return try await readyConnection(for: project, startingIfNeeded: true)
    }

    private func rsyncArguments(
        runtime: VMRuntime,
        port: UInt16,
        source: String,
        destination: String,
        projectRoot: URL,
        preview: Bool = false
    ) -> [String] {
        var ssh = runtime.sshClient.destinationDescription(
            ip: "127.0.0.1",
            port: port
        )
        _ = ssh.popLast()
        let remoteShell = ssh.map(Self.shellQuote).joined(separator: " ")
        var arguments = ["-a", "--delete"]
        if preview {
            arguments.append(contentsOf: [
                "--dry-run",
                "--itemize-changes",
                "--out-format=%i %n",
            ])
        } else {
            arguments.append("--info=progress2")
        }
        for pattern in Self.transferExcludes {
            arguments.append(contentsOf: ["--exclude", pattern])
        }
        if let text = try? String(
            contentsOf: projectRoot.appendingPathComponent(".vetroignore"),
            encoding: .utf8
        ) {
            arguments.append(contentsOf: VetroIgnore.parse(text).map { "--exclude=\($0)" })
        }
        arguments.append(contentsOf: ["-e", remoteShell, source, destination])
        return arguments
    }

    private nonisolated static func runRsync(
        arguments: [String],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> RsyncResult {
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager()
            guard let rsync = rsyncExecutable(fileManager: fileManager) else {
                throw CocoaError(.executableNotLoadable)
            }
            let supportsProgress2 = supportsProgress2(rsync)
            let effectiveArguments = supportsProgress2
                ? arguments
                : arguments.map { $0 == "--info=progress2" ? "--progress" : $0 }
            let captureDirectory = fileManager.temporaryDirectory.appendingPathComponent(
                "vetro-rsync-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: captureDirectory,
                withIntermediateDirectories: true
            )
            defer { try? fileManager.removeItem(at: captureDirectory) }

            let outputURL = captureDirectory.appendingPathComponent("output", isDirectory: false)
            guard fileManager.createFile(atPath: outputURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let writer = try FileHandle(forWritingTo: outputURL)
            let reader = try FileHandle(forReadingFrom: outputURL)
            defer {
                try? writer.close()
                try? reader.close()
            }

            let process = Process()
            process.executableURL = rsync
            process.arguments = effectiveArguments
            process.environment = ["LANG": "C", "LC_ALL": "C"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = writer
            process.standardError = writer
            let capture = RsyncProgressCapture(
                parsePercentages: supportsProgress2,
                progress: progress
            )

            // waitUntilExit can miss the exit of a fast or signalled child
            // (its run-loop race, see SubprocessRunner); terminationHandler
            // is the reliable contract, installed before run().
            let (terminationEvents, terminationContinuation) =
                AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            process.terminationHandler = { _ in
                terminationContinuation.yield()
                terminationContinuation.finish()
            }

            try process.run()
            do {
                while process.isRunning {
                    try Task.checkCancellation()
                    if let data = try reader.read(upToCount: 65_536) {
                        capture.consume(data)
                    }
                    try await Task.sleep(for: .milliseconds(150))
                }
            } catch {
                if process.isRunning {
                    process.terminate()
                }
                for await _ in terminationEvents { break }
                throw error
            }

            for await _ in terminationEvents { break }
            try writer.synchronize()
            if let data = try reader.readToEnd() {
                capture.consume(data)
            }
            return RsyncResult(
                status: process.terminationStatus,
                outputTail: capture.tail()
            )
        }.value
    }

    private nonisolated static func runRsyncPreview(
        arguments: [String]
    ) async throws -> RsyncPreviewResult {
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager()
            guard let rsync = rsyncExecutable(fileManager: fileManager) else {
                throw CocoaError(.executableNotLoadable)
            }
            let captureDirectory = fileManager.temporaryDirectory.appendingPathComponent(
                "vetro-rsync-preview-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: captureDirectory,
                withIntermediateDirectories: true
            )
            defer { try? fileManager.removeItem(at: captureDirectory) }

            let stdoutURL = captureDirectory.appendingPathComponent("stdout", isDirectory: false)
            let stderrURL = captureDirectory.appendingPathComponent("stderr", isDirectory: false)
            guard fileManager.createFile(atPath: stdoutURL.path, contents: nil),
                  fileManager.createFile(atPath: stderrURL.path, contents: nil)
            else {
                throw CocoaError(.fileWriteUnknown)
            }
            let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)
            let process = Process()
            process.executableURL = rsync
            process.arguments = arguments
            process.environment = ["LANG": "C", "LC_ALL": "C"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle

            // Same waitUntilExit race as runRsync: rely on terminationHandler.
            let (terminationEvents, terminationContinuation) =
                AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            process.terminationHandler = { _ in
                terminationContinuation.yield()
                terminationContinuation.finish()
            }

            do {
                try process.run()
            } catch {
                terminationContinuation.finish()
                try? stdoutHandle.close()
                try? stderrHandle.close()
                throw error
            }

            do {
                while process.isRunning {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(150))
                }
            } catch {
                if process.isRunning {
                    process.terminate()
                }
                for await _ in terminationEvents { break }
                try? stdoutHandle.close()
                try? stderrHandle.close()
                throw error
            }

            for await _ in terminationEvents { break }
            try stdoutHandle.close()
            try stderrHandle.close()
            let stdout = String(
                decoding: try Data(contentsOf: stdoutURL),
                as: UTF8.self
            )
            let stderr = String(
                decoding: try Data(contentsOf: stderrURL),
                as: UTF8.self
            )
            return RsyncPreviewResult(
                status: process.terminationStatus,
                stdout: stdout,
                stderrTail: String(stderr.suffix(16_384))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }.value
    }

    /// Prefers an rsync with progress2 support, falling back to stock macOS openrsync.
    private nonisolated static func rsyncExecutable(fileManager: FileManager) -> URL? {
        var paths = [
            "/opt/homebrew/bin/rsync",
            "/usr/local/bin/rsync",
            "/opt/local/bin/rsync",
        ]
        paths.append(contentsOf: (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { "\($0)/rsync" })
        paths.append("/usr/bin/rsync")

        var visited: Set<String> = []
        var fallback: URL?
        for path in paths where visited.insert(path).inserted {
            guard fileManager.isExecutableFile(atPath: path) else { continue }
            let candidate = URL(fileURLWithPath: path, isDirectory: false)
            fallback = fallback ?? candidate
            if supportsProgress2(candidate) { return candidate }
        }
        return fallback
    }

    private nonisolated static func supportsProgress2(_ executableURL: URL) -> Bool {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--info=progress2", "--version"]
        process.environment = ["LANG": "C", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
            done.wait()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Provisioning and agent state

    private static let agentPhaseMapping: [(String, VMProvisioningPhase)] = [
        ("claude", .claude),
        ("codex", .codex),
        ("grok", .grok),
    ]

    private func pendingProvisioningPhases(for id: UUID) -> [VMPhase] {
        var phases = [
            VMPhase(id: "base", label: "Base tools", state: .pending),
            VMPhase(id: "node", label: "Node.js", state: .pending),
        ]
        if let model = vm(id), !model.agents.isEmpty {
            let names = model.agents.map(\.name).joined(separator: " · ")
            phases.append(
                VMPhase(id: "agents", label: "Agents (\(names))", state: .pending)
            )
        }
        phases.append(VMPhase(id: "cleanup", label: "Cleanup", state: .pending))
        if vm(id)?.hasCustomScript == true {
            phases.append(VMPhase(id: "custom", label: "Custom script", state: .pending))
        }
        return phases
    }

    private func provisioningPhases(
        from status: VMProvisioningStatus,
        for id: UUID
    ) -> [VMPhase] {
        let selected = vm(id)?.agents.map(\.name) ?? []
        var phases = [
            VMPhase(
                id: "base",
                label: "Base tools",
                state: Self.phaseState([.aptBase], in: status)
            ),
            VMPhase(
                id: "node",
                label: "Node.js",
                state: Self.phaseState([.node], in: status)
            ),
        ]
        let selectedAgentPhases = Self.agentPhaseMapping.compactMap { name, phase in
            selected.contains(name) ? phase : nil
        }
        if !selectedAgentPhases.isEmpty {
            let names = selected.joined(separator: " · ")
            phases.append(
                VMPhase(
                    id: "agents",
                    label: "Agents (\(names))",
                    state: Self.phaseState(selectedAgentPhases, in: status)
                )
            )
        }
        phases.append(
            VMPhase(
                id: "cleanup",
                label: "Cleanup",
                state: Self.phaseState([.workdir, .prune], in: status)
            )
        )
        if vm(id)?.hasCustomScript == true {
            phases.append(
                VMPhase(
                    id: "custom",
                    label: "Custom script",
                    state: Self.phaseState([.custom], in: status)
                )
            )
        }
        return phases
    }

    private static func phaseState(
        _ phases: [VMProvisioningPhase],
        in status: VMProvisioningStatus
    ) -> VMPhase.State {
        let states = phases.map(status.state(for:))
        if states.contains(.failed) { return .failed }
        let remaining = states.filter { $0 != .skipped }
        if remaining.isEmpty { return .skipped }
        if remaining.allSatisfy({ $0 == .done }) { return .done }
        if remaining.contains(.running) || remaining.contains(.done) { return .running }
        return .pending
    }

    private func applyAgentUpdate(
        _ status: VMProvisioningStatus,
        to vmID: UUID,
        updating names: Set<String>
    ) {
        let mappings: [(String, VMProvisioningPhase)] = [
            ("claude", .updateClaude),
            ("codex", .updateCodex),
            ("grok", .updateGrok),
        ]
        mutateVM(vmID) { vm in
            let terminalFailure = status.failedPhase != nil
            for (name, phase) in mappings {
                guard names.contains(name),
                      let index = vm.agents.firstIndex(where: { $0.name == name })
                else { continue }
                vm.agents[index].status = switch status.state(for: phase) {
                case .pending: terminalFailure ? .ok : .updating
                case .running: .updating
                case .done: .updated
                case .failed: .failed
                case .skipped: .ok
                }
            }
            if vm.agents.contains(where: { $0.status == .failed }) {
                vm.updateState = .partial
            } else if names.allSatisfy({ name in
                vm.agents.first(where: { $0.name == name }).map {
                    $0.status == .updated || $0.status == .ok
                } ?? true
            }), status.isComplete {
                vm.updateState = .done
            } else {
                vm.updateState = .running
            }
        }
    }

    private func refreshAgentVersions(_ vmID: UUID, runtime: VMRuntime) async {
        guard vm(vmID)?.state == .ready,
              let forwardedPort = runtime.forwardedPort
        else {
            return
        }
        let commands = [
            ("claude", "claude --version"),
            ("codex", "codex --version"),
            ("grok", "grok --version"),
        ]
        for (name, versionCommand) in commands {
            let result = try? await runtime.sshClient.exec(
                host: "127.0.0.1",
                port: forwardedPort,
                command: "bash -lc \(Self.shellQuote(versionCommand))",
                timeoutSeconds: 15
            )
            guard let result, result.status == 0,
                  let version = result.stdout
                    .split(whereSeparator: \Character.isNewline)
                    .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                    .first(where: { !$0.isEmpty })
            else {
                continue
            }
            mutateVM(vmID) { vm in
                guard let index = vm.agents.firstIndex(where: { $0.name == name }) else { return }
                vm.agents[index].version = version
            }
        }
    }

    // MARK: - Persistence and model helpers

    private func load() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode(PersistedState.self, from: Data(contentsOf: fileURL))
        vms = persisted.vms
            .sorted { $0.createdAt < $1.createdAt }
            .map {
                makeVM(
                    id: $0.id,
                    name: $0.name,
                    createdAt: $0.createdAt,
                    state: .stopped,
                    pendingFilesystemGrow: $0.pendingFilesystemGrow ?? false
                )
            }
        let knownVMs = Set(vms.map(\.id))
        attachments = Dictionary(uniqueKeysWithValues: persisted.attachments.compactMap {
            projectID, attachment in
            guard let id = UUID(uuidString: projectID), knownVMs.contains(attachment.vmID) else {
                return nil
            }
            return (
                id,
                ProjectVMAttachment(
                    vmID: attachment.vmID,
                    guestPath: attachment.guestPath,
                    state: .ready,
                    importProgress: 100,
                    lastImport: attachment.lastImport,
                    lastExport: attachment.lastExport,
                    excludedMirrorPorts: attachment.excludedMirrorPorts ?? [],
                    mirrorRemaps: Self.remapsFromPersistence(attachment.mirrorRemaps),
                    hostMirrorPorts: attachment.hostMirrorPorts ?? [],
                    dismissedHostMirrorPorts: attachment.dismissedHostMirrorPorts ?? [],
                    removedHostMirrorPorts: attachment.removedHostMirrorPorts ?? []
                )
            )
        })
        selectedVMID = vms.first?.id
        for record in persisted.vms {
            let hostname = Self.slug(record.name, fallback: "vetro")
            runtimes[record.id] = makeRuntime(for: record.id, hostname: hostname)
            refreshSettings(record.id)
            refreshDiskUsage(record.id)
        }
    }

    private func save() throws {
        let records = vms.map {
            PersistedState.Record(
                id: $0.id,
                name: $0.name,
                createdAt: $0.createdAt,
                pendingFilesystemGrow: $0.pendingFilesystemGrow ? true : nil
            )
        }
        let persistedAttachments = Dictionary(uniqueKeysWithValues: attachments.map {
            projectID, attachment in
            (
                projectID.uuidString,
                PersistedState.Attachment(
                    vmID: attachment.vmID,
                    guestPath: attachment.guestPath,
                    lastImport: attachment.lastImport,
                    lastExport: attachment.lastExport,
                    forwardedPorts: nil,
                    excludedMirrorPorts: attachment.excludedMirrorPorts.isEmpty
                        ? nil
                        : attachment.excludedMirrorPorts.sorted(),
                    mirrorRemaps: Self.remapsForPersistence(attachment.mirrorRemaps),
                    hostMirrorPorts: attachment.hostMirrorPorts.isEmpty
                        ? nil
                        : attachment.hostMirrorPorts.sorted(),
                    dismissedHostMirrorPorts: attachment.dismissedHostMirrorPorts.isEmpty
                        ? nil
                        : attachment.dismissedHostMirrorPorts.sorted(),
                    removedHostMirrorPorts: attachment.removedHostMirrorPorts.isEmpty
                        ? nil
                        : attachment.removedHostMirrorPorts.sorted()
                )
            )
        })
        let state = PersistedState(vms: records, attachments: persistedAttachments)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: fileURL, options: .atomic)
    }

    private func makeVM(
        id: UUID,
        name: String,
        createdAt: Date,
        state: VM.State,
        pendingFilesystemGrow: Bool = false
    ) -> VM {
        VM(
            id: id,
            name: name,
            createdAt: createdAt,
            state: state,
            ip: "—",
            uptime: "—",
            cpu: max(1, min(ProcessInfo.processInfo.activeProcessorCount, 6)),
            ram: "4 GB",
            diskUsedGB: 0,
            diskMaxGB: 32,
            agents: Self.defaultAgentRows,
            downloadProgress: 0,
            downloadedImageBytes: 0,
            expectedImageBytes: nil,
            isVerifyingImage: false,
            phases: [],
            updateState: .idle,
            errorMessage: nil,
            idleStopMinutes: nil,
            networkEnabled: true,
            networkChangePending: false,
            pendingFilesystemGrow: pendingFilesystemGrow,
            customScriptFailed: false,
            hasCustomScript: false
        )
    }

    private func stateDirectory(for id: UUID) -> StateDirectory {
        StateDirectory(vmID: id, environment: environment, homeDirectory: homeDirectory)
    }

    private func makeRuntime(for id: UUID, hostname: String) -> VMRuntime {
        VMRuntime(stateDirectory: stateDirectory(for: id), hostname: hostname)
    }

    private func runtime(for id: UUID, hostname: String) -> VMRuntime {
        if let runtime = runtimes[id] { return runtime }
        let runtime = makeRuntime(for: id, hostname: hostname)
        runtimes[id] = runtime
        return runtime
    }

    private func mutateVM(_ id: UUID, _ mutation: (inout VM) -> Void) {
        guard let index = vms.firstIndex(where: { $0.id == id }) else { return }
        mutation(&vms[index])
    }

    private func mutateAttachment(
        _ projectID: UUID,
        _ mutation: (inout ProjectVMAttachment) -> Void
    ) {
        guard var attachment = attachments[projectID] else { return }
        mutation(&attachment)
        attachments[projectID] = attachment
    }

    private func failVM(_ id: UUID, error: any Error) {
        failVM(id, message: Self.describe(error))
    }

    private func failVM(_ id: UUID, message: String) {
        runtimes[id]?.forwardedPort = nil
        if let runtime = runtimes[id] {
            clearLiveForwards(runtime, vmID: id)
        }
        mutateVM(id) {
            $0.state = .error
            $0.errorMessage = message
            $0.isVerifyingImage = false
        }
        lastError = message
    }

    private func record(error: any Error) {
        lastError = Self.describe(error)
        if let lastError {
            errorPresenter?(lastError)
        }
    }

    private func refreshSettings(_ id: UUID) {
        let url = stateDirectory(for: id).configurationURL
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(VMSettings.self, from: data)
        else {
            return
        }
        let selected = Self.normalizedAgents(settings.installAgents)
        mutateVM(id) { vm in
            vm.cpu = settings.cpus
            vm.ram = Self.memoryLabel(settings.memoryMB)
            vm.diskMaxGB = Double(settings.diskSizeGB)
            vm.idleStopMinutes = settings.idleStopMinutes
            vm.networkEnabled = settings.networkEnabled
            vm.hasCustomScript = Self.hasCustomScript(settings.customScript)
            let existing = Dictionary(uniqueKeysWithValues: vm.agents.map { ($0.name, $0) })
            vm.agents = selected.map { name in
                existing[name] ?? VMAgent(name: name, version: "—", status: .ok)
            }
        }
    }

    private func persistCreationSettings(
        _ id: UUID,
        _ configuration: NewVMConfiguration
    ) async throws {
        try await updateSettings(for: id) { settings in
            settings.cpus = max(1, configuration.cpus)
            settings.memoryMB = max(1, configuration.memoryMB)
            settings.diskSizeGB = max(1, configuration.diskSizeGB)
            settings.installAgents = Self.normalizedAgents(configuration.agents)
            settings.transferAuthFromMac = configuration.transferAuth
            settings.customScript = Self.normalizedCustomScript(configuration.customScript)
        }
    }

    private func updateSettings(
        for id: UUID,
        _ body: (inout VMSettings) throws -> Void
    ) async throws {
        let settingsStore = VMSettingsStore(stateDirectory: stateDirectory(for: id))
        var settings = try await settingsStore.loadOrCreate()
        try body(&settings)
        try await settingsStore.save(settings)
    }

    private func growDiskImage(at url: URL, toGigabytes sizeGB: Int) throws {
        let (targetBytes, overflow) = UInt64(sizeGB).multipliedReportingOverflow(by: 1_073_741_824)
        guard !overflow else { throw VMOperationError.cannotShrinkDisk }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let currentBytes = attributes[.size] as? UInt64 ?? 0
        guard targetBytes >= currentBytes else {
            throw VMOperationError.cannotShrinkDisk
        }
        guard targetBytes > currentBytes else { return }
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.truncate(atOffset: targetBytes)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    private func persistAttachmentsOrRecord() {
        do {
            try save()
        } catch {
            record(error: error)
        }
    }

    private func startIdleWatch() {
        idleWatchTask?.cancel()
        idleWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await self?.tickIdleStop()
            }
        }
    }

    private func tickIdleStop() async {
        guard !isTerminating else { return }
        let now = Date.now
        for model in vms where model.state == .ready {
            guard let runtime = runtimes[model.id] else { continue }
            if isVMBusy(model.id) {
                runtime.lastBusy = now
                await restoreMemoryIfReclaimed(model.id)
                continue
            }
            let idleSeconds = now.timeIntervalSince(runtime.lastBusy)
            if let minutes = model.idleStopMinutes, minutes > 0,
               idleSeconds >= Double(minutes) * 60
            {
                runtime.lastBusy = now
                await stopVM(model.id)
                continue
            }
            if !runtime.memoryReclaimed, idleSeconds >= 120 {
                runtime.memoryReclaimed = true
                _ = try? await runtime.controller?.reclaimIdleMemory()
            }
        }
    }

    private func restoreMemoryIfReclaimed(_ vmID: UUID) async {
        guard let runtime = runtimes[vmID], runtime.memoryReclaimed else { return }
        runtime.memoryReclaimed = false
        try? await runtime.controller?.restoreMemory()
    }

    private func isTransferBusy(vmID: UUID) -> Bool {
        if activeTransfers.values.contains(where: { $0.vmID == vmID }) { return true }
        if let pendingTransfer, attachments[pendingTransfer.projectID]?.vmID == vmID {
            return true
        }
        return false
    }

    private func isVMBusy(_ id: UUID) -> Bool {
        guard let model = vm(id) else { return false }
        switch model.state {
        case .downloading, .provisioning, .starting:
            return true
        case .ready, .stopped, .error:
            break
        }
        if model.updateState == .running { return true }
        if runtimes[id]?.busy == true { return true }
        if isTransferBusy(vmID: id) { return true }
        if (openVMSessionsProvider?(id) ?? 0) > 0 { return true }
        for (projectID, attachment) in attachments where attachment.vmID == id {
            if (openSessionsProvider?(projectID) ?? 0) > 0 { return true }
        }
        return false
    }

    private static let defaultAgentRows = VMSettings.defaultInstallAgents.map {
        VMAgent(name: $0, version: "—", status: .ok)
    }

    private static let knownAgentNames = Set(VMSettings.defaultInstallAgents)

    private static func normalizedAgents(_ agents: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in agents {
            let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard knownAgentNames.contains(key), seen.insert(key).inserted else { continue }
            result.append(key)
        }
        return result
    }

    private static func normalizedCustomScript(_ script: String?) -> String? {
        guard let trimmed = script?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    private static func hasCustomScript(_ script: String?) -> Bool {
        normalizedCustomScript(script) != nil
    }

    private func refreshDiskUsage(_ id: UUID) {
        let diskURL = stateDirectory(for: id).diskURL
        guard let values = try? diskURL.resourceValues(forKeys: [
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
        ]) else {
            return
        }
        let bytes = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
        mutateVM(id) {
            $0.diskUsedGB = Double(bytes) / 1_073_741_824
        }
    }

    private func nextVMName() -> String {
        let highest = vms.compactMap { vm -> Int? in
            guard vm.name.hasPrefix("dev-vm-") else { return nil }
            return Int(vm.name.dropFirst("dev-vm-".count))
        }.max() ?? 0
        return "dev-vm-\(highest + 1)"
    }

    private static func guestPath(for project: Project) -> String {
        "/workspace/\(slug(project.name, fallback: "project"))"
    }

    private func availableGuestPath(for project: Project, on vmID: UUID) -> String {
        let base = Self.guestPath(for: project)
        var occupied: Set<String> = Set(attachments.compactMap { projectID, attachment in
            guard projectID != project.id, attachment.vmID == vmID else { return nil }
            return attachment.guestPath
        })
        occupied.formUnion(vmOnlyGuestPathsProvider?(vmID) ?? [])
        guard occupied.contains(base) else { return base }

        let suffix = project.id.uuidString.lowercased().prefix(8)
        var candidate = "\(base)-\(suffix)"
        var discriminator = 2
        while occupied.contains(candidate) {
            candidate = "\(base)-\(suffix)-\(discriminator)"
            discriminator += 1
        }
        return candidate
    }

    /// Materializes this VM's settings before boot and rejects a MAC already
    /// persisted by another record. VM starts are serialized around this check.
    private func ensureUniqueSettings(for id: UUID) async throws {
        let settingsStore = VMSettingsStore(stateDirectory: stateDirectory(for: id))
        var settings = try await settingsStore.loadOrCreate()
        let usedAddresses = Set(vms.compactMap { model -> String? in
            guard model.id != id else { return nil }
            let configurationURL = stateDirectory(for: model.id).configurationURL
            guard let data = try? Data(contentsOf: configurationURL),
                  let other = try? JSONDecoder().decode(VMSettings.self, from: data)
            else {
                return nil
            }
            return other.macAddress.lowercased()
        })
        guard usedAddresses.contains(settings.macAddress.lowercased()) else { return }

        repeat {
            settings.macAddress = Self.randomMACAddress()
        } while usedAddresses.contains(settings.macAddress)
        try await settingsStore.save(settings)
    }

    private static func randomMACAddress() -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes = (0..<6).map { _ in
            UInt8.random(in: UInt8.min ... UInt8.max, using: &generator)
        }
        bytes[0] = (bytes[0] | 0x02) & 0xFE
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    private static func slug(_ value: String, fallback: String) -> String {
        let folded = value.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        var result = ""
        var needsSeparator = false
        for scalar in folded.unicodeScalars {
            let isLetter = (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
            let isDigit = (48...57).contains(scalar.value)
            if isLetter || isDigit {
                if needsSeparator, !result.isEmpty { result.append("-") }
                result.append(Character(String(scalar).lowercased()))
                needsSeparator = false
            } else {
                needsSeparator = true
            }
            if result.utf8.count >= 63 { break }
        }
        while result.last == "-" { result.removeLast() }
        return result.isEmpty ? fallback : result
    }

    private static func isSafeGuestPath(_ path: String) -> Bool {
        guard path.hasPrefix("/workspace/"), !path.hasSuffix("/"),
              !path.contains(".."), !path.contains("\n"), !path.contains("\r")
        else {
            return false
        }
        return !path.dropFirst("/workspace/".count).contains("/")
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// Boots the VM on demand, then runs one bounded SSH command in the guest.
    /// Used for VM-only project discovery/creation and VM-only git.
    func execOnGuest(
        vmID: UUID,
        command: String,
        timeoutSeconds: Int
    ) async -> (status: Int32, stdout: String, stderr: String)? {
        guard let model = vm(vmID) else { return nil }

        switch model.state {
        case .ready:
            runtimes[model.id]?.lastBusy = .now
            await restoreMemoryIfReclaimed(model.id)
        case .stopped, .error:
            await startVM(model.id)
        case .downloading, .provisioning, .starting:
            await waitUntilSettled(model.id)
        }

        guard let currentVM = vm(vmID), currentVM.state == .ready else { return nil }
        let runtime = runtime(
            for: currentVM.id,
            hostname: Self.slug(currentVM.name, fallback: "vetro")
        )
        guard let port = runtime.forwardedPort else { return nil }
        runtime.lastBusy = .now
        return try? await runtime.sshClient.exec(
            host: "127.0.0.1",
            port: port,
            command: command,
            timeoutSeconds: timeoutSeconds
        )
    }

    /// Existing `/workspace/*` folders on the guest, for the VM-only add flow.
    func listWorkspaceFolders(vmID: UUID) async -> [String] {
        let find = "find /workspace -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f\\n' 2>/dev/null | sort"
        if let result = await execOnGuest(vmID: vmID, command: find, timeoutSeconds: 15),
           result.status == 0 {
            let names = Self.splitFolders(result.stdout)
            if !names.isEmpty { return names }
        }
        let ls = "ls -1p /workspace 2>/dev/null | grep '/$' | sed 's:/$::' | sort"
        guard let fallback = await execOnGuest(vmID: vmID, command: ls, timeoutSeconds: 15),
              fallback.status == 0 else { return [] }
        return Self.splitFolders(fallback.stdout)
    }

    private static func splitFolders(_ stdout: String) -> [String] {
        stdout.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(".") }
    }

    /// Creates a new `/workspace/<slug>` folder on the guest; returns its path.
    func makeWorkspaceFolder(vmID: UUID, name: String) async -> String? {
        let guestPath = "/workspace/\(Self.slug(name, fallback: "project"))"
        guard Self.isSafeGuestPath(guestPath) else { return nil }
        guard let result = await execOnGuest(
            vmID: vmID,
            command: "mkdir -p -- \(Self.shellQuote(guestPath))",
            timeoutSeconds: 30
        ), result.status == 0 else { return nil }
        return guestPath
    }

    /// Bounded one-shot SSH on a ready attachment. Does not start the VM.
    func execOnAttachedGuest(
        projectID: UUID,
        command: String,
        timeoutSeconds: Int
    ) async -> (status: Int32, stdout: String, stderr: String)? {
        guard let attachment = attachments[projectID],
              let model = vm(attachment.vmID),
              model.state == .ready,
              let runtime = runtimes[attachment.vmID],
              let port = runtime.forwardedPort
        else { return nil }
        runtime.lastBusy = .now
        return try? await runtime.sshClient.exec(
            host: "127.0.0.1",
            port: port,
            command: command,
            timeoutSeconds: timeoutSeconds
        )
    }

    private static func withTrailingSlash(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }

    private static func memoryLabel(_ memoryMB: Int) -> String {
        if memoryMB.isMultiple(of: 1_024) {
            return "\(memoryMB / 1_024) GB"
        }
        return String(format: "%.1f GB", Double(memoryMB) / 1_024)
    }

    private static func describe(_ error: any Error) -> String {
        if let localized = error as? any LocalizedError,
           let description = localized.errorDescription, !description.isEmpty
        {
            return description
        }
        return String(describing: error)
    }
}
