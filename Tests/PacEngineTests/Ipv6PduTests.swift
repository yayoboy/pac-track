import Testing
@testable import PacEngine

private let MAC = "02:00:00:00:00:01"

private func valid(_ p: Ipv6Packet) -> Bool {
    internetChecksum(pseudoHeader6(p.src, p.dst, p.payload.size, p.payload.nextHeader) + serializePayload(p)) == 0
}

private func frame(_ p: Ipv6Packet) -> EthernetFrame {
    EthernetFrame(id: 1, src: MAC, dst: isMulticast6(p.dst) ? multicastMac6(p.dst) : "02:00:00:00:00:02", etherType: ETHERTYPE_IPV6, payload: .ipv6(p))
}

@Suite struct Ipv6PduTests {
    @Test func parsesAndPrintsAddressesTheRfc5952Way() throws {
        #expect(formatIp6(try parseIp6("2001:0DB8:0000:0000:0000:0000:0000:0001")) == "2001:db8::1")
        #expect(formatIp6(try parseIp6("2001:db8:0:0:1:0:0:1")) == "2001:db8::1:0:0:1") // the first of two equal runs
        #expect(formatIp6(try parseIp6("2001:db8:0:1:1:1:1:1")) == "2001:db8:0:1:1:1:1:1") // one zero group stays
        #expect(formatIp6(try parseIp6("::")) == "::")
        #expect(formatIp6(try parseIp6("::1")) == "::1")
        #expect(formatIp6(try parseIp6("fe80::")) == "fe80::")
        #expect(formatIp6(try parseIp6("1:2:3:4:5:6:7::")) == "1:2:3:4:5:6:7:0")
        for bad in ["", ":", ":::", "1::2::3", "1:2:3:4:5:6:7:8:9", "1:2:3:4:5:6:7", "12345::", "g::1", "::ffff:1.2.3.4", "fe80::1%eth0", " ::1"] {
            expectError("Invalid IPv6 address") { _ = try parseIp6(bad) }
        }
        #expect(try parseCidr6("2001:db8:1::/64") == Cidr6(addr: try parseIp6("2001:db8:1::"), prefix: 64))
        for bad in ["2001:db8::1", "2001:db8::1/129", "2001:db8::1/+6", "2001:db8::1/"] {
            expectError("Invalid IPv6 prefix") { _ = try parseCidr6(bad) }
        }
    }

    @Test func derivesLinkLocalSolicitedNodeAndMulticastMacs() throws {
        #expect(formatIp6(linkLocal(MAC)) == "fe80::ff:fe00:1")
        #expect(formatIp6(linkLocal("00:1a:2b:3c:4d:5e")) == "fe80::21a:2bff:fe3c:4d5e")
        let a = try parseIp6("2001:db8::abcd:1234")
        #expect(formatIp6(solicitedNode(a)) == "ff02::1:ffcd:1234")
        #expect(multicastMac6(solicitedNode(a)) == "33:33:ff:cd:12:34")
        #expect(multicastMac6(ALL_NODES) == "33:33:00:00:00:01" && formatIp6(ALL_ROUTERS) == "ff02::2")
        #expect(try isLinkLocal6(parseIp6("febf::1")) && !isLinkLocal6(parseIp6("fec0::1")) && isMulticast6(ALL_ROUTERS))
        #expect(try formatIp6(networkOf6(a, 64)) == "2001:db8::" && inSubnet6(a, parseIp6("2001:db8::"), 64))
    }

    @Test func packetsHaveTheirWireSizesAndValidChecksums() throws {
        let ll = linkLocal(MAC)
        let target = try parseIp6("2001:db8::2")
        let ns = makeIpv6(src: ll, dst: solicitedNode(target), hopLimit: 255, payload: .ndp(NdpMessage(body: .ns(target: target, slla: MAC))))
        let dad = makeIpv6(src: 0, dst: solicitedNode(target), hopLimit: 255, payload: .ndp(NdpMessage(body: .ns(target: target, slla: nil))))
        let na = makeIpv6(src: target, dst: ll, hopLimit: 255,
                          payload: .ndp(NdpMessage(body: .na(target: target, router: false, solicited: true, override: true, tlla: MAC))))
        let rs = makeIpv6(src: ll, dst: ALL_ROUTERS, hopLimit: 255, payload: .ndp(NdpMessage(body: .rs(slla: MAC))))
        let ra = makeIpv6(src: ll, dst: ALL_NODES, hopLimit: 255, payload: .ndp(NdpMessage(body: .ra(RouterAdvert(
            slla: MAC, prefixes: [PrefixInfo(prefix: try parseIp6("2001:db8:1::"), length: 64)])))))
        let echo = makeIpv6(src: ll, dst: target, hopLimit: 64, payload: .icmp(IcmpMessage(
            type: ICMP6_ECHO_REQUEST, code: 0, checksum: 0, id: 1, seq: 1, data: [UInt8](repeating: 0, count: 56))))
        let udp = makeIpv6(src: ll, dst: target, hopLimit: 1, payload: .udp(makeUdp(srcPort: 33000, dstPort: 33434, data: [UInt8](repeating: 0, count: 32))))
        let all = [ns, dad, na, rs, ra, echo, udp]
        #expect(all.map { frame($0).size } == [86, 78, 86, 70, 118, 118, 94])
        #expect(all.allSatisfy(valid))
        #expect(all.allSatisfy { serializePayload($0).count == $0.payload.size })
        let header = serializeHeader(echo)
        #expect(header.count == 40 && Array(header[0..<8]) == [0x60, 0, 0, 0, 0, 64, 58, 64])
        let raBytes = serializePayload(ra)
        #expect(Array(raBytes[0..<8]) == [134, 0] + u16(ra.payload.ndpChecksum) + [64, 0, 0x07, 0x08])
        #expect(Array(raBytes[24..<36]) == [5, 1, 0, 0, 0, 0, 0x05, 0xDC, 3, 4, 64, 0xC0])
        #expect(serializePayload(na)[4] == 0x60) // S and O
        guard case .udp(let u) = udp.payload else {
            Issue.record("not UDP")
            return
        }
        #expect(u.checksum != 0) // mandatory over IPv6
    }

