import Foundation
import Testing
@testable import VMKit

@Suite("Vsock hook frame parsing")
struct VsockHookFrameTests {
    @Test("parses a complete hook line")
    func parsesCompleteLine() {
        let session = UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")!
        var buffer = Data("\(session.uuidString)\tprompt-submit\t{\"cwd\":\"/tmp\"}\n".utf8)
        #expect(
            VsockHookFrame.consume(from: &buffer)
                == .event(
                    .init(sessionID: session, name: "prompt-submit", payload: "{\"cwd\":\"/tmp\"}")
                )
        )
        #expect(buffer.isEmpty)
    }

    @Test("keeps an empty session id as nil")
    func emptySessionID() {
        var buffer = Data("\tstop\t\n".utf8)
        #expect(
            VsockHookFrame.consume(from: &buffer)
                == .event(.init(sessionID: nil, name: "stop", payload: ""))
        )
        #expect(buffer.isEmpty)
    }

    @Test("preserves extra tabs inside the payload")
    func payloadKeepsTabs() {
        var buffer = Data("\tnotification\t{\"message\":\"a\tb\"}\n".utf8)
        #expect(
            VsockHookFrame.consume(from: &buffer)
                == .event(.init(sessionID: nil, name: "notification", payload: "{\"message\":\"a\tb\"}"))
        )
    }

    @Test("returns needMore until a full line arrives")
    func partialFrame() {
        var buffer = Data("abc\tstop".utf8)
        #expect(VsockHookFrame.consume(from: &buffer) == .needMore)
        #expect(buffer == Data("abc\tstop".utf8))

        buffer.append(contentsOf: Data("\t{}\nleftover".utf8))
        #expect(
            VsockHookFrame.consume(from: &buffer)
                == .event(.init(sessionID: nil, name: "stop", payload: "{}"))
        )
        #expect(buffer == Data("leftover".utf8))
    }

    @Test("accepts CR LF terminated lines")
    func crlfLine() {
        var buffer = Data("\tsession-end\t\r\n".utf8)
        #expect(
            VsockHookFrame.consume(from: &buffer)
                == .event(.init(sessionID: nil, name: "session-end", payload: ""))
        )
        #expect(buffer.isEmpty)
    }

    @Test("ignores malformed and empty-event lines")
    func ignoresMalformed() {
        var missingTab = Data("not-a-hook-line\n".utf8)
        #expect(VsockHookFrame.consume(from: &missingTab) == .ignored)
        #expect(missingTab.isEmpty)

        var emptyEvent = Data("id\t\tpayload\n".utf8)
        #expect(VsockHookFrame.consume(from: &emptyEvent) == .ignored)
        #expect(emptyEvent.isEmpty)
    }

    @Test("overflows when a line never terminates")
    func overflowWithoutNewline() {
        var buffer = Data(repeating: 0x61, count: VsockHookFrame.maxLineBytes)
        #expect(VsockHookFrame.consume(from: &buffer) == .needMore)
        buffer.append(0x61)
        #expect(VsockHookFrame.consume(from: &buffer) == .overflow)
        #expect(buffer.count == VsockHookFrame.maxLineBytes + 1)
    }

    @Test("ignores an oversized complete line and keeps the remainder")
    func ignoresOversizedCompleteLine() {
        var oversized = Data(repeating: 0x61, count: VsockHookFrame.maxLineBytes + 1)
        oversized.append(0x0A)
        oversized.append(contentsOf: Data("\tstop\t\n".utf8))
        #expect(VsockHookFrame.consume(from: &oversized) == .ignored)
        #expect(
            VsockHookFrame.consume(from: &oversized)
                == .event(.init(sessionID: nil, name: "stop", payload: ""))
        )
        #expect(oversized.isEmpty)
    }
}
