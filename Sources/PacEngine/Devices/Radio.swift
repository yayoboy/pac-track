/// Active scanning and association (spec M11 §5): 20 ms on each channel, a new scan 5 s after one nobody answered, 1 s for each
/// answer of the access point before starting over.
let SCAN_DWELL_NS = 20 * MS
let RESCAN_NS = 5 * S
let DOT11_TIMEOUT_NS = 1 * S
/// Messages 1 an access point sends, a second apart, before giving up on a station's handshake (hostapd's default, spec M11 §8).
let EAPOL_ATTEMPTS = 4

/// How far a radio reaches on the canvas, in points (spec M11 §8).
public let WIFI_RANGE = 300.0
/// Minimum sensitivity in dBm of each 802.11g rate (IEEE 802.11-2016 Table 17-18), slowest first.
let DOT11_SENSITIVITY: [(rate: Int, dbm: Int)] = [(6, -82), (9, -81), (12, -79), (18, -77), (24, -74), (36, -70), (48, -66), (54, -65)]

/// What a radio on `b` hears of one on `a` (spec M11 §8): −30 dBm side by side down to −82 dBm (the 6 Mb/s sensitivity) at
/// WIFI_RANGE, linear in dB; nil beyond, where they do not hear each other at all.
// ponytail: linear in dB rather than log-distance, so 54 Mb/s reaches two thirds of the circle at canvas scale
func dot11Signal(_ a: Node, _ b: Node) -> Int? {
    let (dx, dy) = (a.pos.x - b.pos.x, a.pos.y - b.pos.y)
    let d = (dx * dx + dy * dy).squareRoot()
    guard d <= WIFI_RANGE else { return nil }
    return Int((-30 - 52 * d / WIFI_RANGE).rounded())
}

/// The highest rate whose minimum sensitivity `signal` reaches.
func dot11Rate(signal: Int) -> Int {
    DOT11_SENSITIVITY.last { signal >= $0.dbm }?.rate ?? DOT11_BASIC_RATE
}

/// An SSID is at most 32 bytes (IEEE 802.11-2016 §9.4.2.2); an access point's is never empty.
func checkSsid(_ ssid: String, empty: Bool) throws {
    guard ssid.utf8.count <= 32, empty || !ssid.isEmpty else {
        throw EngineError(empty ? "SSID must be at most 32 bytes" : "SSID must be 1 to 32 bytes")
    }
}

/// A WPA2 passphrase (802.11i): 8 to 63 printable ASCII characters; nil is an open network, or a station without one.
func checkPassphrase(_ p: String?) throws {
    guard let p else { return }
    guard (8...63).contains(p.utf8.count), p.utf8.allSatisfy({ (32...126).contains($0) }) else {
        throw EngineError("The password must be 8 to 63 printable ASCII characters")
    }
}

/// One 2.4 GHz channel (spec M11 §4): a half-duplex medium shared by every radio tuned to it. One frame at a time, served in order of
/// arrival (a CSMA/CA that never collides); each holds it for DIFS + backoff + the frame, then SIFS + ACK if unicast.
final class Medium {
    unowned let sim: Sim
    let channel: Int
    private var queue: [(radio: Radio, frame: EthernetFrame)] = []
    private var busy = false

    init(sim: Sim, channel: Int) {
        self.sim = sim
        self.channel = channel
    }

    /// On the air at once if the medium is free, else in the queue (at most DOT11_QUEUE_LIMIT frames per radio).
    func transmit(_ frame: EthernetFrame, from radio: Radio) {
        guard busy else { return start(frame, from: radio) }
        guard radio.queued < DOT11_QUEUE_LIMIT else {
            return sim.emit(.drop, node: radio.iface.node.id, iface: radio.iface.name, frame: frame, reason: .queueFull)
        }
        radio.queued += 1
        queue.append((radio, frame))
    }

