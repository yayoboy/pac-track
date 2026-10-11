final class Host: IpNode {
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

    /// Switches the card between a static address and DHCP.
    func setDhcp(_ on: Bool) throws {
        try setDhcp(on, on: nic)
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

    /// The DHCP client stops with the stack (IpNode); the radio forgets its access point.
    override func reset() {
        super.reset()
        station?.reset()
    }

    /// DHCP on a cable asks again with the stack (IpNode); on Wi-Fi it waits for the association (spec M11 §5).
    override func powerOn() {
        super.powerOn()
        station?.restart()
    }
}
