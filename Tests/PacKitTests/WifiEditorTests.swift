import PacEngine
import Testing
@testable import PacKit

@MainActor
@Suite struct WifiEditorTests {
    let editor = Editor(client: Simulation())

    private func node(_ name: String) -> NodeView { editor.snapshot.nodes.first { $0.name == name }! }
    private func modes(_ name: String) -> [String] { node(name).ifaces.map { "\($0.name) \($0.mode)" } }

    /// Spec M11 §2: an access point on pac-track, channel 6; tablets and smartphones looking for pac-track in DHCP, one step each.
    @Test func wirelessDevicesArriveReadyEachInOneStep() async throws {
        await editor.addDevice(.accessPoint, at: Pos(x: 0, y: 0))
        await editor.addDevice(.tablet, at: Pos(x: 100, y: 0))
        await editor.addDevice(.smartphone, at: Pos(x: 200, y: 0))
        #expect(editor.snapshot.nodes.map(\.name) == ["AP1", "TAB1", "PHONE1"])
        #expect(node("AP1").accessPoint?.config == ApConfig(ssid: "pac-track", channel: 6))
        for name in ["TAB1", "PHONE1"] { #expect(node(name).station?.config == StationConfig(ssid: "pac-track") && modes(name) == ["wlan0 dhcp"]) }
        let saved = editor.current
        #expect(saved.nodes.map(\.accessPoint) == [ApConfig(), nil, nil])
        #expect(saved.nodes.map(\.station) == [nil, StationConfig(ssid: "pac-track"), StationConfig(ssid: "pac-track")])
        #expect(try ProjectFile.decode(try ProjectFile.encode(saved)) == saved)
        await editor.undo()
        #expect(editor.snapshot.nodes.map(\.name) == ["AP1", "TAB1"]) // the smartphone and its settings in one step
        await editor.undo()
        #expect(editor.snapshot.nodes.map(\.name) == ["AP1"])
        let opened = await editor.load(saved)
        #expect(opened && editor.snapshot.nodes.map(\.kind) == [.accessPoint, .tablet, .smartphone])
        for _ in 0..<2 { await editor.tick(wallMs: 100) }
        #expect(editor.snapshot.nodes.dropFirst().map { $0.station?.state } == [.associated, .associated])
    }

    /// Spec M11 §2: *Scheda di rete* swaps the card with its DHCP mode in one undo step; refused while the cable is in.
    @Test func swappingTheCardCarriesDhcpInOneStep() async {
        await editor.addDevice(.laptop, at: Pos(x: 0, y: 0))
        await editor.addDevice(.switch, at: Pos(x: 100, y: 0))
        let (laptop, sw) = (node("LAPTOP1").id, node("SW1").id)
        await editor.edit(.setIfaceMode(node: laptop, iface: "eth0", mode: .dhcp))
        await editor.connect(laptop, sw)
        await editor.setNic(laptop, wifi: true)
        #expect(editor.error == EditorError(key: "nic:\(laptop)", message: "eth0 is connected") && node("LAPTOP1").station == nil)
        await editor.remove(nodes: [], links: [editor.snapshot.links[0].id])
        await editor.setNic(laptop, wifi: true)
        #expect(modes("LAPTOP1") == ["wlan0 dhcp"] && node("LAPTOP1").station?.config == StationConfig())
        await editor.undo()
        #expect(modes("LAPTOP1") == ["eth0 dhcp"] && node("LAPTOP1").station == nil)
        await editor.redo()
        #expect(modes("LAPTOP1") == ["wlan0 dhcp"])
        await editor.setNic(laptop, wifi: false)
        #expect(modes("LAPTOP1") == ["eth0 dhcp"] && node("LAPTOP1").station == nil)
        await editor.connect(laptop, sw)
        #expect(editor.snapshot.links.count == 1)
    }

    /// Spec M11 §10: copies keep the access point's network, the client's network and a laptop's Wi-Fi card.
    @Test func copiesKeepTheNetworkAndTheCard() async {
        await editor.addDevice(.accessPoint, at: Pos(x: 0, y: 0))
        await editor.addDevice(.laptop, at: Pos(x: 100, y: 0))
        await editor.addDevice(.tablet, at: Pos(x: 200, y: 0))
        let ids = editor.snapshot.nodes.map(\.id)
        await editor.edit(.setAccessPoint(node: ids[0], config: ApConfig(ssid: "lab", channel: 11)))
        await editor.setNic(ids[1], wifi: true)
        await editor.edit([.setStation(node: ids[1], config: StationConfig(ssid: "lab")), .setIfaceMode(node: ids[1], iface: "wlan0", mode: .dhcp)])
        await editor.duplicate(ids)
        let copies = Array(editor.snapshot.nodes.suffix(3))
        #expect(copies.map(\.name) == ["AP2", "LAPTOP2", "TAB2"])
        #expect(copies.map { $0.accessPoint?.config } == [ApConfig(ssid: "lab", channel: 11), nil, nil])
        #expect(copies.map { $0.station?.config } == [nil, StationConfig(ssid: "lab"), StationConfig(ssid: "pac-track")])
        #expect(copies.map { $0.ifaces.map { "\($0.name) \($0.mode)" } } == [["Gi0 static", "Dot11Radio0 static"], ["wlan0 dhcp"], ["wlan0 dhcp"]])
    }

    /// Spec M11 §1: SW1 with AP1 and a Server DHCP on its cables; a tablet, a smartphone and a laptop with the Wi-Fi card on pac-track,
    /// in DHCP; nothing else typed.
    @Test func theSpecLabWorksAsDropped() async {
        await editor.addDevice(.switch, at: Pos(x: 0, y: 0))
        await editor.addDevice(.accessPoint, at: Pos(x: 0, y: 100))
        await editor.addDevice(.server, at: Pos(x: 100, y: 100), preset: .dhcp)
        await editor.addDevice(.tablet, at: Pos(x: 0, y: 200))
        await editor.addDevice(.smartphone, at: Pos(x: 100, y: 200))
        await editor.addDevice(.laptop, at: Pos(x: 200, y: 200))
        for name in ["AP1", "SRV1"] { await editor.connect(node("SW1").id, node(name).id) }
        let laptop = node("LAPTOP1").id
        await editor.setNic(laptop, wifi: true)
        await editor.edit([.setStation(node: laptop, config: StationConfig(ssid: "pac-track")), .setIfaceMode(node: laptop, iface: "wlan0", mode: .dhcp)])
        for _ in 0..<2 { await editor.tick(wallMs: 100) }
        // Associated within ms: a dashed line per client, "associato" with AP1's BSSID.
        #expect(airLinks(editor.snapshot.nodes).map(\.b.node) == Array(repeating: node("AP1").id, count: 3))
        #expect(node("TAB1").station?.bssid == node("AP1").ifaces[1].mac && node("AP1").accessPoint?.clients.count == 3)
        // SW1's port to AP1 forwards at 30 s; the DISCOVERs sent at association retry at 4, 12, 28 and 60 s.
        for _ in 0..<608 { await editor.tick(wallMs: 100) }
        #expect(Set(["TAB1", "PHONE1", "LAPTOP1"].map { node($0).ifaces[0].cidr }) == ["192.168.1.100/24", "192.168.1.101/24", "192.168.1.102/24"])
        let phone = String(node("PHONE1").ifaces[0].cidr!.split(separator: "/")[0])
        await editor.run(.ping(node: node("TAB1").id, target: phone))
        for _ in 0..<50 { await editor.tick(wallMs: 100) }
        #expect(editor.snapshot.apps.last?.lines.contains("4 packets transmitted, 4 received, 0% packet loss") == true)
        // The generator measures what SRV1's sink receives; in the air one frame at a time with DIFS, backoff and ACK (spec M11 §4).
        await editor.edit(.setSink(node: node("SRV1").id, on: true))
        await editor.startTraffic(node("TAB1").id, target: "192.168.1.2", kind: .udp, amount: "50", seconds: "2")
        for _ in 0..<25 { await editor.tick(wallMs: 100) }
        let goodput = 1470.0 * 8 / 389e-6
        let samples = editor.snapshot.apps.last!.samples
        #expect(samples.count >= 15)
        for s in samples[5...14] { #expect(abs(s.bitsPerSecond - goodput) / goodput < 0.01) }
        // AP1 off: the lines go at once; back on, the clients find it at their next scan.
        await editor.edit(.setPower(id: node("AP1").id, on: false))
        #expect(airLinks(editor.snapshot.nodes).isEmpty && node("TAB1").ifaces[0].cidr == nil)
        await editor.edit(.setPower(id: node("AP1").id, on: true))
        for _ in 0..<52 { await editor.tick(wallMs: 100) }
        #expect(airLinks(editor.snapshot.nodes).count == 3)
        // Saved and reopened: the same network; the clients associate again by themselves.
        let saved = editor.current
        _ = await editor.load(saved)
        for _ in 0..<2 { await editor.tick(wallMs: 100) }
        #expect(editor.current.nodes.map(\.kind) == saved.nodes.map(\.kind) && modes("LAPTOP1") == ["wlan0 dhcp"])
        #expect(airLinks(editor.snapshot.nodes).count == 3)
    }
}
