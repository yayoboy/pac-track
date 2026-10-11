final class Host: IpNode {
    /// Set while the card takes its address from DHCP.
    private(set) var dhcp: DhcpClient?

    init(sim: Sim, id: String, wifi: Bool = false) {
        super.init(sim: sim, id: id)
        addNic(wifi: wifi)
    }

    /// The host's only card (spec M10 §4): `eth0`, or `wlan0` with a radio (spec M11 §2).
    var nic: Interface { interfaces[0] }
    var station: StationRadio? { nic.radio as? StationRadio }

    private func addNic(wifi: Bool) {
        let nic = addInterface(wifi ? "wlan0" : "eth0")
        if wifi { nic.radio = StationRadio(iface: nic) }
    }

    /// Switches the card between a static address and DHCP. Entering DHCP drops the static address; leaving releases the lease.
    func setDhcp(_ on: Bool) throws {
        guard on != (dhcp != nil) else { return }
        guard on else {
            dhcp?.shutdown()
            dhcp = nil
            return
        }
        nic.ipv4 = nil
        let client = try DhcpClient(node: self, iface: nic)
        dhcp = client
        // A Wi-Fi card asks once associated (spec M11 §5).
        if nic.radio == nil ? powered : nic.lineUp { client.start() }
    }

    /// The card and its network (spec M11 §2): Wi-Fi looking for `config.ssid`, or Ethernet with nil. A new card takes the old one's
    /// place with a new MAC, unconfigured (static, no address, IPv6 off), and the old one goes without a word (no DHCP release, no
    /// Deauthentication). Refused while a cable is plugged in.
    func setStation(_ config: StationConfig?) throws {
        if let config { try checkSsid(config.ssid, empty: true) }
        if (config != nil) != (station != nil) {
            guard nic.link == nil else { throw EngineError("\(nic.name) is connected") }
            dhcp?.stop(release: false)
            try setDhcp(false)
            try v6.configure(nic.name, nil)
            station?.reset()
            arp.reset()
            removeInterface(nic)
            addNic(wifi: config != nil)
        }
        if let config { try station?.configure(config) }
    }

    override func reset() {
        super.reset()
        dhcp?.stop(release: false)
        station?.reset()
    }

    override func powerOn() {
        super.powerOn()
        if nic.radio == nil { dhcp?.start() } // on Wi-Fi at association (spec M11 §5)
        station?.restart()
    }

    /// A Wi-Fi card's DHCP client runs while it is associated (spec M11 §5), like NetworkManager's: it starts at association and stops,
    /// address and all, when the association ends. On a cable it keeps M3's behaviour.
    override func linkChanged(_ iface: Interface) {
        super.linkChanged(iface)
        guard iface.radio != nil, let dhcp else { return }
        if iface.lineUp { dhcp.start() } else { dhcp.stop(release: false) }
    }
}
