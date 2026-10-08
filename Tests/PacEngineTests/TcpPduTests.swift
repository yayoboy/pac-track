import Testing
@testable import PacEngine

private let a: UInt32 = 0x0A00_0001
private let b: UInt32 = 0x0A00_0002

private func frame(_ l4: L4) -> EthernetFrame {
    EthernetFrame(id: 1, src: "02:00:00:00:00:01", dst: "02:00:00:00:00:02", etherType: ETHERTYPE_IPV4,
                  payload: .ipv4(makeIpv4(src: a, dst: b, ttl: 64, id: 1, payload: l4)))
}

private let syn = makeTcp(TcpSegment(srcPort: 40000, dstPort: 9, seq: 1000, ack: 0, flags: [.syn], window: 65535, mss: 1460), src: a, dst: b)
private let data = makeTcp(TcpSegment(srcPort: 40000, dstPort: 9, seq: 1001, ack: 5001, flags: [.ack], window: 65535, dataLength: 1460),
                           src: a, dst: b)

@Suite struct TcpPduTests {
    @Test func sizesFollowTheHeaderAndTheMssOption() {
        #expect(syn.headerSize == 24 && syn.size == 24)
        #expect(data.headerSize == 20 && data.size == 1480)
        #expect(frame(.tcp(syn)).size == 58) // Ethernet 14 + IPv4 20 + TCP 20 + MSS option 4
        #expect(frame(.tcp(data)).size == 1514) // a full-sized segment fills the 1500-byte MTU
        let datagram = makeUdp(srcPort: 40000, dstPort: 9, payload: .traffic(TrafficData(flow: 1, seq: 7, sentAt: 0)))
        #expect(frame(.udp(datagram)).size == 1512) // iperf3's 1470-byte payload
        guard case .ipv4(let p) = frame(.tcp(syn)).payload else {
            Issue.record("not IPv4")
            return
        }
        #expect(p.proto == IPPROTO_TCP)
    }

    @Test func checksumsCoverThePseudoHeaderTheHeaderAndTheZeroPayload() {
        // Reference values computed independently (RFC 1071 sum over pseudo-header + header + zero data).
        #expect(syn.checksum == 0xE3F2)
        #expect(data.checksum == 0xE262)
        // A receiver's check: summing everything, checksum included, gives zero.
        let pseudo: [UInt8] = [10, 0, 0, 1, 10, 0, 0, 2, 0, 6, 0x05, 0xC8] // TCP length 1480
        #expect(internetChecksum(pseudo + serialize(data) + [UInt8](repeating: 0, count: 1460)) == 0)
    }

    @Test func describesSegmentsLikeWiresharkAndDecodesEveryHeaderField() {
        let e = SimEvent(time: 0, kind: .tx, node: "A", iface: "eth0", frame: frame(.tcp(syn)))
        let v = eventView(e)
        #expect(v.proto == .tcp && v.bytes == 58)
        #expect(v.info == "10.0.0.1 → 10.0.0.2 TCP 40000 → 9 [SYN] seq=1000 win=65535 len=0 mss=1460")
        #expect(eventView(SimEvent(time: 0, kind: .tx, node: "A", iface: "eth0", frame: frame(.tcp(data)))).info
            == "10.0.0.1 → 10.0.0.2 TCP 40000 → 9 [ACK] seq=1001 ack=5001 win=65535 len=1460")
        let rst = TcpSegment(srcPort: 9, dstPort: 40000, seq: 0, ack: 1001, flags: [.rst, .ack], window: 0)
        #expect(eventView(SimEvent(time: 0, kind: .tx, node: "B", iface: "eth0", frame: frame(.tcp(rst)))).info
            == "10.0.0.1 → 10.0.0.2 TCP 9 → 40000 [RST, ACK] seq=0 ack=1001 win=0 len=0")
        let layers = pduLayers(e)
        #expect(layers.map(\.title) == ["Ethernet II", "IPv4", "TCP"])
        #expect(layers.map(\.bytes) == [58, 44, 24])
        #expect(layers[1].fields.first { $0.name == "Protocollo" }?.value == "6 (TCP)")
        #expect(layers[2].fields.map { "\($0.name): \($0.value)" } == [
            "Porta sorgente: 40000",
            "Porta destinazione: 9",
            "Numero di sequenza: 1000",
            "Numero di ack: 0",
            "Lungh. header: 24 B (data offset 6)",
            "Flag: 0x002 (SYN)",
            "Finestra: 65535",
            "Checksum: 0xe3f2",
            "Puntatore urgente: 0",
            "Opzione MSS: 1460 B",
            "Dati: 0 B",
        ])
    }

    @Test func generatorDatagramsAreUdpAndShowTheirSequenceNumber() {
        let u = makeUdp(srcPort: 40000, dstPort: 9, payload: .traffic(TrafficData(flow: 1, seq: 7, sentAt: 0)))
        let e = SimEvent(time: 0, kind: .tx, node: "A", iface: "eth0", frame: frame(.udp(u)))
        #expect(eventView(e).proto == .udp)
        #expect(eventView(e).info == "10.0.0.1 → 10.0.0.2 UDP 40000 → 9 ttl=64")
        #expect(pduLayers(e)[2].fields.last?.value == "1470 B (generatore di traffico, seq 7)")
    }
}
