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

/// The address a DHCP message is about: offered/assigned, requested, or the client's own.
private func dhcpAddress(_ m: DhcpMessage) -> UInt32? {
    m.yiaddr != 0 ? m.yiaddr : m.requestedIp ?? (m.ciaddr != 0 ? m.ciaddr : nil)
}

private func dnsSummary(_ m: DnsMessage) -> String {
    let id = hex(Int(m.id), digits: 4)
    if !m.response { return "Query \(id) A \(m.name)" }
    if m.rcode == DNS_NXDOMAIN { return "Risposta \(id) NXDOMAIN \(m.name)" }
    return "Risposta \(id) A \(m.name) → " + m.answers.map { formatIp($0.addr) }.joined(separator: ", ")
}

private func describe(_ b: Bpdu) -> String {
    guard case .config(let c) = b else { return "Topology Change Notification" }
    return "Conf. root = \(c.root.text) costo = \(c.cost) porta = \(hex(c.port, digits: 4))" + (c.tc ? " TC" : "") + (c.tca ? " TCA" : "")
}

private func lsaName(_ k: LsaKey) -> String {
    "\(k.type == 1 ? "router" : "network") \(formatIp(k.id))"
}

private func seqText(_ seq: Int32) -> String {
    hex(Int(UInt32(bitPattern: seq)), digits: 8)
}

private func ospfSummary(_ o: OspfPacket) -> String {
    switch o.body {
    case .hello(let h): "Hello DR \(formatIp(h.dr)) BDR \(formatIp(h.bdr)) vicini \(h.neighbors.count)"
    case .dbd(let d):
        "DBD seq \(d.seq)" + [(d.initial, " I"), (d.more, " M"), (d.master, " MS")].filter(\.0).map(\.1).joined() + " (\(d.headers.count) LSA)"
    case .request(let keys): "LS Request " + keys.map(lsaName).joined(separator: ", ")
    case .update(let lsas): "LS Update " + lsas.map { "\(lsaName($0.header.key)) seq \(seqText($0.header.seq))" }.joined(separator: ", ")
    case .ack(let headers): "LS Ack " + headers.map { lsaName($0.key) }.joined(separator: ", ")
    }
}

private func proto(of p: Ipv4Packet) -> Proto {
    switch p.payload {
    case .icmp: .icmp
    case .udp(let u):
        switch u.payload {
        case .dhcp: .dhcp
        case .dns: .dns
        case .rip: .rip
        case .raw, .traffic: .udp
        }
    case .tcp: .tcp
    case .ospf: .ospf
    }
}

private let TCP_FLAG_NAMES: [(TcpFlags, String)] = [(.fin, "FIN"), (.syn, "SYN"), (.rst, "RST"), (.ack, "ACK")]

/// Wireshark order, lowest bit first: "SYN, ACK".
private func flagNames(_ f: TcpFlags) -> String {
    TCP_FLAG_NAMES.filter { f.contains($0.0) }.map { $0.1 }.joined(separator: ", ")
}

private func describe(_ p: Ipv4Packet) -> String {
    let ends = "\(formatIp(p.src)) → \(formatIp(p.dst))"
    switch p.payload {
    case .icmp(let m): return "\(ends) \(icmpName(m))" + (isEcho(m) ? " id=\(m.id) seq=\(m.seq)" : "") + " ttl=\(p.ttl)"
    case .udp(let u):
        switch u.payload {
        case .dhcp(let m): return "\(ends) DHCP \(m.type.name)" + (dhcpAddress(m).map { " \(formatIp($0))" } ?? "") + " xid=\(hex(Int(m.xid), digits: 8))"
        case .dns(let m): return "\(ends) DNS \(dnsSummary(m))"
        case .rip(let m):
            return "\(ends) RIPv2 " + (m.command == RIP_REQUEST ? "Request"
                : "Response " + m.entries.map { "\(formatIp($0.network))/\($0.prefix) m\($0.metric)" }.joined(separator: ", "))
        case .raw, .traffic: return "\(ends) UDP \(u.srcPort) → \(u.dstPort) ttl=\(p.ttl)"
        }
    case .tcp(let t):
        return "\(ends) TCP \(t.srcPort) → \(t.dstPort) [\(flagNames(t.flags))] seq=\(t.seq)" + (t.flags.contains(.ack) ? " ack=\(t.ack)" : "")
            + " win=\(t.window) len=\(t.dataLength)" + (t.mss.map { " mss=\($0)" } ?? "")
    case .ospf(let o):
        return "\(ends) OSPF " + ospfSummary(o)
    }
}

/// Frame payload, or the bare packet of an L3 drop (no route, TTL, ARP timeout).
private func l3(_ e: SimEvent) -> L3? {
    e.frame?.payload ?? e.packet.map(L3.ipv4)
}

