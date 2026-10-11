import Testing
@testable import PacEngine

private let STA: Mac = "02:00:00:00:00:01"
private let DST: Mac = "02:00:00:00:00:02"
private let AP: Mac = "02:00:00:00:00:0a"

private func mgmt(_ m: Dot11Mgmt, from src: Mac = STA, to dst: Mac = AP, bssid: Mac = AP) -> EthernetFrame {
    EthernetFrame(id: 1, src: src, dst: dst, etherType: 0, payload: .mgmt(m), air: Dot11Header(bssid: bssid))
}

/// A 56-byte ping from STA to DST, To DS or relayed From DS by AP.
private func echo(toDS: Bool) -> EthernetFrame {
    let p = makeIpv4(src: 1, dst: 2, ttl: 64, id: 1,
                     payload: .icmp(makeIcmp(type: ICMP_ECHO_REQUEST, code: 0, id: 1, seq: 1, data: [UInt8](repeating: 0, count: 56))))
    return EthernetFrame(id: 1, src: STA, dst: DST, etherType: ETHERTYPE_IPV4, payload: .ipv4(p),
                         air: Dot11Header(toDS: toDS, fromDS: !toDS, bssid: AP, seq: 7))
}

/// µs from taking the medium to the end of the frame, then µs of SIFS + ACK.
private func air(_ f: EthernetFrame) -> [Int] {
    let a = dot11Airtime(f)
    return [a.frame, a.ack]
}

private func lines(_ l: PduLayer) -> [String] { l.fields.map { "\($0.name): \($0.value)" } }

@Suite struct Dot11PduTests {
    /// IEEE 802.11-2016 §9.3.3: header 24 B + body (fixed fields, SSID 2 + n, Supported Rates 2 + 8, DS Parameter Set 2 + 1; the Probe
    /// Response also ERP 2 + 1, §9.4.2.12).
    @Test func managementFramesHaveTheirIeee80211Sizes() {
        let frames: [Dot11Mgmt] = [.probeRequest(ssid: "pac-track"), .probeResponse(ssid: "pac-track", channel: 6, timestamp: 20_189),
                                   .authentication(seq: 1, status: 0), .associationRequest(ssid: "pac-track"),
                                   .associationResponse(status: 0, aid: 1), .deauthentication(reason: 3)]
        #expect(frames.map(\.size) == [21, 39, 6, 25, 16, 2])
        #expect(frames.map { mgmt($0).size } == [45, 63, 30, 49, 40, 26])
        #expect(frames.map(\.subtype) == [4, 5, 11, 0, 1, 12])
    }

