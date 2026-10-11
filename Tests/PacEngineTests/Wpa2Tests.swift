import Foundation
import Testing
@testable import PacEngine

/// AP1 with `casa` on channel 6 (WPA2-PSK with `apPassword`, or open with nil) and TAB1 looking for it with `password`, in DHCP.
private func secured(apPassword: String? = "segreta123", password: String?) throws -> (sim: Sim, ap: AccessPoint, tab: PacEngine.Host) {
    let sim = Sim()
    let ap = AccessPoint(sim: sim, id: "AP1")
    try ap.radio.configure(ApConfig(ssid: "casa", channel: 6, passphrase: apPassword))
    let tab = PacEngine.Host(sim: sim, id: "TAB1", wifi: true)
    try tab.setDhcp(true)
    try tab.station!.configure(StationConfig(ssid: "casa", passphrase: password))
    return (sim, ap, tab)
}

private func isEapol(_ e: SimEvent) -> Bool {
    e.frame?.etherType == ETHERTYPE_EAPOL
}

/// "<node> <info> <bytes>" of each EAPOL-Key frame sent.
private func handshakeLog(_ sim: Sim) -> [String] {
    sim.log.all.filter { $0.kind == .tx && isEapol($0) }.map { "\($0.node) \(eventView($0).info) \($0.frame!.size)" }
}

private func isDhcp(_ e: SimEvent) -> Bool {
    guard case .ipv4(let p)? = e.frame?.payload, case .udp(let u) = p.payload, case .dhcp = u.payload else { return false }
    return true
}

@Suite struct Wpa2Tests {
    /// Spec M11 §8: a WPA2 passphrase is 8 to 63 printable ASCII characters; nil is an open network (a station: no password).
    @Test func passphrasesAreEightToSixtyThreePrintableCharacters() throws {
        let sim = Sim()
        let ap = AccessPoint(sim: sim, id: "AP1")
        let tab = PacEngine.Host(sim: sim, id: "TAB1", wifi: true)
        for bad in ["1234567", String(repeating: "a", count: 64), "passwordè"] {
            expectError("The password must be 8 to 63 printable ASCII characters") { try ap.radio.configure(ApConfig(passphrase: bad)) }
            expectError("The password must be 8 to 63 printable ASCII characters") {
                try tab.station!.configure(StationConfig(ssid: "casa", passphrase: bad))
            }
        }
        try ap.radio.configure(ApConfig(passphrase: "12345678"))
        try ap.radio.configure(ApConfig(passphrase: String(repeating: "~", count: 63)))
        try ap.radio.configure(ApConfig(passphrase: nil))
        #expect(ap.radio.config == ApConfig())
        withExtendedLifetime(sim) {}
    }