func eventView(_ e: SimEvent) -> EventView {
    let (proto, info): (Proto, String) = switch l3(e) {
    case .arp(let a)?: (.arp, describe(a))
    case .ipv4(let p)?: (proto(of: p), describe(p))
    case .bpdu(let b)?: (.stp, describe(b))
    case nil: (.stp, e.note ?? "") // a spanning-tree state change; every other logged event carries a frame or a packet
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

private func dhcpLayer(_ m: DhcpMessage) -> PduLayer {
    var fields = [
        field("Operazione", m.op == 1 ? "1 (Boot Request)" : "2 (Boot Reply)"),
        field("Tipo hardware", "1 (Ethernet)"),
        field("Lungh. indirizzo HW", "6"),
        field("Hop", "0"),
        field("Transaction ID", hex(Int(m.xid), digits: 8)),
        field("Secondi", "0"),
        field("Flag", m.broadcast ? "0x8000 (broadcast)" : "0x0000 (unicast)"),
        field("IP client (ciaddr)", formatIp(m.ciaddr)),
        field("IP assegnato (yiaddr)", formatIp(m.yiaddr)),
        field("IP server (siaddr)", formatIp(m.siaddr)),
        field("IP relay (giaddr)", "0.0.0.0"),
        field("MAC client (chaddr)", m.chaddr),
        field("Nome server (sname)", "vuoto (64 B)"),
        field("File di boot", "vuoto (128 B)"),
        field("Magic cookie", "0x63825363 (DHCP)"),
        field("Opzione 53", "Tipo messaggio: \(m.type.rawValue) (\(m.type.name))"),
    ]
    if let v = m.requestedIp { fields.append(field("Opzione 50", "IP richiesto: \(formatIp(v))")) }
    if let v = m.leaseS { fields.append(field("Opzione 51", "Durata lease: \(v) s")) }
    if let v = m.serverId { fields.append(field("Opzione 54", "Server DHCP: \(formatIp(v))")) }
    if let v = m.subnetMask { fields.append(field("Opzione 1", "Maschera di sottorete: \(formatIp(v))")) }
    if let v = m.router { fields.append(field("Opzione 3", "Router: \(formatIp(v))")) }
    if let v = m.dns { fields.append(field("Opzione 6", "Server DNS: \(formatIp(v))")) }
    fields.append(field("Opzione 255", "Fine"))
    let padding = m.size - 240 - m.optionsSize
    if padding > 0 { fields.append(field("Padding", "\(padding) B")) }
    return PduLayer(title: "DHCP", bytes: m.size, fields: fields)
}

private func dnsLayer(_ m: DnsMessage) -> PduLayer {
    var flags = [m.response ? "risposta" : "query"]
    if m.authoritative { flags.append("autoritativa") }
    if m.recursionDesired { flags.append("ricorsione desiderata") }
    if m.response { flags.append(m.rcode == DNS_NXDOMAIN ? "NXDOMAIN" : m.rcode == 0 ? "NOERROR" : "rcode \(m.rcode)") }
    var fields = [
        field("ID", hex(Int(m.id), digits: 4)),
        field("Flag", "\(hex(Int(m.flags), digits: 4)) (\(flags.joined(separator: ", ")))"),
        field("Domande", "1"),
        field("Risposte", "\(m.answers.count)"),
        field("Autorità", "0"),
        field("Aggiuntivi", "0"),
        field("Domanda", "\(m.name) tipo A, classe IN"),
    ]
    for (i, a) in m.answers.enumerated() {
        fields.append(field("Risposta \(i + 1)", "\(m.name) A \(formatIp(a.addr)), TTL \(a.ttl) s"))
    }
    return PduLayer(title: "DNS", bytes: m.size, fields: fields)
}

private func ripLayer(_ m: RipMessage) -> PduLayer {
    var fields = [
        field("Comando", m.command == RIP_REQUEST ? "1 (Request)" : "2 (Response)"),
        field("Versione", "2"),
        field("Zero", "0x0000"),
    ]
    for (i, e) in m.entries.enumerated() {
        fields.append(field("Voce \(i + 1)", e.afi == 0 ? "AFI 0, metrica 16: intera tabella"
            : "AFI 2, \(formatIp(e.network))/\(e.prefix) maschera \(formatIp(prefixMask(e.prefix))), next hop 0.0.0.0, metrica \(e.metric), tag 0"))
    }
    return PduLayer(title: "RIPv2", bytes: m.size, fields: fields)
}

private func lsaHeaderText(_ h: LsaHeader) -> String {
    "\(h.type == 1 ? "router-LSA" : "network-LSA") \(formatIp(h.id)) da \(formatIp(h.adv)), seq \(seqText(h.seq)), età \(h.age) s, "
        + "checksum \(hex(Int(h.checksum), digits: 4)), \(h.length) B"
}

private func ospfLayer(_ o: OspfPacket) -> PduLayer {
    let names = ["Hello", "Database Description", "LS Request", "LS Update", "LS Acknowledgment"]
    var fields = [
        field("Versione", "2"),
        field("Tipo", "\(o.body.type) (\(names[Int(o.body.type) - 1]))"),
        field("Lunghezza", "\(o.size) B"),
        field("Router ID", formatIp(o.routerId)),
        field("Area", "0.0.0.0"),
        field("Checksum", hex(Int(o.checksum), digits: 4)),
        field("Autenticazione", "0 (nessuna)"),
    ]
    switch o.body {
    case .hello(let h):
        fields += [
            field("Maschera", formatIp(prefixMask(h.prefix))),
            field("Hello interval", "\(OSPF_HELLO_S) s"),
            field("Opzioni", "0x02 (E)"),
            field("Priorità", "\(h.priority)"),
            field("Dead interval", "\(OSPF_DEAD_S) s"),
            field("DR", formatIp(h.dr)),
            field("BDR", formatIp(h.bdr)),
        ]
        for (i, n) in h.neighbors.enumerated() { fields.append(field("Vicino \(i + 1)", formatIp(n))) }
    case .dbd(let d):
        let flags = [(d.initial, 4, "I"), (d.more, 2, "M"), (d.master, 1, "MS")].filter(\.0)
        fields += [
            field("MTU", "1500"),
            field("Opzioni", "0x02 (E)"),
            field("Flag", hex(flags.reduce(0) { $0 | $1.1 }, digits: 2) + (flags.isEmpty ? "" : " (\(flags.map(\.2).joined(separator: ", ")))")),
            field("Sequenza DD", "\(d.seq)"),
        ]
        for (i, h) in d.headers.enumerated() { fields.append(field("LSA \(i + 1)", lsaHeaderText(h))) }
    case .request(let keys):
        for (i, k) in keys.enumerated() {
            fields.append(field("Richiesta \(i + 1)", "\(k.type == 1 ? "router-LSA" : "network-LSA") \(formatIp(k.id)) da \(formatIp(k.adv))"))
        }
    case .update(let lsas):
        fields.append(field("Numero di LSA", "\(lsas.count)"))
        for (i, l) in lsas.enumerated() {
            fields.append(field("LSA \(i + 1)", lsaHeaderText(l.header)))
            switch l.body {
            case .router(let links):
                for (j, k) in links.enumerated() {
                    let text = switch k.type {
                    case LINK_P2P: "point-to-point verso \(formatIp(k.id)), dati \(formatIp(k.data))"
                    case LINK_TRANSIT: "transit, DR \(formatIp(k.id)), dati \(formatIp(k.data))"
                    default: "stub \(formatIp(k.id)) maschera \(formatIp(k.data))"
                    }
                    fields.append(field("LSA \(i + 1) link \(j + 1)", "\(text), costo \(k.metric)"))
                }
            case .network(let prefix, let routers):
                fields.append(field("LSA \(i + 1) rete", "maschera \(formatIp(prefixMask(prefix))), router " + routers.map(formatIp).joined(separator: ", ")))
            }
        }
    case .ack(let headers):
        for (i, h) in headers.enumerated() { fields.append(field("LSA \(i + 1)", lsaHeaderText(h))) }
    }
    return PduLayer(title: "OSPF", bytes: o.size, fields: fields)
}

/// Wireshark's layout of a Cisco PVST+ BPDU: LLC/SNAP, then the 802.1D BPDU with the PVID TLV.
private func bpduLayers(_ b: Bpdu) -> [PduLayer] {
    let llc = PduLayer(title: "LLC/SNAP", bytes: 8, fields: [
        field("DSAP", "0xaa (SNAP)"),
        field("SSAP", "0xaa (SNAP)"),
        field("Controllo", "0x03 (UI)"),
        field("OUI", "0x00000c (Cisco)"),
        field("PID", "0x010b (PVST+)"),
    ])
    var fields = [field("ID protocollo", "0x0000"), field("Versione", "0 (STP)")]
    guard case .config(let c) = b else {
        return [llc, PduLayer(title: "STP", bytes: 4, fields: fields + [field("Tipo BPDU", "0x80 (TCN)")])]
    }
    let flags = [(c.tca, 0x80, "TCA"), (c.tc, 0x01, "TC")].filter(\.0)
    fields += [
        field("Tipo BPDU", "0x00 (configurazione)"),
        field("Flag", hex(flags.reduce(0) { $0 | $1.1 }, digits: 2) + (flags.isEmpty ? "" : " (\(flags.map(\.2).joined(separator: ", ")))")),
        field("Root ID", c.root.text),
        field("Costo verso la root", "\(c.cost)"),
        field("Bridge ID", c.bridge.text),
        field("Port ID", hex(c.port, digits: 4)),
        field("Message age", "\(c.messageAge) s"),
        field("Max age", "\(STP_MAX_AGE_NS / S) s"),
        field("Hello time", "\(STP_HELLO_NS / S) s"),
        field("Forward delay", "\(STP_FORWARD_DELAY_NS / S) s"),
        field("VLAN di origine (PVID)", "\(c.bridge.vlan)"),
    ]
    return [llc, PduLayer(title: "STP", bytes: b.size - 8, fields: fields)]
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
        field("Protocollo", p.proto == IPPROTO_ICMP ? "1 (ICMP)" : p.proto == IPPROTO_TCP ? "6 (TCP)" : p.proto == IPPROTO_OSPF ? "89 (OSPF)" : "17 (UDP)"),
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
        let body: String = switch u.payload {
        case .raw(let data): "\(data.count) B"
        case .dhcp(let m): "\(m.size) B (DHCP)"
        case .dns(let m): "\(m.size) B (DNS)"
        case .rip(let m): "\(m.size) B (RIP)"
        case .traffic(let d): "\(TRAFFIC_DATAGRAM) B (generatore di traffico, seq \(d.seq))"
        }
        let udp = PduLayer(title: "UDP", bytes: u.size, fields: [
            field("Porta sorgente", "\(u.srcPort)"),
            field("Porta destinazione", "\(u.dstPort)"),
            field("Lunghezza", "\(u.size) B"),
            field("Checksum", hex(Int(u.checksum), digits: 4) + (u.checksum == 0 ? " (non calcolato)" : "")),
            field("Dati", body),
        ])
        switch u.payload {
        case .raw, .traffic: return [ip, udp]
        case .dhcp(let m): return [ip, udp, dhcpLayer(m)]
        case .dns(let m): return [ip, udp, dnsLayer(m)]
        case .rip(let m): return [ip, udp, ripLayer(m)]
        }
    case .tcp(let t):
        var fields = [
            field("Porta sorgente", "\(t.srcPort)"),
            field("Porta destinazione", "\(t.dstPort)"),
            field("Numero di sequenza", "\(t.seq)"),
            field("Numero di ack", "\(t.ack)"),
            field("Lungh. header", "\(t.headerSize) B (data offset \(t.headerSize / 4))"),
            field("Flag", "\(hex(Int(t.flags.rawValue), digits: 3)) (\(flagNames(t.flags)))"),
            field("Finestra", "\(t.window)"),
            field("Checksum", hex(Int(t.checksum), digits: 4)),
            field("Puntatore urgente", "0"),
        ]
        if let mss = t.mss { fields.append(field("Opzione MSS", "\(mss) B")) }
        fields.append(field("Dati", "\(t.dataLength) B"))
        return [ip, PduLayer(title: "TCP", bytes: t.size, fields: fields)]
    case .ospf(let o):
        return [ip, ospfLayer(o)]
    }
}

/// Header-by-header view of the frame (or packet) an event logged, with real field values.
func pduLayers(_ e: SimEvent) -> [PduLayer] {
    var layers: [PduLayer] = []
    if let f = e.frame {
        // A BPDU rides an IEEE 802.3 frame: a length where Ethernet II has its EtherType.
        let bpdu = if case .bpdu = f.payload { true } else { false }
        let typeName = bpdu ? "Lunghezza" : "EtherType"
        let type = bpdu ? "\(f.etherType) B" : hex(Int(f.etherType), digits: 4) + (f.etherType == ETHERTYPE_ARP ? " (ARP)" : " (IPv4)")
        layers.append(PduLayer(title: bpdu ? "IEEE 802.3 Ethernet" : "Ethernet II", bytes: f.size, fields: [
            field("Destinazione", f.dst),
            field("Sorgente", f.src),
            f.vlan == nil ? field(typeName, type) : field("EtherType", "0x8100 (802.1Q)"),
        ]))
        // Wireshark's layout: the tag (TCI) is its own 4-byte header, which carries the payload's EtherType.
        if let vid = f.vlan {
            layers.append(PduLayer(title: "802.1Q", bytes: 4, fields: [
                field("Priorità (PCP)", "0"),
                field("DEI", "0"),
                field("VLAN ID", "\(vid)"),
                field(typeName, type),
            ]))
        }
    }
    switch l3(e) {
    case .arp(let a)?: layers.append(arpLayer(a))
    case .ipv4(let p)?: layers += ipLayers(p)
    case .bpdu(let b)?: layers += bpduLayers(b)
    case nil: break
    }
    return layers
}
