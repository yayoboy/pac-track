import Testing
@testable import PacEngine

private let pcMac: Mac = "02:00:00:00:00:01"

private func frame(_ src: UInt32, _ dst: UInt32, _ sport: UInt16, _ dport: UInt16, _ payload: UdpPayload) -> EthernetFrame {
    EthernetFrame(id: 1, src: pcMac, dst: BROADCAST_MAC, etherType: ETHERTYPE_IPV4,
                  payload: .ipv4(makeIpv4(src: src, dst: dst, ttl: 64, id: 1,
                                          payload: .udp(makeUdp(srcPort: sport, dstPort: dport, payload: payload)))))
}

private func fields(_ layer: PduLayer) -> [String: String] {
    Dictionary(uniqueKeysWithValues: layer.fields.map { ($0.name, $0.value) })
}

@Suite struct DhcpDnsPduTests {
    @Test func dhcpMessagesArePaddedToTheBootpMinimumLikeRealClients() {
        let discover = DhcpMessage(op: 1, xid: 0x1A2B_3C4D, broadcast: true, chaddr: pcMac, type: .discover)
        #expect(discover.optionsSize == 4) // 53 (3 B) + end (1 B)
        #expect(discover.size == 300)
        let ack = DhcpMessage(op: 2, xid: 1, broadcast: true, yiaddr: 0x0A00_0064, chaddr: pcMac, type: .ack, leaseS: 86_400,
                              serverId: 0x0A00_0001, subnetMask: 0xFFFF_FF00, router: 0x0A00_0001, dns: 0x0A00_0035)
        #expect(ack.optionsSize == 34) // 3 + 5 × 6 + 1
        #expect(ack.size == 300)
        // Ethernet 14 + IPv4 20 + UDP 8 + BOOTP 300: the 342-byte DHCP frame Wireshark shows
        #expect(frame(0, BROADCAST_IP, 68, 67, .dhcp(discover)).size == 342)
    }

    @Test func dnsSizesFollowTheWireFormatWithNameCompression() {
        let query = DnsMessage(id: 0x1234, response: false, name: "www.lab")
        #expect(query.size == 25) // header 12 + name 9 (3www3lab0) + type/class 4
        #expect(query.flags == 0x0100)
        var reply = DnsMessage(id: 0x1234, response: true, authoritative: true, name: "www.lab",
                               answers: [DnsAnswer(ttl: 300, addr: 0x0A00_0050), DnsAnswer(ttl: 300, addr: 0x0A00_0051)])
        #expect(reply.size == 57) // + 2 answers × 16 B (2-byte pointer to the question name)
        #expect(reply.flags == 0x8500)
        reply.rcode = DNS_NXDOMAIN
        reply.answers = []
        #expect(reply.flags == 0x8503)
        #expect(frame(0x0A00_000A, 0x0A00_0035, 40000, 53, .dns(query)).size == 67)
    }

