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

private func proto(of p: Ipv4Packet) -> Proto {
    switch p.payload {
    case .icmp: .icmp
    case .udp(let u):
        switch u.payload {
        case .dhcp: .dhcp
        case .dns: .dns
        case .raw, .traffic: .udp
        }
    case .tcp: .tcp
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
        case .raw, .traffic: return "\(ends) UDP \(u.srcPort) → \(u.dstPort) ttl=\(p.ttl)"
        }
    case .tcp(let t):
        return "\(ends) TCP \(t.srcPort) → \(t.dstPort) [\(flagNames(t.flags))] seq=\(t.seq)" + (t.flags.contains(.ack) ? " ack=\(t.ack)" : "")
            + " win=\(t.window) len=\(t.dataLength)" + (t.mss.map { " mss=\($0)" } ?? "")
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
        field("Protocollo", p.proto == IPPROTO_ICMP ? "1 (ICMP)" : p.proto == IPPROTO_TCP ? "6 (TCP)" : "17 (UDP)"),
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
