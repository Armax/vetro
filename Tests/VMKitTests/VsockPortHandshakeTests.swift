import Foundation
import Testing
@testable import VMKit

@Suite("Vsock port-forward handshake framing")
struct VsockPortHandshakeTests {
    @Test("request encodes CONNECT with a trailing newline")
    func requestEncoding() {
        #expect(VsockPortHandshake.request(guestPort: 5_173) == Data("CONNECT 5173\n".utf8))
        #expect(VsockPortHandshake.request(guestPort: 80) == Data("CONNECT 80\n".utf8))
    }

    @Test("consume parses OK and leaves trailing payload")
    func consumeOKWithRemainder() {
        var buffer = Data("OK\nHTTP/1.1 200 OK\n".utf8)
        #expect(VsockPortHandshake.consumeResponse(from: &buffer) == .ok)
        #expect(buffer == Data("HTTP/1.1 200 OK\n".utf8))
    }

    @Test("consume parses CR LF terminated OK")
    func consumeOKWithCRLF() {
        var buffer = Data("OK\r\n".utf8)
        #expect(VsockPortHandshake.consumeResponse(from: &buffer) == .ok)
        #expect(buffer.isEmpty)
    }

    @Test("consume parses ERR reasons")
    func consumeERR() {
        var refused = Data("ERR [Errno 111] Connection refused\n".utf8)
        #expect(
            VsockPortHandshake.consumeResponse(from: &refused)
                == .error("[Errno 111] Connection refused")
        )
        #expect(refused.isEmpty)

        var bare = Data("ERR\n".utf8)
        #expect(VsockPortHandshake.consumeResponse(from: &bare) == .error(""))
    }

    @Test("consume returns nil until a full line arrives")
    func consumeIncomplete() {
        var buffer = Data("O".utf8)
        #expect(VsockPortHandshake.consumeResponse(from: &buffer) == nil)
        #expect(buffer == Data("O".utf8))

        buffer.append(contentsOf: Data("K".utf8))
        #expect(VsockPortHandshake.consumeResponse(from: &buffer) == nil)

        buffer.append(contentsOf: Data("\nmore".utf8))
        #expect(VsockPortHandshake.consumeResponse(from: &buffer) == .ok)
        #expect(buffer == Data("more".utf8))
    }

    @Test("consume rejects unexpected lines")
    func consumeInvalid() {
        var buffer = Data("NOPE\n".utf8)
        #expect(VsockPortHandshake.consumeResponse(from: &buffer) == .invalid)
        #expect(buffer.isEmpty)
    }

    @Test("consumeRequest parses CONNECT and leaves trailing payload")
    func consumeRequestValid() {
        var buffer = Data("CONNECT 5173\nREST".utf8)
        #expect(VsockPortHandshake.consumeRequest(from: &buffer) == .connect(guestPort: 5_173))
        #expect(buffer == Data("REST".utf8))

        var crlf = Data("CONNECT 80\r\n".utf8)
        #expect(VsockPortHandshake.consumeRequest(from: &crlf) == .connect(guestPort: 80))
        #expect(crlf.isEmpty)
    }

    @Test("consumeRequest returns nil until a full line arrives")
    func consumeRequestPartial() {
        var buffer = Data("CONNECT 8".utf8)
        #expect(VsockPortHandshake.consumeRequest(from: &buffer) == nil)
        #expect(buffer == Data("CONNECT 8".utf8))

        buffer.append(contentsOf: Data("0\nmore".utf8))
        #expect(VsockPortHandshake.consumeRequest(from: &buffer) == .connect(guestPort: 80))
        #expect(buffer == Data("more".utf8))
    }

    @Test("consumeRequest rejects garbage lines")
    func consumeRequestGarbage() {
        var buffer = Data("NOPE\n".utf8)
        #expect(VsockPortHandshake.consumeRequest(from: &buffer) == .invalid)
        #expect(buffer.isEmpty)

        var missingSpace = Data("CONNECT80\n".utf8)
        #expect(VsockPortHandshake.consumeRequest(from: &missingSpace) == .invalid)
    }

    @Test("consumeRequest rejects out-of-range ports")
    func consumeRequestOutOfRange() {
        var zero = Data("CONNECT 0\n".utf8)
        #expect(VsockPortHandshake.consumeRequest(from: &zero) == .invalid)

        var over = Data("CONNECT 65536\n".utf8)
        #expect(VsockPortHandshake.consumeRequest(from: &over) == .invalid)

        var huge = Data("CONNECT 99999\n".utf8)
        #expect(VsockPortHandshake.consumeRequest(from: &huge) == .invalid)
    }
}
