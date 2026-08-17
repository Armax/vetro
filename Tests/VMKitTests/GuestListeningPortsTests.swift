import Foundation
import Testing
@testable import VMKit

@Suite("Guest ss listener parsing")
struct GuestListeningPortsTests {
    @Test("extracts and dedupes IPv4, IPv6, and wildcard listen ports")
    func parsesTypicalSSOutput() {
        let output = """
        LISTEN 0      128          0.0.0.0:22         0.0.0.0:*
        LISTEN 0      128        127.0.0.1:3000       0.0.0.0:*
        LISTEN 0      128          0.0.0.0:5173       0.0.0.0:*
        LISTEN 0      128             [::]:5173          [::]:*
        LISTEN 0      128             [::]:8080          [::]:*
        LISTEN 0      511          127.0.0.1:40327     0.0.0.0:*
        LISTEN 0      4096     127.0.0.53%lo:53        0.0.0.0:*
        LISTEN 0      128                *:4000             *:*
        """

        #expect(
            GuestListeningPorts.parse(output) == [22, 3_000, 5_173, 8_080, 40_327, 53, 4_000]
        )
    }

    @Test("ignores non-listen rows and malformed addresses")
    func ignoresNoise() {
        let output = """
        ESTAB 0 0 127.0.0.1:5173 127.0.0.1:43000
        LISTEN 0 128
        TIME-WAIT 0 0 127.0.0.1:8080 127.0.0.1:9
        """
        #expect(GuestListeningPorts.parse(output).isEmpty)
    }

    @Test("parseProcNet extracts LISTEN ports and ignores other states")
    func parseProcNetListenRows() {
        let tcp = """
          sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 0100007F:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1 1 0000000000000000 100 0 0 10 0
           1: 0100007F:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 2 1 0000000000000000 100 0 0 10 0
           2: 0100007F:0BB8 0100007F:C350 01 00000000:00000000 00:00000000 00000000     0        0 3 1 0000000000000000 100 0 0 10 0
           3: 00000000:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 4 1 0000000000000000 100 0 0 10 0
           4: 0100007F:1435 0100007F:C351 06 00000000:00000000 00:00000000 00000000     0        0 5 1 0000000000000000 100 0 0 10 0
        """
        let tcp6 = """
          sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 00000000000000000000000000000000:1F90 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 6 1 0000000000000000 100 0 0 10 0
           1: 00000000000000000000000001000000:1435 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 7 1 0000000000000000 100 0 0 10 0
           2: 00000000000000000000000001000000:0BB8 00000000000000000000000001000000:C350 01 00000000:00000000 00:00000000 00000000     0        0 8 1 0000000000000000 100 0 0 10 0
        """

        #expect(GuestListeningPorts.parseProcNet(tcp) == [22, 3_000, 8_080])
        #expect(GuestListeningPorts.parseProcNet(tcp6) == [8_080, 5_173])
        #expect(
            GuestListeningPorts.parseProcNet(tcp).union(GuestListeningPorts.parseProcNet(tcp6))
                == [22, 3_000, 5_173, 8_080]
        )
        #expect(
            GuestListeningPorts.parseProcNet(tcp + "\n" + tcp6) == [22, 3_000, 5_173, 8_080]
        )
    }

    @Test("PortDiff decodes snapshot, added/removed, and refused line shapes")
    func portDiffJSONShapes() throws {
        let snapshot = try JSONDecoder().decode(
            PortDiff.self,
            from: Data(#"{"snapshot":[3000,8080]}"#.utf8)
        )
        #expect(snapshot.snapshot == [3_000, 8_080])
        #expect(snapshot.added.isEmpty)
        #expect(snapshot.removed.isEmpty)
        #expect(snapshot.refused == nil)

        let diff = try JSONDecoder().decode(
            PortDiff.self,
            from: Data(#"{"added":[5173],"removed":[8080]}"#.utf8)
        )
        #expect(diff.snapshot == nil)
        #expect(diff.added == [5_173])
        #expect(diff.removed == [8_080])
        #expect(diff.refused == nil)

        let refused = try JSONDecoder().decode(
            PortDiff.self,
            from: Data(#"{"refused":[5432,6379]}"#.utf8)
        )
        #expect(refused.snapshot == nil)
        #expect(refused.added.isEmpty)
        #expect(refused.removed.isEmpty)
        #expect(refused.refused == [5_432, 6_379])

        let mixed = try JSONDecoder().decode(
            PortDiff.self,
            from: Data(#"{"added":[3000],"removed":[],"refused":[27017]}"#.utf8)
        )
        #expect(mixed.added == [3_000])
        #expect(mixed.removed.isEmpty)
        #expect(mixed.refused == [27_017])
    }
}
