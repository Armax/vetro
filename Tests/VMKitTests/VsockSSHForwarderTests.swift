import Darwin
import Foundation
import Testing
@testable import VMKit

@Suite("Vsock SSH byte forwarding")
struct VsockSSHForwarderTests {
    @Test("pump relays both directions and preserves half-close semantics")
    func bidirectionalRelayAndHalfClose() throws {
        let leftPair = try makeSocketPair()
        let rightPair = try makeSocketPair()
        let leftClient = leftPair.0
        let leftPump = leftPair.1
        let rightPump = rightPair.0
        let rightClient = rightPair.1
        let queue = DispatchQueue(label: "com.vetro.vmkit.tests.socket-pump")
        let didStop = DispatchSemaphore(value: 0)

        try setNonBlocking(leftPump)
        try setNonBlocking(rightPump)

        let pump = BidirectionalSocketPump(
            queue: queue,
            firstDescriptor: leftPump,
            secondDescriptor: rightPump,
            closeFirst: { Darwin.close(leftPump) },
            closeSecond: { Darwin.close(rightPump) },
            didStop: { didStop.signal() }
        )
        queue.sync {
            pump.start()
        }
        defer {
            queue.sync {
                pump.stop()
            }
            Darwin.close(leftClient)
            Darwin.close(rightClient)
        }

        let leftToRight = Data("left to right".utf8)
        try writeAll(leftToRight, to: leftClient)
        #expect(try readExactly(leftToRight.count, from: rightClient) == leftToRight)

        let rightToLeft = Data("right to left".utf8)
        try writeAll(rightToLeft, to: rightClient)
        #expect(try readExactly(rightToLeft.count, from: leftClient) == rightToLeft)

        try requireZero(
            Darwin.shutdown(leftClient, SHUT_WR),
            operation: "shutdown(left, SHUT_WR)"
        )
        try expectEOF(from: rightClient)

        let afterHalfClose = Data("reverse direction remains open".utf8)
        try writeAll(afterHalfClose, to: rightClient)
        #expect(try readExactly(afterHalfClose.count, from: leftClient) == afterHalfClose)

        try requireZero(
            Darwin.shutdown(rightClient, SHUT_WR),
            operation: "shutdown(right, SHUT_WR)"
        )
        try expectEOF(from: leftClient)
        #expect(didStop.wait(timeout: .now() + 2) == .success)
    }

    @Test("pump flushes leftover handshake payload toward the local client")
    func leftoverHandshakePayloadIsForwarded() throws {
        let leftPair = try makeSocketPair()
        let rightPair = try makeSocketPair()
        let leftClient = leftPair.0
        let leftPump = leftPair.1
        let rightPump = rightPair.0
        let rightClient = rightPair.1
        let queue = DispatchQueue(label: "com.vetro.vmkit.tests.socket-pump-leftover")
        let leftover = Data("HTTP/1.1 200 OK\r\n".utf8)

        try setNonBlocking(leftPump)
        try setNonBlocking(rightPump)

        let pump = BidirectionalSocketPump(
            queue: queue,
            firstDescriptor: leftPump,
            secondDescriptor: rightPump,
            closeFirst: { Darwin.close(leftPump) },
            closeSecond: { Darwin.close(rightPump) },
            didStop: {},
            initialSecondPending: leftover
        )
        queue.sync {
            pump.start()
        }
        defer {
            queue.sync {
                pump.stop()
            }
            Darwin.close(leftClient)
            Darwin.close(rightClient)
        }

        #expect(try readExactly(leftover.count, from: leftClient) == leftover)
    }

    @Test("fixed bindPort is reported by getsockname")
    func fixedPortBind() throws {
        let reserved = try bindListeningIPv4Loopback(port: 0)
        let port = reserved.port
        Darwin.close(reserved.descriptor)

        let queue = DispatchQueue(label: "com.vetro.vmkit.tests.fixed-port")
        let forwarder = VsockSSHForwarder(
            queue: queue,
            bindPort: port,
            bindMode: .loopbackV4
        )
        let bound = try queue.sync { try forwarder.start() }
        defer {
            queue.sync {
                forwarder.stop()
            }
        }

        #expect(bound == port)
        #expect(forwarder.port == port)

        let client = try connectIPv4Loopback(port: port)
        defer { Darwin.close(client) }
        #expect(try getpeernameIPv4Port(of: client) == port)
    }

