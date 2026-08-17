import Darwin
import Foundation
import Virtualization

/// Accepts loopback TCP connections and attaches each one to the guest SSH vsock port.
///
/// All methods and callbacks are confined to the virtual machine's dispatch queue.
final class VsockSSHForwarder: @unchecked Sendable {
    enum Failure: Error, Sendable, Equatable {
        case socketOperation(operation: String, code: Int32)
        case addressInUse
    }

    enum BindMode: Sendable, Equatable {
        case loopbackV4
        case loopbackV6
        case anyV4LoopbackFiltered
    }

    static let guestPort: UInt32 = 1_026
    static let portBridgeGuestPort: UInt32 = 1_027

    private let queue: DispatchQueue
    private let socketDevice: VZVirtioSocketDevice?
    private let guestVsockPort: UInt32
    private let handshake: VsockGuestHandshake
    private let bindPort: UInt16
    private let bindMode: BindMode

    private var listenerDescriptor: Int32 = -1
    private var listenerSource: (any DispatchSourceRead)?
    private var pendingClientDescriptors: Set<Int32> = []
    private var activeRelays: [Int32: BidirectionalSocketPump] = [:]
    private var handshakes: [Int32: HandshakeSession] = [:]

    private(set) var port: UInt16?

    init(
        queue: DispatchQueue,
        socketDevice: VZVirtioSocketDevice? = nil,
        guestVsockPort: UInt32 = VsockSSHForwarder.guestPort,
        handshake: VsockGuestHandshake = .none,
        bindPort: UInt16 = 0,
        bindMode: BindMode = .loopbackV4
    ) {
        self.queue = queue
        self.socketDevice = socketDevice
        self.guestVsockPort = guestVsockPort
        self.handshake = handshake
        self.bindPort = bindPort
        self.bindMode = bindMode
    }

    /// Starts a TCP listener. `bindPort` 0 selects an ephemeral port.
    func start() throws -> UInt16 {
        dispatchPrecondition(condition: .onQueue(queue))
        if let port {
            return port
        }

        let descriptor: Int32
        switch bindMode {
        case .loopbackV4:
            descriptor = try openIPv4Listener(
                address: in_addr_t(INADDR_LOOPBACK).bigEndian
            )
        case .anyV4LoopbackFiltered:
            descriptor = try openIPv4Listener(address: INADDR_ANY)
        case .loopbackV6:
            descriptor = try openIPv6LoopbackListener()
        }

        do {
            let boundPort = try resolvedPort(of: descriptor)
            listenerDescriptor = descriptor
            port = boundPort
            let source = DispatchSource.makeReadSource(
                fileDescriptor: descriptor,
                queue: queue
            )
            source.setEventHandler { [weak self] in
                self?.acceptReadyClients()
            }
            listenerSource = source
            source.resume()
            return boundPort
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    /// Stops accepting and closes pending and active connections.
    func stop() {
        dispatchPrecondition(condition: .onQueue(queue))

        port = nil
        if let source = listenerSource {
            source.setEventHandler {}
            source.cancel()
            listenerSource = nil
        }
        if listenerDescriptor >= 0 {
            Darwin.close(listenerDescriptor)
            listenerDescriptor = -1
        }

        for descriptor in pendingClientDescriptors {
            Darwin.close(descriptor)
        }
        pendingClientDescriptors.removeAll()

        for relay in Array(activeRelays.values) {
            relay.stop()
        }
        activeRelays.removeAll()

        for session in Array(handshakes.values) {
            abortHandshake(session)
        }
        handshakes.removeAll()
    }

    private func acceptReadyClients() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard listenerDescriptor >= 0 else { return }

        while true {
            let clientDescriptor = Darwin.accept(listenerDescriptor, nil, nil)
            if clientDescriptor >= 0 {
                do {
                    try Self.setNonBlocking(clientDescriptor)
                    try Self.setCloseOnExec(clientDescriptor)
                    try Self.setSocketOption(
                        descriptor: clientDescriptor,
                        level: SOL_SOCKET,
                        option: SO_NOSIGPIPE,
                        value: 1,
                        operation: "setsockopt(SO_NOSIGPIPE)"
                    )
                } catch {
                    Darwin.close(clientDescriptor)
                    continue
                }

                // Wildcard binds are reachable from any interface; drop non-loopback peers.
                if bindMode == .anyV4LoopbackFiltered,
                   !Self.isLoopbackIPv4Peer(clientDescriptor)
                {
                    Darwin.close(clientDescriptor)
                    continue
                }

                guard let socketDevice else {
                    Darwin.close(clientDescriptor)
                    continue
                }

                pendingClientDescriptors.insert(clientDescriptor)
                socketDevice.connect(toPort: guestVsockPort) { [weak self] result in
                    guard let self else {
                        if case let .success(connection) = result {
                            connection.close()
                        }
                        return
                    }
                    self.finishVsockConnection(
                        result,
                        clientDescriptor: clientDescriptor
                    )
                }
                continue
            }

            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            }
            return
        }
    }