    /// TX when the frame takes the medium, RX at every radio of the channel that is on and addressed when it ends (the others drop it
    /// silently, like a card's MAC filter); the ACK keeps the medium busy after that.
    private func start(_ frame: EthernetFrame, from radio: Radio) {
        busy = true
        sim.emit(.tx, node: radio.iface.node.id, iface: radio.iface.name, frame: frame)
        let t = dot11Airtime(frame)
        sim.sched.after(t.frame * US) { [self] in
            for r in sim.radios() where r !== radio && r.channel == channel && r.iface.node.powered && r.hears(frame)
                && dot11Signal(radio.iface.node, r.iface.node) != nil {
                sim.emit(.rx, node: r.iface.node.id, iface: r.iface.name, frame: frame)
                r.receive(frame, from: radio)
            }
            sim.sched.after(t.ack * US) { [self] in next() }
        }
    }

    private func next() {
        while !queue.isEmpty {
            let (radio, frame) = queue.removeFirst()
            radio.queued -= 1
            if radio.iface.node.powered { return start(frame, from: radio) }
            // A radio switched off loses what was waiting, and says so (like a cable's queue).
            sim.emit(.drop, node: radio.iface.node.id, iface: radio.iface.name, frame: frame, reason: .ifaceDown)
        }
        busy = false
    }
}

/// A Wi-Fi interface's radio (spec M11 §4): it puts frames on its channel's medium with an 802.11 header and hears, of what goes by,
/// only what is addressed to it. Subclasses override `receive`.
class Radio {
    unowned let iface: Interface
    /// The channel it is tuned to.
    var channel: Int
    /// Its frames waiting for the medium.
    var queued = 0
    /// The next sequence number: 12 bits, one counter per transmitter (§9.2.4.4).
    private var seq = 0

    init(iface: Interface, channel: Int) {
        self.iface = iface
        self.channel = channel
    }

    var sim: Sim { iface.node.sim }
    /// Its BSS: an access point's own MAC, a station's chosen access point.
    var bssid: Mac? { nil }
    /// What `Interface.lineUp` reports: a station associated, an access point with stations.
    var lineUp: Bool { false }

    /// The interfaces its frames reach over the air (what `Interface.segmentPeers` crosses).
    var peers: [Interface] { [] }

    /// A data frame of its node.
    func send(_ frame: EthernetFrame) {
        fatalError("\(type(of: self)) must override send(_:)")
    }

    func receive(_ f: EthernetFrame, from sender: Radio) {
        fatalError("\(type(of: self)) must override receive(_:from:)")
    }

    /// The address filter (spec M11 §4): frames to its own MAC, and group frames of its BSS (for an access point: the Probe Requests,
    /// sent to the wildcard BSSID). A group frame the access point relays back to its source is not heard there (spec M11 §6).
    func hears(_ f: EthernetFrame) -> Bool {
        guard let h = f.air, f.src != iface.mac else { return false }
        if f.receiver == iface.mac { return true }
        let bss: Mac? = self is ApRadio ? BROADCAST_MAC : bssid
        return isGroupMac(f.receiver) && h.bssid == bss
    }

    /// The unicast data rate toward `other` at their distance (spec M11 §8).
    func rate(to other: Radio) -> Int {
        dot11Signal(iface.node, other.iface.node).map { dot11Rate(signal: $0) } ?? DOT11_BASIC_RATE
    }

    /// On the air with `header`, the next sequence number and the rate it goes at (6 Mb/s unless a unicast data rate is given).
    func transmit(_ frame: EthernetFrame, _ header: Dot11Header, rate: Int = DOT11_BASIC_RATE) {
        var f = frame
        f.air = header
        f.air!.seq = seq
        f.air!.rate = rate
        seq = (seq + 1) % 4096
        sim.medium(channel).transmit(f, from: self)
    }

    func sendMgmt(_ m: Dot11Mgmt, to dst: Mac, bssid: Mac) {
        transmit(EthernetFrame(id: sim.nextId(), src: iface.mac, dst: dst, etherType: 0, payload: .mgmt(m)), Dot11Header(bssid: bssid))
    }

