import Testing
@testable import PacEngine

private func echo(_ length: Int = 56) -> IcmpMessage {
    makeIcmp(type: ICMP_ECHO_REQUEST, code: 0, id: 1, seq: 1, data: [UInt8](repeating: 0, count: length))
}

@Suite struct PduTests {
    @Test func matchesTheClassicIpv4HeaderExample() throws {
        // 4500 0073 0000 4000 4011 xxxx c0a8 0001 c0a8 00c7
        let p = makeIpv4(src: try parseIp("192.168.0.1"), dst: try parseIp("192.168.0.199"), ttl: 64, id: 0,
                         payload: .udp(makeUdp(srcPort: 1, dstPort: 2, data: [UInt8](repeating: 0, count: 87))))
        #expect(p.size == 0x73)
        #expect(p.checksum == 0xB861)
    }

    @Test func producesHeadersThatVerifyToZero() throws {
        let m = echo()
        let p = makeIpv4(src: try parseIp("10.0.0.1"), dst: try parseIp("10.0.0.2"), ttl: 64, id: 7, payload: .icmp(m))
        #expect(internetChecksum(serializeHeader(p)) == 0)
        #expect(internetChecksum(serialize(m)) == 0)
    }

    @Test func withTtlReturnsANewPacketWithAValidChecksum() throws {
        let p = makeIpv4(src: try parseIp("10.0.0.1"), dst: try parseIp("10.0.0.2"), ttl: 64, id: 7, payload: .icmp(echo()))
        let q = withTtl(p, 63)
        #expect(p.ttl == 64)
        #expect(q.ttl == 63)
        #expect(q.checksum != p.checksum)
        #expect(internetChecksum(serializeHeader(q)) == 0)
    }

    @Test func handlesOddLengthInput() {
        #expect(internetChecksum([0x01]) == 0xFEFF)
    }

    @Test func icmpEchoWith56BytesIs98BytesOnEthernetAnd122OnTheWire() {
        let p = makeIpv4(src: 1, dst: 2, ttl: 64, id: 1, payload: .icmp(echo()))
        let f = EthernetFrame(id: 1, src: "02:00:00:00:00:01", dst: "02:00:00:00:00:02", etherType: ETHERTYPE_IPV4, payload: .ipv4(p))
        #expect(p.size == 84)
        #expect(f.size == 98)
        #expect(f.wireBytes == 122)
    }

    @Test func arpFrameIs42BytesPaddedTo64PlusOverhead() {
        let f = EthernetFrame(id: 1, src: "02:00:00:00:00:01", dst: BROADCAST_MAC, etherType: ETHERTYPE_ARP,
                              payload: .arp(ArpPacket(op: 1, senderMac: "02:00:00:00:00:01", senderIp: 1, targetMac: "00:00:00:00:00:00", targetIp: 2)))
        #expect(f.size == 42)
        #expect(f.wireBytes == 84)
    }

    @Test func an8021QTagAddsFourBytesEvenToAMinimumFrame() {
        let p = makeIpv4(src: 1, dst: 2, ttl: 64, id: 1, payload: .icmp(echo()))
        let f = EthernetFrame(id: 1, src: "02:00:00:00:00:01", dst: "02:00:00:00:00:02", etherType: ETHERTYPE_IPV4, payload: .ipv4(p), vlan: 10)
        #expect(f.size == 102)
        #expect(f.wireBytes == 126)
        let arp = EthernetFrame(id: 2, src: "02:00:00:00:00:01", dst: BROADCAST_MAC, etherType: ETHERTYPE_ARP,
                                payload: .arp(ArpPacket(op: 1, senderMac: "02:00:00:00:00:01", senderIp: 1, targetMac: "00:00:00:00:00:00", targetIp: 2)),
                                vlan: 10)
        #expect(arp.size == 46)
        #expect(arp.wireBytes == 88) // padded to 64 untagged, then 68 with the tag
    }

