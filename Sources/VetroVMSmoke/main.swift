// Headless acceptance harness for the ported VMKit engine.
// Default: boot a throwaway VM, verify guest identity, shut down.
// Also: hold / disk-report for the V6/V7 bench harness, and clone-smoke
// for golden-image capture/clone. Run via Support/vm-smoke.sh.

import Darwin
import Foundation
import VMKit

@main
struct VetroVMSmoke {
    static let smokeID = UUID(uuidString: "00000000-0000-0000-0000-00000000531E")!
    static let benchID = UUID(uuidString: "00000000-0000-0000-0000-0000000B33C4")!
    static let cloneDonorID = UUID(uuidString: "00000000-0000-0000-0000-00000000C10A")!
    static let cloneCloneID = UUID(uuidString: "00000000-0000-0000-0000-00000000C10B")!
    static let shareTag = "bench"

    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IOLBF, 0)
        let arguments = Array(CommandLine.arguments.dropFirst())

        switch arguments.first {
        case "wipe":
            wipe()
        case "hold":
            await hold(Array(arguments.dropFirst()))
        case "disk-report":
            diskReport()
        case "clone-smoke":
            await cloneSmoke()
        default:
            await smoke()
        }
    }

    private static func wipe() {
        let smoke = StateDirectory(vmID: smokeID)
        let bench = StateDirectory(vmID: benchID)
        try? FileManager.default.removeItem(at: smoke.rootURL)
        try? FileManager.default.removeItem(at: bench.rootURL)
        print("WIPED \(smoke.rootURL.path)")
        print("WIPED \(bench.rootURL.path)")
    }

    /// Boots donor A through full provision, captures a golden, then boots clone B.
    private static func cloneSmoke() async {
        let donorState = StateDirectory(vmID: cloneDonorID)
        let cloneState = StateDirectory(vmID: cloneCloneID)
        try? FileManager.default.removeItem(at: donorState.rootURL)
        try? FileManager.default.removeItem(at: cloneState.rootURL)
        print("WIPED \(donorState.rootURL.path)")
        print("WIPED \(cloneState.rootURL.path)")

        var failures: [String] = []
        func check(_ passed: Bool, _ name: String, _ detail: String = "") {
            if passed {
                print("PASS \(name)")
            } else {
                let suffix = detail.isEmpty ? "" : " (\(detail))"
                print("FAIL \(name)\(suffix)")
                failures.append(name)
            }
        }

        let donor = VMController(stateDirectory: donorState, hostname: "clone-donor")
        do {
            try await writeCloneSmokeSettings(state: donorState)

            let donorStart = ContinuousClock.now
            let donorResult = try await donor.start(
                imageDownloadProgress: { got, total in
                    print("DOWNLOAD \(got)/\(total.map(String.init) ?? "?")")
                }
            )
            print("DONOR ssh-ready total=\(String(format: "%.1f", donorResult.totalSeconds))s")
            _ = try await donor.waitForProvisioned(
                statusUpdate: { status in
                    let running = status.activePhases.first {
                        status.state(for: $0) == .running
                    }
                    print("PROVISION \(running?.rawValue ?? (status.isComplete ? "complete" : "waiting"))")
                }
            )
            let donorElapsed = Self.seconds(donorStart.duration(to: .now))
            print("DONOR provisioned total=\(String(format: "%.1f", donorElapsed))s")
            check(true, "donor provisioned")

            let donorSSH = SSHClient(stateDirectory: donorState)
            let donorIdentity = try await guestIdentity(
                ssh: donorSSH,
                port: donorResult.forwardedPort
            )
            print("DONOR machine-id=\(donorIdentity.machineID)")
            print("DONOR host-key=\(donorIdentity.hostKey)")

            _ = try await donor.stageGoldenAccessKey()
            try await donor.scrubForGoldenCapture()
            let clean = try await donor.stop()
            check(clean, "donor clean stop")
            try await donor.captureGolden()

            let golden = try await GoldenImageStore(stateDirectory: donorState).lookup(
                inputs: GoldenImageStore.Inputs(installAgents: [], customScript: nil)
            )
            check(golden != nil, "golden artifacts exist")

            try await writeCloneSmokeSettings(state: cloneState)
            let clone = VMController(stateDirectory: cloneState, hostname: "clone-copy")
            let cloneResult = try await clone.start()
            print(
                "CLONE ready total=\(String(format: "%.1f", cloneResult.totalSeconds))s "
                    + "needsGrow=\(cloneResult.needsGrow)"
            )
            check(cloneResult.totalSeconds < 180, "clone ready in tens of seconds")

            let cloneSSH = SSHClient(stateDirectory: cloneState)
            let probe = try await cloneSSH.exec(
                host: "127.0.0.1",
                port: cloneResult.forwardedPort,
                command: "echo USER=$(whoami); echo HOST=$(hostname)",
                timeoutSeconds: 20
            )
            let probeOK = probe.status == 0
                && probe.stdout.contains("USER=vetro")
                && probe.stdout.contains("HOST=clone-copy")
            check(probeOK, "clone reachable with own key", probe.stdout)

            let cloneIdentity = try await guestIdentity(
                ssh: cloneSSH,
                port: cloneResult.forwardedPort
            )
            check(
                cloneIdentity.machineID != donorIdentity.machineID
                    && !cloneIdentity.machineID.isEmpty,
                "machine-id differs"
            )
            check(
                cloneIdentity.hostKey != donorIdentity.hostKey
                    && !cloneIdentity.hostKey.isEmpty,
                "host-key differs"
            )
            check(cloneIdentity.hostname == "clone-copy", "hostname correct")

            let status = try await clone.provisioningStatus()
            check(status.isComplete, "provision-status complete without re-provision")

            let cloneClean = try await clone.stop()
            check(cloneClean, "clone clean stop")
        } catch {
            check(false, "clone-smoke", "\(error)")
        }

        if failures.isEmpty {
            print("PASS clone-smoke")
            Darwin.exit(0)
        } else {
            print("FAIL clone-smoke (\(failures.joined(separator: ", ")))")
            Darwin.exit(1)
        }
    }

    /// Shared clone-smoke hardware/provision settings so A and B share a cache key.
    private static func writeCloneSmokeSettings(state: StateDirectory) async throws {
        let store = VMSettingsStore(stateDirectory: state)
        var settings = try await store.loadOrCreate()
        settings.installAgents = []
        settings.customScript = nil
        try await store.save(settings)
    }

    /// Reads machine-id, hostname, and the guest SSH host-key fingerprint.
    private static func guestIdentity(
        ssh: SSHClient,
        port: UInt16
    ) async throws -> (machineID: String, hostname: String, hostKey: String) {
        let result = try await ssh.exec(
            host: "127.0.0.1",
            port: port,
            command: """
            echo MACHINE=$(cat /etc/machine-id); \
            echo HOST=$(hostname); \
            echo HOSTKEY=$(ssh-keygen -l -f /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $2}')
            """,
            timeoutSeconds: 20
        )
        guard result.status == 0 else {
            throw CloneSmokeError.identityProbeFailed(result.status, result.stderr)
        }
        var machineID = ""
        var hostname = ""
        var hostKey = ""
        for line in result.stdout.split(whereSeparator: \.isNewline) {
            let text = String(line)
            if text.hasPrefix("MACHINE=") { machineID = String(text.dropFirst(8)) }
            if text.hasPrefix("HOST=") { hostname = String(text.dropFirst(5)) }
            if text.hasPrefix("HOSTKEY=") { hostKey = String(text.dropFirst(8)) }
        }
        return (machineID, hostname, hostKey)
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func diskReport() {
        let state = StateDirectory(vmID: benchID)
        var info = stat()
        guard lstat(state.diskURL.path, &info) == 0 else {
            fail("cannot stat \(state.diskURL.path)")
        }
        let logical = info.st_size
        let physical = Int64(info.st_blocks) * 512
        print("DISK logical=\(logical) physical=\(physical)")
    }

    private static func smoke() async {
        let state = StateDirectory(vmID: smokeID)
        let controller = VMController(stateDirectory: state, hostname: "smoke-test")
        do {
            let result = try await controller.start(
                imageDownloadProgress: { got, total in
                    print("DOWNLOAD \(got)/\(total.map(String.init) ?? "?")")
                }
            )
            print("READY ip=\(result.ipAddress)")

            let ssh = SSHClient(stateDirectory: state)
            let probe = try await ssh.exec(
                host: result.ipAddress,
                command: "echo \"USER=$(whoami) HOST=$(hostname)\"; uname -m; ls -ld /workspace 2>/dev/null || echo 'no /workspace yet'",
                timeoutSeconds: 20
            )
            print(probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines))

            let env = try await ssh.exec(
                host: result.ipAddress,
                command: "echo KEYTEST=$ANTHROPIC_API_KEY",
                environment: ["ANTHROPIC_API_KEY": "smoke-abc123"],
                timeoutSeconds: 20
            )
            print(env.stdout.trimmingCharacters(in: .whitespacesAndNewlines))

            let clean = try await controller.stop()
            print("SHUTDOWN clean=\(clean)")
            Darwin.exit(clean ? 0 : 1)
        } catch {
            fail("\(error)")
        }
    }

    private static func hold(_ arguments: [String]) async {
        let options: HoldOptions
        do {
            options = try HoldOptions.parse(arguments)
        } catch {
            fail("\(error)")
        }

        let state = StateDirectory(vmID: benchID)
        let controller = VMController(stateDirectory: state, hostname: "bench")
        do {
            await controller.setPortEventHandler { snapshot, added, removed, refused in
                func list(_ ports: [UInt16]?) -> String {
                    (ports ?? []).map(String.init).joined(separator: ", ")
                }
                print(
                    "PORTEVENT snapshot=[\(list(snapshot))] added=[\(list(added))] "
                        + "removed=[\(list(removed))] refused=[\(list(refused))]"
                )
                fflush(stdout)
            }

            if options.noAgents {
                try await writeEmptyAgentsIfNeeded(state: state)
            }

            let share = options.shareURL.map { (url: $0, tag: shareTag) }
            let result = try await controller.start(
                imageDownloadProgress: { got, total in
                    FileHandle.standardError.write(
                        Data("DOWNLOAD \(got)/\(total.map(String.init) ?? "?")\n".utf8)
                    )
                },
                sharedDirectory: share
            )

            _ = try await controller.waitForProvisioned(
                statusUpdate: { status in
                    let running = status.activePhases.first {
                        status.state(for: $0) == .running
                    }
                    let label = running?.rawValue
                        ?? (status.isComplete ? "complete" : "waiting")
                    FileHandle.standardError.write(Data("PROVISION \(label)\n".utf8))
                }
            )

            if options.shareURL != nil {
                let ssh = SSHClient(stateDirectory: state)
                let mount = try await ssh.exec(
                    host: "127.0.0.1",
                    port: result.forwardedPort,
                    command: "sudo mkdir -p /mnt/bench && sudo mount -t virtiofs bench /mnt/bench",
                    timeoutSeconds: 30
                )
                guard mount.status == 0 else {
                    let detail = [mount.stdout, mount.stderr]
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")
                    fail("virtiofs mount failed (status \(mount.status)): \(detail)")
                }
            }

            print(
                "HOLD ready ip=\(result.ipAddress) port=\(result.forwardedPort) "
                    + "key=\(state.sshPrivateKeyURL.path) state=\(state.rootURL.path)"
            )
            fflush(stdout)

            await waitForRelease(controller: controller)

            let clean = try await controller.stop()
            print("SHUTDOWN clean=\(clean)")
            Darwin.exit(clean ? 0 : 1)
        } catch {
            fail("\(error)")
        }
    }

    /// Writes `installAgents: []` before first boot so provision skips agent CLIs.
    private static func writeEmptyAgentsIfNeeded(state: StateDirectory) async throws {
        let store = VMSettingsStore(stateDirectory: state)
        var settings = try await store.loadOrCreate()
        guard !settings.firstBootCompleted else { return }
        settings.installAgents = []
        try await store.save(settings)
    }

    /// Blocks until stdin hits EOF or SIGTERM/SIGINT, then returns for a clean stop.
    /// Stdin lines `reclaim` / `restore` drive the idle memory balloon and
    /// print a `BALLOON …` marker; anything else is ignored.
    private static func waitForRelease(controller: VMController) async {
        let gate = ReleaseGate()
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        sigterm.setEventHandler { Task { await gate.fire() } }
        sigint.setEventHandler { Task { await gate.fire() } }
        sigterm.resume()
        sigint.resume()

        let stdinThread = Thread {
            while let line = readLine(strippingNewline: true) {
                switch line.trimmingCharacters(in: .whitespaces) {
                case "reclaim":
                    Task {
                        let target = try? await controller.reclaimIdleMemory()
                        print("BALLOON target=\(target.map { String($0 ?? 0) } ?? "none")")
                        fflush(stdout)
                    }
                case "restore":
                    Task {
                        try? await controller.restoreMemory()
                        print("BALLOON restored")
                        fflush(stdout)
                    }
                default:
                    break
                }
            }
            Task { await gate.fire() }
        }
        stdinThread.name = "vetro-hold-stdin"
        stdinThread.start()

        await gate.wait()
        sigterm.cancel()
        sigint.cancel()
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("ERROR \(message)\n".utf8))
        Darwin.exit(1)
    }
}