    /// A handshake message to `peer` (spec M11 §8): a data frame, unprotected, at the peer's rate.
    func sendEapol(_ k: EapolKey, to peer: Radio, _ header: Dot11Header) {
        transmit(EthernetFrame(id: sim.nextId(), src: iface.mac, dst: peer.iface.mac, etherType: ETHERTYPE_EAPOL, payload: .eapol(k)), header,
                 rate: rate(to: peer))
    }

    /// 32 B from the seed: an ANonce or SNonce.
    func nonce() -> [UInt8] {
        (0..<32).map { _ in UInt8(sim.rng.int(256)) }
    }
}

/// A Wi-Fi client's radio (spec M11 §5): active scanning, Open System authentication, association with the first access point that
/// answered. It stores no timers: a callback acts only if `generation` is unchanged since it was scheduled (as in `DhcpClient`).
final class StationRadio: Radio {
    private(set) var config = StationConfig()
    private(set) var state = StationState.idle
    /// The access point it chose, from authentication on.
    private(set) weak var ap: ApRadio?
    /// The first access point that answered the scan under way, and the channel it announced.
    private weak var found: ApRadio?
    private var foundChannel = 0
    private var foundSignal = 0
    private var foundRsn = false
    /// WPA2 with the access point it chose (it announced RSN): a 4-way handshake after the association, then protected data.
    private var rsn = false
    private var anonce: [UInt8] = []
    private var snonce: [UInt8] = []
    private var generation = 0

    init(iface: Interface) {
        super.init(iface: iface, channel: WIFI_CHANNELS[0])
    }

    override var bssid: Mac? { ap?.iface.mac }
    override var lineUp: Bool { state == .associated }
    override var peers: [Interface] { state == .associated ? ap.map { [$0.iface] } ?? [] : [] }
    /// dBm from its access point while associated (spec M11 §8).
    var signal: Int? { state == .associated ? ap.flatMap { dot11Signal(iface.node, $0.iface.node) } : nil }

    /// To its access point (To DS), once associated (spec M11 §3, §5).
    override func send(_ frame: EthernetFrame) {
        guard state == .associated, let bssid else {
            return sim.emit(.drop, node: iface.node.id, iface: iface.name, frame: frame, reason: .notAssociated)
        }
        transmit(frame, Dot11Header(toDS: true, bssid: bssid, protected: rsn), rate: ap.map { rate(to: $0) } ?? DOT11_DATA_RATE)
    }

    /// A new network (spec M11 §5): leaving an access point says so with a Deauthentication (reason 3), then the scan starts over.
    func configure(_ c: StationConfig) throws {
        try checkSsid(c.ssid, empty: true)
        try checkPassphrase(c.passphrase)
        guard c != config else { return }
        if state == .associated, let ap { sendMgmt(.deauthentication(reason: DOT11_REASON_LEAVING), to: ap.iface.mac, bssid: ap.iface.mac) }
        config = c
        restart()
    }

    /// Scans again from channel 1 after leaving any access point; idle without a network or while switched off. Also how an access
    /// point's going away (switched off, removed, a Deauthentication) reaches the station. The access point forgets it at once, without
    /// a frame: one that accepted an Association Request whose answer came too late keeps no orphan.
    func restart() {
        ap?.forget(self)
        leave()
        guard iface.node.powered, !config.ssid.isEmpty else { return }
        state = .scanning
        later(0) { $0.scan(0) }
    }

    /// Switched off or removed (spec M11 §5): the access point forgets it at once, without a frame.
    func reset() {
        ap?.forget(self)
        leave()
    }

    /// Back to idle with every timer void; a line that was up goes down (IPv6 and DHCP follow, spec M11 §5).
    private func leave() {
        let wasUp = state == .associated
        generation += 1
        state = .idle
        ap = nil
        if wasUp { iface.node.linkChanged(iface) }
    }

    private func later(_ delay: Int, _ action: @escaping (StationRadio) -> Void) {
        let gen = generation
        sim.sched.after(delay) { [self] in
            if gen == generation { action(self) }
        }
    }