    private func finishVsockConnection(
        _ result: Result<VZVirtioSocketConnection, any Error>,
        clientDescriptor: Int32
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard pendingClientDescriptors.remove(clientDescriptor) != nil else {
            if case let .success(connection) = result {
                connection.close()
            }
            return
        }

        guard port != nil else {
            Darwin.close(clientDescriptor)
            if case let .success(connection) = result {
                connection.close()
            }
            return
        }

        switch result {
        case .failure:
            // SSH owns retry policy; a refused early-boot vsock connection ends this attempt.
            Darwin.close(clientDescriptor)
        case let .success(connection):
            let vsockDescriptor = connection.fileDescriptor
            guard vsockDescriptor >= 0 else {
                Darwin.close(clientDescriptor)
                connection.close()
                return
            }
            do {
                try Self.setNonBlocking(vsockDescriptor)
                try Self.setCloseOnExec(vsockDescriptor)
                try Self.setSocketOption(
                    descriptor: vsockDescriptor,
                    level: SOL_SOCKET,
                    option: SO_NOSIGPIPE,
                    value: 1,
                    operation: "setsockopt(SO_NOSIGPIPE)"
                )
            } catch {
                Darwin.close(clientDescriptor)
                connection.close()
                return
            }

            switch handshake {
            case .none:
                startRelay(
                    clientDescriptor: clientDescriptor,
                    vsockDescriptor: vsockDescriptor,
                    connection: connection,
                    initialSecondPending: Data()
                )
            case .connect(let guestPort):
                beginHandshake(
                    clientDescriptor: clientDescriptor,
                    vsockDescriptor: vsockDescriptor,
                    connection: connection,
                    request: VsockPortHandshake.request(guestPort: guestPort)
                )
            }
        }
    }

    private func startRelay(
        clientDescriptor: Int32,
        vsockDescriptor: Int32,
        connection: VZVirtioSocketConnection,
        initialSecondPending: Data
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        let relay = BidirectionalSocketPump(
            queue: queue,
            firstDescriptor: clientDescriptor,
            secondDescriptor: vsockDescriptor,
            closeFirst: {
                Darwin.close(clientDescriptor)
            },
            closeSecond: {
                connection.close()
            },
            didStop: { [weak self] in
                self?.activeRelays.removeValue(forKey: clientDescriptor)
            },
            initialSecondPending: initialSecondPending
        )
        activeRelays[clientDescriptor] = relay
        relay.start()
    }

    private func beginHandshake(
        clientDescriptor: Int32,
        vsockDescriptor: Int32,
        connection: VZVirtioSocketConnection,
        request: Data
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        let session = HandshakeSession(
            clientDescriptor: clientDescriptor,
            vsockDescriptor: vsockDescriptor,
            connection: connection,
            request: request
        )
        handshakes[clientDescriptor] = session
        let timeout = DispatchWorkItem { [weak self] in
            self?.failHandshake(clientDescriptor)
        }
        session.timeoutWork = timeout
        queue.asyncAfter(deadline: .now() + 10, execute: timeout)
        writeHandshakeRequest(session)
    }

