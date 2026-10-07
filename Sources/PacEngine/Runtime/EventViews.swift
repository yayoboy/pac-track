import Foundation

private func hex(_ v: Int, digits: Int) -> String {
    "0x" + String(format: "%0\(digits)x", v)
}

private func icmpName(_ m: IcmpMessage) -> String {
    switch m.type {
    case ICMP_ECHO_REPLY: "Echo reply"
    case ICMP_ECHO_REQUEST: "Echo request"
    case ICMP_TIME_EXCEEDED: "Time exceeded"
    case ICMP_DEST_UNREACH:
        switch m.code {
        case UNREACH_NET: "Destination unreachable (net)"
        case UNREACH_HOST: "Destination unreachable (host)"
        case UNREACH_PORT: "Destination unreachable (port)"
        case UNREACH_FRAG_NEEDED: "Destination unreachable (fragmentation needed)"
        default: "Destination unreachable (code \(m.code))"
        }
    default: "Type \(m.type)"
    }
}

private func isEcho(_ m: IcmpMessage) -> Bool {
    m.type == ICMP_ECHO_REQUEST || m.type == ICMP_ECHO_REPLY
}

private func describe(_ a: ArpPacket) -> String {
    a.op == 1 ? "Chi ha \(formatIp(a.targetIp))? Rispondi a \(formatIp(a.senderIp))" : "\(formatIp(a.senderIp)) è \(a.senderMac)"
}

private func describe(_ p: Ipv4Packet) -> String {
    let ends = "\(formatIp(p.src)) → \(formatIp(p.dst))"
    switch p.payload {
    case .icmp(let m): return "\(ends) \(icmpName(m))" + (isEcho(m) ? " id=\(m.id) seq=\(m.seq)" : "") + " ttl=\(p.ttl)"
    case .udp(let u): return "\(ends) UDP \(u.srcPort) → \(u.dstPort) ttl=\(p.ttl)"
    }
}

/// Frame payload, or the bare packet of an L3 drop (no route, TTL, ARP timeout).
private func l3(_ e: SimEvent) -> L3? {
    e.frame?.payload ?? e.packet.map(L3.ipv4)
}

func eventView(_ e: SimEvent) -> EventView {
    let (proto, info): (Proto, String) = switch l3(e) {
    case .arp(let a)?: (.arp, describe(a))
    case .ipv4(let p)?: (p.proto == IPPROTO_ICMP ? .icmp : .udp, describe(p))
    case nil: (.arp, "") // every logged event carries a frame or a packet
    }
    return EventView(id: e.seq, timeNs: e.time, kind: e.kind, node: e.node, iface: e.iface, proto: proto,
                     frameId: e.frame?.id, bytes: e.frame?.size ?? e.packet?.size ?? 0, info: info, reason: e.reason?.rawValue)
}

private func field(_ name: String, _ value: String) -> PduField {
    PduField(name: name, value: value)
}

private func arpLayer(_ a: ArpPacket) -> PduLayer {
    PduLayer(title: "ARP", bytes: 28, fields: [
        field("Tipo hardware", "1 (Ethernet)"),
        field("Tipo protocollo", "0x0800 (IPv4)"),
        field("Lungh. hardware", "6"),
        field("Lungh. protocollo", "4"),
        field("Operazione", a.op == 1 ? "1 (request)" : "2 (reply)"),
        field("MAC mittente", a.senderMac),
        field("IP mittente", formatIp(a.senderIp)),
        field("MAC destinatario", a.targetMac),
        field("IP destinatario", formatIp(a.targetIp)),
    ])
}

private func ipLayers(_ p: Ipv4Packet) -> [PduLayer] {
    let ip = PduLayer(title: "IPv4", bytes: p.size, fields: [
        field("Versione", "4"),
        field("Lungh. header", "20 B (IHL 5)"),
        field("ToS", hex(Int(p.tos), digits: 2)),
        field("Lunghezza totale", "\(p.size) B"),
        field("Identificazione", "\(hex(Int(p.id), digits: 4)) (\(p.id))"),
        field("Flag", p.dontFragment ? "0x2 (DF)" : "0x0"),
        field("Offset frammento", "0"),
        field("TTL", "\(p.ttl)"),
        field("Protocollo", p.proto == IPPROTO_ICMP ? "1 (ICMP)" : "17 (UDP)"),
        field("Checksum header", hex(Int(p.checksum), digits: 4)),
        field("Sorgente", formatIp(p.src)),
        field("Destinazione", formatIp(p.dst)),
    ])
    switch p.payload {
    case .icmp(let m):
        var fields = [field("Tipo", "\(m.type) (\(icmpName(m)))"), field("Codice", "\(m.code)"),
                      field("Checksum", hex(Int(m.checksum), digits: 4))]
        if isEcho(m) { fields += [field("Identificatore", "\(m.id)"), field("Sequenza", "\(m.seq)")] }
        fields.append(field("Dati", isEcho(m) ? "\(m.data.count) B" : "\(m.data.count) B (header IP + 8 B del pacchetto originale)"))
        return [ip, PduLayer(title: "ICMP", bytes: m.size, fields: fields)]
    case .udp(let u):
        return [ip, PduLayer(title: "UDP", bytes: u.size, fields: [
            field("Porta sorgente", "\(u.srcPort)"),
            field("Porta destinazione", "\(u.dstPort)"),
            field("Lunghezza", "\(u.size) B"),
            field("Checksum", hex(Int(u.checksum), digits: 4) + (u.checksum == 0 ? " (non calcolato)" : "")),
            field("Dati", "\(u.data.count) B"),
        ])]
    }
}

/// Header-by-header view of the frame (or packet) an event logged, with real field values.
func pduLayers(_ e: SimEvent) -> [PduLayer] {
    var layers: [PduLayer] = []
    if let f = e.frame {
        layers.append(PduLayer(title: "Ethernet II", bytes: f.size, fields: [
            field("Destinazione", f.dst),
            field("Sorgente", f.src),
            field("EtherType", hex(Int(f.etherType), digits: 4) + (f.etherType == ETHERTYPE_ARP ? " (ARP)" : " (IPv4)")),
        ]))
    }
    switch l3(e) {
    case .arp(let a)?: layers.append(arpLayer(a))
    case .ipv4(let p)?: layers += ipLayers(p)
    case nil: break
    }
    return layers
}
