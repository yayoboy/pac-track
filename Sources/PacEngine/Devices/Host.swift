final class Host: IpNode {
    /// Set while eth0 takes its address from DHCP.
    private(set) var dhcp: DhcpClient?

    override init(sim: Sim, id: String) {
        super.init(sim: sim, id: id)
        addInterface("eth0")
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
    }

    override func powerOn() {
        dhcp?.start()
    }
}