    /// IPv6 rows name the message first: the event list cuts long lines, and two IPv6 addresses fill it (review M9a).
    @Test func theInspectorShowsIpv6IcmpV6AndNdp() throws {
        let ll = linkLocal(MAC)
        let target = try parseIp6("2001:db8::2")
        let event = { (p: Ipv6Packet) in SimEvent(time: 0, kind: .tx, node: "A", iface: "eth0", frame: frame(p)) }
        let ns = makeIpv6(src: ll, dst: solicitedNode(target), hopLimit: 255, payload: .ndp(NdpMessage(body: .ns(target: target, slla: MAC))))
        let view = eventView(event(ns))
        #expect(view.proto == .ndp && view.bytes == 86 && view.info == "NDP NS chi ha 2001:db8::2? · fe80::ff:fe00:1 → ff02::1:ff00:2")
        let layers = pduLayers(event(ns))
        #expect(layers.map(\.title) == ["Ethernet II", "IPv6", "ICMPv6"])
        #expect(layers[0].fields[2] == PduField(name: "EtherType", value: "0x86dd (IPv6)"))
        #expect(layers[1].fields.contains(PduField(name: "Hop limit", value: "255")))
        #expect(layers[1].fields.contains(PduField(name: "Next header", value: "58 (ICMPv6)")))
        #expect(layers[2].fields.contains(PduField(name: "Target", value: "2001:db8::2")))
        #expect(layers[2].fields.contains(PduField(name: "Opzione 1", value: "Source link-layer address 02:00:00:00:00:01")))
        let dad = makeIpv6(src: 0, dst: solicitedNode(target), hopLimit: 255, payload: .ndp(NdpMessage(body: .ns(target: target, slla: nil))))
        #expect(eventView(event(dad)).info == "NDP NS DAD 2001:db8::2 · :: → ff02::1:ff00:2")
        let na = makeIpv6(src: target, dst: ALL_NODES, hopLimit: 255,
                          payload: .ndp(NdpMessage(body: .na(target: target, router: true, solicited: false, override: true, tlla: MAC))))
        #expect(eventView(event(na)).info == "NDP NA 2001:db8::2 è 02:00:00:00:00:01 [R, O] · 2001:db8::2 → ff02::1")
        let ra = makeIpv6(src: ll, dst: ALL_NODES, hopLimit: 255, payload: .ndp(NdpMessage(body: .ra(RouterAdvert(
            slla: MAC, prefixes: [PrefixInfo(prefix: try parseIp6("2001:db8:1::"), length: 64)])))))
        #expect(eventView(event(ra)).info == "NDP RA 2001:db8:1::/64, lifetime 1800 s · fe80::ff:fe00:1 → ff02::1")
        #expect(pduLayers(event(ra))[2].fields.contains(PduField(name: "Router lifetime", value: "1800 s")))
        let echo = makeIpv6(src: ll, dst: target, hopLimit: 64, payload: .icmp(IcmpMessage(
            type: ICMP6_ECHO_REQUEST, code: 0, checksum: 0, id: 7, seq: 1, data: [UInt8](repeating: 0, count: 56))))
        let echoView = eventView(event(echo))
        #expect(echoView.proto == .icmp && echoView.info == "ICMPv6 Echo request id=7 seq=1 hlim=64 · fe80::ff:fe00:1 → 2001:db8::2")
        // An IPv6 packet dropped above the link (no frame) shows as a bare packet.
        let drop = SimEvent(time: 0, kind: .drop, node: "A", reason: .noRoute, packet6: echo)
        #expect(eventView(drop).bytes == 104 && pduLayers(drop).map(\.title) == ["IPv6", "ICMPv6"])
        let tooBig = makeIpv6(src: target, dst: ll, hopLimit: 64, payload: .icmp(IcmpMessage(
            type: ICMP6_PACKET_TOO_BIG, code: 0, checksum: 0, id: 0, seq: 1500, data: [])))
        #expect(eventView(event(tooBig)).info == "ICMPv6 Packet too big (MTU 1500) hlim=64 · 2001:db8::2 → fe80::ff:fe00:1")
    }
}

private extension Ipv6Payload {
    var ndpChecksum: UInt16 {
        if case .ndp(let n) = self { return n.checksum }
        return 0
    }
}