    private func writeHandshakeRequest(_ session: HandshakeSession) {
        dispatchPrecondition(condition: .onQueue(queue))
        while session.requestOffset < session.request.count {
            let count = session.request.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.write(
                    session.vsockDescriptor,
                    baseAddress.advanced(by: session.requestOffset),
                    rawBuffer.count - session.requestOffset
                )
            }
            if count > 0 {
                session.requestOffset += count
                continue
            }
            if count < 0, errno == EINTR {
                continue
            }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                ensureHandshakeWriteSource(session)
                return
            }
            failHandshake(session.clientDescriptor)
            return
        }
        cancelHandshakeWriteSource(session)
        ensureHandshakeReadSource(session)
    }

    private func readHandshakeResponse(_ session: HandshakeSession) {
        dispatchPrecondition(condition: .onQueue(queue))
        while true {
            var bytes = [UInt8](repeating: 0, count: 256)
            let count = bytes.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(session.vsockDescriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count > 0 {
                session.response.append(contentsOf: bytes.prefix(count))
                guard session.response.count <= 1_024 else {
                    failHandshake(session.clientDescriptor)
                    return
                }
                if let outcome = VsockPortHandshake.consumeResponse(from: &session.response) {
                    finishHandshake(session, outcome: outcome)
                    return
                }
                continue
            }
            if count == 0 {
                failHandshake(session.clientDescriptor)
                return
            }
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            }
            failHandshake(session.clientDescriptor)
            return
        }
    }

    private func finishHandshake(
        _ session: HandshakeSession,
        outcome: VsockPortHandshake.Response
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard handshakes.removeValue(forKey: session.clientDescriptor) != nil else { return }
        cancelHandshakeIO(session)
        switch outcome {
        case .ok:
            startRelay(
                clientDescriptor: session.clientDescriptor,
                vsockDescriptor: session.vsockDescriptor,
                connection: session.connection,
                initialSecondPending: session.response
            )
        case .error, .invalid:
            Darwin.close(session.clientDescriptor)
            session.connection.close()
        }
    }

    private func failHandshake(_ clientDescriptor: Int32) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let session = handshakes.removeValue(forKey: clientDescriptor) else { return }
        abortHandshake(session)
    }

    private func abortHandshake(_ session: HandshakeSession) {
        cancelHandshakeIO(session)
        Darwin.close(session.clientDescriptor)
        session.connection.close()
    }

    private func ensureHandshakeWriteSource(_ session: HandshakeSession) {
        guard session.writeSource == nil else { return }
        let source = DispatchSource.makeWriteSource(
            fileDescriptor: session.vsockDescriptor,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.writeHandshakeRequest(session)
        }
        session.writeSource = source
        source.resume()
    }

    private func ensureHandshakeReadSource(_ session: HandshakeSession) {
        guard session.readSource == nil else { return }
        let source = DispatchSource.makeReadSource(
            fileDescriptor: session.vsockDescriptor,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.readHandshakeResponse(session)
        }
        session.readSource = source
        source.resume()
    }

    private func cancelHandshakeWriteSource(_ session: HandshakeSession) {
        guard let source = session.writeSource else { return }
        source.setEventHandler {}
        source.cancel()
        session.writeSource = nil
    }

    private func cancelHandshakeReadSource(_ session: HandshakeSession) {
        guard let source = session.readSource else { return }
        source.setEventHandler {}
        source.cancel()
        session.readSource = nil
    }

    private func cancelHandshakeIO(_ session: HandshakeSession) {
        session.timeoutWork?.cancel()
        session.timeoutWork = nil
        cancelHandshakeWriteSource(session)
        cancelHandshakeReadSource(session)
    }

    private final class HandshakeSession {
        let clientDescriptor: Int32
        let vsockDescriptor: Int32
        let connection: VZVirtioSocketConnection
        var request: Data
        var requestOffset = 0
        var response = Data()
        var writeSource: (any DispatchSourceWrite)?
        var readSource: (any DispatchSourceRead)?
        var timeoutWork: DispatchWorkItem?

        init(
            clientDescriptor: Int32,
            vsockDescriptor: Int32,
            connection: VZVirtioSocketConnection,
            request: Data
        ) {
            self.clientDescriptor = clientDescriptor
            self.vsockDescriptor = vsockDescriptor
            self.connection = connection
            self.request = request
        }
    }

    private func currentFailure(_ operation: String) -> Failure {
        Failure.socketOperation(operation: operation, code: errno)
    }

    private func bindFailure() -> Failure {
        if bindPort != 0, errno == EADDRINUSE {
            return .addressInUse
        }
        return currentFailure("bind")
    }

    /// True when `address` (network byte order, as in `sockaddr_in.sin_addr`) is in 127.0.0.0/8.
    static func isLoopbackIPv4(_ address: in_addr_t) -> Bool {
        (UInt32(bigEndian: address) >> 24) == 127
    }

    private static func isLoopbackIPv4Peer(_ descriptor: Int32) -> Bool {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getpeername(descriptor, $0, &length)
            }
        }
        guard result == 0, address.sin_family == sa_family_t(AF_INET) else {
            return false
        }
        return isLoopbackIPv4(address.sin_addr.s_addr)
    }

    private func openIPv4Listener(address: in_addr_t) throws -> Int32 {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw currentFailure("socket")
        }

        do {
            try Self.setSocketOption(
                descriptor: descriptor,
                level: SOL_SOCKET,
                option: SO_REUSEADDR,
                value: 1,
                operation: "setsockopt(SO_REUSEADDR)"
            )
            try Self.setNonBlocking(descriptor)
            try Self.setCloseOnExec(descriptor)

            var sockAddress = sockaddr_in()
            sockAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sockAddress.sin_family = sa_family_t(AF_INET)
            sockAddress.sin_port = bindPort.bigEndian
            sockAddress.sin_addr.s_addr = address

            let bindResult = withUnsafePointer(to: &sockAddress) { addressPointer in
                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
            guard bindResult == 0 else {
                throw bindFailure()
            }
            guard Darwin.listen(descriptor, SOMAXCONN) == 0 else {
                throw currentFailure("listen")
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func openIPv6LoopbackListener() throws -> Int32 {
        let descriptor = Darwin.socket(AF_INET6, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw currentFailure("socket")
        }

        do {
            try Self.setSocketOption(
                descriptor: descriptor,
                level: SOL_SOCKET,
                option: SO_REUSEADDR,
                value: 1,
                operation: "setsockopt(SO_REUSEADDR)"
            )
            try Self.setSocketOption(
                descriptor: descriptor,
                level: Int32(IPPROTO_IPV6),
                option: IPV6_V6ONLY,
                value: 1,
                operation: "setsockopt(IPV6_V6ONLY)"
            )
            try Self.setNonBlocking(descriptor)
            try Self.setCloseOnExec(descriptor)

            var sockAddress = sockaddr_in6()
            sockAddress.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            sockAddress.sin6_family = sa_family_t(AF_INET6)
            sockAddress.sin6_port = bindPort.bigEndian
            sockAddress.sin6_addr = in6addr_loopback

            let bindResult = withUnsafePointer(to: &sockAddress) { addressPointer in
                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in6>.size)
                    )
                }
            }
            guard bindResult == 0 else {
                throw bindFailure()
            }
            guard Darwin.listen(descriptor, SOMAXCONN) == 0 else {
                throw currentFailure("listen")
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func resolvedPort(of descriptor: Int32) throws -> UInt16 {
        let boundPort: UInt16
        switch bindMode {
        case .loopbackV4, .anyV4LoopbackFiltered:
            var boundAddress = sockaddr_in()
            var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let nameResult = withUnsafeMutablePointer(to: &boundAddress) { addressPointer in
                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getsockname(descriptor, $0, &boundAddressLength)
                }
            }
            guard nameResult == 0 else {
                throw currentFailure("getsockname")
            }
            boundPort = UInt16(bigEndian: boundAddress.sin_port)
        case .loopbackV6:
            var boundAddress = sockaddr_in6()
            var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let nameResult = withUnsafeMutablePointer(to: &boundAddress) { addressPointer in
                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getsockname(descriptor, $0, &boundAddressLength)
                }
            }
            guard nameResult == 0 else {
                throw currentFailure("getsockname")
            }
            boundPort = UInt16(bigEndian: boundAddress.sin6_port)
        }
        guard boundPort != 0 else {
            throw Failure.socketOperation(operation: "getsockname(port)", code: EINVAL)
        }
        return boundPort
    }

    private static func setNonBlocking(_ descriptor: Int32) throws {
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags >= 0 else {
            throw Failure.socketOperation(operation: "fcntl(F_GETFL)", code: errno)
        }
        guard Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw Failure.socketOperation(operation: "fcntl(F_SETFL)", code: errno)
        }
    }

    private static func setCloseOnExec(_ descriptor: Int32) throws {
        let flags = Darwin.fcntl(descriptor, F_GETFD)
        guard flags >= 0 else {
            throw Failure.socketOperation(operation: "fcntl(F_GETFD)", code: errno)
        }
        guard Darwin.fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
            throw Failure.socketOperation(operation: "fcntl(F_SETFD)", code: errno)
        }
    }

    private static func setSocketOption(
        descriptor: Int32,
        level: Int32,
        option: Int32,
        value: Int32,
        operation: String
    ) throws {
        var mutableValue = value
        let result = withUnsafePointer(to: &mutableValue) {
            Darwin.setsockopt(
                descriptor,
                level,
                option,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        guard result == 0 else {
            throw Failure.socketOperation(operation: operation, code: errno)
        }
    }
}

/// Queue-confined, backpressured byte pump between two nonblocking socket descriptors.
///
/// EOF in one direction half-closes only the peer's write side. Both owned endpoints are
/// released after EOF in both directions, or immediately after a hard read/write error.
final class BidirectionalSocketPump: @unchecked Sendable {
    private final class Flow {
        let sourceDescriptor: Int32
        let destinationDescriptor: Int32
        var readSource: (any DispatchSourceRead)?
        var writeSource: (any DispatchSourceWrite)?
        var pendingBytes = Data()
        var pendingOffset = 0
        var readSuspended = false
        var sourceReachedEOF = false
        var destinationHalfClosed = false

        init(sourceDescriptor: Int32, destinationDescriptor: Int32) {
            self.sourceDescriptor = sourceDescriptor
            self.destinationDescriptor = destinationDescriptor
        }
    }

    private static let readChunkSize = 64 * 1_024
    private static let maximumReadPerEvent = 256 * 1_024

    private let queue: DispatchQueue
    private let closeFirst: () -> Void
    private let closeSecond: () -> Void
    private let didStop: () -> Void
    private let flows: [Flow]
    private var isRunning = false

    init(
        queue: DispatchQueue,
        firstDescriptor: Int32,
        secondDescriptor: Int32,
        closeFirst: @escaping () -> Void,
        closeSecond: @escaping () -> Void,
        didStop: @escaping () -> Void,
        initialSecondPending: Data = Data()
    ) {
        self.queue = queue
        self.closeFirst = closeFirst
        self.closeSecond = closeSecond
        self.didStop = didStop
        let secondToFirst = Flow(
            sourceDescriptor: secondDescriptor,
            destinationDescriptor: firstDescriptor
        )
        if !initialSecondPending.isEmpty {
            secondToFirst.pendingBytes = initialSecondPending
        }
        self.flows = [
            Flow(
                sourceDescriptor: firstDescriptor,
                destinationDescriptor: secondDescriptor
            ),
            secondToFirst,
        ]
    }

    func start() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isRunning else { return }
        isRunning = true

        for index in flows.indices {
            let flow = flows[index]
            let source = DispatchSource.makeReadSource(
                fileDescriptor: flow.sourceDescriptor,
                queue: queue
            )
            source.setEventHandler { [weak self] in
                self?.readAvailable(flowIndex: index)
            }
            flow.readSource = source
            source.resume()
        }

        if !flows[1].pendingBytes.isEmpty {
            flushPendingBytes(flowIndex: 1)
        }
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        finish()
    }

    private func readAvailable(flowIndex: Int) {
        guard isRunning else { return }
        let flow = flows[flowIndex]
        guard !flow.sourceReachedEOF, !flow.readSuspended else { return }

        var bytesReadThisEvent = 0
        while bytesReadThisEvent < Self.maximumReadPerEvent {
            var bytes = [UInt8](repeating: 0, count: Self.readChunkSize)
            let count = bytes.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(
                    flow.sourceDescriptor,
                    rawBuffer.baseAddress,
                    rawBuffer.count
                )
            }

            if count > 0 {
                bytesReadThisEvent += count
                flow.pendingBytes.append(contentsOf: bytes.prefix(count))
                flushPendingBytes(flowIndex: flowIndex)
                guard isRunning else { return }
                if !flow.pendingBytes.isEmpty {
                    suspendReads(flow)
                    ensureWriteSource(flowIndex: flowIndex)
                    return
                }
                continue
            }

            if count == 0 {
                flow.sourceReachedEOF = true
                cancelReadSource(flow)
                finishHalfCloseIfReady(flow)
                return
            }

            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            }
            finish()
            return
        }
    }

    private func writeAvailable(flowIndex: Int) {
        guard isRunning else { return }
        flushPendingBytes(flowIndex: flowIndex)
    }

    private func flushPendingBytes(flowIndex: Int) {
        let flow = flows[flowIndex]
        while flow.pendingOffset < flow.pendingBytes.count {
            let count = flow.pendingBytes.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.write(
                    flow.destinationDescriptor,
                    baseAddress.advanced(by: flow.pendingOffset),
                    rawBuffer.count - flow.pendingOffset
                )
            }
            if count > 0 {
                flow.pendingOffset += count
                continue
            }
            if count < 0, errno == EINTR {
                continue
            }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                ensureWriteSource(flowIndex: flowIndex)
                return
            }
            finish()
            return
        }

        flow.pendingBytes.removeAll(keepingCapacity: true)
        flow.pendingOffset = 0
        cancelWriteSource(flow)
        finishHalfCloseIfReady(flow)
        if isRunning, !flow.sourceReachedEOF {
            resumeReads(flow)
        }
    }

    private func ensureWriteSource(flowIndex: Int) {
        let flow = flows[flowIndex]
        guard flow.writeSource == nil else { return }
        let source = DispatchSource.makeWriteSource(
            fileDescriptor: flow.destinationDescriptor,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.writeAvailable(flowIndex: flowIndex)
        }
        flow.writeSource = source
        source.resume()
    }

    private func suspendReads(_ flow: Flow) {
        guard let source = flow.readSource, !flow.readSuspended else { return }
        flow.readSuspended = true
        source.suspend()
    }

    private func resumeReads(_ flow: Flow) {
        guard let source = flow.readSource, flow.readSuspended else { return }
        flow.readSuspended = false
        source.resume()
    }

    private func cancelReadSource(_ flow: Flow) {
        guard let source = flow.readSource else { return }
        if flow.readSuspended {
            flow.readSuspended = false
            source.resume()
        }
        source.setEventHandler {}
        source.cancel()
        flow.readSource = nil
    }

    private func cancelWriteSource(_ flow: Flow) {
        guard let source = flow.writeSource else { return }
        source.setEventHandler {}
        source.cancel()
        flow.writeSource = nil
    }

    private func finishHalfCloseIfReady(_ flow: Flow) {
        guard flow.sourceReachedEOF,
              flow.pendingBytes.isEmpty,
              !flow.destinationHalfClosed
        else { return }

        flow.destinationHalfClosed = true
        _ = Darwin.shutdown(flow.destinationDescriptor, SHUT_WR)
        if flows.allSatisfy(\.destinationHalfClosed) {
            finish()
        }
    }

    private func finish() {
        guard isRunning else { return }
        isRunning = false
        for flow in flows {
            cancelReadSource(flow)
            cancelWriteSource(flow)
        }
        closeFirst()
        closeSecond()
        didStop()
    }
}
