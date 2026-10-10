import Testing
@testable import PacEngine

private let stub = RouterLink(type: LINK_STUB, id: 0xC0A8_0100, data: 0xFFFF_FF00, metric: 1)

/// R1 (10.0.12.1) sending `body` to `dst` out of Gi0/1.
private func event(_ body: OspfBody, to dst: UInt32 = OSPF_ALL_ROUTERS, mac: Mac = OSPF_ALL_ROUTERS_MAC) -> SimEvent {
    let p = makeIpv4(src: 0x0A00_0C01, dst: dst, ttl: 1, id: 1, payload: .ospf(makeOspf(routerId: 0x0A00_0C01, body)))
    return SimEvent(time: 0, kind: .tx, node: "R1", iface: "Gi0/1",
                    frame: EthernetFrame(id: 1, src: "02:00:00:00:00:01", dst: mac, etherType: ETHERTYPE_IPV4, payload: .ipv4(p)))
}

@Suite struct OspfPduTests {
    @Test func everyPacketTypeIsAsLongAsItsBytesAndCarriesAValidChecksum() {
        let lsa = makeLsa(type: 1, id: 0x0A00_0C01, adv: 0x0A00_0C01, seq: OSPF_INITIAL_SEQ, body: .router([stub]))
        let bodies: [OspfBody] = [
            .hello(OspfHello(prefix: 30, priority: 1, dr: 0, bdr: 0, neighbors: [0x0A00_0C02])),
            .dbd(OspfDbd(initial: true, more: true, master: true, seq: 40_000, headers: [lsa.header])),
            .request([lsa.header.key]),
            .update([lsa]),
            .ack([lsa.header]),
        ]
        for b in bodies {
            let p = makeOspf(routerId: 0x0A00_0C01, b)
            #expect(serialize(p).count == p.size)
            #expect(internetChecksum(serialize(p)) == 0) // a valid checksum sums the packet to all ones
        }
        #expect(bodies.map { makeOspf(routerId: 1, $0).size } == [48, 52, 36, 64, 44])
        #expect(bodies.map(\.type) == [1, 2, 3, 4, 5])
    }

    @Test func lsaChecksumsAreIsoFletcherOverEverythingButTheAge() {
        let lsa = makeLsa(type: 2, id: 0x0A00_0C02, adv: 0xC0A8_0201, seq: OSPF_INITIAL_SEQ, body: .network(prefix: 30, routers: [0xC0A8_0201, 0xC0A8_0101]))
        let bytes = Array(serialize(lsa).dropFirst(2))
        var c0 = 0
        var c1 = 0
        for b in bytes {
            c0 = (c0 + Int(b)) % 255
            c1 = (c1 + c0) % 255
        }
        #expect(c0 == 0 && c1 == 0 && lsa.header.checksum != 0)
        #expect(lsa.header.length == 32 && serialize(lsa).count == 32)
        var older = lsa
        older.header.age = 900
        #expect(Array(serialize(older).dropFirst(2)) == bytes) // the age is outside the checksum
    }

    @Test func theInspectorDecodesHellosAndUpdates() {
        let hello = event(.hello(OspfHello(prefix: 30, priority: 1, dr: 0, bdr: 0, neighbors: [0xC0A8_0201])))
        #expect(eventView(hello).proto == .ospf)
        #expect(eventView(hello).info == "10.0.12.1 → 224.0.0.5 OSPF Hello DR 0.0.0.0 BDR 0.0.0.0 vicini 1")
        let layers = pduLayers(hello)
        #expect(layers.map(\.title) == ["Ethernet II", "IPv4", "OSPF"])
        #expect(layers[1].fields.first { $0.name == "Protocollo" }?.value == "89 (OSPF)")
        #expect(layers[2].bytes == 48)
        #expect(layers[2].fields.map(\.value).prefix(7) == ["2", "1 (Hello)", "48 B", "10.0.12.1", "0.0.0.0", layers[2].fields[5].value, "0 (nessuna)"])
        #expect(layers[2].fields.suffix(8).map(\.value) == ["255.255.255.252", "10 s", "0x02 (E)", "1", "40 s", "0.0.0.0", "0.0.0.0", "192.168.2.1"])
        let lsa = makeLsa(type: 1, id: 0x0A00_0C01, adv: 0x0A00_0C01, seq: OSPF_INITIAL_SEQ, body: .router([stub]))
        let update = event(.update([lsa]), to: OSPF_ALL_DROUTERS, mac: OSPF_ALL_DROUTERS_MAC)
        #expect(eventView(update).info == "10.0.12.1 → 224.0.0.6 OSPF LS Update router 10.0.12.1 seq 0x80000001")
        let fields = pduLayers(update)[2].fields.suffix(3).map(\.value)
        #expect(fields[0] == "1")
        #expect(fields[1].hasPrefix("router-LSA 10.0.12.1 da 10.0.12.1, seq 0x80000001, età 0 s, checksum 0x"))
        #expect(fields[2] == "stub 192.168.1.0 maschera 255.255.255.0, costo 1")
    }
}
