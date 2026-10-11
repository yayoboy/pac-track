import PacEngine
import Testing
@testable import PacKit

@MainActor
@Suite struct HomeRouterEditorTests {
    let editor = Editor(client: Simulation())

    private func node(_ name: String) -> NodeView { editor.snapshot.nodes.first { $0.name == name }! }

    private func tick(_ times: Int) async {
        for _ in 0..<times { await editor.tick(wallMs: 100) }
    }

    /// Drags `name` to `pos` the way the canvas does: start, positions, end.
    private func drag(_ name: String, to pos: Pos) async {
        editor.moveStart()
        editor.setPosition(node(name).id, pos)
        await editor.moveEnd()
    }

    /// Spec M11 §8: a home router arrives as one: LAN 192.168.0.1/24, DHCP 192.168.0.100–149 with itself as gateway, NAT from LAN
    /// to Internet, the Internet port in DHCP, the access point's defaults; in one undo step.
    @Test func aHomeRouterArrivesReadyInOneStep() async throws {
        await editor.addDevice(.homeRouter, at: Pos(x: 0, y: 0))
        let hr = node("HR1")
        #expect(hr.kind == .homeRouter && DeviceKind.homeRouter.label == "Router Wi-Fi" && DeviceKind.homeRouter.hasIp && !DeviceKind.homeRouter.isHost)
        // The Wi-Fi settings sit in Servizi: six tabs do not fit the 300-point inspector.
        #expect(inspectorTabs(for: .homeRouter) == [.interfaces, .routing, .services, .tables, .app])
        #expect(hr.ifaces.map { "\($0.name) \($0.mode) \($0.cidr ?? "-")" } == [
            "Internet dhcp -", "LAN1 static -", "LAN2 static -", "LAN3 static -", "LAN4 static -", "WLAN static -", "LAN static 192.168.0.1/24",
        ])
        #expect(hr.dhcpServer == DhcpConfig(start: "192.168.0.100", end: "192.168.0.149", gateway: "192.168.0.1", dns: "192.168.0.1"))
        #expect(hr.nat == NatConfig(inside: ["LAN"], outside: "Internet") && hr.accessPoint?.config == ApConfig() && hr.firewall == nil)
        let saved = editor.current
        #expect(try ProjectFile.decode(try ProjectFile.encode(saved)) == saved)
        await editor.undo()
        #expect(editor.snapshot.nodes.isEmpty)
        let opened = await editor.load(saved)
        #expect(opened && node("HR1").nat != nil && node("HR1").ifaces[0].mode == .dhcp)
    }

    /// Spec M11 §8: Servizi's DHCP switch proposes the LAN's pool with HR1 as gateway and DNS; a copy arrives with the factory LAN,
    /// DHCP and NAT (settings out of the box, not the user's addresses).
    @Test func dhcpSwitchAndCopiesKeepTheLan() async {
        await editor.addDevice(.homeRouter, at: Pos(x: 0, y: 0))
        let hr = node("HR1").id
        await editor.edit([.setIfaceMode(node: hr, iface: "Internet", mode: .static), .setIp(node: hr, iface: "Internet", cidr: "203.0.113.7/24")])
        await editor.enableDhcp(hr, false)
        await editor.enableDhcp(hr, true)
        #expect(node("HR1").dhcpServer == DhcpConfig(start: "192.168.0.100", end: "192.168.0.199", gateway: "192.168.0.1", dns: "192.168.0.1"))
        await editor.duplicate([hr])
        let copy = node("HR2")
        #expect(copy.ifaces.last?.cidr == "192.168.0.1/24" && copy.nat == NatConfig(inside: ["LAN"], outside: "Internet")
            && copy.dhcpServer == DhcpConfig(start: "192.168.0.100", end: "192.168.0.149", gateway: "192.168.0.1", dns: "192.168.0.1"))
    }

    /// Spec M11 §8: the Cloud/ISP hands out the customer's address too.
    @Test func theCloudArrivesWithADhcpPool() async {
        await editor.addDevice(.cloud, at: Pos(x: 0, y: 0))
        #expect(node("ISP1").dhcpServer == DhcpConfig(start: "203.0.113.100", end: "203.0.113.199", gateway: "203.0.113.1", dns: "203.0.113.1"))
    }

    /// Spec M11 §8: a cable from a home router goes to its Internet port toward a Cloud/ISP or a router, else to the first free LAN
    /// port; never to WLAN or LAN.
    @Test func cablesPickTheInternetPortTowardTheProvider() async {
        await editor.addDevice(.homeRouter, at: Pos(x: 0, y: 0))
        await editor.addDevice(.pc, at: Pos(x: 100, y: 0))
        await editor.addDevice(.cloud, at: Pos(x: 200, y: 0))
        await editor.addDevice(.pc, at: Pos(x: 300, y: 0))
        await editor.connect(node("HR1").id, node("PC1").id)
        await editor.connect(node("ISP1").id, node("HR1").id)
        await editor.connect(node("HR1").id, node("PC2").id)
        #expect(editor.snapshot.links.map { "\($0.a.iface)-\($0.b.iface)" } == ["LAN1-eth0", "Gi0/0-Internet", "LAN2-eth0"])
        for _ in 0..<3 { await editor.addDevice(.pc, at: Pos(x: 0, y: 100)) }
        for name in ["PC3", "PC4", "PC5"] { await editor.connect(node("HR1").id, node(name).id) }
        #expect(editor.snapshot.links.count == 5 && editor.error?.message == "HR1 has no free port")
    }

    /// Spec M11 §8, M12 §2: a modem is the provider side too; whichever end is cabled first, it is the modem's eth0 to the home
    /// router's Internet port, and the Internet port leases its address from ISP1 across the modem's line.
    @Test func cablesPickTheInternetPortTowardAModem() async {
        for kind: DeviceKind in [.cloud, .modem, .homeRouter, .modem, .homeRouter] { await editor.addDevice(kind, at: Pos(x: 0, y: 0)) }
        await editor.connect(node("HR1").id, node("MODEM1").id)
        await editor.connect(node("MODEM2").id, node("HR2").id)
        await editor.connect(node("ISP1").id, node("MODEM1").id)
        #expect(editor.snapshot.links.map { "\($0.a.iface)-\($0.b.iface)" } == ["Internet-eth0", "eth0-Internet", "Gi0/0-dsl0"])
        for _ in 0..<60 { await editor.tick(wallMs: 100) }
        #expect(node("HR1").ifaces.first?.cidr == "203.0.113.100/24")
    }

    /// Spec M11 §1 (success M11b), §8: HR1 on ISP1 with `casa` in WPA2-PSK; TAB1 with the right password associates, runs the
    /// handshake and leases 192.168.0.100 with ISP1's DNS, then reaches the Internet; PHONE1 with a wrong one stops on "Password
    /// errata"; dragged out of range TAB1 loses HR1, dragged back it finds it again, slower near the edge.
    @Test func theSpecLabWorksAsDropped() async throws {
        await editor.addDevice(.cloud, at: Pos(x: 0, y: 0))
        await editor.addDevice(.homeRouter, at: Pos(x: 0, y: 150))
        await editor.connect(node("ISP1").id, node("HR1").id)
        let hr = node("HR1").id
        await editor.edit(.setAccessPoint(node: hr, config: ApConfig(ssid: "casa", channel: 6, passphrase: "segreta123")))
        await editor.addDevice(.tablet, at: Pos(x: 0, y: 250))
        await editor.addDevice(.smartphone, at: Pos(x: -100, y: 250))
        await editor.edit(.setStation(node: node("TAB1").id, config: StationConfig(ssid: "casa", passphrase: "segreta123")))
        await editor.edit(.setStation(node: node("PHONE1").id, config: StationConfig(ssid: "casa", passphrase: "sbagliata1")))
        // The PHONE1 handshake gives up at ~4 s; by then everything else has long settled.
        await tick(60)
        #expect(node("TAB1").station?.state == .associated && airLinks(editor.snapshot.nodes).map(\.b) == [IfaceRef(node: hr, iface: "WLAN")])
        #expect(node("TAB1").ifaces[0].cidr == "192.168.0.100/24" && node("TAB1").learnedNameServer == "192.168.0.1")
        #expect(node("HR1").ifaces[0].cidr == "203.0.113.100/24")
        #expect(wifiSignal(node("TAB1").station!) == "Segnale -47 dBm · 54 Mb/s")
        #expect(associationRows(node("HR1").accessPoint!, in: editor.snapshot.nodes) == [["1", node("TAB1").ifaces[0].mac, "TAB1\n-47 dBm · 54 Mb/s"]])
        await editor.run(.nslookup(node: node("TAB1").id, name: "www.example.com"))
        await tick(5)
        #expect(editor.snapshot.apps.last?.lines.contains("Address: 198.51.100.10") == true)
        await editor.run(.ping(node: node("TAB1").id, target: "198.51.100.10"))
        await tick(50)
        #expect(editor.snapshot.apps.last?.lines.contains("4 packets transmitted, 4 received, 0% packet loss") == true)
        #expect(wifiStatus(node("PHONE1").station!, in: editor.snapshot.nodes) == "Password errata" && node("PHONE1").ifaces[0].cidr == nil)
        // Out of range: the association ends at once; back near the edge it returns at the next scan, at a lower rate.
        await drag("TAB1", to: Pos(x: 400, y: 150))
        #expect(node("TAB1").station?.state != .associated && airLinks(editor.snapshot.nodes).isEmpty)
        await drag("TAB1", to: Pos(x: 270, y: 150))
        await tick(55)
        #expect(node("TAB1").station?.state == .associated && node("TAB1").station?.rate == 18)
        // Undoing the move puts TAB1 back out of range in the engine too.
        await editor.undo()
        #expect(editor.positions[node("TAB1").id] == Pos(x: 400, y: 150) && node("TAB1").station?.state != .associated)
    }
}