    /// Active scanning (§11.1.4.3): a Probe Request for the SSID on each channel in turn, listening SCAN_DWELL_NS on each.
    private func scan(_ k: Int) {
        if k == 0 {
            state = .scanning
            found = nil
        }
        guard k < WIFI_CHANNELS.count else { return choose() }
        channel = WIFI_CHANNELS[k]
        sendMgmt(.probeRequest(ssid: config.ssid), to: BROADCAST_MAC, bssid: BROADCAST_MAC)
        later(SCAN_DWELL_NS) { $0.scan(k + 1) }
    }

    /// The scan is over: authenticate with the strongest access point that answered (the first of equals, spec M11 §8), or scan again
    /// in RESCAN_NS.
    private func choose() {
        guard let found else {
            state = .notFound
            return later(RESCAN_NS) { $0.scan(0) }
        }
        ap = found
        channel = foundChannel
        rsn = foundRsn
        state = .authenticating
        sendMgmt(.authentication(seq: 1, status: 0), to: found.iface.mac, bssid: found.iface.mac)
        later(DOT11_TIMEOUT_NS) { $0.restart() }
    }

    override func receive(_ f: EthernetFrame, from sender: Radio) {
        let fromAp = f.src == bssid
        guard case .mgmt(let m) = f.payload else {
            // The handshake with its access point; data from it once associated.
            if case .eapol(let k) = f.payload {
                if state == .handshake && fromAp { handshake(k) }
            } else if state == .associated, f.air?.bssid == bssid {
                iface.node.receive(f, on: iface)
            }
            return
        }
        switch m {
        case .probeResponse(let ssid, let channel, _, let rsn) where state == .scanning && ssid == config.ssid:
            let signal = dot11Signal(iface.node, sender.iface.node) ?? Int.min
            if found == nil || signal > foundSignal {
                found = sender as? ApRadio
                foundChannel = channel
                foundSignal = signal
                foundRsn = rsn
            }
        case .authentication(seq: 2, status: 0) where state == .authenticating && fromAp:
            generation += 1
            state = .associating
            sendMgmt(.associationRequest(ssid: config.ssid, rsn: rsn), to: f.src, bssid: f.src)
            later(DOT11_TIMEOUT_NS) { $0.restart() }
        case .associationResponse(status: 0, aid: _) where state == .associating && fromAp:
            generation += 1
            // WPA2 waits for the access point's message 1, with no timer of its own: the access point's Deauthentication, its going
            // away or a new network ends the wait (spec M11 §8).
            guard !rsn else {
                state = .handshake
                snonce = nonce()
                return
            }
            state = .associated
            iface.node.linkChanged(iface)
        case .deauthentication(let reason) where fromAp:
            // The access point gave up on the handshake: the password is wrong, and trying again would fail again (spec M11 §8).
            guard reason == DOT11_REASON_HANDSHAKE_TIMEOUT && state == .handshake else { return restart() }
            leave()
            state = .wrongPassword
        default:
            break
        }
    }

    /// Supplicant side of the 4-way handshake (spec M11 §8): message 2 answers each message 1 with the SNonce and a MIC of its own
    /// password; a message 3 whose MIC matches installs the keys: message 4, and the line comes up.
    private func handshake(_ k: EapolKey) {
        guard let ap else { return }
        let pass = config.passphrase ?? ""
        let header = Dot11Header(toDS: true, bssid: ap.iface.mac)
        switch k.message {
        case 1:
            anonce = k.nonce
            let mic = eapolMic(passphrase: pass, ssid: config.ssid, anonce: anonce, snonce: snonce, message: 2)
            sendEapol(EapolKey(message: 2, replay: k.replay, nonce: snonce, mic: mic), to: ap, header)
        case 3 where k.nonce == anonce && k.mic == eapolMic(passphrase: pass, ssid: config.ssid, anonce: anonce, snonce: snonce, message: 3):
            let mic = eapolMic(passphrase: pass, ssid: config.ssid, anonce: anonce, snonce: snonce, message: 4)
            sendEapol(EapolKey(message: 4, replay: k.replay, nonce: [UInt8](repeating: 0, count: 32), mic: mic), to: ap, header)
            state = .associated
            iface.node.linkChanged(iface)
        default:
            break
        }
    }
}