    @Test func describesDhcpEventsAndDecodesEveryBootpFieldAndOption() {
        let discover = DhcpMessage(op: 1, xid: 0x1A2B_3C4D, broadcast: true, chaddr: pcMac, type: .discover)
        let de = SimEvent(time: 0, kind: .tx, node: "C", iface: "eth0", frame: frame(0, BROADCAST_IP, 68, 67, .dhcp(discover)))
        #expect(eventView(de).info == "0.0.0.0 → 255.255.255.255 DHCP Discover xid=0x1a2b3c4d")
        let offer = DhcpMessage(op: 2, xid: 0x1A2B_3C4D, broadcast: true, yiaddr: 0x0A00_0064, chaddr: pcMac, type: .offer, leaseS: 3600,
                                serverId: 0x0A00_0001, subnetMask: 0xFFFF_FF00, router: 0x0A00_0001, dns: 0x0A00_0035)
        let e = SimEvent(time: 0, kind: .tx, node: "S", iface: "eth0", frame: frame(0x0A00_0001, BROADCAST_IP, 67, 68, .dhcp(offer)))
        let v = eventView(e)
        #expect(v.proto == .dhcp)
        #expect(v.bytes == 342)
        #expect(v.info == "10.0.0.1 → 255.255.255.255 DHCP Offer 10.0.0.100 xid=0x1a2b3c4d")
        let layers = pduLayers(e)
        #expect(layers.map(\.title) == ["Ethernet II", "IPv4", "UDP", "DHCP"])
        #expect(layers.map(\.bytes) == [342, 328, 308, 300])
        #expect(fields(layers[2])["Dati"] == "300 B (DHCP)")
        let dhcp = fields(layers[3])
        #expect(dhcp["Operazione"] == "2 (Boot Reply)")
        #expect(dhcp["Transaction ID"] == "0x1a2b3c4d")
        #expect(dhcp["Flag"] == "0x8000 (broadcast)")
        #expect(dhcp["IP client (ciaddr)"] == "0.0.0.0")
        #expect(dhcp["IP assegnato (yiaddr)"] == "10.0.0.100")
        #expect(dhcp["MAC client (chaddr)"] == pcMac)
        #expect(dhcp["Magic cookie"] == "0x63825363 (DHCP)")
        #expect(dhcp["Padding"] == "26 B")
        #expect(layers[3].fields.filter { $0.name.hasPrefix("Opzione") }.map { "\($0.name) \($0.value)" } == [
            "Opzione 53 Tipo messaggio: 2 (Offer)",
            "Opzione 51 Durata lease: 3600 s",
            "Opzione 54 Server DHCP: 10.0.0.1",
            "Opzione 1 Maschera di sottorete: 255.255.255.0",
            "Opzione 3 Router: 10.0.0.1",
            "Opzione 6 Server DNS: 10.0.0.53",
            "Opzione 255 Fine",
        ])
    }

    @Test func describesDnsQueriesAnswersAndNxdomain() {
        let q = DnsMessage(id: 0x1234, response: false, name: "www.lab")
        let qe = SimEvent(time: 0, kind: .tx, node: "C", iface: "eth0", frame: frame(0x0A00_000A, 0x0A00_0035, 40000, 53, .dns(q)))
        #expect(eventView(qe).proto == .dns)
        #expect(eventView(qe).info == "10.0.0.10 → 10.0.0.53 DNS Query 0x1234 A www.lab")
        #expect(fields(pduLayers(qe)[3])["Flag"] == "0x0100 (query, ricorsione desiderata)")
        let r = DnsMessage(id: 0x1234, response: true, authoritative: true, name: "www.lab", answers: [DnsAnswer(ttl: 300, addr: 0x0A00_0050)])
        let re = SimEvent(time: 0, kind: .tx, node: "S", iface: "eth0", frame: frame(0x0A00_0035, 0x0A00_000A, 53, 40000, .dns(r)))
        #expect(eventView(re).info == "10.0.0.53 → 10.0.0.10 DNS Risposta 0x1234 A www.lab → 10.0.0.80")
        let layer = pduLayers(re)[3]
        #expect(layer.title == "DNS" && layer.bytes == 41)
        #expect(layer.fields.map { "\($0.name): \($0.value)" } == [
            "ID: 0x1234",
            "Flag: 0x8500 (risposta, autoritativa, ricorsione desiderata, NOERROR)",
            "Domande: 1",
            "Risposte: 1",
            "Autorità: 0",
            "Aggiuntivi: 0",
            "Domanda: www.lab tipo A, classe IN",
            "Risposta 1: www.lab A 10.0.0.80, TTL 300 s",
        ])
        var nx = r
        nx.rcode = DNS_NXDOMAIN
        nx.answers = []
        nx.name = "nope.lab"
        let ne = SimEvent(time: 0, kind: .tx, node: "S", iface: "eth0", frame: frame(0x0A00_0035, 0x0A00_000A, 53, 40000, .dns(nx)))
        #expect(eventView(ne).info == "10.0.0.53 → 10.0.0.10 DNS Risposta 0x1234 NXDOMAIN nope.lab")
    }
}
