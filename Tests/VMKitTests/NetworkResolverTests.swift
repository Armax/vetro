import Testing
@testable import VMKit

@Suite("macOS DHCP lease parsing")
struct NetworkResolverTests {
    @Test("parser matches a normalized MAC among several lease blocks")
    func parsesMatchingLease() {
        let leases = """
        {
            name=other;
            ip_address=192.168.64.2;
            hw_address=1,3a:22:33:44:55:66;
            lease=0x1234;
        }
        {
            name=vetro;
            ip_address=192.168.64.7;
            hw_address=1,9a:5:c:d:e:f;
            lease=0x5678;
        }
        {
            name=unrelated;
            ip_address=192.168.64.9;
            hw_address=1,aa:bb:cc:dd:ee:ff;
        }
        """
        let resolver = NetworkResolver()

        #expect(
            resolver.ipAddress(
                forMACAddress: "9a:05:0c:0d:0e:0f",
                in: leases
            ) == "192.168.64.7"
        )
    }

    @Test("parser returns nil when the MAC is absent")
    func absentMAC() {
        let leases = """
        {
            name=other;
            ip_address=192.168.64.2;
            hw_address=1,3a:22:33:44:55:66;
        }
        """
        let resolver = NetworkResolver()

        #expect(
            resolver.ipAddress(
                forMACAddress: "9a:05:0c:0d:0e:0f",
                in: leases
            ) == nil
        )
    }

    @Test("normalization treats zero-padded and stripped octets as equivalent")
    func normalizationEquivalence() {
        let resolver = NetworkResolver()
        let padded = resolver.normalizeMACAddress("9a:05:0c:0d:0e:0f")
        let stripped = resolver.normalizeMACAddress("9A:5:c:d:e:f")

        #expect(padded == "9a:05:0c:0d:0e:0f")
        #expect(stripped == padded)
        #expect(resolver.normalizeMACAddress("not-a-mac") == nil)
    }
}
