import Testing
@testable import PacEngine

/// R1 sending `m` out of Gi0/1 (10.0.12.1) to the RIP-2 routers group.
private func event(_ m: RipMessage) -> SimEvent {
    let p = makeIpv4(src: 0x0A00_0C01, dst: RIP_GROUP, ttl: 1, id: 1, payload: .udp(makeUdp(srcPort: PORT_RIP, dstPort: PORT_RIP, payload: .rip(m))))
    return SimEvent(time: 0, kind: .tx, node: "R1", iface: "Gi0/1",
                    frame: EthernetFrame(id: 1, src: "02:00:00:00:00:01", dst: RIP_MAC, etherType: ETHERTYPE_IPV4, payload: .ipv4(p)))
}

@Suite struct RipPduTests {
    @Test func aWholeTableRequestIsOneEntryOf20BytesAfterA4ByteHeader() {
        let e = event(RipMessage(command: RIP_REQUEST, entries: [RipEntry(afi: 0, network: 0, prefix: 0, metric: RIP_INFINITY)]))
        #expect(e.frame?.size == 14 + 20 + 8 + 24)
        let view = eventView(e)
        #expect(view.proto == .rip && view.info == "10.0.12.1 → 224.0.0.9 RIPv2 Request")
        let layers = pduLayers(e)
        #expect(layers.map(\.title) == ["Ethernet II", "IPv4", "UDP", "RIPv2"])
        #expect(layers[2].fields.last?.value == "24 B (RIP)")
        #expect(layers[3].fields.map(\.value) == ["1 (Request)", "2", "0x0000", "AFI 0, metrica 16: intera tabella"])
    }

    @Test func aResponseListsEveryRouteWithMaskAndMetric() {
        let e = event(RipMessage(command: RIP_RESPONSE, entries: [
            RipEntry(network: 0xC0A8_0100, prefix: 24, metric: 1),
            RipEntry(network: 0x0A00_1700, prefix: 30, metric: 16),
        ]))
        #expect(eventView(e).info == "10.0.12.1 → 224.0.0.9 RIPv2 Response 192.168.1.0/24 m1, 10.0.23.0/30 m16")
        let rip = pduLayers(e)[3]
        #expect(rip.bytes == 44)
        #expect(rip.fields.map(\.name) == ["Comando", "Versione", "Zero", "Voce 1", "Voce 2"])
        #expect(rip.fields[0].value == "2 (Response)")
        #expect(rip.fields[3].value == "AFI 2, 192.168.1.0/24 maschera 255.255.255.0, next hop 0.0.0.0, metrica 1, tag 0")
        #expect(rip.fields[4].value == "AFI 2, 10.0.23.0/30 maschera 255.255.255.252, next hop 0.0.0.0, metrica 16, tag 0")
    }
}
