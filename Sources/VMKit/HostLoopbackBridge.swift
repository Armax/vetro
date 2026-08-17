import Darwin
import Foundation

/// Relays one guest vsock connection (port 1028) onto a host loopback TCP port.
///
/// All methods and callbacks are confined to the virtual machine's dispatch queue.
final class HostLoopbackBridge: @unchecked Sendable {
    private static let requestLimit = 64
    private static let handshakeTimeout: TimeInterval = 10

    private let queue: DispatchQueue
    private let connectionDescriptor: Int32
    private let allowlist: () -> Set<UInt16>
    private let closeConnection: () -> Void
    private let didStop: () -> Void

    private var requestBuffer = Data()
    private var reply = Data()
    private var replyOffset = 0
    private var leftover = Data()
    private var localDescriptor: Int32 = -1
    private var readSource: (any DispatchSourceRead)?
    private var writeSource: (any DispatchSourceWrite)?
    private var connectSource: (any DispatchSourceWrite)?
    private var timeoutWork: DispatchWorkItem?
    private var pump: BidirectionalSocketPump?
    private var releasedConnection = false
    private var stopped = false

    init(
        queue: DispatchQueue,
        connectionDescriptor: Int32,
        allowlist: @escaping () -> Set<UInt16>,
        closeConnection: @escaping () -> Void,
        didStop: @escaping () -> Void = {}
    ) {
        self.queue = queue
        self.connectionDescriptor = connectionDescriptor
        self.allowlist = allowlist
        self.closeConnection = closeConnection
        self.didStop = didStop
    }

    func start() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped else { return }
        do {
            try Self.setNonBlocking(connectionDescriptor)
            try Self.setCloseOnExec(connectionDescriptor)
            try Self.setSocketOption(
                descriptor: connectionDescriptor,
                level: SOL_SOCKET,
                option: SO_NOSIGPIPE,
                value: 1,
                operation: "setsockopt(SO_NOSIGPIPE)"
            )
        } catch {
            finish()
            return
        }

