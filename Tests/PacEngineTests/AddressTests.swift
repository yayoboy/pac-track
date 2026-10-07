import Testing
@testable import PacEngine

@Suite struct AddressTests {
    @Test func roundTripsDottedQuads() throws {
        for ip in ["0.0.0.0", "10.0.0.1", "192.168.1.254", "255.255.255.255"] {
            #expect(formatIp(try parseIp(ip)) == ip)
        }
        #expect(try parseIp("192.168.0.1") == 0xC0A8_0001)
    }

    @Test func rejectsMalformedAddresses() {
        for bad in ["10.0.0.256", "10.0.0", "10.0.0.1.2", "a.b.c.d", "01.2.3.4", " 10.0.0.1", "", "-1.0.0.0"] {
            expectError("Invalid IPv4 address: \"\(bad)\"") { _ = try parseIp(bad) }
        }
    }

    @Test func parsesCidrAndRejectsBadPrefixes() throws {
        #expect(try parseCidr("10.0.0.5/24") == Cidr(addr: try parseIp("10.0.0.5"), prefix: 24))
        #expect(try parseCidr("0.0.0.0/0") == Cidr(addr: 0, prefix: 0))
        for bad in ["10.0.0.1/33", "10.0.0.1", "10.0.0.1/", "10.0.0.1/ 24", "10.0.0.1/24/1", "10.0.0.1/024"] {
            expectError("Invalid") { _ = try parseCidr(bad) }
        }
    }

    @Test func computesMasksNetworksAndBroadcasts() throws {
        #expect(prefixMask(0) == 0)
        #expect(prefixMask(24) == 0xFFFF_FF00)
        #expect(prefixMask(32) == 0xFFFF_FFFF)
        #expect(formatIp(networkOf(try parseIp("10.0.0.5"), 30)) == "10.0.0.4")
        #expect(formatIp(broadcastOf(try parseIp("10.0.0.5"), 30)) == "10.0.0.7")
        #expect(inSubnet(try parseIp("192.168.1.77"), try parseIp("192.168.1.0"), 24))
        #expect(!inSubnet(try parseIp("192.168.2.1"), try parseIp("192.168.1.0"), 24))
        #expect(inSubnet(try parseIp("8.8.8.8"), 0, 0))
    }

    @Test func generatesLocallyAdministeredUnicastMacs() {
        #expect(macFromIndex(11) == "02:00:00:00:00:0b")
        #expect(macFromIndex(0x0102_0304) == "02:00:01:02:03:04")
        #expect(!isGroupMac(macFromIndex(1)))
    }

    @Test func detectsBroadcastAndMulticast() {
        #expect(isGroupMac("ff:ff:ff:ff:ff:ff"))
        #expect(isGroupMac("01:00:5e:00:00:01"))
    }
}
