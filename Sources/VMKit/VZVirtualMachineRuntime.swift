import Darwin
import Foundation
import Virtualization

/// Queue-confined bridge around Virtualization.framework's callback and delegate APIs.
// Safety: every VZ object and mutable field is accessed only on vmQueue; public methods enqueue work there.
final class VZVirtualMachineRuntime: NSObject, @unchecked Sendable,
    VZVirtualMachineDelegate, VZVirtioSocketListenerDelegate
{
    enum Failure: Error {
        case missingSocketDevice
        case cannotForceStop(VZVirtualMachine.State)
    }

    enum StopEvent: Sendable {
        case guestStopped
        case failed(String)
    }

    private struct GuestReadiness: Decodable {
        let ip: String
        let ready: Bool
    }

    private let vmQueue: DispatchQueue
    private let virtualMachine: VZVirtualMachine
    private let readinessContinuation: AsyncStream<String>.Continuation
    private let stopContinuation: AsyncStream<StopEvent>.Continuation

    let readinessEvents: AsyncStream<String>
    let stopEvents: AsyncStream<StopEvent>

    static let guestAgentPort: UInt32 = 1_024
    static let hookPort: UInt32 = 1_025
    static let hostBridgePort: UInt32 = 1_028
    static let portEventPort: UInt32 = 1_029

    private enum SocketRole {
        case readiness
        case hook
        case portEvents
        case hostBridge
    }

    private var socketDevice: VZVirtioSocketDevice?
    private var socketListener: VZVirtioSocketListener?
    private var hookSocketListener: VZVirtioSocketListener?
    private var hostBridgeSocketListener: VZVirtioSocketListener?
    private var portEventSocketListener: VZVirtioSocketListener?
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
    private var hostBridges: [Int32: HostLoopbackBridge] = [:]
    private var sshForwarder: VsockSSHForwarder?
    private var portForwarders: [UInt16: VsockSSHForwarder] = [:]
    private var mirrorForwarders: [UInt16: [VsockSSHForwarder]] = [:]
    private var socketConnections: [Int32: VZVirtioSocketConnection] = [:]
    // DispatchSourceRead is required because VZ exposes only the connection file descriptor.
    private var socketReadSources: [Int32: any DispatchSourceRead] = [:]
    private var socketBuffers: [Int32: Data] = [:]
    private var socketRoles: [Int32: SocketRole] = [:]

    init(configuration: VZVirtualMachineConfiguration) {
        let queue = DispatchQueue(label: "com.vetro.vmkit.virtual-machine")
        let readinessPair = AsyncStream<String>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let stopPair = AsyncStream<StopEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.vmQueue = queue
        self.virtualMachine = VZVirtualMachine(
            configuration: configuration,
            queue: queue
        )
        self.readinessEvents = readinessPair.stream
        self.readinessContinuation = readinessPair.continuation
        self.stopEvents = stopPair.stream
        self.stopContinuation = stopPair.continuation
        super.init()
    }

    deinit {
        readinessContinuation.finish()
        stopContinuation.finish()
    }

    func setHookEventHandler(_ handler: (@Sendable (UUID?, String, String) -> Void)?) {
        vmQueue.async { [self] in
            hookEventHandler = handler
        }
    }

    func setPortEventHandler(
        _ handler: (
            @Sendable (
                _ snapshot: [UInt16]?,
                _ added: [UInt16],
                _ removed: [UInt16],
                _ refused: [UInt16]
            ) -> Void
        )?
    ) {
        vmQueue.async { [self] in
            portEventHandler = handler
        }
    }

    func setHostMirrorAllowlist(_ ports: Set<UInt16>) {
        vmQueue.async { [self] in
            hostMirrorAllowlist = ports
        }
    }

    /// Retargets the traditional memory balloon; the guest releases (or regains)
    /// pages until its visible memory matches `bytes`.
    func setMemoryBalloonTarget(bytes: UInt64) {
        vmQueue.async { [self] in
            guard let device = virtualMachine.memoryBalloonDevices.first
                as? VZVirtioTraditionalMemoryBalloonDevice
            else {
                return
            }
            device.targetVirtualMachineMemorySize = bytes
        }
    }

    /// Starts the guest and installs the host-side vsock listeners on ports 1024, 1025, 1028, and 1029.
    func start() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            vmQueue.async { [self] in
                virtualMachine.delegate = self
                virtualMachine.start { [self] result in
                    switch result {
                    case .success:
                        guard let device = virtualMachine.socketDevices.first
                            as? VZVirtioSocketDevice
                        else {
                            continuation.resume(throwing: Failure.missingSocketDevice)
                            return
                        }
                        let listener = VZVirtioSocketListener()
                        listener.delegate = self
                        device.setSocketListener(listener, forPort: Self.guestAgentPort)
                        let hookListener = VZVirtioSocketListener()
                        hookListener.delegate = self
                        device.setSocketListener(hookListener, forPort: Self.hookPort)
                        let hostBridgeListener = VZVirtioSocketListener()
                        hostBridgeListener.delegate = self
                        device.setSocketListener(hostBridgeListener, forPort: Self.hostBridgePort)
                        let portEventListener = VZVirtioSocketListener()
                        portEventListener.delegate = self
                        device.setSocketListener(portEventListener, forPort: Self.portEventPort)
                        socketDevice = device
                        socketListener = listener
                        hookSocketListener = hookListener
                        hostBridgeSocketListener = hostBridgeListener
                        portEventSocketListener = portEventListener
                        continuation.resume()
                    case let .failure(error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Starts a loopback TCP listener that forwards each client to a guest TCP port via vsock 1027.
    func startPortForward(guestPort: UInt16) async throws -> UInt16 {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<UInt16, any Error>) in
            vmQueue.async { [self] in
                if let existing = portForwarders[guestPort], let port = existing.port {
                    continuation.resume(returning: port)
                    return
                }
                guard let socketDevice else {
                    continuation.resume(throwing: Failure.missingSocketDevice)
                    return
                }
                let forwarder = VsockSSHForwarder(
                    queue: vmQueue,
                    socketDevice: socketDevice,
                    guestVsockPort: VsockSSHForwarder.portBridgeGuestPort,
                    handshake: .connect(guestPort: guestPort)
                )
                do {
                    let port = try forwarder.start()
                    portForwarders[guestPort] = forwarder
                    continuation.resume(returning: port)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stopPortForward(guestPort: UInt16) async {
        await withCheckedContinuation { continuation in
            vmQueue.async { [self] in
                portForwarders.removeValue(forKey: guestPort)?.stop()
                continuation.resume()
            }
        }
    }

    /// Starts host listeners that bind `hostPort` (default: `guestPort`) and forward via vsock 1027.
    func startMirror(guestPort: UInt16, hostPort: UInt16? = nil) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            vmQueue.async { [self] in
                if mirrorForwarders[guestPort] != nil {
                    continuation.resume()
                    return
                }
                guard let socketDevice else {
                    continuation.resume(throwing: Failure.missingSocketDevice)
                    return
                }
                let effectiveHostPort = hostPort ?? guestPort
                let modes: [VsockSSHForwarder.BindMode] = effectiveHostPort >= 1_024
                    ? [.loopbackV4, .loopbackV6]
                    : [.anyV4LoopbackFiltered]
                var started: [VsockSSHForwarder] = []
                do {
                    for mode in modes {
                        let forwarder = VsockSSHForwarder(
                            queue: vmQueue,
                            socketDevice: socketDevice,
                            guestVsockPort: VsockSSHForwarder.portBridgeGuestPort,
                            handshake: .connect(guestPort: guestPort),
                            bindPort: effectiveHostPort,
                            bindMode: mode
                        )
                        _ = try forwarder.start()
                        started.append(forwarder)
                    }
                    mirrorForwarders[guestPort] = started
                    continuation.resume()
                } catch {
                    for forwarder in started {
                        forwarder.stop()
                    }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stopMirror(guestPort: UInt16) async {
        await withCheckedContinuation { continuation in
            vmQueue.async { [self] in
                if let forwarders = mirrorForwarders.removeValue(forKey: guestPort) {
                    for forwarder in forwarders {
                        forwarder.stop()
                    }
                }
                continuation.resume()
            }
        }
    }

    /// Starts a loopback TCP listener that forwards each client to guest vsock port 1026.
    func startSSHForwarder() async throws -> UInt16 {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<UInt16, any Error>) in
            vmQueue.async { [self] in
                if let port = sshForwarder?.port {
                    continuation.resume(returning: port)
                    return
                }
                guard let socketDevice else {
                    continuation.resume(throwing: Failure.missingSocketDevice)
                    return
                }

                let forwarder = VsockSSHForwarder(
                    queue: vmQueue,
                    socketDevice: socketDevice
                )
                do {
                    let port = try forwarder.start()
                    sshForwarder = forwarder
                    continuation.resume(returning: port)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Destructively stops a guest that did not finish graceful shutdown.
    func forceStop() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            vmQueue.async { [self] in
                if virtualMachine.state == .stopped {
                    finishRuntimeDevices()
                    continuation.resume()
                    return
                }
                guard virtualMachine.canStop else {
                    finishRuntimeDevices()
                    continuation.resume(
                        throwing: Failure.cannotForceStop(virtualMachine.state)
                    )
                    return
                }
                virtualMachine.stop { error in
                    if let error {
                        self.finishRuntimeDevices()
                        continuation.resume(throwing: error)
                    } else {
                        self.finishRuntimeDevices()
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// Reads the queue-confined VZ state as a Sendable Boolean.
    func isStopped() async -> Bool {
        await withCheckedContinuation { continuation in
            vmQueue.async { [self] in
                let stopped = virtualMachine.state == .stopped
                if stopped {
                    finishRuntimeDevices()
                }
                continuation.resume(returning: stopped)
            }
        }
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        finishRuntimeDevices()
        stopContinuation.yield(.guestStopped)
    }

    func virtualMachine(
        _ virtualMachine: VZVirtualMachine,
        didStopWithError error: any Error
    ) {
        finishRuntimeDevices()
        stopContinuation.yield(.failed(error.localizedDescription))
    }

    func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        let descriptor = connection.fileDescriptor
        guard descriptor >= 0 else { return false }

        if listener === hostBridgeSocketListener {
            let bridge = HostLoopbackBridge(
                queue: vmQueue,
                connectionDescriptor: descriptor,
                allowlist: { [weak self] in
                    self?.hostMirrorAllowlist ?? []
                },
                closeConnection: { connection.close() },
                didStop: { [weak self] in
                    self?.hostBridges.removeValue(forKey: descriptor)
                }
            )
            hostBridges[descriptor] = bridge
            bridge.start()
            return true
        }

        socketConnections[descriptor] = connection
        socketBuffers[descriptor] = Data()
        if listener === hookSocketListener {
            socketRoles[descriptor] = .hook
        } else if listener === portEventSocketListener {
            socketRoles[descriptor] = .portEvents
        } else {
            socketRoles[descriptor] = .readiness
        }
        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: vmQueue
        )
        source.setEventHandler { [self] in
            receiveSocketBytes(descriptor: descriptor, available: source.data)
        }
        socketReadSources[descriptor] = source
        source.resume()
        return true
    }

    /// Reads only the byte count reported available, keeping the VM queue nonblocking.
    private func receiveSocketBytes(descriptor: Int32, available: UInt) {
        guard available > 0 else {
            closeSocket(descriptor: descriptor)
            return
        }
        let requestedCount = max(1, min(Int(available), 4_096))
        var bytes = [UInt8](repeating: 0, count: requestedCount)
        let count = bytes.withUnsafeMutableBytes { rawBuffer in
            Darwin.read(descriptor, rawBuffer.baseAddress, requestedCount)
        }
        guard count > 0 else {
            closeSocket(descriptor: descriptor)
            return
        }

        var buffer = socketBuffers[descriptor] ?? Data()
        buffer.append(contentsOf: bytes.prefix(count))
        if socketRoles[descriptor] == .hook {
            drainHookBuffer(descriptor: descriptor, buffer: buffer)
            return
        }
        if socketRoles[descriptor] == .portEvents {
            drainPortEventBuffer(descriptor: descriptor, buffer: buffer)
            return
        }
        guard buffer.count <= 65_536 else {
            closeSocket(descriptor: descriptor)
            return
        }

        if let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            if let readiness = try? JSONDecoder().decode(
                GuestReadiness.self,
                from: Data(line)
            ),
               readiness.ready,
               !readiness.ip.isEmpty
            {
                readinessContinuation.yield(readiness.ip)
            }
            closeSocket(descriptor: descriptor)
        } else {
            socketBuffers[descriptor] = buffer
        }
    }

    private func drainHookBuffer(descriptor: Int32, buffer: Data) {
        var buffer = buffer
        while true {
            switch VsockHookFrame.consume(from: &buffer) {
            case .needMore:
                socketBuffers[descriptor] = buffer
                return
            case .overflow:
                closeSocket(descriptor: descriptor)
                return
            case .ignored:
                continue
            case let .event(event):
                guard let handler = hookEventHandler else { continue }
                DispatchQueue.global(qos: .utility).async {
                    handler(event.sessionID, event.name, event.payload)
                }
            }
        }
    }

    private func drainPortEventBuffer(descriptor: Int32, buffer: Data) {
        var buffer = buffer
        while true {
            guard let newline = buffer.firstIndex(of: 0x0A) else {
                if buffer.count > VsockHookFrame.maxLineBytes {
                    closeSocket(descriptor: descriptor)
                    return
                }
                socketBuffers[descriptor] = buffer
                return
            }
            var line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            if line.last == 0x0D {
                line.removeLast()
            }
            guard line.count <= VsockHookFrame.maxLineBytes,
                  let event = try? JSONDecoder().decode(PortEvent.self, from: Data(line))
            else {
                continue
            }
            guard let handler = portEventHandler else { continue }
            let snapshot = event.snapshot
            let added = event.added
            let removed = event.removed
            let refused = event.refused ?? []
            DispatchQueue.global(qos: .utility).async {
                handler(snapshot, added, removed, refused)
            }
        }
    }

    /// Removes one accepted connection without double-closing its VZ-owned descriptor.
    private func closeSocket(descriptor: Int32) {
        if let source = socketReadSources.removeValue(forKey: descriptor) {
            source.setEventHandler {}
            source.cancel()
        }
        socketBuffers.removeValue(forKey: descriptor)
        socketRoles.removeValue(forKey: descriptor)
        socketConnections.removeValue(forKey: descriptor)?.close()
    }

    /// Detaches listeners and connections after either clean or failed guest stop.
    private func finishRuntimeDevices() {
        for forwarder in portForwarders.values {
            forwarder.stop()
        }
        portForwarders.removeAll()
        for forwarders in mirrorForwarders.values {
            for forwarder in forwarders {
                forwarder.stop()
            }
        }
        mirrorForwarders.removeAll()
        sshForwarder?.stop()
        sshForwarder = nil
        let bridges = Array(hostBridges.values)
        hostBridges.removeAll()
        for bridge in bridges {
            bridge.stop()
        }
        socketDevice?.removeSocketListener(forPort: Self.guestAgentPort)
        socketDevice?.removeSocketListener(forPort: Self.hookPort)
        socketDevice?.removeSocketListener(forPort: Self.hostBridgePort)
        socketDevice?.removeSocketListener(forPort: Self.portEventPort)
        socketListener?.delegate = nil
        socketListener = nil
        hookSocketListener?.delegate = nil
        hookSocketListener = nil
        hostBridgeSocketListener?.delegate = nil
        hostBridgeSocketListener = nil
        portEventSocketListener?.delegate = nil
        portEventSocketListener = nil
        socketDevice = nil
        for descriptor in Array(socketConnections.keys) {
            closeSocket(descriptor: descriptor)
        }
    }
}
