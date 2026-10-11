import PacEngine
import Testing
@testable import PacKit

@MainActor
@Suite struct HomeDevicesEditorTests {
    let editor = Editor(client: Simulation())

    private func node(_ name: String) -> NodeView { editor.snapshot.nodes.first { $0.name == name }! }

    /// Spec M12 §2–§5: each kind with its defaults in one undo step, saved and reopened the same.
    @Test func homeDevicesArriveWithTheirDefaultsInOneStep() async throws {
        let kinds: [DeviceKind] = [.modem, .nas, .console, .smartBulb, .thermostat, .smartSpeaker]
        for (i, kind) in kinds.enumerated() { await editor.addDevice(kind, at: Pos(x: Double(i) * 100, y: 0)) }
        #expect(editor.snapshot.nodes.map(\.name) == ["MODEM1", "NAS1", "CONSOLE1", "LAMP1", "THERM1", "SPK1"])
        let (modem, nas, console) = (node("MODEM1"), node("NAS1"), node("CONSOLE1"))
        #expect(modem.ifaces.map(\.name) == ["dsl0", "eth0"] && modem.ifaces.allSatisfy { $0.cidr == nil } && !modem.sink)
        #expect(nas.sink && nas.ifaces.map(\.name) == ["eth0"] && nas.ifaces[0].mode == .dhcp)
        #expect(!console.sink && console.ifaces.map(\.name) == ["eth0"] && console.ifaces[0].mode == .dhcp && console.station == nil)
        for name in ["LAMP1", "THERM1", "SPK1"] {
            #expect(node(name).ifaces.map(\.name) == ["wlan0"] && node(name).ifaces[0].mode == .dhcp && node(name).station?.config.ssid == "pac-track")
        }
        let saved = editor.current
        #expect(try ProjectFile.decode(try ProjectFile.encode(saved)) == saved)
        await editor.undo()
        #expect(editor.snapshot.nodes.count == 5) // the speaker with its network and mode
        for _ in 0..<5 { await editor.undo() }
        #expect(editor.snapshot.nodes.isEmpty)
        let opened = await editor.load(saved)
        #expect(opened && editor.snapshot.nodes.map(\.kind) == kinds && editor.current == saved)
    }

