public import Foundation

/// Owns preparation, boot, readiness, and shutdown for one persistent Linux VM.
public actor VMController {
    /// The externally observable VM lifecycle.
    public enum State: Sendable, Equatable {
        /// No virtual machine is running.
        case stopped

        /// Host artifacts are being prepared or Virtualization.framework is starting.
        case starting

        /// The guest is running while address and SSH readiness are established.
        case provisioning

        /// The guest accepts key-based SSH commands.
        case ready

        /// A graceful or forced shutdown is in progress.
        case stopping

        /// Startup or runtime failed with a human-readable reason.
        case error(String)
    }

    /// Lifecycle failures raised directly by the controller.
    public enum Failure: Error, Sendable, Equatable {
        /// The requested operation was not valid from the current lifecycle state.
        case invalidState(State)

        /// Neither vsock nor the NAT DHCP leases produced a guest address in time.
        case ipResolutionTimedOut

        /// SSH did not become ready within the first- or subsequent-boot deadline.
        case sshReadinessTimedOut

        /// The VM stopped while startup was still establishing readiness.
        case guestStoppedDuringStartup

        /// Provisioning polling received an invalid interval or timeout.
        case invalidProvisioningWait(pollSeconds: Double, timeoutSeconds: Double)

        /// The guest status marker could not be fetched over SSH.
        case provisioningStatusCommandFailed(status: Int32, stderr: String)

        /// A guest phase failed; the associated text is the last 40 provisioning-log lines.
        case provisioningFailed(phase: VMProvisioningPhase, logTail: String)

        /// Provisioning did not finish before the requested deadline.
        case provisioningTimedOut(timeoutSeconds: Double)

        /// The update command failed without writing an update-phase failure marker.
        case agentUpdateCommandFailed(status: Int32, stderr: String)

        /// `update-agent` was asked for a name outside `{claude,codex,grok}`.
        case unknownAgent(String)

        /// Guest-side root filesystem expansion failed.
        case filesystemExpandFailed(status: Int32, output: String)

        /// Clone identity reset or golden guest command failed.
        case goldenGuestCommandFailed(status: Int32, output: String)
    }

    private enum StopObservation: Sendable {
        case guestStopped
        case failed(String)
        case timedOut
    }

    private let stateDirectory: StateDirectory
    private let hostname: String
    private let settingsStore: VMSettingsStore
    private let imageStore: ImageStore
    private let goldenStore: GoldenImageStore
    private let cloudInitSeed: CloudInitSeed
    private let configurationBuilder: VMConfigurationBuilder
    private let networkResolver: NetworkResolver
    private let sshClient: SSHClient
    private let clock: ContinuousClock

    private var lifecycleState: State = .stopped
    private var runtime: VZVirtualMachineRuntime?
    private var hookEventHandler: (@Sendable (UUID?, String, String) -> Void)?
    private var portEventHandler: (
        @Sendable (
            _ snapshot: [UInt16]?,
            _ added: [UInt16],
            _ removed: [UInt16],
            _ refused: [UInt16]
        ) -> Void
    )?
    private var hostMirrorAllowlist: Set<UInt16> = []
    private var activeIPAddress: String?
    private var activeForwardedPort: UInt16?
    private var runtimeMonitorTask: Task<Void, Never>?
    private var stateObservers: [UUID: AsyncStream<State>.Continuation] = [:]
    private var stopObservers: [UUID: AsyncStream<VZVirtualMachineRuntime.StopEvent>.Continuation] = [:]

    /// Creates the production M1 lifecycle stack rooted in one state directory.
    ///
    /// - Parameters:
    ///   - stateDirectory: The centralized persistent-state paths.
    ///   - hostname: The VM name slug injected through cloud-init.
    public init(stateDirectory: StateDirectory, hostname: String = "vetro") {
        self.stateDirectory = stateDirectory
        self.hostname = hostname
        self.settingsStore = VMSettingsStore(
            stateDirectory: stateDirectory,
            fileManager: FileManager()
        )
        self.imageStore = ImageStore(stateDirectory: stateDirectory)
        self.goldenStore = GoldenImageStore(stateDirectory: stateDirectory)
        self.cloudInitSeed = CloudInitSeed(
            stateDirectory: stateDirectory,
            fileManager: FileManager()
        )
        self.configurationBuilder = VMConfigurationBuilder(
            stateDirectory: stateDirectory,
            fileManager: FileManager()
        )
        self.networkResolver = NetworkResolver()
        self.sshClient = SSHClient(
            stateDirectory: stateDirectory,
            fileManager: FileManager()
        )
        self.clock = ContinuousClock()
    }

    deinit {
        runtimeMonitorTask?.cancel()
        for continuation in stateObservers.values {
            continuation.finish()
        }
        for continuation in stopObservers.values {
            continuation.finish()
        }
    }

    /// The latest lifecycle state.
    public var currentState: State {
        lifecycleState
    }

    /// The ready guest's current IPv4 address, or `nil` outside the ready state.
    public var ipAddress: String? {
        activeIPAddress
    }

    /// The active host loopback port forwarding SSH over virtio-vsock.
    public var forwardedPort: UInt16? {
        activeForwardedPort
    }

    /// The running desktop VM's display handle, or `nil` for headless VMs.
    public func displayHandle() -> VMDisplayHandle? {
        runtime?.displayHandle()
    }

    /// Starts a host loopback listener that forwards to `guestPort` inside the guest.
    public func startPortForward(guestPort: UInt16) async throws -> UInt16 {
        guard let runtime else {
            throw Failure.invalidState(lifecycleState)
        }
        return try await runtime.startPortForward(guestPort: guestPort)
    }

    /// Stops the host listener for `guestPort` if one is running.
    public func stopPortForward(guestPort: UInt16) async {
        await runtime?.stopPortForward(guestPort: guestPort)
    }

    /// Starts host listeners that bind `hostPort` (default: `guestPort`) and forward to `guestPort`.
    public func startMirror(guestPort: UInt16, hostPort: UInt16? = nil) async throws {
        guard let runtime else {
            throw Failure.invalidState(lifecycleState)
        }
        try await runtime.startMirror(guestPort: guestPort, hostPort: hostPort)
    }

    /// Stops the host mirror listeners for `guestPort` if any are running.
    public func stopMirror(guestPort: UInt16) async {
        await runtime?.stopMirror(guestPort: guestPort)
    }

    /// Routes guest hook lines from vsock 1025 into the host hook handler.
    public func setHookEventHandler(
        _ handler: (@Sendable (UUID?, String, String) -> Void)?
    ) {
        hookEventHandler = handler
        runtime?.setHookEventHandler(handler)
    }

    /// Routes guest port-event lines from vsock 1029 into the host handler.
    public func setPortEventHandler(
        _ handler: (
            @Sendable (
                _ snapshot: [UInt16]?,
                _ added: [UInt16],
                _ removed: [UInt16],
                _ refused: [UInt16]
            ) -> Void
        )?
    ) {
        portEventHandler = handler
        runtime?.setPortEventHandler(handler)
    }

    /// Replaces the host-loopback reverse-bridge allowlist used by vsock 1028.
    public func setHostMirrorAllowlist(_ ports: Set<UInt16>) {
        hostMirrorAllowlist = ports
        runtime?.setHostMirrorAllowlist(ports)
    }

    /// Creates an observation stream that begins with the current state.
    ///
    /// Each observer receives every later transition until its task is cancelled
    /// or this controller is released.
    ///
    /// - Returns: A buffered stream of ``State`` snapshots.
    public func stateUpdates() -> AsyncStream<State> {
        let identifier = UUID()
        let pair = AsyncStream<State>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        stateObservers[identifier] = pair.continuation
        pair.continuation.yield(lifecycleState)
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStateObserver(identifier) }
        }
        return pair.stream
    }

    /// Prepares persistent artifacts, boots the guest, and waits for SSH readiness.
    ///
    /// The first successful boot has a 90-second deadline. Later boots use a
    /// 20-second deadline recorded through `firstBootCompleted` in `vm.json`.
    ///
    /// - Parameters:
    ///   - imageDownloadProgress: Receives downloaded and expected raw-image bytes.
    ///   - imagePreparationUpdate: Receives ordered shared-image preparation stages.
    ///   - sharedDirectory: Optional host directory attached as a writable virtiofs
    ///     share. `nil` leaves the configuration's directory-sharing devices empty.
    /// - Returns: The ready address and stage timings.
    /// - Throws: A preparation, Virtualization.framework, timeout, or SSH error.
    public func start(
        imageDownloadProgress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in },
        imagePreparationUpdate: @escaping @Sendable (VMImagePreparationState) -> Void = { _ in },
        sharedDirectory: (url: URL, tag: String)? = nil
    ) async throws -> VMStartResult {
        guard runtime == nil,
              lifecycleState == .stopped || isErrorState(lifecycleState)
        else {
            throw Failure.invalidState(lifecycleState)
        }

        transition(to: .starting)
        let totalStart = clock.now
        var startedRuntime: VZVirtualMachineRuntime?

        do {
            var settings = try await settingsStore.loadOrCreate()
            try Task.checkCancellation()

            let imageStart = clock.now
            let baseImageURL = try await imageStore.ensureBaseImage(
                progress: imageDownloadProgress,
                stateUpdate: imagePreparationUpdate
            )
            try Task.checkCancellation()
            let imageReadySeconds = Self.seconds(imageStart.duration(to: clock.now))

            let diskStart = clock.now
            let diskPrepared = try await prepareDisk(
                settings: settings,
                baseImageURL: baseImageURL
            )
            let needsGrow = diskPrepared.needsGrow
            let pendingCloneInit = diskPrepared.pendingCloneInit
            let cloneAccessIdentity = diskPrepared.cloneAccessIdentity
            try Task.checkCancellation()
            let diskReadySeconds = Self.seconds(diskStart.duration(to: clock.now))

            let seedStart = clock.now
            let publicKey = try await sshClient.ensureKeypair()
            _ = try cloudInitSeed.ensureSeed(
                publicKey: publicKey,
                hostname: hostname,
                installAgents: settings.installAgents,
                customScript: settings.customScript,
                desktopEnabled: settings.desktopEnabled
            )
            try Task.checkCancellation()
            let seedReadySeconds = Self.seconds(seedStart.duration(to: clock.now))

            try Task.checkCancellation()
            let configuration = try configurationBuilder.build(
                settings: settings,
                sharedDirectory: sharedDirectory
            )
            try Task.checkCancellation()
            let runtime = VZVirtualMachineRuntime(
                configuration: configuration,
                useMainQueue: settings.desktopEnabled
            )
            runtime.setHookEventHandler(hookEventHandler)
            runtime.setPortEventHandler(portEventHandler)
            runtime.setHostMirrorAllowlist(hostMirrorAllowlist)
            self.runtime = runtime
            startedRuntime = runtime

            let bootStart = clock.now
            let timeout: Duration = settings.firstBootCompleted
                ? .seconds(20)
                : .seconds(90)
            let deadline = bootStart.advanced(by: timeout)
            try Task.checkCancellation()
            try await runtime.start()
            try Task.checkCancellation()
            let forwardedPort = try await runtime.startSSHForwarder()
            activeForwardedPort = forwardedPort
            try Task.checkCancellation()
            beginMonitoring(runtime)
            transition(to: .provisioning)
            trace(
                "guest started; forwarding ssh on 127.0.0.1:\(forwardedPort); "
                    + "resolving IP (timeout \(timeout))"
            )

            let ipAddress = try await resolveIPAddress(
                runtime: runtime,
                macAddress: settings.macAddress,
                deadline: deadline
            )
            let ipReadyTime = clock.now
            let bootToIPSeconds = Self.seconds(bootStart.duration(to: ipReadyTime))
            trace("IP resolved \(ipAddress); waiting for ssh over forwarded loopback")
            if pendingCloneInit, let cloneAccessIdentity {
                let cloneDeadline = clock.now.advanced(by: .seconds(20))
                try await waitForSSH(
                    port: forwardedPort,
                    deadline: cloneDeadline,
                    identityFile: cloneAccessIdentity
                )
                try await resetClonedIdentity(
                    port: forwardedPort,
                    publicKey: publicKey,
                    identityFile: cloneAccessIdentity
                )
                // The reset script restarts ssh after 1s; wait for the new
                // host key before the per-VM probe can pin the donor's key.
                try await clock.sleep(for: .seconds(2))
                try? FileManager().removeItem(at: stateDirectory.knownHostsURL)
                trace("clone identity reset; waiting for per-VM ssh")
            }
            try await waitForSSH(port: forwardedPort, deadline: deadline)
            trace("ssh ready")
            let sshReadyTime = clock.now
            let ipToSSHReadySeconds = Self.seconds(ipReadyTime.duration(to: sshReadyTime))

            guard self.runtime === runtime else {
                throw Failure.guestStoppedDuringStartup
            }
            if !settings.firstBootCompleted {
                settings.firstBootCompleted = true
                try await settingsStore.save(settings)
            }

            activeIPAddress = ipAddress
            transition(to: .ready)
            return VMStartResult(
                ipAddress: ipAddress,
                forwardedPort: forwardedPort,
                imageReadySeconds: imageReadySeconds,
                diskReadySeconds: diskReadySeconds,
                seedReadySeconds: seedReadySeconds,
                bootToIPSeconds: bootToIPSeconds,
                ipToSSHReadySeconds: ipToSSHReadySeconds,
                totalSeconds: Self.seconds(totalStart.duration(to: clock.now)),
                needsGrow: needsGrow
            )
        } catch {
            runtimeMonitorTask?.cancel()
            runtimeMonitorTask = nil
            var retainedRuntime: VZVirtualMachineRuntime?
            if let startedRuntime, !(await startedRuntime.isStopped()) {
                do {
                    try await startedRuntime.forceStop()
                } catch {
                    if !(await startedRuntime.isStopped()) {
                        retainedRuntime = startedRuntime
                        trace("startup unwind retained a VM after force-stop failure: \(error)")
                    }
                }
            }
            runtime = retainedRuntime
            if let retainedRuntime {
                beginMonitoring(retainedRuntime)
            }
            activeIPAddress = nil
            activeForwardedPort = nil
            transition(to: .error(String(describing: error)))
            throw error
        }
    }

    /// Fetches and parses the guest's persistent provisioning marker file.
    ///
    /// A connected guest with no marker file is represented by an all-pending
    /// status. Calling this method without a ready guest address is invalid.
    ///
    /// - Returns: The latest parsed provisioning or agent-update snapshot.
    /// - Throws: ``Failure/invalidState(_:)`` or an SSH/process failure.
    public func provisioningStatus() async throws -> VMProvisioningStatus {
        guard activeIPAddress != nil, let activeForwardedPort else {
            throw Failure.invalidState(lifecycleState)
        }
        let result = try await sshClient.exec(
            host: "127.0.0.1",
            port: activeForwardedPort,
            command: "if [ -r /var/lib/vetro/provision-status ]; then cat /var/lib/vetro/provision-status; fi",
            timeoutSeconds: 10
        )
        guard result.status == 0 else {
            throw Failure.provisioningStatusCommandFailed(
                status: result.status,
                stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return VMProvisioningStatus.parse(markerText: result.stdout)
    }

    /// Polls the guest marker file until provisioning completes or fails.
    ///
    /// The first probe is immediate. A phase failure includes the last 40 lines
    /// of `/var/log/vetro-provision.log` in the thrown error.
    ///
    /// - Parameters:
    ///   - pollSeconds: Delay between marker probes; defaults to five seconds.
    ///   - timeoutSeconds: Overall monotonic deadline; defaults to 30 minutes.
    ///   - statusUpdate: Receives every parsed snapshot, including terminal states.
    /// - Returns: The completed provisioning snapshot.
    /// - Throws: A polling, SSH, timeout, or phase-failure error.
    public func waitForProvisioned(
        pollSeconds: Double = 5,
        timeoutSeconds: Double = 1_800,
        statusUpdate: @escaping @Sendable (VMProvisioningStatus) -> Void = { _ in }
    ) async throws -> VMProvisioningStatus {
        guard pollSeconds > 0, timeoutSeconds >= 0 else {
            throw Failure.invalidProvisioningWait(
                pollSeconds: pollSeconds,
                timeoutSeconds: timeoutSeconds
            )
        }

        let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
        var consecutivePollFailures = 0
        while true {
            try Task.checkCancellation()
            // Transient poll failures (ssh timing out under first-boot apt
            // load, sshd restarting) must not abort a provisioning run that
            // is still making progress inside the guest. Only a long streak
            // of unreachability, an explicit phase failure, or the overall
            // deadline ends the wait.
            var status: VMProvisioningStatus?
            do {
                status = try await provisioningStatus()
                consecutivePollFailures = 0
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                consecutivePollFailures += 1
                if consecutivePollFailures >= 30 {
                    throw error
                }
            }
            if let status {
                statusUpdate(status)
                if status.isComplete {
                    return status
                }
                if let failedPhase = status.failedPhase {
                    throw await provisioningFailure(for: failedPhase)
                }
            }

            let now = clock.now
            guard now < deadline else {
                throw Failure.provisioningTimedOut(timeoutSeconds: timeoutSeconds)
            }
            try await clock.sleep(
                for: min(.seconds(pollSeconds), now.duration(to: deadline))
            )
        }
    }

    /// Refreshes all installed agent CLIs through the guest provisioning script.
    ///
    /// - Returns: The authoritative update snapshot written by the guest.
    /// - Throws: An SSH/process failure or a command failure without update markers.
    public func updateAgents() async throws -> VMProvisioningStatus {
        guard activeIPAddress != nil, let activeForwardedPort else {
            throw Failure.invalidState(lifecycleState)
        }
        let commandResult = try await sshClient.exec(
            host: "127.0.0.1",
            port: activeForwardedPort,
            command: "sudo /usr/local/lib/vetro/provision.sh update-agents",
            timeoutSeconds: 1_800
        )
        let status = try await provisioningStatus()
        if commandResult.status == 0
            || (status.operation == .update && status.failedPhase != nil)
        {
            return status
        }
        throw Failure.agentUpdateCommandFailed(
            status: commandResult.status,
            stderr: commandResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Installs the XFCE desktop live by running the `desktop` provision phase.
    ///
    /// Used when the desktop toggle is enabled on an already-provisioned VM;
    /// the graphics hardware still attaches on the next restart.
    ///
    /// - Returns: The authoritative provisioning snapshot written by the guest.
    /// - Throws: An SSH/process failure or a command failure without a marker.
    @discardableResult
    public func installDesktop() async throws -> VMProvisioningStatus {
        guard activeIPAddress != nil, let activeForwardedPort else {
            throw Failure.invalidState(lifecycleState)
        }
        let commandResult = try await sshClient.exec(
            host: "127.0.0.1",
            port: activeForwardedPort,
            command: "sudo /usr/local/lib/vetro/provision.sh desktop",
            timeoutSeconds: 1_800
        )
        let status = try await provisioningStatus()
        if commandResult.status == 0 || status.failedPhase != nil {
            return status
        }
        throw Failure.agentUpdateCommandFailed(
            status: commandResult.status,
            stderr: commandResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Refreshes one installed agent CLI through the guest provisioning script.
    ///
    /// - Parameter name: An agent name in `{claude,codex,grok}`.
    /// - Returns: The authoritative update snapshot written by the guest.
    /// - Throws: ``Failure/unknownAgent(_:)``, an SSH/process failure, or a
    ///   command failure without update markers.
    public func updateAgent(named name: String) async throws -> VMProvisioningStatus {
        guard Self.knownAgents.contains(name) else {
            throw Failure.unknownAgent(name)
        }
        guard activeIPAddress != nil, let activeForwardedPort else {
            throw Failure.invalidState(lifecycleState)
        }
        let commandResult = try await sshClient.exec(
            host: "127.0.0.1",
            port: activeForwardedPort,
            command: "sudo /usr/local/lib/vetro/provision.sh update-agent \(name)",
            timeoutSeconds: 1_800
        )
        let status = try await provisioningStatus()
        if commandResult.status == 0
            || (status.operation == .update && status.failedPhase != nil)
        {
            return status
        }
        throw Failure.agentUpdateCommandFailed(
            status: commandResult.status,
            stderr: commandResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Returns a bounded tail of the guest custom-setup script log.
    ///
    /// A missing log file yields an empty string.
    ///
    /// - Parameter maxBytes: Maximum number of trailing bytes to read.
    /// - Returns: The log tail as UTF-8 text.
    /// - Throws: ``Failure/invalidState(_:)`` or an SSH/process failure.
    public func customScriptLog(maxBytes: Int) async throws -> String {
        guard activeIPAddress != nil, let activeForwardedPort else {
            throw Failure.invalidState(lifecycleState)
        }
        let bounded = max(0, maxBytes)
        let result = try await sshClient.exec(
            host: "127.0.0.1",
            port: activeForwardedPort,
            command: """
            if [ -r /var/lib/vetro/custom-script.log ]; then \
            tail -c \(bounded) /var/lib/vetro/custom-script.log; fi
            """,
            timeoutSeconds: 10
        )
        guard result.status == 0 else {
            throw Failure.provisioningStatusCommandFailed(
                status: result.status,
                stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result.stdout
    }

    /// Returns whether a usable golden already exists for this VM's provision inputs.
    public func hasGolden() async -> Bool {
        guard let settings = try? await settingsStore.loadOrCreate() else { return false }
        return (try? await goldenStore.lookup(inputs: GoldenImageStore.Inputs(settings))) != nil
    }

    /// Stages a golden-access key and appends it to the running guest's authorized_keys.
    ///
    /// - Returns: The golden cache key the donor should capture on the next clean stop.
    /// - Throws: ``Failure/invalidState(_:)``, a golden-store error, or
    ///   ``Failure/goldenGuestCommandFailed``.
    @discardableResult
    public func stageGoldenAccessKey() async throws -> String {
        guard activeIPAddress != nil, let activeForwardedPort else {
            throw Failure.invalidState(lifecycleState)
        }
        let settings = try await settingsStore.loadOrCreate()
        let staged = try await goldenStore.stageAccessKey(inputs: GoldenImageStore.Inputs(settings))
        let result = try await sshClient.exec(
            host: "127.0.0.1",
            port: activeForwardedPort,
            command: Self.appendAuthorizedKeyCommand(publicKey: staged.publicKey),
            timeoutSeconds: 15
        )
        guard result.status == 0 else {
            throw Failure.goldenGuestCommandFailed(
                status: result.status,
                output: Self.combinedProcessOutput(result)
            )
        }
        return staged.cacheKey
    }

    /// Captures this stopped VM's disk as a golden for its current provision inputs.
    ///
    /// - Throws: ``Failure/invalidState(_:)`` when a runtime is still attached,
    ///   or a golden-store error.
    public func captureGolden() async throws {
        guard runtime == nil else {
            throw Failure.invalidState(lifecycleState)
        }
        let settings = try await settingsStore.loadOrCreate()
        let inputs = GoldenImageStore.Inputs(settings)
        let cacheKey = try await goldenStore.cacheKey(for: inputs)
        let manifest = try await goldenStore.makeManifest(
            inputs: inputs,
            cacheKey: cacheKey,
            donorDiskSizeGB: settings.diskSizeGB
        )
        try await goldenStore.capture(
            cacheKey: cacheKey,
            donorDiskURL: stateDirectory.diskURL,
            manifest: manifest
        )
    }

    /// Deletes guest home paths listed in `/var/lib/vetro/golden-exclude`.
    ///
    /// Absolute paths and any path containing `..` are ignored.
    ///
    /// - Throws: ``Failure/invalidState(_:)`` or an SSH/process failure.
    public func scrubForGoldenCapture() async throws {
        guard activeIPAddress != nil, let activeForwardedPort else {
            throw Failure.invalidState(lifecycleState)
        }
        let listed = try await sshClient.exec(
            host: "127.0.0.1",
            port: activeForwardedPort,
            command: "if [ -r /var/lib/vetro/golden-exclude ]; then cat /var/lib/vetro/golden-exclude; fi",
            timeoutSeconds: 15
        )
        guard listed.status == 0 else {
            throw Failure.goldenGuestCommandFailed(
                status: listed.status,
                output: Self.combinedProcessOutput(listed)
            )
        }
        let paths = listed.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { GoldenExcludePath.validated(String($0)) }
        guard !paths.isEmpty else { return }

        let removals = paths.map { path in
            "rm -rf \(Self.posixSingleQuoted("/home/vetro/\(path)"))"
        }.joined(separator: "\n")
        // Cloud-init pins netplan to the donor's MAC; clones boot with their
        // own MAC and would never get DHCP. Rewrite to name-based matching so
        // the captured disk is portable (cloud-init is disabled, so nothing
        // regenerates the pinned config).
        let netplanNormalize = """
        if [ -f /etc/netplan/50-cloud-init.yaml ]; then
          printf '%s\\n' \
            'network:' \
            '  version: 2' \
            '  ethernets:' \
            '    enp0s1:' \
            '      dhcp4: true' \
            '      dhcp6: true' \
            > /etc/netplan/50-cloud-init.yaml
          chmod 600 /etc/netplan/50-cloud-init.yaml
        fi
        """
        let result = try await sshClient.exec(
            host: "127.0.0.1",
            port: activeForwardedPort,
            command: "sudo bash -c \(Self.posixSingleQuoted("set -e\n\(removals)\n\(netplanNormalize)\n"))",
            timeoutSeconds: 30
        )
        guard result.status == 0 else {
            throw Failure.goldenGuestCommandFailed(
                status: result.status,
                output: Self.combinedProcessOutput(result)
            )
        }
    }

    /// Grows the guest root partition and ext4 filesystem to fill the block device.
    ///
    /// The host must already have enlarged `disk.img`. `growpart` reporting
    /// `NOCHANGE` is treated as success.
    ///
    /// - Returns: Combined `growpart` and `resize2fs` output.
    /// - Throws: ``Failure/invalidState(_:)`` or ``Failure/filesystemExpandFailed``.
    public func expandRootFilesystem() async throws -> String {
        guard activeIPAddress != nil, let activeForwardedPort else {
            throw Failure.invalidState(lifecycleState)
        }
        let result = try await sshClient.exec(
            host: "127.0.0.1",
            port: activeForwardedPort,
            command: Self.expandRootFilesystemCommand,
            timeoutSeconds: 120
        )
        if result.status == 0 {
            return Self.combinedProcessOutput(result)
        }
        throw Failure.filesystemExpandFailed(
            status: result.status,
            output: Self.combinedProcessOutput(result)
        )
    }

    /// Returns host memory to macOS while the guest is idle.
    ///
    /// Drops guest page caches, then inflates the memory balloon down to the
    /// guest's actual usage plus headroom (never below 1 GiB). The guest keeps
    /// running; call ``restoreMemory()`` before new load.
    ///
    /// - Returns: The balloon target in bytes, or `nil` when usage could not be
    ///   read and the balloon was left alone.
    /// - Throws: ``Failure/invalidState(_:)`` or an SSH/process failure.
    @discardableResult
    public func reclaimIdleMemory() async throws -> UInt64? {
        guard activeIPAddress != nil, let activeForwardedPort, let runtime else {
            throw Failure.invalidState(lifecycleState)
        }
        let result = try await sshClient.exec(
            host: "127.0.0.1",
            port: activeForwardedPort,
            command: """
            sync && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null \
            && awk '/MemTotal|MemAvailable/ {print $1 $2}' /proc/meminfo
            """,
            timeoutSeconds: 30
        )
        guard result.status == 0 else { return nil }
        var totalKB: UInt64?
        var availableKB: UInt64?
        for line in result.stdout.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("MemTotal:") { totalKB = UInt64(line.dropFirst(9)) }
            if line.hasPrefix("MemAvailable:") { availableKB = UInt64(line.dropFirst(13)) }
        }
        guard let totalKB, let availableKB, availableKB <= totalKB else { return nil }
        let usedBytes = (totalKB - availableKB) * 1_024
        let floorBytes: UInt64 = 1_024 * 1_024 * 1_024
        let headroomBytes: UInt64 = 384 * 1_024 * 1_024
        let settings = try await settingsStore.loadOrCreate()
        let configuredBytes = UInt64(settings.memoryMB) * 1_024 * 1_024
        let target = min(configuredBytes, max(floorBytes, usedBytes + headroomBytes))
        runtime.setMemoryBalloonTarget(bytes: target)
        return target
    }

    /// Deflates the balloon so the guest can use its full configured memory again.
    public func restoreMemory() async throws {
        guard let runtime else {
            throw Failure.invalidState(lifecycleState)
        }
        let settings = try await settingsStore.loadOrCreate()
        runtime.setMemoryBalloonTarget(bytes: UInt64(settings.memoryMB) * 1_024 * 1_024)
    }

    /// Requests guest poweroff and force-stops only after a 15-second grace period.
    ///
    /// - Returns: `true` when the VZ delegate observed guest shutdown within the grace period;
    ///   otherwise `false` after a failed or forced stop.
    /// - Throws: A force-stop Virtualization.framework error.
    public func stop() async throws -> Bool {
        if lifecycleState == .stopped {
            activeIPAddress = nil
            activeForwardedPort = nil
            return true
        }
        guard let runtime else {
            activeIPAddress = nil
            activeForwardedPort = nil
            transition(to: .stopped)
            return true
        }

        transition(to: .stopping)
        let (observerID, events) = makeStopObserver()
        if await runtime.isStopped() {
            removeStopObserver(observerID)
            finishStoppedRuntime(runtime)
            return true
        }

        if let activeForwardedPort {
            _ = try? await sshClient.exec(
                host: "127.0.0.1",
                port: activeForwardedPort,
                command: "sudo poweroff",
                timeoutSeconds: 10
            )
        }

        let observation = await Self.waitForStopEvent(
            events,
            timeout: .seconds(15),
            clock: clock
        )
        removeStopObserver(observerID)

        switch observation {
        case .guestStopped:
            finishStoppedRuntime(runtime)
            return true
        case let .failed(reason):
            self.runtime = nil
            activeIPAddress = nil
            activeForwardedPort = nil
            transition(to: .error(reason))
            return false
        case .timedOut:
            do {
                try await runtime.forceStop()
                finishStoppedRuntime(runtime)
                return false
            } catch {
                activeIPAddress = nil
                activeForwardedPort = nil
                transition(to: .error(String(describing: error)))
                throw error
            }
        }
    }

    /// Races the guest's vsock report against the host NAT lease resolver.
    private func resolveIPAddress(
        runtime: VZVirtualMachineRuntime,
        macAddress: String,
        deadline: ContinuousClock.Instant
    ) async throws -> String {
        let now = clock.now
        guard now < deadline else { throw Failure.ipResolutionTimedOut }
        let remaining = now.duration(to: deadline)
        let resolver = networkResolver
        let clock = clock
        let readinessEvents = runtime.readinessEvents

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                for await ipAddress in readinessEvents {
                    try Task.checkCancellation()
                    return ipAddress
                }
                throw Failure.ipResolutionTimedOut
            }
            group.addTask {
                guard let ipAddress = try await resolver.resolve(
                    macAddress: macAddress,
                    timeout: remaining
                ) else {
                    throw Failure.ipResolutionTimedOut
                }
                return ipAddress
            }
            group.addTask {
                try await clock.sleep(for: remaining)
                throw Failure.ipResolutionTimedOut
            }

            guard let first = try await group.next() else {
                throw Failure.ipResolutionTimedOut
            }
            group.cancelAll()
            return first
        }
    }

    /// Prepares the writable disk from a golden when eligible, otherwise the base image.
    private func prepareDisk(
        settings: VMSettings,
        baseImageURL: URL
    ) async throws -> (
        needsGrow: Bool,
        pendingCloneInit: Bool,
        cloneAccessIdentity: URL?
    ) {
        let fileManager = FileManager()
        let diskExists = fileManager.fileExists(atPath: stateDirectory.diskURL.path)
        if !diskExists, !settings.firstBootCompleted {
            do {
                if let golden = try await goldenStore.lookup(
                    inputs: GoldenImageStore.Inputs(settings)
                ) {
                    let cloned = try await goldenStore.cloneDisk(
                        from: golden,
                        into: stateDirectory,
                        targetDiskSizeGB: settings.diskSizeGB
                    )
                    switch cloned {
                    case let .cloned(needsGrow):
                        return (
                            needsGrow: needsGrow,
                            pendingCloneInit: true,
                            cloneAccessIdentity: golden.accessPrivateKeyURL
                        )
                    case .ineligible:
                        break
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                trace("golden lookup/clone failed; falling back to base image: \(error)")
            }
        }
        _ = try await imageStore.ensureDisk(from: baseImageURL, settings: settings)
        return (needsGrow: false, pendingCloneInit: false, cloneAccessIdentity: nil)
    }

    /// Resets hostname, machine-id, host keys, and authorized_keys on a clone.
    private func resetClonedIdentity(
        port: UInt16,
        publicKey: String,
        identityFile: URL
    ) async throws {
        let result = try await sshClient.exec(
            host: "127.0.0.1",
            port: port,
            command: Self.cloneIdentityResetCommand(hostname: hostname, publicKey: publicKey),
            timeoutSeconds: 20,
            identityFile: identityFile
        )
        guard result.status == 0 else {
            throw Failure.goldenGuestCommandFailed(
                status: result.status,
                output: Self.combinedProcessOutput(result)
            )
        }
    }

    /// Polls the exact `ssh true` acceptance probe until the shared boot deadline.
    private func waitForSSH(
        port: UInt16,
        deadline: ContinuousClock.Instant,
        identityFile: URL? = nil
    ) async throws {
        while clock.now < deadline {
            try Task.checkCancellation()
            let remaining = clock.now.duration(to: deadline)
            let commandTimeout = max(
                1,
                min(5, Int(Self.seconds(remaining).rounded(.up)))
            )
            if let result = try? await sshClient.exec(
                host: "127.0.0.1",
                port: port,
                command: "true",
                timeoutSeconds: commandTimeout,
                identityFile: identityFile
            ) {
                if result.status == 0 { return }
                let reason = result.stderr
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: "\n")
                    .last.map(String.init) ?? "no stderr"
                trace("ssh probe status \(result.status): \(reason)")
            } else {
                trace("ssh probe threw")
            }

            let now = clock.now
            guard now < deadline else { break }
            // M1 requires an explicit one-second SSH readiness polling cadence.
            try await clock.sleep(for: min(.seconds(1), now.duration(to: deadline)))
        }
        throw Failure.sshReadinessTimedOut
    }

    /// Builds a phase-failure error with a best-effort remote log tail.
    private func provisioningFailure(
        for phase: VMProvisioningPhase
    ) async -> Failure {
        guard activeIPAddress != nil, let activeForwardedPort else {
            return .provisioningFailed(phase: phase, logTail: "")
        }
        let result = try? await sshClient.exec(
            host: "127.0.0.1",
            port: activeForwardedPort,
            command: "tail -n 40 /var/log/vetro-provision.log",
            timeoutSeconds: 10
        )
        let logTail: String
        if let result, result.status == 0 {
            logTail = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            logTail = ""
        }
        return .provisioningFailed(phase: phase, logTail: logTail)
    }

    /// Starts the single consumer of VZ delegate stop events.
    private func beginMonitoring(_ runtime: VZVirtualMachineRuntime) {
        runtimeMonitorTask?.cancel()
        runtimeMonitorTask = Task { [weak self] in
            for await event in runtime.stopEvents {
                guard !Task.isCancelled else { return }
                await self?.handleRuntimeStop(event, runtime: runtime)
                return
            }
        }
    }

    /// Publishes unexpected and requested guest-stop callbacks to lifecycle consumers.
    private func handleRuntimeStop(
        _ event: VZVirtualMachineRuntime.StopEvent,
        runtime stoppedRuntime: VZVirtualMachineRuntime
    ) {
        guard runtime === stoppedRuntime else { return }
        for continuation in stopObservers.values {
            continuation.yield(event)
        }
        runtime = nil
        activeIPAddress = nil
        activeForwardedPort = nil
        runtimeMonitorTask = nil

        switch event {
        case .guestStopped:
            if !isErrorState(lifecycleState) {
                transition(to: .stopped)
            }
        case let .failed(reason):
            transition(to: .error(reason))
        }
    }

    /// Allocates a one-shot broadcast subscriber for graceful-stop observation.
    private func makeStopObserver() -> (
        UUID,
        AsyncStream<VZVirtualMachineRuntime.StopEvent>
    ) {
        let identifier = UUID()
        let pair = AsyncStream<VZVirtualMachineRuntime.StopEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        stopObservers[identifier] = pair.continuation
        return (identifier, pair.stream)
    }

    /// Races one VZ stop notification against the shutdown grace period.
    private nonisolated static func waitForStopEvent(
        _ events: AsyncStream<VZVirtualMachineRuntime.StopEvent>,
        timeout: Duration,
        clock: ContinuousClock
    ) async -> StopObservation {
        await withTaskGroup(of: StopObservation.self) { group in
            group.addTask {
                for await event in events {
                    switch event {
                    case .guestStopped:
                        return .guestStopped
                    case let .failed(reason):
                        return .failed(reason)
                    }
                }
                return .timedOut
            }
            group.addTask {
                try? await clock.sleep(for: timeout)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
    }

    /// Releases references after either graceful or destructive stop.
    private func finishStoppedRuntime(_ stoppedRuntime: VZVirtualMachineRuntime) {
        if runtime === stoppedRuntime {
            runtime = nil
        }
        runtimeMonitorTask?.cancel()
        runtimeMonitorTask = nil
        activeIPAddress = nil
        activeForwardedPort = nil
        transition(to: .stopped)
    }

    /// Publishes one lifecycle transition to all active observers.
    private func transition(to newState: State) {
        lifecycleState = newState
        trace("state -> \(newState)")
        for continuation in stateObservers.values {
            continuation.yield(newState)
        }
    }

    /// Appends a timestamped diagnostic line to `<state-dir>/controller.log`.
    /// Never logs credentials or command output; stage names only.
    func trace(_ message: String) {
        let line = "\(Date.now.ISO8601Format()) \(message)\n"
        let url = stateDirectory.rootURL.appendingPathComponent(
            "controller.log",
            isDirectory: false
        )
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// Removes a terminated lifecycle subscriber.
    private func removeStateObserver(_ identifier: UUID) {
        stateObservers.removeValue(forKey: identifier)
    }

    /// Finishes and removes one graceful-stop subscriber.
    private func removeStopObserver(_ identifier: UUID) {
        stopObservers.removeValue(forKey: identifier)?.finish()
    }

    /// Recognizes the associated-value error case without discarding its reason.
    private func isErrorState(_ state: State) -> Bool {
        if case .error = state { return true }
        return false
    }

    /// Converts Swift's attosecond duration representation for plain CLI output.
    private nonisolated static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static let knownAgents: Set<String> = ["claude", "codex", "grok"]

    /// One root script that unique-ifies a cloned guest before the per-VM SSH wait.
    private static func cloneIdentityResetCommand(hostname: String, publicKey: String) -> String {
        let script = """
        set -e
        hostnamectl set-hostname \(posixSingleQuoted(hostname))
        if grep -qE '^127\\.0\\.1\\.1[[:space:]]' /etc/hosts; then
          sed -i -E 's/^127\\.0\\.1\\.1[[:space:]].*/127.0.1.1\\t\(hostname)/' /etc/hosts
        else
          printf '127.0.1.1\\t%s\\n' \(posixSingleQuoted(hostname)) >> /etc/hosts
        fi
        rm -f /etc/machine-id /var/lib/dbus/machine-id
        systemd-machine-id-setup
        ln -sf /etc/machine-id /var/lib/dbus/machine-id
        rm -f /etc/ssh/ssh_host_*
        ssh-keygen -A
        mkdir -p /home/vetro/.ssh
        printf '%s\\n' \(posixSingleQuoted(publicKey)) > /home/vetro/.ssh/authorized_keys
        chown vetro:vetro /home/vetro/.ssh/authorized_keys
        chmod 600 /home/vetro/.ssh/authorized_keys
        ( sleep 1; systemctl restart ssh ) >/dev/null 2>&1 &
        """
        return "sudo bash -c \(posixSingleQuoted(script))"
    }

    /// Appends one OpenSSH public key to the guest vetro authorized_keys file.
    private static func appendAuthorizedKeyCommand(publicKey: String) -> String {
        let script = """
        set -e
        mkdir -p /home/vetro/.ssh
        touch /home/vetro/.ssh/authorized_keys
        if ! grep -qxF \(posixSingleQuoted(publicKey)) /home/vetro/.ssh/authorized_keys; then
          printf '%s\\n' \(posixSingleQuoted(publicKey)) >> /home/vetro/.ssh/authorized_keys
        fi
        chown vetro:vetro /home/vetro/.ssh /home/vetro/.ssh/authorized_keys
        chmod 700 /home/vetro/.ssh
        chmod 600 /home/vetro/.ssh/authorized_keys
        """
        return "sudo bash -c \(posixSingleQuoted(script))"
    }

    /// POSIX single-quotes a value so it can be interpolated into a shell command.
    private static func posixSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static let expandRootFilesystemCommand = """
    set +e
    root="$(findmnt -no SOURCE /)"
    out=""
    part="$(lsblk -ndo PARTN "${root}" 2>/dev/null || true)"
    if [ -n "${part}" ]; then
      disk="/dev/$(lsblk -no PKNAME "${root}")"
      gp="$(sudo growpart "${disk}" "${part}" 2>&1)"
      rc=$?
      out="${out}${gp}"$'\\n'
      if [ "${rc}" -ne 0 ] && ! printf '%s\\n' "${gp}" | grep -q NOCHANGE; then
        printf '%s' "${out}"
        exit "${rc}"
      fi
    fi
    rs="$(sudo resize2fs "${root}" 2>&1)"
    rc=$?
    out="${out}${rs}"$'\\n'
    printf '%s' "${out}"
    exit "${rc}"
    """

    private nonisolated static func combinedProcessOutput(
        _ result: (status: Int32, stdout: String, stderr: String)
    ) -> String {
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if stdout.isEmpty { return stderr }
        if stderr.isEmpty { return stdout }
        return stdout + "\n" + stderr
    }
}