/// An access point's radio (spec M11 §2, §5): one SSID on one channel; it answers probes for its SSID, authenticates (Open System)
/// and associates every station that asks, numbering them from AID 1.
// ponytail: no per-station authentication state; the stations here always authenticate before they associate
final class ApRadio: Radio {
    /// One association: what the radio side of the bridge knows of a station (spec M11 §6).
    struct Client {
        let aid: Int
        let station: StationRadio
        /// Open network, or a WPA2 handshake done (spec M11 §8): its data crosses the bridge.
        var authorized: Bool
        /// The handshake under way: nonces (the SNonce once a valid message 2 came), replay counter, messages 1 sent.
        var anonce: [UInt8] = []
        var snonce: [UInt8] = []
        var replay = 0
        var tries = 0
    }

    private(set) var config = ApConfig()
    /// By AID.
    private(set) var clients: [Client] = []

    init(iface: Interface) {
        super.init(iface: iface, channel: ApConfig().channel)
    }

    override var bssid: Mac? { iface.mac }
    /// Stations whose data crosses the bridge: a WPA2 one only after its handshake (spec M11 §8).
    private var authorized: [Client] { clients.filter(\.authorized) }
    override var lineUp: Bool { !authorized.isEmpty }
    override var peers: [Interface] { authorized.map(\.station.iface) }

    /// A frame of the bridge for the stations (From DS): to one of them at its rate, to a group at 6 Mb/s; protected on a WPA2 network.
    override func send(_ frame: EthernetFrame) {
        let to = clients.first { $0.station.iface.mac == frame.dst }?.station
        transmit(frame, Dot11Header(fromDS: true, bssid: iface.mac, protected: config.passphrase != nil),
                 rate: to.map { rate(to: $0) } ?? DOT11_BASIC_RATE)
    }

    func associated(_ mac: Mac) -> Bool {
        authorized.contains { $0.station.iface.mac == mac }
    }

    /// A new SSID, channel or security (spec M11 §5, §8): a group Deauthentication (reason 3) on the old channel; the stations scan again when they
    /// hear it.
    func configure(_ c: ApConfig) throws {
        try checkSsid(c.ssid, empty: false)
        try checkPassphrase(c.passphrase)
        guard WIFI_CHANNELS.contains(c.channel) else { throw EngineError("Channel must be 1, 6 or 11") }
        guard c != config else { return }
        if !clients.isEmpty { sendMgmt(.deauthentication(reason: DOT11_REASON_LEAVING), to: BROADCAST_MAC, bssid: iface.mac) }
        clients = []
        config = c
        channel = c.channel
    }

    func forget(_ s: StationRadio) {
        clients.removeAll { $0.station === s }
    }

    /// Switched off or removed (spec M11 §5): every station knows at once, without a frame, and scans again.
    func dropAll() {
        let gone = clients
        clients = []
        for c in gone { c.station.restart() }
    }