    /// Spec M12 §2: dsl0 faces a Cloud/ISP and eth0 anything else, whichever is cabled first; when that port is taken, the other one.
    @Test func aModemFacesTheCloudWithDsl0InEitherOrder() async {
        for kind: DeviceKind in [.cloud, .router, .modem, .modem, .router] { await editor.addDevice(kind, at: Pos(x: 0, y: 0)) }
        await editor.connect(node("R1").id, node("MODEM1").id) // the router first
        await editor.connect(node("MODEM1").id, node("ISP1").id)
        await editor.connect(node("ISP1").id, node("MODEM2").id) // the cloud first
        await editor.connect(node("MODEM2").id, node("R1").id)
        await editor.connect(node("R2").id, node("MODEM1").id)
        #expect(editor.error == EditorError(key: "connect", message: "MODEM1 has no free port"))
        // Between two routers: eth0, then the line.
        await editor.addDevice(.modem, at: Pos(x: 0, y: 0))
        await editor.connect(node("R2").id, node("MODEM3").id)
        await editor.connect(node("MODEM3").id, node("R1").id)
        let ends = editor.snapshot.links.map { link in [link.a, link.b].map { "\(node(at: $0.node)) \($0.iface)" }.sorted() }
        #expect(ends == [["MODEM1 eth0", "R1 Gi0/0"], ["ISP1 Gi0/0", "MODEM1 dsl0"], ["ISP1 Gi0/1", "MODEM2 dsl0"], ["MODEM2 eth0", "R1 Gi0/1"],
                         ["MODEM3 eth0", "R2 Gi0/0"], ["MODEM3 dsl0", "R1 Gi0/2"]])
        // The line shows its sync rates on the canvas, a slower cable its own; an Ethernet cable is unchanged.
        let links = editor.snapshot.links
        #expect(links.map { cableRate($0, in: editor.snapshot.nodes) } == ["1 Gb/s", "100/20 Mb/s", "100/20 Mb/s", "1 Gb/s", "1 Gb/s", "100/20 Mb/s"])
        await editor.edit(.updateLink(id: links[1].id, options: LinkOptions(bandwidthBps: 10e6)))
        #expect(cableRate(editor.snapshot.links[1], in: editor.snapshot.nodes) == "10/10 Mb/s")
        #expect(syncLabel(VDSL2_SYNC) == "100/20 Mb/s")
    }

    /// Review M12: line to line both modems send upstream, 20 Mb/s each way; copies keep the sink, the network, the card and DHCP.
    @Test func aLineBetweenTwoModemsAndCopiesOfHomeDevices() async {
        for kind: DeviceKind in [.modem, .modem, .nas, .smartBulb, .console] { await editor.addDevice(kind, at: Pos(x: 0, y: 0)) }
        await editor.edit(.connect(id: "l", a: IfaceRef(node: node("MODEM1").id, iface: "dsl0"), b: IfaceRef(node: node("MODEM2").id, iface: "dsl0")))
        #expect(cableRate(editor.snapshot.links[0], in: editor.snapshot.nodes) == "20/20 Mb/s")
        await editor.setNic(node("CONSOLE1").id, wifi: true)
        await editor.duplicate(["NAS1", "LAMP1", "CONSOLE1"].map { node($0).id })
        let (nas, lamp, console) = (node("NAS2"), node("LAMP2"), node("CONSOLE2"))
        #expect(nas.sink && nas.ifaces[0].mode == .dhcp && lamp.station?.config.ssid == "pac-track" && lamp.ifaces[0].mode == .dhcp)
        #expect(console.ifaces.map(\.name) == ["wlan0"] && console.ifaces[0].mode == .dhcp)
    }

    private func node(at id: String) -> String { editor.snapshot.nodes.first { $0.id == id }!.name }

    /// Spec M12 §1: ISP1 — MODEM1 — R1 (NAT, DHCP) — SW1 with NAS1, CONSOLE1 and AP1; the IoT devices on AP1; nothing typed on them.
    @Test func theHomeLabWorksAsDropped() async {
        for kind: DeviceKind in [.cloud, .modem, .router, .switch, .nas, .console, .accessPoint, .smartBulb, .thermostat, .smartSpeaker] {
            await editor.addDevice(kind, at: Pos(x: 0, y: 0))
        }
        await editor.connect(node("ISP1").id, node("MODEM1").id)
        await editor.connect(node("MODEM1").id, node("R1").id) // R1 Gi0/0
        for name in ["R1", "NAS1", "CONSOLE1", "AP1"] { await editor.connect(node("SW1").id, node(name).id) } // R1 Gi0/1
        let r1 = node("R1").id
        await editor.edit([.setIp(node: r1, iface: "Gi0/0", cidr: "203.0.113.2/24"), .setIp(node: r1, iface: "Gi0/1", cidr: "192.168.1.1/24"),
                           .addRoute(node: r1, cidr: "0.0.0.0/0", nextHop: "203.0.113.1"),
                           .setNat(node: r1, config: NatConfig(inside: ["Gi0/1"], outside: "Gi0/0")),
                           .setDhcpServer(node: r1, config: DhcpConfig(start: "192.168.1.100", end: "192.168.1.199", gateway: "192.168.1.1", dns: "8.8.8.8"))])
        #expect(editor.error == nil)
        for _ in 0..<610 { await editor.tick(wallMs: 100) }
        let hosts = ["NAS1", "CONSOLE1", "LAMP1", "THERM1", "SPK1"]
        let ips = hosts.compactMap { node($0).ifaces[0].cidr }
        #expect(Set(ips).count == 5 && ips.allSatisfy { $0.hasPrefix("192.168.1.1") && $0.hasSuffix("/24") })
        let nasIp = String(node("NAS1").ifaces[0].cidr?.split(separator: "/").first ?? "")
        await editor.startTraffic(node("CONSOLE1").id, target: nasIp, kind: .tcp, amount: "100000", seconds: "")
        await editor.run(.ping(node: node("CONSOLE1").id, target: "www.example.com"))
        for _ in 0..<60 { await editor.tick(wallMs: 100) }
        #expect(editor.snapshot.apps.first?.lines.last == "iperf Done.")
        #expect(editor.snapshot.apps.last?.lines.contains("4 packets transmitted, 4 received, 0% packet loss") == true)
    }
}