    @Test func theInspectorShowsThe8021QHeaderBetweenEthernetAndIpv4() {
        let p = makeIpv4(src: 1, dst: 2, ttl: 64, id: 1, payload: .icmp(echo()))
        let f = EthernetFrame(id: 1, src: "02:00:00:00:00:01", dst: "02:00:00:00:00:02", etherType: ETHERTYPE_IPV4, payload: .ipv4(p), vlan: 20)
        let e = SimEvent(time: 0, kind: .tx, node: "R1", iface: "Gi0/0", frame: f)
        let layers = pduLayers(e)
        #expect(layers.map(\.title) == ["Ethernet II", "802.1Q", "IPv4", "ICMP"])
        #expect(layers.map(\.bytes) == [102, 4, 84, 64])
        #expect(layers[0].fields.last == PduField(name: "EtherType", value: "0x8100 (802.1Q)"))
        #expect(layers[1].fields.map { "\($0.name): \($0.value)" } == ["Priorità (PCP): 0", "DEI: 0", "VLAN ID: 20", "EtherType: 0x0800 (IPv4)"])
        #expect(eventView(e).bytes == 102)
    }

    @Test func aPvstConfigurationBpduIsA64ByteFrameDecodedAsStp() {
        let root = BridgeId(priority: 4096, vlan: 10, mac: "02:00:00:00:00:01")
        let me = BridgeId(priority: 32768, vlan: 10, mac: "02:00:00:00:00:09")
        let bpdu = Bpdu.config(StpConfig(root: root, cost: 4, bridge: me, port: 0x8002, messageAge: 1, tc: true))
        let f = EthernetFrame(id: 1, src: "02:00:00:00:00:0a", dst: SSTP_MAC, etherType: UInt16(bpdu.size), payload: .bpdu(bpdu), vlan: 10)
        #expect(f.size == 68)
        let e = SimEvent(time: 0, kind: .tx, node: "SW2", iface: "Gi0/2", frame: f)
        #expect(eventView(e).proto == .stp)
        #expect(eventView(e).info == "Conf. root = 4096/10/02:00:00:00:00:01 costo = 4 porta = 0x8002 TC")
        let layers = pduLayers(e)
        #expect(layers.map(\.title) == ["IEEE 802.3 Ethernet", "802.1Q", "LLC/SNAP", "STP"])
        #expect(layers.map(\.bytes) == [68, 4, 8, 42])
        #expect(layers[0].fields.last == PduField(name: "EtherType", value: "0x8100 (802.1Q)"))
        #expect(layers[1].fields.last == PduField(name: "Lunghezza", value: "50 B"))
        #expect(layers[2].fields.map(\.value) == ["0xaa (SNAP)", "0xaa (SNAP)", "0x03 (UI)", "0x00000c (Cisco)", "0x010b (PVST+)"])
        #expect(layers[3].fields.map { "\($0.name): \($0.value)" } == [
            "ID protocollo: 0x0000", "Versione: 0 (STP)", "Tipo BPDU: 0x00 (configurazione)", "Flag: 0x01 (TC)",
            "Root ID: 4096/10/02:00:00:00:00:01", "Costo verso la root: 4", "Bridge ID: 32768/10/02:00:00:00:00:09", "Port ID: 0x8002",
            "Message age: 1 s", "Max age: 20 s", "Hello time: 2 s", "Forward delay: 15 s", "VLAN di origine (PVID): 10",
        ])
    }

    @Test func aTcnIsA26ByteFrame() {
        let f = EthernetFrame(id: 1, src: "02:00:00:00:00:0a", dst: SSTP_MAC, etherType: UInt16(Bpdu.tcn.size), payload: .bpdu(.tcn))
        #expect(f.size == 26)
        let e = SimEvent(time: 0, kind: .tx, node: "SW2", iface: "Gi0/1", frame: f)
        #expect(eventView(e).info == "Topology Change Notification")
        let layers = pduLayers(e)
        #expect(layers.map(\.title) == ["IEEE 802.3 Ethernet", "LLC/SNAP", "STP"])
        #expect(layers.map(\.bytes) == [26, 8, 4])
        #expect(layers[0].fields.last == PduField(name: "Lunghezza", value: "12 B"))
        #expect(layers[2].fields.last == PduField(name: "Tipo BPDU", value: "0x80 (TCN)"))
    }
}
