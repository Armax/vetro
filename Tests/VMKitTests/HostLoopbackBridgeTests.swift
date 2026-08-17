import Darwin
import Foundation
import Testing
@testable import VMKit

@Suite("Host loopback reverse bridge")
struct HostLoopbackBridgeTests {
    @Test("allowlisted port replies OK and relays both directions")
    func allowlistedPortRelaysBytes() throws {
        let service = try bindListeningIPv4Loopback(port: 0)
        defer { Darwin.close(service.descriptor) }
        let pair = try makeSocketPair()
        let guest = pair.0
        let vsock = pair.1
        let queue = DispatchQueue(label: "com.vetro.vmkit.tests.host-loopback-ok")
        let didStop = DispatchSemaphore(value: 0)
        let acceptedBox = AcceptedDescriptor()
        let acceptedReady = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            acceptedBox.descriptor = withUnsafeMutablePointer(to: &address) { addressPointer in
                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(service.descriptor, $0, &length)
                }
            }
            acceptedReady.signal()
        }

        let bridge = HostLoopbackBridge(
            queue: queue,
            connectionDescriptor: vsock,
            allowlist: { [service] in [service.port] },
            closeConnection: { Darwin.close(vsock) },
            didStop: { didStop.signal() }
        )
        queue.sync {
            bridge.start()
        }
        defer {
            queue.sync {
                bridge.stop()
            }
            Darwin.close(guest)
            if acceptedBox.descriptor >= 0 {
                Darwin.close(acceptedBox.descriptor)
            }
        }

        try writeAll(Data("CONNECT \(service.port)\n".utf8), to: guest)
        #expect(try readLine(from: guest) == "OK")
        #expect(acceptedReady.wait(timeout: .now() + 2) == .success)
        #expect(acceptedBox.descriptor >= 0)

        let towardHost = Data("guest-to-host".utf8)
        try writeAll(towardHost, to: guest)
        #expect(try readExactly(towardHost.count, from: acceptedBox.descriptor) == towardHost)

        let towardGuest = Data("host-to-guest".utf8)
        try writeAll(towardGuest, to: acceptedBox.descriptor)
        #expect(try readExactly(towardGuest.count, from: guest) == towardGuest)
    }

    @Test("non-allowlisted port replies ERR not allowed")
    func nonAllowlistedPortIsRejected() throws {
        let pair = try makeSocketPair()
        let guest = pair.0
        let vsock = pair.1
        let queue = DispatchQueue(label: "com.vetro.vmkit.tests.host-loopback-deny")
        let didStop = DispatchSemaphore(value: 0)

        let bridge = HostLoopbackBridge(
            queue: queue,
            connectionDescriptor: vsock,
            allowlist: { [8_080] },
            closeConnection: { Darwin.close(vsock) },
            didStop: { didStop.signal() }
        )
        queue.sync {
            bridge.start()
        }
        defer {
            queue.sync {
                bridge.stop()
            }
            Darwin.close(guest)
        }

        try writeAll(Data("CONNECT 3000\n".utf8), to: guest)
        #expect(try readLine(from: guest) == "ERR not allowed")
        try expectEOF(from: guest)
        #expect(didStop.wait(timeout: .now() + 2) == .success)
    }

    @Test("garbage handshake closes the connection")
    func garbageHandshakeCloses() throws {
        let pair = try makeSocketPair()
        let guest = pair.0
        let vsock = pair.1
        let queue = DispatchQueue(label: "com.vetro.vmkit.tests.host-loopback-garbage")
        let didStop = DispatchSemaphore(value: 0)

        let bridge = HostLoopbackBridge(
            queue: queue,
            connectionDescriptor: vsock,
            allowlist: { [80] },
            closeConnection: { Darwin.close(vsock) },
            didStop: { didStop.signal() }
        )
        queue.sync {
            bridge.start()
        }
        defer {
            queue.sync {
                bridge.stop()
            }
            Darwin.close(guest)
        }

        try writeAll(Data("NOPE\n".utf8), to: guest)
        try expectClosed(from: guest)
        #expect(didStop.wait(timeout: .now() + 2) == .success)
    }

    private func makeSocketPair() throws -> (Int32, Int32) {
        var descriptors = [Int32](repeating: -1, count: 2)
        let result = descriptors.withUnsafeMutableBufferPointer { buffer in
            Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress)
        }
        try requireZero(result, operation: "socketpair")
        return (descriptors[0], descriptors[1])
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

    private func readLine(from descriptor: Int32) throws -> String {
        var received = Data()
        while !received.contains(0x0A) {
            try waitUntilReadable(descriptor)
            var byte: UInt8 = 0
            let count = Darwin.read(descriptor, &byte, 1)
            if count > 0 {
                received.append(byte)
            } else if count < 0, errno == EINTR {
                continue
            } else {
                throw POSIXTestFailure(operation: "read(line)", code: errno)
            }
        }
        if received.last == 0x0A {
            received.removeLast()
        }
        if received.last == 0x0D {
            received.removeLast()
        }
        return String(decoding: received, as: UTF8.self)
    }

    private func expectEOF(from descriptor: Int32) throws {
        try waitUntilReadable(descriptor)
        var byte: UInt8 = 0
        let count = Darwin.read(descriptor, &byte, 1)
        guard count == 0 else {
            throw POSIXTestFailure(operation: "read(expected EOF)", code: errno)
        }
    }

    private func expectClosed(from descriptor: Int32) throws {
        try waitUntilReadable(descriptor)
        var bytes = [UInt8](repeating: 0, count: 64)
        let count = bytes.withUnsafeMutableBytes { rawBuffer in
            Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
        }
        if count == 0 {
            return
        }
        if count > 0 {
            try expectEOF(from: descriptor)
            return
        }
        throw POSIXTestFailure(operation: "read(expected close)", code: errno)
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
            var reuse: Int32 = 1
            _ = withUnsafePointer(to: &reuse) {
                Darwin.setsockopt(
                    descriptor,
                    SOL_SOCKET,
                    SO_REUSEADDR,
                    $0,
                    socklen_t(MemoryLayout<Int32>.size)
                )
            }
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
}

private final class AcceptedDescriptor: @unchecked Sendable {
    var descriptor: Int32 = -1
}

private struct POSIXTestFailure: Error, CustomStringConvertible {
    let operation: String
    let code: Int32

    var description: String {
        "\(operation) failed with errno \(code)"
    }
}