        let timeout = DispatchWorkItem { [weak self] in
            self?.finish()
        }
        timeoutWork = timeout
        queue.asyncAfter(deadline: .now() + Self.handshakeTimeout, execute: timeout)
        ensureReadSource()
        readRequest()
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        finish()
    }

    private func readRequest() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped else { return }
        while true {
            var bytes = [UInt8](repeating: 0, count: Self.requestLimit)
            let count = bytes.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(connectionDescriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count > 0 {
                requestBuffer.append(contentsOf: bytes.prefix(count))
                if requestBuffer.firstIndex(of: 0x0A) == nil,
                   requestBuffer.count > Self.requestLimit
                {
                    failNotAllowed()
                    return
                }
                if let request = VsockPortHandshake.consumeRequest(from: &requestBuffer) {
                    leftover = requestBuffer
                    handleRequest(request)
                    return
                }
                continue
            }
            if count == 0 {
                finish()
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

    private func handleRequest(_ request: VsockPortHandshake.Request) {
        dispatchPrecondition(condition: .onQueue(queue))
        cancelReadSource()
        switch request {
        case .invalid:
            failNotAllowed()
        case let .connect(guestPort):
            guard allowlist().contains(guestPort) else {
                failNotAllowed()
                return
            }
            connectLoopback(port: guestPort)
        }
    }

    private func connectLoopback(port: UInt16) {
        dispatchPrecondition(condition: .onQueue(queue))
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            failConnect(errno)
            return
        }
        do {
            try Self.setNonBlocking(descriptor)
            try Self.setCloseOnExec(descriptor)
            try Self.setSocketOption(
                descriptor: descriptor,
                level: SOL_SOCKET,
                option: SO_NOSIGPIPE,
                value: 1,
                operation: "setsockopt(SO_NOSIGPIPE)"
            )
        } catch {
            let code = errno
            Darwin.close(descriptor)
            failConnect(code == 0 ? EIO : code)
            return
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian

        let result = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        if result == 0 {
            localDescriptor = descriptor
            sendReply(Data("OK\n".utf8), startPump: true)
            return
        }
        if errno == EINPROGRESS {
            localDescriptor = descriptor
            ensureConnectSource()
            return
        }
        let code = errno
        Darwin.close(descriptor)
        failConnect(code)
    }

    private func finishConnect() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard localDescriptor >= 0 else { return }
        var errorCode: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        let result = withUnsafeMutablePointer(to: &errorCode) { errorPointer in
            Darwin.getsockopt(
                localDescriptor,
                SOL_SOCKET,
                SO_ERROR,
                errorPointer,
                &length
            )
        }
        cancelConnectSource()
        if result != 0 || errorCode != 0 {
            let code = result != 0 ? errno : errorCode
            Darwin.close(localDescriptor)
            localDescriptor = -1
            failConnect(code)
            return
        }
        sendReply(Data("OK\n".utf8), startPump: true)
    }

    private func failNotAllowed() {
        leftover.removeAll()
        sendReply(Data("ERR not allowed\n".utf8), startPump: false)
    }

    private func failConnect(_ code: Int32) {
        leftover.removeAll()
        sendReply(Data("ERR \(code)\n".utf8), startPump: false)
    }

    private func sendReply(_ data: Data, startPump: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped else { return }
        reply = data
        replyOffset = 0
        flushReply(startPump: startPump)
    }

    private func flushReply(startPump: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        while replyOffset < reply.count {
            let count = reply.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.write(
                    connectionDescriptor,
                    baseAddress.advanced(by: replyOffset),
                    rawBuffer.count - replyOffset
                )
            }
            if count > 0 {
                replyOffset += count
                continue
            }
            if count < 0, errno == EINTR {
                continue
            }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                ensureWriteSource(startPump: startPump)
                return
            }
            finish()
            return
        }
        cancelWriteSource()
        if startPump {
            beginPump()
        } else {
            finish()
        }
    }

    private func beginPump() {
        dispatchPrecondition(condition: .onQueue(queue))
        cancelHandshakeIO()
        let local = localDescriptor
        guard local >= 0 else {
            finish()
            return
        }
        let vsock = connectionDescriptor
        let closeConnection = closeConnection
        let relay = BidirectionalSocketPump(
            queue: queue,
            firstDescriptor: local,
            secondDescriptor: vsock,
            closeFirst: { Darwin.close(local) },
            closeSecond: { closeConnection() },
            didStop: { [weak self] in
                self?.pumpDidStop()
            },
            initialSecondPending: leftover
        )
        leftover.removeAll()
        releasedConnection = true
        localDescriptor = -1
        pump = relay
        relay.start()
    }

    private func pumpDidStop() {
        dispatchPrecondition(condition: .onQueue(queue))
        pump = nil
        if !stopped {
            finish()
        }
    }

    private func ensureReadSource() {
        guard readSource == nil else { return }
        let source = DispatchSource.makeReadSource(
            fileDescriptor: connectionDescriptor,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.readRequest()
        }
        readSource = source
        source.resume()
    }

    private func ensureWriteSource(startPump: Bool) {
        guard writeSource == nil else { return }
        let source = DispatchSource.makeWriteSource(
            fileDescriptor: connectionDescriptor,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.flushReply(startPump: startPump)
        }
        writeSource = source
        source.resume()
    }

    private func ensureConnectSource() {
        guard connectSource == nil, localDescriptor >= 0 else { return }
        let source = DispatchSource.makeWriteSource(
            fileDescriptor: localDescriptor,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.finishConnect()
        }
        connectSource = source
        source.resume()
    }

    private func cancelReadSource() {
        guard let source = readSource else { return }
        source.setEventHandler {}
        source.cancel()
        readSource = nil
    }

    private func cancelWriteSource() {
        guard let source = writeSource else { return }
        source.setEventHandler {}
        source.cancel()
        writeSource = nil
    }

    private func cancelConnectSource() {
        guard let source = connectSource else { return }
        source.setEventHandler {}
        source.cancel()
        connectSource = nil
    }

    private func cancelHandshakeIO() {
        timeoutWork?.cancel()
        timeoutWork = nil
        cancelReadSource()
        cancelWriteSource()
        cancelConnectSource()
    }

    private func finish() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped else { return }
        stopped = true
        cancelHandshakeIO()
        if let pump {
            self.pump = nil
            pump.stop()
        } else {
            if localDescriptor >= 0 {
                Darwin.close(localDescriptor)
                localDescriptor = -1
            }
            if !releasedConnection {
                releasedConnection = true
                closeConnection()
            }
        }
        didStop()
    }

    private static func setNonBlocking(_ descriptor: Int32) throws {
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags >= 0 else {
            throw POSIXFailure(operation: "fcntl(F_GETFL)", code: errno)
        }
        guard Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw POSIXFailure(operation: "fcntl(F_SETFL)", code: errno)
        }
    }

    private static func setCloseOnExec(_ descriptor: Int32) throws {
        let flags = Darwin.fcntl(descriptor, F_GETFD)
        guard flags >= 0 else {
            throw POSIXFailure(operation: "fcntl(F_GETFD)", code: errno)
        }
        guard Darwin.fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
            throw POSIXFailure(operation: "fcntl(F_SETFD)", code: errno)
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
            throw POSIXFailure(operation: operation, code: errno)
        }
    }

    private struct POSIXFailure: Error {
        let operation: String
        let code: Int32
    }
}
