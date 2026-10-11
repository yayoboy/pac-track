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

    /// Switches eth0 between a static address and DHCP. Entering DHCP drops the static address; leaving releases the lease.
    func setDhcp(_ on: Bool) throws {
        guard on != (dhcp != nil) else { return }
        guard on else {
            dhcp?.shutdown()
            dhcp = nil
            return
        }
        let eth0 = try iface("eth0")
        eth0.ipv4 = nil
        let client = try DhcpClient(node: self, iface: eth0)
        dhcp = client
        if powered { client.start() }
    }

    override func reset() {
        super.reset()
        dhcp?.stop(release: false)
        station?.reset()
    }

    override func powerOn() {
        super.powerOn()
        dhcp?.start()
        station?.restart()
    }
}