private enum CloneSmokeError: Error, CustomStringConvertible {
    case identityProbeFailed(Int32, String)

    var description: String {
        switch self {
        case let .identityProbeFailed(status, stderr):
            return "identity probe failed status=\(status) \(stderr)"
        }
    }
}

/// Parsed `hold` flags.
private struct HoldOptions {
    var noAgents = false
    var shareURL: URL?

    enum ParseError: Error, CustomStringConvertible {
        case missingSharePath
        case shareNotADirectory(String)
        case unexpectedArgument(String)

        var description: String {
            switch self {
            case .missingSharePath:
                return "hold --share requires a host directory"
            case let .shareNotADirectory(path):
                return "hold --share path is not a directory: \(path)"
            case let .unexpectedArgument(argument):
                return "hold: unexpected argument \(argument)"
            }
        }
    }

    static func parse(_ arguments: [String]) throws -> HoldOptions {
        var options = HoldOptions()
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            switch argument {
            case "--no-agents":
                options.noAgents = true
            case "--share":
                let next = arguments.index(after: index)
                guard next < arguments.endIndex else { throw ParseError.missingSharePath }
                let path = arguments[next]
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                      isDirectory.boolValue
                else {
                    throw ParseError.shareNotADirectory(path)
                }
                options.shareURL = URL(fileURLWithPath: path, isDirectory: true)
                index = next
            default:
                throw ParseError.unexpectedArgument(argument)
            }
            index = arguments.index(after: index)
        }
        return options
    }
}

/// Resumes a single waiter the first time stdin or a signal fires.
private actor ReleaseGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func wait() async {
        await withCheckedContinuation { continuation in
            if self.fired {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }

    func fire() {
        guard !fired else { return }
        fired = true
        continuation?.resume()
        continuation = nil
    }
}