    override func receive(_ f: EthernetFrame, from sender: Radio) {
        guard case .mgmt(let m) = f.payload else {
            // The handshake from the stations it associated; their data once authorized (spec M11 §5, §8).
            if case .eapol(let k) = f.payload, let station = sender as? StationRadio, clients.contains(where: { $0.station === station }) {
                return handshake(k, f, from: station)
            }
            guard authorized.contains(where: { $0.station === sender }) else {
                return sim.emit(.drop, node: iface.node.id, iface: iface.name, frame: f, reason: .notAssociated)
            }
            return iface.node.receive(f, on: iface)
        }
        guard let station = sender as? StationRadio else { return }
        let wpa2 = config.passphrase != nil
        switch m {
        case .probeRequest(let ssid) where ssid == config.ssid:
            sendMgmt(.probeResponse(ssid: ssid, channel: config.channel, timestamp: sim.now / US, rsn: wpa2), to: f.src, bssid: iface.mac)
        case .authentication(seq: 1, status: _):
            sendMgmt(.authentication(seq: 2, status: 0), to: f.src, bssid: iface.mac)
        case .associationRequest(let ssid, _) where ssid == config.ssid:
            let aid = clients.first { $0.station === station }?.aid ?? freeAid()
            clients.removeAll { $0.station === station }
            clients.append(Client(aid: aid, station: station, authorized: !wpa2, anonce: wpa2 ? nonce() : []))
            clients.sort { $0.aid < $1.aid }
            sendMgmt(.associationResponse(status: 0, aid: aid), to: f.src, bssid: iface.mac)
            // WPA2: message 1 right after the Association Response (spec M11 §8).
            if wpa2 { sendMessage1(station) }
        case .deauthentication:
            forget(station)
        default:
            break
        }
    }

    /// Authenticator side of the 4-way handshake (spec M11 §8): a valid message 2 gets message 3 at once; message 4 opens the port.
    /// A wrong MIC is dropped and logged; the timer of message 1 deals with the silence.
    private func handshake(_ k: EapolKey, _ f: EthernetFrame, from s: StationRadio) {
        guard let pass = config.passphrase, let i = clients.firstIndex(where: { $0.station === s }), !clients[i].authorized,
              k.replay == clients[i].replay else { return }
        let c = clients[i]
        switch k.message {
        case 2 where c.snonce.isEmpty:
            guard k.mic == eapolMic(passphrase: pass, ssid: config.ssid, anonce: c.anonce, snonce: k.nonce, message: 2) else {
                return sim.emit(.drop, node: iface.node.id, iface: iface.name, frame: f, reason: .micFailure)
            }
            clients[i].snonce = k.nonce
            clients[i].replay += 1
            let mic = eapolMic(passphrase: pass, ssid: config.ssid, anonce: c.anonce, snonce: k.nonce, message: 3)
            sendEapol(EapolKey(message: 3, replay: clients[i].replay, nonce: c.anonce, mic: mic), to: s, Dot11Header(fromDS: true, bssid: iface.mac))
        case 4 where !c.snonce.isEmpty:
            guard k.mic == eapolMic(passphrase: pass, ssid: config.ssid, anonce: c.anonce, snonce: c.snonce, message: 4) else {
                return sim.emit(.drop, node: iface.node.id, iface: iface.name, frame: f, reason: .micFailure)
            }
            clients[i].authorized = true
        default:
            break
        }
    }

    /// Message 1 with a new replay counter; repeated a second later while no valid message 2 came, and after the last attempt a
    /// Deauthentication with reason 15 (spec M11 §8). The timer acts only if the station is still in this handshake.
    private func sendMessage1(_ s: StationRadio) {
        guard let i = clients.firstIndex(where: { $0.station === s }) else { return }
        clients[i].tries += 1
        clients[i].replay += 1
        let (anonce, tries) = (clients[i].anonce, clients[i].tries)
        sendEapol(EapolKey(message: 1, replay: clients[i].replay, nonce: anonce, mic: [UInt8](repeating: 0, count: 16)), to: s,
                  Dot11Header(fromDS: true, bssid: iface.mac))
        sim.sched.after(DOT11_TIMEOUT_NS) { [self] in
            guard let c = clients.first(where: { $0.station === s }), c.anonce == anonce, c.tries == tries, c.snonce.isEmpty else { return }
            if tries < EAPOL_ATTEMPTS { return sendMessage1(s) }
            forget(s)
            sendMgmt(.deauthentication(reason: DOT11_REASON_HANDSHAKE_TIMEOUT), to: s.iface.mac, bssid: iface.mac)
        }
    }

    private func freeAid() -> Int {
        var aid = 1
        while clients.contains(where: { $0.aid == aid }) { aid += 1 }
        return aid
    }
}