    /// Spec M11 §8: the RSN element in the Probe Response and the Association Request; after the Association Response the four
    /// EAPOL-Key messages (99, 121, 155 and 99 B of EAPOL, unprotected); the line comes up only with message 4, so DHCP starts then;
    /// data frames are Protected and 16 B longer (CCMP header and MIC).
    @Test func theRightPasswordRunsTheFourWayHandshakeThenDataFlows() throws {
        let (sim, ap, tab) = try secured(password: "segreta123")
        sim.run(200 * MS)
        #expect(handshakeLog(sim) == [
            "AP1 EAPOL-Key 1 di 4 131", "TAB1 EAPOL-Key 2 di 4 153",
            "AP1 EAPOL-Key 3 di 4 187", "TAB1 EAPOL-Key 4 di 4 131",
        ])
        let sent = sim.log.all.filter { $0.kind == .tx }
        let rsn = sent.compactMap { e -> Dot11Mgmt? in if case .mgmt(let m)? = e.frame?.payload { m } else { nil } }.filter {
            switch $0 {
            case .probeResponse(_, _, _, true), .associationRequest(_, true): true
            default: false
            }
        }
        #expect(rsn.count == 2)
        let apSent = sent.filter { $0.node == "AP1" }.map { eventView($0).info }
        #expect(apSent.firstIndex(of: "EAPOL-Key 1 di 4") == apSent.firstIndex(of: "Association Response, stato 0, AID=1")! + 1)
        #expect(sent.filter(isEapol).allSatisfy { $0.frame?.air?.protected == false })
        let msg4 = sent.first { isEapol($0) && $0.node == "TAB1" && eventView($0).info.hasSuffix("4 di 4") }!
        let discover = sent.first { isDhcp($0) && $0.node == "TAB1" }!
        #expect(discover.time > msg4.time && discover.frame?.air?.protected == true)
        if case .ipv4(let p)? = discover.frame?.payload { #expect(discover.frame?.size == 24 + 8 + 16 + p.size) }
        #expect(tab.station!.state == .associated && tab.nic.lineUp && ap.radio.clients.map(\.authorized) == [true])
        // The relayed broadcast DISCOVER goes back on the air protected (group key) too.
        #expect(sent.contains { isDhcp($0) && $0.node == "AP1" && $0.frame?.air?.protected == true })
    }

    /// Spec M11 §8: with a wrong password each message 2 fails the MIC check (`mic-failure`); message 1 goes four times a second apart,
    /// then a Deauthentication with reason 15; the station stops on "wrong password" until its network or password changes.
    @Test func aWrongPasswordFailsTheMicAndEndsInADeauthentication() throws {
        let (sim, ap, tab) = try secured(password: "sbagliata1")
        sim.run(5 * S)
        // Counted from the Association Request: message 1 waits for the Association Response on the medium, its repeats do not.
        let t0 = sim.log.all.first { $0.kind == .rx && $0.node == "AP1" && eventView($0).info.hasPrefix("Association Request") }!.time
        let firsts = sim.log.all.filter { $0.kind == .tx && isEapol($0) && $0.node == "AP1" }.map { $0.time - t0 }
        #expect(firsts.count == 4 && firsts[0] < 1 * MS && Array(firsts.dropFirst()) == [1 * S, 2 * S, 3 * S])
        #expect(drops(sim, .micFailure) == 4 && sim.log.all.filter { $0.reason == .micFailure }.allSatisfy { $0.node == "AP1" })
        let deauth = sim.log.all.first { $0.kind == .tx && $0.node == "AP1" && eventView($0).info == "Deauthentication, motivo 15" }
        #expect(deauth.map { $0.time - t0 } == 4 * S)
        #expect(tab.station!.state == .wrongPassword && !tab.nic.lineUp && ap.radio.clients.isEmpty)
        let before = sim.log.all.count
        sim.run(10 * S)
        #expect(sim.log.all.count == before)
        try tab.station!.configure(StationConfig(ssid: "casa", passphrase: "segreta123"))
        sim.run(200 * MS)
        #expect(tab.station!.state == .associated)
    }

    /// Spec M11 §8: without a password a WPA2 network fails the same way.
    @Test func withoutAPasswordTheHandshakeFailsToo() throws {
        let (sim, _, tab) = try secured(password: nil)
        sim.run(5 * S)
        #expect(tab.station!.state == .wrongPassword && drops(sim, .micFailure) == 4)
    }

    /// Spec M11 §8: a password on an open network is not used: no handshake, no Protected flag.
    @Test func aStationWithAPasswordJoinsAnOpenNetworkWithoutHandshake() throws {
        let (sim, _, tab) = try secured(apPassword: nil, password: "segreta123")
        sim.run(200 * MS)
        #expect(tab.station!.state == .associated && handshakeLog(sim).isEmpty)
        #expect(sim.log.all.filter { $0.frame?.air != nil }.allSatisfy { $0.frame?.air?.protected == false })
    }

    /// Spec M11 §8: nonces come from the seed: two runs give the same handshake, and the two nonces differ.
    @Test func sameSeedSameNoncesAndMics() throws {
        let keys = try (0..<2).map { _ -> [EapolKey] in
            let (sim, _, _) = try secured(password: "segreta123")
            sim.run(200 * MS)
            return sim.log.all.filter { $0.kind == .tx }.compactMap { if case .eapol(let k)? = $0.frame?.payload { k } else { nil } }
        }
        #expect(keys[0] == keys[1] && keys[0].count == 4)
        #expect(keys[0][0].nonce.count == 32 && keys[0][0].nonce != keys[0][1].nonce && keys[0][1].mic.count == 16)
        #expect(keys[0][0].mic == [UInt8](repeating: 0, count: 16) && keys[0][3].nonce == [UInt8](repeating: 0, count: 32))
        #expect(keys[0].map(\.replay) == [1, 1, 2, 2])
    }

    /// Spec M11 §5, §8: a new password on the access point sends its stations away; with the old one they fail the handshake.
    @Test func changingTheAccessPointPasswordDeauthenticatesTheStations() throws {
        let (sim, ap, tab) = try secured(password: "segreta123")
        sim.run(200 * MS)
        try ap.radio.configure(ApConfig(ssid: "casa", channel: 6, passphrase: "nuovapass"))
        sim.run(6 * S)
        #expect(tab.station!.state == .wrongPassword)
    }

    /// Spec M11 §10: files of M11a have no passwords: open networks, stations without one.
    @Test func m11aConfigurationsDecodeWithoutAPassword() throws {
        let ap = try JSONDecoder().decode(ApConfig.self, from: Data(#"{"ssid":"lab","channel":1}"#.utf8))
        let station = try JSONDecoder().decode(StationConfig.self, from: Data(#"{"ssid":"lab"}"#.utf8))
        #expect(ap == ApConfig(ssid: "lab", channel: 1) && ap.passphrase == nil && station == StationConfig(ssid: "lab"))
    }
}