    @Test("fixed bindPort throws addressInUse when the port is taken")
    func addressInUseIsDistinct() throws {
        let occupied = try bindListeningIPv4Loopback(port: 0)
        defer { Darwin.close(occupied.descriptor) }

        let queue = DispatchQueue(label: "com.vetro.vmkit.tests.address-in-use")
        let forwarder = VsockSSHForwarder(
            queue: queue,
            bindPort: occupied.port,
            bindMode: .loopbackV4
        )
        #expect(throws: VsockSSHForwarder.Failure.addressInUse) {
            try queue.sync {
                try forwarder.start()
            }
        }
    }

    @Test("loopbackV6 listener accepts a connection to ::1")
    func loopbackV6Accepts() throws {
        let queue = DispatchQueue(label: "com.vetro.vmkit.tests.loopback-v6")
        let forwarder = VsockSSHForwarder(
            queue: queue,
            bindMode: .loopbackV6
        )
        let port = try queue.sync { try forwarder.start() }
        defer {
            queue.sync {
                forwarder.stop()
            }
        }

        let client = try connectIPv6Loopback(port: port)
        defer { Darwin.close(client) }
        #expect(try getsocknameIPv6Port(of: client) != 0)
        #expect(try getpeernameIPv6Port(of: client) == port)
    }

    @Test("anyV4LoopbackFiltered accepts a loopback client")
    func anyV4LoopbackFilteredAcceptsLoopback() throws {
        let queue = DispatchQueue(label: "com.vetro.vmkit.tests.any-v4-loopback")
        let forwarder = VsockSSHForwarder(
            queue: queue,
            bindMode: .anyV4LoopbackFiltered
        )
        let port = try queue.sync { try forwarder.start() }
        defer {
            queue.sync {
                forwarder.stop()
            }
        }

        let client = try connectIPv4Loopback(port: port)
        defer { Darwin.close(client) }
        #expect(try getpeernameIPv4Port(of: client) == port)
    }

    @Test("isLoopbackIPv4 matches only 127.0.0.0/8")
    func loopbackIPv4Predicate() {
        #expect(VsockSSHForwarder.isLoopbackIPv4(inet_addr("127.0.0.1")))
        #expect(VsockSSHForwarder.isLoopbackIPv4(inet_addr("127.0.0.0")))
        #expect(VsockSSHForwarder.isLoopbackIPv4(inet_addr("127.255.255.254")))
        #expect(!VsockSSHForwarder.isLoopbackIPv4(inet_addr("126.255.255.255")))
        #expect(!VsockSSHForwarder.isLoopbackIPv4(inet_addr("128.0.0.1")))
        #expect(!VsockSSHForwarder.isLoopbackIPv4(inet_addr("8.8.8.8")))
        #expect(!VsockSSHForwarder.isLoopbackIPv4(inet_addr("0.0.0.0")))
        #expect(!VsockSSHForwarder.isLoopbackIPv4(inet_addr("192.168.1.1")))
    }

    private func makeSocketPair() throws -> (Int32, Int32) {
        var descriptors = [Int32](repeating: -1, count: 2)
        let result = descriptors.withUnsafeMutableBufferPointer { buffer in
            Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress)
        }
        try requireZero(result, operation: "socketpair")
        return (descriptors[0], descriptors[1])
    }

    private func setNonBlocking(_ descriptor: Int32) throws {
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags >= 0 else {
            throw POSIXTestFailure(operation: "fcntl(F_GETFL)", code: errno)
        }
        try requireZero(
            Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK),
            operation: "fcntl(F_SETFL)"
        )
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
            }
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                throw POSIXTestFailure(operation: "write", code: errno)
            }
        }
    }

    private func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
        var received = Data()
        while received.count < count {
            try waitUntilReadable(descriptor)
            var bytes = [UInt8](repeating: 0, count: count - received.count)
            let readCount = bytes.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if readCount > 0 {
                received.append(contentsOf: bytes.prefix(readCount))
            } else if readCount < 0, errno == EINTR {
                continue
            } else {
                throw POSIXTestFailure(operation: "read", code: errno)
            }
        }
        return received
    }

    private func expectEOF(from descriptor: Int32) throws {
        try waitUntilReadable(descriptor)
        var byte: UInt8 = 0
        let count = Darwin.read(descriptor, &byte, 1)
        guard count == 0 else {
            throw POSIXTestFailure(operation: "read(expected EOF)", code: errno)
        }
    }

    private func waitUntilReadable(_ descriptor: Int32) throws {
        var pollDescriptor = pollfd(
            fd: descriptor,
            events: Int16(POLLIN),
            revents: 0
        )
        let result = Darwin.poll(&pollDescriptor, 1, 2_000)
        guard result > 0 else {
            throw POSIXTestFailure(
                operation: result == 0 ? "poll(timeout)" : "poll",
                code: result == 0 ? ETIMEDOUT : errno
            )
        }
    }

    private func requireZero(_ result: Int32, operation: String) throws {
        guard result == 0 else {
            throw POSIXTestFailure(operation: operation, code: errno)
        }
    }

    private func bindListeningIPv4Loopback(port: UInt16) throws -> (descriptor: Int32, port: UInt16) {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXTestFailure(operation: "socket(AF_INET)", code: errno)
        }
        do {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
            try requireZero(
                withUnsafePointer(to: &address) { addressPointer in
                    addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(
                            descriptor,
                            $0,
                            socklen_t(MemoryLayout<sockaddr_in>.size)
                        )
                    }
                },
                operation: "bind(AF_INET)"
            )
            try requireZero(Darwin.listen(descriptor, 1), operation: "listen")
            return (descriptor, try getsocknameIPv4Port(of: descriptor))
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func connectIPv4Loopback(port: UInt16) throws -> Int32 {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXTestFailure(operation: "socket(AF_INET)", code: errno)
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
        guard result == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw POSIXTestFailure(operation: "connect(AF_INET)", code: code)
        }
        return descriptor
    }

    private func connectIPv6Loopback(port: UInt16) throws -> Int32 {
        let descriptor = Darwin.socket(AF_INET6, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXTestFailure(operation: "socket(AF_INET6)", code: errno)
        }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        address.sin6_addr = in6addr_loopback
        let result = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in6>.size)
                )
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw POSIXTestFailure(operation: "connect(AF_INET6)", code: code)
        }
        return descriptor
    }

    private func getsocknameIPv4Port(of descriptor: Int32) throws -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        try requireZero(
            withUnsafeMutablePointer(to: &address) { addressPointer in
                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getsockname(descriptor, $0, &length)
                }
            },
            operation: "getsockname(AF_INET)"
        )
        return UInt16(bigEndian: address.sin_port)
    }

    private func getpeernameIPv4Port(of descriptor: Int32) throws -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        try requireZero(
            withUnsafeMutablePointer(to: &address) { addressPointer in
                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getpeername(descriptor, $0, &length)
                }
            },
            operation: "getpeername(AF_INET)"
        )
        return UInt16(bigEndian: address.sin_port)
    }

    private func getsocknameIPv6Port(of descriptor: Int32) throws -> UInt16 {
        var address = sockaddr_in6()
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        try requireZero(
            withUnsafeMutablePointer(to: &address) { addressPointer in
                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getsockname(descriptor, $0, &length)
                }
            },
            operation: "getsockname(AF_INET6)"
        )
        return UInt16(bigEndian: address.sin6_port)
    }

    private func getpeernameIPv6Port(of descriptor: Int32) throws -> UInt16 {
        var address = sockaddr_in6()
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        try requireZero(
            withUnsafeMutablePointer(to: &address) { addressPointer in
                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getpeername(descriptor, $0, &length)
                }
            },
            operation: "getpeername(AF_INET6)"
        )
        return UInt16(bigEndian: address.sin6_port)
    }
}

private struct POSIXTestFailure: Error, CustomStringConvertible {
    let operation: String
    let code: Int32

    var description: String {
        "\(operation) failed with errno \(code)"
    }
}
