/// Never "the Internet": this network, private (RFC 1918), loopback, link-local, multicast and reserved addresses.
private let NOT_INTERNET: [(net: UInt32, prefix: Int)] = [(0x0000_0000, 8), (0x0A00_0000, 8), (0x7F00_0000, 8), (0xA9FE_0000, 16),
                                                          (0xAC10_0000, 12), (0xC0A8_0000, 16), (0xE000_0000, 3)]

/// ISP edge (spec §5.5): a router whose Internet is every public address it has no route for. It answers for them itself —
/// ping, traceroute's last hop, TCP RST and the DNS server it runs — so a lab reaches "the Internet" through NAT with no more devices.
final class Cloud: Router {
    override func ownsIp(_ ip: UInt32) -> Bool {
        super.ownsIp(ip) || (!NOT_INTERNET.contains { inSubnet(ip, $0.net, $0.prefix) } && routes.lookup(ip) == nil)
    }
}