    /// 802.11g ERP-OFDM, short slot (spec M11 §4): DIFS 28 µs, backoff 7 × 9 µs, then 20 µs + 4 µs symbols + 6 µs of signal extension;
    /// unicast adds SIFS 10 µs + a 14-byte ACK at 24 Mb/s (34 µs). Management and group frames at 6 Mb/s, unicast data at 54.
    /// The ACK goes at the highest basic rate not above the frame's (§10.7.6.5.2): after a 6 Mb/s management frame at 6 (50 µs).
    @Test func airtimeFollowsErpOfdmTiming() {
        #expect(DOT11_DIFS_US == 28 && DOT11_BACKOFF_US == 63)
        #expect(dot11TxUs(bytes: DOT11_ACK_BYTES, rateMbps: DOT11_ACK_RATE) == 34 && DOT11_ACK_US == 44)
        #expect(dot11TxUs(bytes: DOT11_ACK_BYTES, rateMbps: DOT11_BASIC_RATE) == 50)
        let probe = mgmt(.probeRequest(ssid: "pac-track"), to: BROADCAST_MAC, bssid: BROADCAST_MAC)
        #expect(probe.receiver == BROADCAST_MAC && air(probe) == [189, 0])
        #expect([mgmt(.probeResponse(ssid: "pac-track", channel: 6, timestamp: 0), from: AP, to: STA), mgmt(.authentication(seq: 1, status: 0)),
                 mgmt(.associationRequest(ssid: "pac-track")), mgmt(.associationResponse(status: 0, aid: 1), from: AP, to: STA),
                 mgmt(.deauthentication(reason: 3)), mgmt(.deauthentication(reason: 3), from: AP, to: BROADCAST_MAC)].map(air)
            == [[213, 60], [169, 60], [193, 60], [181, 60], [161, 60], [161, 0]])
        // A 56-byte ping: 24 + LLC/SNAP 8 + 84 = 116 B, 46 µs at 54 Mb/s; to the AP its receiver (address 1) is the BSSID.
        #expect(echo(toDS: true).size == 116 && echo(toDS: true).receiver == AP && air(echo(toDS: true)) == [137, 44])
        #expect(echo(toDS: false).receiver == DST)
        // An ARP broadcast: unicast to the BSSID on its way in (54 Mb/s, ACK), a group frame on its way out (6 Mb/s, no ACK).
        var arp = EthernetFrame(id: 2, src: STA, dst: BROADCAST_MAC, etherType: ETHERTYPE_ARP,
                                payload: .arp(ArpPacket(op: 1, senderMac: STA, senderIp: 1, targetMac: "00:00:00:00:00:00", targetIp: 2)),
                                air: Dot11Header(toDS: true, bssid: AP))
        #expect(arp.size == 60 && air(arp) == [129, 44])
        arp.air = Dot11Header(fromDS: true, bssid: AP)
        #expect(air(arp) == [209, 0])
        // iperf3's 1470-byte datagram: 1530 B, a 254 µs PPDU, 389 µs of medium in all: 30.2 Mb/s of payload at most.
        let udp = EthernetFrame(id: 3, src: STA, dst: DST, etherType: ETHERTYPE_IPV4,
                                payload: .ipv4(makeIpv4(src: 1, dst: 2, ttl: 64, id: 1, payload: .udp(makeUdp(srcPort: 5001, dstPort: 9,
                                    payload: .traffic(TrafficData(flow: 1, seq: 0, sentAt: 0)))))),
                                air: Dot11Header(toDS: true, bssid: AP))
        #expect(udp.size == 1530 && dot11TxUs(bytes: 1534, rateMbps: 54) == 254 && air(udp) == [345, 44])
    }

    /// Spec M11 §3: To DS the addresses are BSSID, source, destination; From DS destination, BSSID, source; LLC/SNAP (RFC 1042)
    /// carries the EtherType, then the packet as on Ethernet.
    @Test func dataFramesShowTheirAddressesByDirectionAndLlcSnap() {
        let e = SimEvent(time: 0, kind: .tx, node: "TAB1", iface: "wlan0", frame: echo(toDS: true))
        let layers = pduLayers(e)
        #expect(layers.map(\.title) == ["IEEE 802.11", "LLC/SNAP", "IPv4", "ICMP"])
        #expect(layers.map(\.bytes) == [116, 8, 84, 64])
        #expect(lines(layers[0]) == [
            "Versione: 0", "Tipo: 2 (dati)", "Sottotipo: 0 (Data)", "Flag: 0x01 (To DS)", "Duration: 44 µs",
            "Indirizzo 1 (ricevitore, BSSID): 02:00:00:00:00:0a", "Indirizzo 2 (trasmettitore, sorgente): 02:00:00:00:00:01",
            "Indirizzo 3 (destinazione): 02:00:00:00:00:02", "Numero di sequenza: 7", "Frammento: 0", "Velocità: 54 Mb/s",
        ])
        #expect(lines(layers[1]) == ["DSAP: 0xaa (SNAP)", "SSAP: 0xaa (SNAP)", "Controllo: 0x03 (UI)", "OUI: 0x000000 (RFC 1042)",
                                     "EtherType: 0x0800 (IPv4)"])
        let back = pduLayers(SimEvent(time: 0, kind: .tx, node: "AP1", iface: "Dot11Radio0", frame: echo(toDS: false)))
        #expect(lines(back[0]).filter { $0.hasPrefix("Flag") || $0.hasPrefix("Indirizzo") } == [
            "Flag: 0x02 (From DS)", "Indirizzo 1 (ricevitore, destinazione): 02:00:00:00:00:02",
            "Indirizzo 2 (trasmettitore, BSSID): 02:00:00:00:00:0a", "Indirizzo 3 (sorgente): 02:00:00:00:00:01",
        ])
        #expect(eventView(e).proto == .icmp && eventView(e).bytes == 116)
    }

    /// Spec M11 §3, §7: management frames are 802.11 events, decoded field by field like Wireshark.
    @Test func managementFramesAreDecodedForTheEventListAndTheInspector() {
        let views = [Dot11Mgmt.probeRequest(ssid: "pac-track"), .probeResponse(ssid: "pac-track", channel: 6, timestamp: 20_189),
                     .authentication(seq: 1, status: 0), .authentication(seq: 2, status: 0), .associationRequest(ssid: "pac-track"),
                     .associationResponse(status: 0, aid: 1), .deauthentication(reason: 3)]
            .map { eventView(SimEvent(time: 0, kind: .tx, node: "AP1", iface: "Dot11Radio0", frame: mgmt($0))) }
        #expect(views.allSatisfy { $0.proto == .wifi } && Proto.wifi.rawValue == "wifi")
        #expect(views.map(\.info) == [
            "Probe Request, SSID=pac-track", "Probe Response, SSID=pac-track, canale 6", "Authentication, Open System, transazione 1",
            "Authentication, Open System, transazione 2, stato 0", "Association Request, SSID=pac-track",
            "Association Response, stato 0, AID=1", "Deauthentication, motivo 3",
        ])
        let response = pduLayers(SimEvent(time: 0, kind: .rx, node: "TAB1", iface: "wlan0",
                                          frame: mgmt(.associationResponse(status: 0, aid: 1), from: AP, to: STA)))
        #expect(response.map(\.title) == ["IEEE 802.11", "Gestione 802.11"] && response.map(\.bytes) == [40, 16])
        #expect(lines(response[0]) == [
            "Versione: 0", "Tipo: 0 (gestione)", "Sottotipo: 1 (Association Response)", "Flag: 0x00", "Duration: 60 µs",
            "Indirizzo 1 (ricevitore, destinazione): 02:00:00:00:00:01", "Indirizzo 2 (trasmettitore, sorgente): 02:00:00:00:00:0a",
            "Indirizzo 3 (BSSID): 02:00:00:00:00:0a", "Numero di sequenza: 0", "Frammento: 0", "Velocità: 6 Mb/s",
        ])
        #expect(lines(response[1]) == ["Capability: 0x0401 (ESS, short slot)", "Stato: 0 (successo)", "AID: 1 (0xc001)",
                                       "Velocità supportate: 6(B), 9, 12(B), 18, 24(B), 36, 48, 54 Mb/s"])
        let probe = pduLayers(SimEvent(time: 0, kind: .tx, node: "AP1", iface: "Dot11Radio0",
                                       frame: mgmt(.probeResponse(ssid: "pac-track", channel: 6, timestamp: 20_189), from: AP, to: STA)))
        #expect(lines(probe[1]) == [
            "Timestamp: 20189 µs", "Intervallo di beacon: 100 TU (102.4 ms)", "Capability: 0x0401 (ESS, short slot)", "SSID: pac-track",
            "Velocità supportate: 6(B), 9, 12(B), 18, 24(B), 36, 48, 54 Mb/s", "Canale (DS Parameter Set): 6", "ERP: 0x00",
        ])
        let others = [Dot11Mgmt.probeRequest(ssid: "pac-track"), .authentication(seq: 2, status: 0), .associationRequest(ssid: "pac-track"),
                      .deauthentication(reason: 3)]
            .map { lines(pduLayers(SimEvent(time: 0, kind: .tx, node: "TAB1", iface: "wlan0", frame: mgmt($0)))[1]) }
        #expect(others == [
            ["SSID: pac-track", "Velocità supportate: 6(B), 9, 12(B), 18, 24(B), 36, 48, 54 Mb/s"],
            ["Algoritmo: 0 (Open System)", "Numero di transazione: 2", "Stato: 0 (successo)"],
            ["Capability: 0x0401 (ESS, short slot)", "Intervallo di ascolto: 10", "SSID: pac-track",
             "Velocità supportate: 6(B), 9, 12(B), 18, 24(B), 36, 48, 54 Mb/s"],
            ["Motivo: 3 (lascia il BSS)"],
        ])
    }

    /// Spec M11 §8: unicast data goes at the rate in its header (the station's, from the distance); the ACK at the highest basic rate
    /// (6, 12, 24) not above it (§10.7.6.5.2): 12 after 18, 6 after 9, 24 after 36.
    @Test func dataGoesAtItsHeadersRateAndTheAckAtTheBasicRateBelow() {
        var f = echo(toDS: true)
        let acks = [(18, 12), (9, 6), (36, 24), (54, 24)].map { rate, ack -> Bool in
            f.air?.rate = rate
            return air(f) == [DOT11_DIFS_US + DOT11_BACKOFF_US + dot11TxUs(bytes: 120, rateMbps: rate),
                              DOT11_SIFS_US + dot11TxUs(bytes: DOT11_ACK_BYTES, rateMbps: ack)]
        }
        #expect(acks == [true, true, true, true])
        f.air?.rate = 18
        #expect(lines(pduLayers(SimEvent(time: 0, kind: .tx, node: "TAB1", iface: "wlan0", frame: f))[0]).last == "Velocità: 18 Mb/s")
        // Management and group frames go at 6 whatever the header says.
        var probe = mgmt(.probeRequest(ssid: "pac-track"), to: BROADCAST_MAC, bssid: BROADCAST_MAC)
        probe.air?.rate = 18
        #expect(air(probe) == [189, 0])
    }

    /// Spec M11 §8: the RSN element (22 B: CCMP, PSK) in the Probe Response and the Association Request of a WPA2 network; EAPOL-Key
    /// frames as data with LLC/SNAP 0x888e; a protected data frame carries the Protected flag and 16 B more (CCMP header and MIC).
    @Test func wpa2FramesShowRsnEapolAndProtection() {
        #expect(Dot11Mgmt.probeResponse(ssid: "casa", channel: 6, timestamp: 0, rsn: true).size == 8 + 2 + 2 + 2 + 4 + 10 + 3 + 3 + 22)
        #expect(Dot11Mgmt.associationRequest(ssid: "casa", rsn: true).size == 2 + 2 + 2 + 4 + 10 + 22)
        let probe = pduLayers(SimEvent(time: 0, kind: .tx, node: "AP1", iface: "Dot11Radio0",
                                       frame: mgmt(.probeResponse(ssid: "casa", channel: 6, timestamp: 0, rsn: true), from: AP, to: STA)))
        #expect(lines(probe[1]).last == "RSN: CCMP, PSK (2 + 20 B)")
        let request = pduLayers(SimEvent(time: 0, kind: .tx, node: "TAB1", iface: "wlan0", frame: mgmt(.associationRequest(ssid: "casa", rsn: true))))
        #expect(lines(request[1]).last == "RSN: CCMP, PSK (2 + 20 B)")
        let nonce = [UInt8](0..<32)
        let key = EapolKey(message: 2, replay: 1, nonce: nonce, mic: [UInt8](repeating: 0xab, count: 16))
        let f = EthernetFrame(id: 1, src: STA, dst: AP, etherType: ETHERTYPE_EAPOL, payload: .eapol(key), air: Dot11Header(toDS: true, bssid: AP))
        let e = SimEvent(time: 0, kind: .tx, node: "TAB1", iface: "wlan0", frame: f)
        #expect(eventView(e).proto == .wifi && eventView(e).info == "EAPOL-Key 2 di 4" && f.size == 153)
        let layers = pduLayers(e)
        #expect(layers.map(\.title) == ["IEEE 802.11", "LLC/SNAP", "EAPOL-Key"] && layers.map(\.bytes) == [153, 8, 121])
        #expect(lines(layers[0])[3] == "Flag: 0x01 (To DS)" && lines(layers[1]).last == "EtherType: 0x888e (EAPOL)")
        #expect(lines(layers[2]) == [
            "Versione: 2 (802.1X-2004)", "Tipo: 3 (Key)", "Lunghezza: 117", "Descrittore: 2 (RSN)",
            "Key Information: 0x010a (Pairwise, MIC)", "Lunghezza chiave: 0", "Replay counter: 1",
            "Nonce: 0001020304050607…", "MIC: abababababababababababababababab", "Lunghezza dati chiave: 22",
        ])
        let infos = [(1, "0x008a (Pairwise, ACK)", 16, 0), (3, "0x13ca (Pairwise, Install, ACK, MIC, Secure, dati cifrati)", 16, 56),
                     (4, "0x030a (Pairwise, MIC, Secure)", 0, 0)].map { m, info, length, data in
            let fields = pduLayers(SimEvent(time: 0, kind: .tx, node: "AP1", iface: "Dot11Radio0", frame: EthernetFrame(
                id: 1, src: AP, dst: STA, etherType: ETHERTYPE_EAPOL, payload: .eapol(EapolKey(message: m, replay: 1, nonce: nonce, mic: [])),
                air: Dot11Header(fromDS: true, bssid: AP))))[2].fields
            return fields[4].value == info && fields[5].value == "\(length)" && fields[9].value == "\(data)"
        }
        #expect(infos == [true, true, true])
        var protected = echo(toDS: true)
        protected.air?.protected = true
        #expect(protected.size == 116 + 16 && lines(pduLayers(SimEvent(time: 0, kind: .tx, node: "TAB1", iface: "wlan0", frame: protected))[0])[3]
            == "Flag: 0x41 (To DS, Protected)")
        protected.air = Dot11Header(fromDS: true, bssid: AP, protected: true)
        #expect(lines(pduLayers(SimEvent(time: 0, kind: .tx, node: "AP1", iface: "Dot11Radio0", frame: protected))[0])[3]
            == "Flag: 0x42 (From DS, Protected)")
    }
}
