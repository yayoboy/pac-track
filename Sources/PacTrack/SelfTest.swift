import AppKit
import PacEngine
import PacKit
import SwiftUI

/// `PacTrack --selftest out.png`: drives the real Editor + Simulation, renders the window offscreen, exits 0/1.
@MainActor
enum SelfTest {
    static func run(output: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let failures = await scenario(output: output)
            print(failures.isEmpty ? "SELFTEST OK" : "SELFTEST FAIL: " + failures.joined(separator: "; "))
            exit(failures.isEmpty ? 0 : 1)
        }
        app.run()
        exit(1)
    }

    private static func scenario(output: String) async -> [String] {
        var failures: [String] = []
        let editor = Editor(client: Simulation())
        for _ in 0..<5 { await editor.tick(wallMs: 100) }
        if editor.snapshot.timeNs != 500_000_000 { failures.append("clock at \(editor.snapshot.timeNs) ns, expected 500 ms") }

        await editor.addDevice(.switch, at: Pos(x: 560, y: 140))
        await editor.addDevice(.pc, at: Pos(x: 380, y: 340))
        await editor.addDevice(.pc, at: Pos(x: 740, y: 340))
        let id = { (name: String) in editor.snapshot.nodes.first { $0.name == name }?.id ?? "" }
        await editor.connect(id("SW1"), id("PC1"))
        await editor.connect(id("SW1"), id("PC2"))
        if editor.snapshot.links.count != 2 { failures.append("expected 2 cables, got \(editor.snapshot.links.count)") }
        await editor.edit(.setIp(node: id("PC1"), iface: "eth0", cidr: "10.0.0.1/24"))
        await editor.edit(.setIp(node: id("PC2"), iface: "eth0", cidr: "10.0.0.2/24"))
        await converge(editor)
        await editor.run(.ping(node: id("PC1"), target: "10.0.0.2"))
        for _ in 0..<60 { await editor.tick(wallMs: 100) }
        let lines = editor.snapshot.apps.first?.lines ?? []
        if !lines.contains("4 packets transmitted, 4 received, 0% packet loss") { failures.append("ping output: \(lines)") }
        editor.select(.node(id("PC1")))
        let targets = NodeMenu.targets(for: id("PC1"), in: editor.snapshot.nodes).map(\.name)
        if targets != ["PC2"] { failures.append("ping menu targets \(targets), expected [PC2]") }
        await editor.connect(id("PC1"), id("PC2")) // both ports taken: the error must be visible without opening a tab
        if editor.error?.key != "connect" { failures.append("no connect error, got \(String(describing: editor.error))") }
        // M2b: Simulation mode, step, events, PDU, flights
        await editor.run(.setMode(.simulation))
        if editor.snapshot.running { failures.append("simulation mode must stop the clock") }
        let paused = editor.snapshot.version
        await editor.tick(wallMs: 100)
        if editor.snapshot.version != paused { failures.append("a paused tick bumped the snapshot version") }
        await editor.run(.ping(node: id("PC1"), target: "10.0.0.2"))
        await editor.step()
        if editor.events.last.map({ "\($0.kind.rawValue) \($0.proto.rawValue)" }) != "tx icmp" {
            failures.append("step: last event \(String(describing: editor.events.last))")
        }
        if editor.pdu?.map(\.title) != ["Ethernet II", "IPv4", "ICMP"] { failures.append("PDU \(String(describing: editor.pdu))") }
        if editor.flights.isEmpty { failures.append("no packet animated after a step") }
        failures += await loopScenario()
        // M2b: link properties and faults, power, duplicate, palette search
        let cable = editor.snapshot.links[0].id
        await editor.setLink(cable, .bandwidth, "100")
        await editor.setLink(cable, .delay, "veloce")
        if editor.error?.key != "link:\(cable):delay" { failures.append("link field error: \(String(describing: editor.error))") }
        await editor.edit(.setLinkUp(id: editor.snapshot.links[1].id, up: false))
        await editor.duplicate([id("PC2")])
        await editor.edit(.setPower(id: id("PC3"), on: false))
        if editor.snapshot.nodes.first(where: { $0.name == "PC3" })?.powered != false { failures.append("PC3 should be off") }
        if PaletteView.groups(matching: "rou").map(\.1) != [[PaletteItem(kind: .router)]] { failures.append("palette search") }
        if PaletteView.groups(matching: "stamp").map(\.1) != [[PaletteItem(kind: .printer)]] { failures.append("palette search: printer") }
        if PaletteView.groups(matching: "server").map(\.0) != ["Server"] || PaletteView.groups(matching: "server").first?.1.count != 3 {
            failures.append("palette search: servers")
        }
        if PaletteItem(payload: "server-dhcp") != PaletteItem(kind: .server, preset: .dhcp) || PaletteItem(payload: "tv")?.label != "Smart TV" {
            failures.append("palette payloads")
        }
        let wireless = [PaletteItem(kind: .accessPoint), PaletteItem(kind: .tablet), PaletteItem(kind: .smartphone)]
        if PaletteView.groups(matching: "wireless").map(\.1) != [wireless] || PaletteView.groups(matching: "wifi").map(\.1) != [wireless]
            || PaletteView.groups(matching: "ap").last?.1 != wireless || PaletteView.groups(matching: "phone").map(\.1) != [[PaletteItem(kind: .smartphone)]] {
            failures.append("palette search: wireless")
        }
        if PaletteView.groups(matching: "").map(\.0) != ["Rete", "Host", "Server", "Wireless", "Casa"] { failures.append("palette sections") }
        // M12 (spec M12 §6): the Casa section by its name and aliases, the modem by its line, the smart devices across sections.
        let home = [DeviceKind.modem, .nas, .console, .smartBulb, .thermostat, .smartSpeaker].map { PaletteItem(kind: $0) }
        if PaletteView.groups(matching: "casa").map(\.1) != [home] || PaletteView.groups(matching: "iot").map(\.1) != [home]
            || PaletteView.groups(matching: "dsl").map(\.1) != [[PaletteItem(kind: .modem)]]
            || PaletteView.groups(matching: "smart").map(\.1) != [[PaletteItem(kind: .tv)], [PaletteItem(kind: .smartphone)], [PaletteItem(kind: .smartBulb), PaletteItem(kind: .smartSpeaker)]] {
            failures.append("palette search: home devices")
        }
        if !PaletteView.groups(matching: "zzz").isEmpty { failures.append("palette search should find nothing") }
        editor.select(.link(cable))
        // Pinch anchored at the pointer: the world point under the fingers stays put.
        let o = CanvasView.zoomed(offset: CGSize(width: 10, height: 20), zoom: 1, to: 2, anchor: CGPoint(x: 110, y: 120))
        if o != CGSize(width: -90, height: -80) { failures.append("anchored zoom offset \(o)") }
        if !render(editor, to: output) { failures.append("could not write \(output)") }
        failures += await servicesScenario(output: output)
        failures += await trafficScenario(output: output)
        failures += await natScenario(output: output)
        failures += await selectionScenario(output: output)
        failures += await toolsScenario(output: output)
        failures += await portsScenario(output: output)
        failures += await cloudScenario(output: output)
        failures += await pingScenario(output: output)
        failures += await exportScenario(output: output)
        failures += await vlanScenario(output: output)
        failures += await stickScenario(output: output)
        failures += await stpScenario(output: output)
        failures += await ripScenario(output: output)
        failures += await ospfScenario(output: output)
        failures += await ipv6Scenario(output: output)
        failures += await ipv6ServicesScenario(output: output)
        failures += await m10Scenario(output: output)
        failures += await m11aScenario(output: output)
        failures += await m12Scenario(output: output)
        return failures
    }

    /// M3: SRV1 runs DHCP and DNS; PC1 and PC2 in DHCP mode get addresses and resolve srv1.lab.
    private static func servicesScenario(output: String) async -> [String] {
        var failures: [String] = []
        let editor = Editor(client: Simulation())
        await editor.addDevice(.switch, at: Pos(x: 560, y: 140))
        await editor.addDevice(.server, at: Pos(x: 560, y: 360))
        await editor.addDevice(.pc, at: Pos(x: 360, y: 300))
        await editor.addDevice(.pc, at: Pos(x: 760, y: 300))
        let id = { (name: String) in editor.snapshot.nodes.first { $0.name == name }?.id ?? "" }
        for name in ["SRV1", "PC1", "PC2"] { await editor.connect(id("SW1"), id(name)) }
        await converge(editor)
        await editor.edit(.setIp(node: id("SRV1"), iface: "eth0", cidr: "10.0.0.2/24"))
        await editor.enableDns(id("SRV1"), true)
        await editor.addDnsRecord(id("SRV1"), name: "srv1.lab", ip: "10.0.0.2", ttl: "")
        await editor.enableDhcp(id("SRV1"), true)
        let config = editor.snapshot.nodes.first { $0.name == "SRV1" }?.dhcpServer
        if config != DhcpConfig(start: "10.0.0.100", end: "10.0.0.199", dns: "10.0.0.2") { failures.append("suggested pool \(String(describing: config))") }
        await editor.setDhcp(id("SRV1"), .start, "10.0.1.5")
        if editor.error?.key != "dhcp:\(id("SRV1")):start" { failures.append("pool error: \(String(describing: editor.error))") }
        for name in ["PC1", "PC2"] { await editor.edit(.setIfaceMode(node: id(name), iface: "eth0", mode: .dhcp)) }
        for _ in 0..<10 { await editor.tick(wallMs: 100) }
        let ips = ["PC1", "PC2"].map { name in editor.snapshot.nodes.first { $0.name == name }?.ifaces.first?.cidr }
        if ips != ["10.0.0.100/24", "10.0.0.101/24"] { failures.append("DHCP addresses \(ips)") }
        await editor.run(.nslookup(node: id("PC1"), name: "srv1.lab"))
        await editor.run(.ping(node: id("PC2"), target: "srv1.lab"))
        for _ in 0..<50 { await editor.tick(wallMs: 100) }
        let lines = editor.snapshot.apps.flatMap(\.lines)
        if !lines.contains("Address: 10.0.0.2") { failures.append("nslookup output \(lines)") }
        if !lines.contains("4 packets transmitted, 4 received, 0% packet loss") { failures.append("ping by name \(lines)") }
        let protos = Set(editor.events.map(\.proto))
        if !protos.isSuperset(of: [.dhcp, .dns]) { failures.append("no DHCP/DNS events: \(protos)") }
        if let offer = editor.events.first(where: { $0.proto == .dhcp && $0.kind == .tx && $0.info.contains("Offer") }) {
            await editor.selectEvent(offer.id)
            if editor.pdu?.last?.title != "DHCP" { failures.append("Offer PDU \(String(describing: editor.pdu?.map(\.title)))") }
        } else {
            failures.append("no DHCP Offer in the event list")
        }
        editor.select(.node(id("SRV1")))
        editor.inspectorTab = .services
        if !render(editor, to: sibling(output, "m3")) { failures.append("could not write the M3 services image") }
        editor.select(.node(id("PC1")))
        editor.inspectorTab = .interfaces
        if !render(editor, to: sibling(output, "m3-pc")) { failures.append("could not write the M3 host image") }
        return failures
    }

    /// M4: SRV1 runs the sink behind a 10 Mb/s cable; PC1 sends 1 MB over TCP and PC2 1 Mb/s of UDP for 2 s.
    private static func trafficScenario(output: String) async -> [String] {
        var failures: [String] = []
        let editor = Editor(client: Simulation())
        await editor.addDevice(.switch, at: Pos(x: 560, y: 140))
        await editor.addDevice(.server, at: Pos(x: 560, y: 360))
        await editor.addDevice(.pc, at: Pos(x: 360, y: 300))
        await editor.addDevice(.pc, at: Pos(x: 760, y: 300))
        let id = { (name: String) in editor.snapshot.nodes.first { $0.name == name }?.id ?? "" }
        for name in ["SRV1", "PC1", "PC2"] { await editor.connect(id("SW1"), id(name)) }
        await converge(editor)
        for (name, cidr) in [("SRV1", "10.0.0.2/24"), ("PC1", "10.0.0.10/24"), ("PC2", "10.0.0.11/24")] {
            await editor.edit(.setIp(node: id(name), iface: "eth0", cidr: cidr))
        }
        let cable = editor.snapshot.links[0].id // a = SW1, b = SRV1
        await editor.setLink(cable, .bandwidth, "10")
        await editor.edit(.setSink(node: id("SRV1"), on: true))
        await editor.startTraffic(id("PC1"), target: "10.0.0.2", kind: .tcp, amount: "1000000", seconds: "")
        await editor.startTraffic(id("PC2"), target: "10.0.0.2", kind: .udp, amount: "1", seconds: "2")
        for _ in 0..<40 { await editor.tick(wallMs: 100) }
        let apps = editor.snapshot.apps
        if apps.map({ $0.lines.last }) != ["iperf Done.", "iperf Done."] { failures.append("traffic output \(apps.map(\.lines))") }
        if !(apps.last?.lines.contains { $0.hasSuffix("0/171 (0%)") } ?? false) { failures.append("UDP report \(apps.last?.lines ?? [])") }
        if apps.contains(where: { $0.samples.isEmpty }) { failures.append("a flow has no metrics") }
        let peak = editor.snapshot.linkSamples[cable]?.map(\.ab.utilization).max() ?? 0
        if peak < 0.9 { failures.append("SW1 → SRV1 peak utilisation \(peak)") }
        if editor.snapshot.nodes.first(where: { $0.name == "SRV1" })?.tcp.first?.state != "LISTEN" { failures.append("SRV1 TCP table") }
        editor.select(.link(cable))
        editor.bottomTab = .metrics
        if !render(editor, to: sibling(output, "m4")) { failures.append("could not write the M4 metrics image") }
        editor.select(.node(id("PC1")))
        editor.inspectorTab = .app
        editor.bottomTab = .output
        if !render(editor, to: sibling(output, "m4-app")) { failures.append("could not write the M4 app image") }
        return failures
    }

    /// M5: PC1 behind R1's NAT (inside Gi0/0, outside Gi0/1) reaches SRV1, which knows no route back; R1's firewall (default deny,
    /// anything entering Gi0/0 allowed) lets the replies through but not SRV1's own ping.
    private static func natScenario(output: String) async -> [String] {
        var failures: [String] = []
        let editor = Editor(client: Simulation())
        await editor.addDevice(.pc, at: Pos(x: 360, y: 300))
        await editor.addDevice(.router, at: Pos(x: 560, y: 300))
        await editor.addDevice(.server, at: Pos(x: 760, y: 300))
        let id = { (name: String) in editor.snapshot.nodes.first { $0.name == name }?.id ?? "" }
        await editor.connect(id("PC1"), id("R1")) // PC1 eth0 — R1 Gi0/0
        await editor.connect(id("R1"), id("SRV1")) // R1 Gi0/1 — SRV1 eth0
        for (name, iface, cidr) in [("PC1", "eth0", "192.168.1.10/24"), ("R1", "Gi0/0", "192.168.1.1/24"), ("R1", "Gi0/1", "203.0.113.1/24"),
                                    ("SRV1", "eth0", "203.0.113.10/24")] {
            await editor.edit(.setIp(node: id(name), iface: iface, cidr: cidr))
        }
        await editor.edit(.addRoute(node: id("PC1"), cidr: "0.0.0.0/0", nextHop: "192.168.1.1"))
        await editor.setNatRole(id("R1"), iface: "Gi0/0", .inside)
        await editor.setNatRole(id("R1"), iface: "Gi0/1", .outside)
        await editor.edit(.setFirewall(node: id("R1"), config: FirewallConfig(defaultAction: .deny)))
        await editor.addFirewallRule(id("R1"), FirewallRule(iface: "Gi0/0", direction: .inbound, action: .allow, proto: .any, src: "", dst: ""), port: "")
        await editor.edit(.setSink(node: id("SRV1"), on: true))
        await editor.run(.ping(node: id("PC1"), target: "203.0.113.10"))
        await editor.startTraffic(id("PC1"), target: "203.0.113.10", kind: .tcp, amount: "100000", seconds: "")
        await editor.run(.ping(node: id("SRV1"), target: "203.0.113.1"))
        for _ in 0..<60 { await editor.tick(wallMs: 100) }
        let apps = editor.snapshot.apps
        if !(apps.first?.lines.contains("4 packets transmitted, 4 received, 0% packet loss") ?? false) { failures.append("NAT ping \(apps.first?.lines ?? [])") }
        if apps.count != 3 || apps[1].lines.last != "iperf Done." { failures.append("NAT traffic \(apps.map(\.lines))") }
        if apps.count == 3, apps[2].lines.contains(where: { $0.contains("bytes from") }) { failures.append("SRV1 pinged R1 through the firewall") }
        let r1 = editor.snapshot.nodes.first { $0.name == "R1" }
        if Set(r1?.natTable.map(\.proto) ?? []) != ["icmp", "tcp"] { failures.append("NAT table \(r1?.natTable ?? [])") }
        if !editor.events.contains(where: { $0.kind == .tx && $0.node == id("R1") && $0.info.hasPrefix("203.0.113.1 → 203.0.113.10 Echo request") }) {
            failures.append("no translated echo request leaving R1")
        }
        if !editor.events.contains(where: { $0.reason == "firewall-default" && $0.node == id("R1") }) { failures.append("no firewall drop") }
        editor.select(.node(id("R1")))
        editor.inspectorTab = .services
        if !render(editor, to: sibling(output, "m5")) { failures.append("could not write the M5 services image") }
        editor.inspectorTab = .tables
        if !render(editor, to: sibling(output, "m5-tables")) { failures.append("could not write the M5 tables image") }
        return failures
    }

    /// M6: three devices, the first and the last picked together; Seleziona tutto takes all three.
    private static func selectionScenario(output: String) async -> [String] {
        var failures: [String] = []
        let editor = Editor(client: Simulation())
        for x in [420.0, 560, 700] { await editor.addDevice(.pc, at: Pos(x: x, y: 300)) }
        let ids = editor.snapshot.nodes.map(\.id)
        editor.select(.node(ids[0]))
        editor.toggle(ids[2])
        if editor.selection != .nodes([ids[0], ids[2]]) { failures.append("shift-click selection \(String(describing: editor.selection))") }
        if !render(editor, to: sibling(output, "m6-selection")) { failures.append("could not write the M6 selection image") }
        editor.selectAll()
        if editor.selectedNodes != ids { failures.append("select all \(editor.selectedNodes)") }
        return failures
    }

    /// M6: a fibre cable drawn with the Collega tool, back to Sposta (the palette still marks Fibra, which the port dot also draws),
    /// the grid hidden, the minimap in the corner faded around the PC that sits under it.
    private static func toolsScenario(output: String) async -> [String] {
        var failures: [String] = []
        let editor = Editor(client: Simulation())
        await editor.addDevice(.switch, at: Pos(x: 420, y: 200))
        await editor.addDevice(.server, at: Pos(x: 700, y: 360))
        await editor.addDevice(.pc, at: Pos(x: 840, y: 380))
        editor.tool = .connect
        editor.cable = .fiber
        let ids = editor.snapshot.nodes.map(\.id)
        await editor.connect(ids[0], ids[1])
        if editor.snapshot.links.first?.options.bandwidthBps != 10e9 { failures.append("fibre cable \(String(describing: editor.snapshot.links.first))") }
        editor.tool = .move
        editor.grid = false
        if !render(editor, to: sibling(output, "m6-tools")) { failures.append("could not write the M6 tools image") }
        return failures
    }

    /// M6: a 24-port switch in its Porte tab.
    private static func portsScenario(output: String) async -> [String] {
        var failures: [String] = []
        let editor = Editor(client: Simulation())
        await editor.addDevice(.switch, at: Pos(x: 560, y: 300))
        let sw = editor.snapshot.nodes[0].id
        await editor.edit(.setPorts(id: sw, count: 24), key: "ports:\(sw)")
        if editor.snapshot.nodes[0].ifaces.last?.name != "Gi0/24" { failures.append("switch ports \(editor.snapshot.nodes[0].ifaces.count)") }
        editor.select(.node(sw))
        if !render(editor, to: sibling(output, "m6-ports")) { failures.append("could not write the M6 ports image") }
        return failures
    }

    /// M6: PC1 behind R1's NAT reaches ISP1's Internet: ping by name through its public DNS.
    private static func cloudScenario(output: String) async -> [String] {
        var failures: [String] = []
        let editor = Editor(client: Simulation())
        await editor.addDevice(.pc, at: Pos(x: 360, y: 300))
        await editor.addDevice(.router, at: Pos(x: 560, y: 300))
        await editor.addDevice(.cloud, at: Pos(x: 760, y: 300))
        let id = { (name: String) in editor.snapshot.nodes.first { $0.name == name }?.id ?? "" }
        await editor.connect(id("PC1"), id("R1")) // PC1 eth0 — R1 Gi0/0
        await editor.connect(id("R1"), id("ISP1")) // R1 Gi0/1 — ISP1 Gi0/0 (203.0.113.1/24, preset)
        for (name, iface, cidr) in [("PC1", "eth0", "192.168.1.10/24"), ("R1", "Gi0/0", "192.168.1.1/24"), ("R1", "Gi0/1", "203.0.113.2/24")] {
            await editor.edit(.setIp(node: id(name), iface: iface, cidr: cidr))
        }
        await editor.edit(.addRoute(node: id("PC1"), cidr: "0.0.0.0/0", nextHop: "192.168.1.1"))
        await editor.edit(.addRoute(node: id("R1"), cidr: "0.0.0.0/0", nextHop: "203.0.113.1"))
        await editor.setNatRole(id("R1"), iface: "Gi0/0", .inside)
        await editor.setNatRole(id("R1"), iface: "Gi0/1", .outside)
        await editor.edit(.setNameServer(node: id("PC1"), ip: "8.8.8.8"))
        await editor.run(.ping(node: id("PC1"), target: "www.example.com"))
        for _ in 0..<60 { await editor.tick(wallMs: 100) }
        let lines = editor.snapshot.apps.first?.lines ?? []
        if lines.first?.hasPrefix("PING www.example.com (198.51.100.10)") != true || !lines.contains("4 packets transmitted, 4 received, 0% packet loss") {
            failures.append("ping to the Internet \(lines)")
        }
        editor.select(.node(id("ISP1")))
        editor.inspectorTab = .services
        editor.bottomTab = .output
        if !render(editor, to: sibling(output, "m6-cloud")) { failures.append("could not write the M6 cloud image") }
        return failures
    }

    /// M6: ping with count, interval, size and TTL typed in the App tab.
    private static func pingScenario(output: String) async -> [String] {
        var failures: [String] = []
        let editor = Editor(client: Simulation())
        await editor.addDevice(.pc, at: Pos(x: 460, y: 300))
        await editor.addDevice(.pc, at: Pos(x: 660, y: 300))
        let ids = editor.snapshot.nodes.map(\.id)
        await editor.connect(ids[0], ids[1])
        await editor.edit(.setIp(node: ids[0], iface: "eth0", cidr: "10.0.0.1/24"))
        await editor.edit(.setIp(node: ids[1], iface: "eth0", cidr: "10.0.0.2/24"))
        await editor.ping(ids[0], target: "10.0.0.2", count: "3", interval: "0.5", size: "1472", ttl: "1")
        for _ in 0..<20 { await editor.tick(wallMs: 100) }
        let lines = editor.snapshot.apps.first?.lines ?? []
        if lines.first != "PING 10.0.0.2 (10.0.0.2) 1472(1500) bytes of data." || !lines.contains("3 packets transmitted, 3 received, 0% packet loss") {
            failures.append("ping options \(lines)")
        }
        editor.select(.node(ids[0]))
        editor.inspectorTab = .app
        editor.bottomTab = .output
        if !render(editor, to: sibling(output, "m6-ping")) { failures.append("could not write the M6 ping image") }
        return failures
    }

    /// M6: File ▸ Esporta immagine… draws every device at 2× with a 40 pt margin, also left of the origin.
    private static func exportScenario(output: String) async -> [String] {
        let editor = Editor(client: Simulation())
        await editor.addDevice(.switch, at: Pos(x: 140, y: 70))
        await editor.addDevice(.pc, at: Pos(x: 0, y: 210))
        await editor.addDevice(.pc, at: Pos(x: 280, y: 210))
        let ids = editor.snapshot.nodes.map(\.id)
        await editor.connect(ids[0], ids[1])
        await editor.connect(ids[0], ids[2])
        guard let data = ExportImage.png(editor), let rep = NSBitmapImageRep(data: data) else { return ["export produced no PNG"] }
        // Boxes span x −52…332 and y 47…233; with the margin 464 × 266 pt, at 2×.
        var failures = rep.pixelsWide == 928 && rep.pixelsHigh == 532 ? [] : ["export size \(rep.pixelsWide)×\(rep.pixelsHigh)"]
        if (try? data.write(to: URL(fileURLWithPath: sibling(output, "m6-export")))) == nil { failures.append("could not write the export") }
        return failures
    }

    /// M7a: VLAN 10 on two switches joined by a trunk, PC3 in VLAN 20 on the same subnet; SW1's Porte tab with a field error, then its MAC table.
    private static func vlanScenario(output: String) async -> [String] {
        var failures: [String] = []
        let editor = Editor(client: Simulation())
        await editor.addDevice(.switch, at: Pos(x: 460, y: 160))
        await editor.addDevice(.switch, at: Pos(x: 760, y: 160))
        await editor.addDevice(.pc, at: Pos(x: 460, y: 360))
        await editor.addDevice(.pc, at: Pos(x: 680, y: 360))
        await editor.addDevice(.pc, at: Pos(x: 860, y: 360))
        let id = { (name: String) in editor.snapshot.nodes.first { $0.name == name }?.id ?? "" }
        await editor.connect(id("SW1"), id("PC1")) // SW1 Gi0/1
        await editor.connect(id("SW1"), id("SW2")) // SW1 Gi0/2 — SW2 Gi0/1
        await editor.connect(id("SW2"), id("PC2")) // SW2 Gi0/2
        await editor.connect(id("SW2"), id("PC3")) // SW2 Gi0/3
        for (sw, port) in [("SW1", "Gi0/2"), ("SW2", "Gi0/1")] {
            await editor.edit(.setSwitchport(node: id(sw), iface: port, config: PortConfig(mode: .trunk)))
        }
        for (sw, port, vlan) in [("SW1", "Gi0/1", "10"), ("SW2", "Gi0/2", "10"), ("SW2", "Gi0/3", "20")] {
            await editor.setPort(id(sw), iface: port, .vlan, vlan)
        }
        await converge(editor)
        for (name, cidr) in [("PC1", "10.0.0.1/24"), ("PC2", "10.0.0.2/24"), ("PC3", "10.0.0.3/24")] {
            await editor.edit(.setIp(node: id(name), iface: "eth0", cidr: cidr))
        }
        await editor.run(.ping(node: id("PC1"), target: "10.0.0.2"))
        await editor.run(.ping(node: id("PC1"), target: "10.0.0.3"))
        for _ in 0..<60 { await editor.tick(wallMs: 100) }
        let apps = editor.snapshot.apps
        if !(apps.first?.lines.contains("4 packets transmitted, 4 received, 0% packet loss") ?? false) { failures.append("same-VLAN ping \(apps.first?.lines ?? [])") }
        if apps.count != 2 || apps[1].lines.contains(where: { $0.contains("bytes from") }) { failures.append("PC3 (VLAN 20) answered: \(apps.map(\.lines))") }
        let sw2 = editor.snapshot.nodes.first { $0.name == "SW2" }
        if !(sw2?.mac.contains { $0.vlan == 10 && $0.iface == "Gi0/1" } ?? false) { failures.append("SW2 MAC table \(sw2?.mac ?? [])") }
        if !isTrunk(editor.snapshot.links[1], in: editor.snapshot.nodes) { failures.append("SW1–SW2 is not a trunk") }
        await editor.setPort(id("SW1"), iface: "Gi0/2", .allowed, "10,5000")
        if editor.error?.key != "port:\(id("SW1")):Gi0/2:allowed" { failures.append("port field error \(String(describing: editor.error))") }
        editor.select(.node(id("SW1")))
        if !render(editor, to: sibling(output, "m7a-ports")) { failures.append("could not write the M7a ports image") }
        editor.inspectorTab = .tables
        if !render(editor, to: sibling(output, "m7a-mac")) { failures.append("could not write the M7a MAC table image") }
        return failures
    }

    /// M7a: router-on-a-stick — PC1 (VLAN 10) pings PC2 (VLAN 20) through R1's subinterfaces on SW1's trunk; R1's Interfacce tab beside
    /// the 802.1Q PDU of the echo request R1 forwards.
    private static func stickScenario(output: String) async -> [String] {
        var failures: [String] = []
        let editor = Editor(client: Simulation())
        await editor.addDevice(.router, at: Pos(x: 560, y: 120))
        await editor.addDevice(.switch, at: Pos(x: 560, y: 260))
        await editor.addDevice(.pc, at: Pos(x: 420, y: 400))
        await editor.addDevice(.pc, at: Pos(x: 700, y: 400))
        let id = { (name: String) in editor.snapshot.nodes.first { $0.name == name }?.id ?? "" }
        await editor.connect(id("R1"), id("SW1")) // R1 Gi0/0 — SW1 Gi0/1
        await editor.connect(id("SW1"), id("PC1")) // SW1 Gi0/2
        await editor.connect(id("SW1"), id("PC2")) // SW1 Gi0/3
        await editor.edit(.setSwitchport(node: id("SW1"), iface: "Gi0/1", config: PortConfig(mode: .trunk)))
        await editor.setPort(id("SW1"), iface: "Gi0/2", .vlan, "10")
        await editor.setPort(id("SW1"), iface: "Gi0/3", .vlan, "20")
        await converge(editor)
        await editor.addSubinterface(id("R1"), parent: "Gi0/0", vlan: "20", cidr: "10.0.20.1/24")
        await editor.addSubinterface(id("R1"), parent: "Gi0/0", vlan: "10", cidr: "10.0.10.1/24")
        for (name, cidr, gateway) in [("PC1", "10.0.10.10/24", "10.0.10.1"), ("PC2", "10.0.20.10/24", "10.0.20.1")] {
            await editor.edit(.setIp(node: id(name), iface: "eth0", cidr: cidr))
            await editor.edit(.addRoute(node: id(name), cidr: "0.0.0.0/0", nextHop: gateway))
        }
        await editor.run(.ping(node: id("PC1"), target: "10.0.20.10"))
        for _ in 0..<60 { await editor.tick(wallMs: 100) }
        let lines = editor.snapshot.apps.first?.lines ?? []
        if !lines.contains("4 packets transmitted, 4 received, 0% packet loss") || !lines.contains(where: { $0.contains("ttl=63") }) {
            failures.append("inter-VLAN ping \(lines)")
        }
        let names = editor.snapshot.nodes.first { $0.name == "R1" }?.ifaces.map(\.name) ?? []
        if names != ["Gi0/0", "Gi0/0.10", "Gi0/0.20", "Gi0/1", "Gi0/2", "Gi0/3"] { failures.append("R1 interfaces \(names)") }
        if let fwd = editor.events.first(where: { $0.kind == .tx && $0.node == id("R1") && $0.info.hasPrefix("10.0.10.10 → 10.0.20.10 Echo request") }) {
            await editor.selectEvent(fwd.id)
            if editor.pdu?.map(\.title) != ["Ethernet II", "802.1Q", "IPv4", "ICMP"] { failures.append("tagged PDU \(String(describing: editor.pdu?.map(\.title)))") }
        } else {
            failures.append("no echo request forwarded by R1")
        }
        editor.select(.node(id("R1")))
        editor.inspectorTab = .interfaces
        if !render(editor, to: sibling(output, "m7a-stick")) { failures.append("could not write the M7a router-on-a-stick image") }
        return failures
    }

    /// M7b: SW1 and SW2 cabled twice, PC1 on a PortFast port of SW1, PC2 on SW2. Once converged SW2 blocks its second cable (red dot)
    /// and the ping crosses; SW1's Porte tab with PortFast, SW2's Spanning Tree table and priorities, an STP PDU.
    private static func stpScenario(output: String) async -> [String] {
        var failures: [String] = []
        let editor = Editor(client: Simulation())
        await editor.addDevice(.switch, at: Pos(x: 460, y: 160))
        await editor.addDevice(.switch, at: Pos(x: 760, y: 160))
        await editor.addDevice(.pc, at: Pos(x: 460, y: 380))
        await editor.addDevice(.pc, at: Pos(x: 760, y: 380))
        let id = { (name: String) in editor.snapshot.nodes.first { $0.name == name }?.id ?? "" }
        await editor.connect(id("SW1"), id("SW2")) // Gi0/1 — Gi0/1
        await editor.connect(id("SW1"), id("SW2")) // Gi0/2 — Gi0/2
        await editor.connect(id("SW1"), id("PC1")) // SW1 Gi0/3
        await editor.connect(id("SW2"), id("PC2")) // SW2 Gi0/3
        await editor.edit(.setSwitchport(node: id("SW1"), iface: "Gi0/3", config: PortConfig(portfast: true)))
        for (name, cidr) in [("PC1", "10.0.0.1/24"), ("PC2", "10.0.0.2/24")] {
            await editor.edit(.setIp(node: id(name), iface: "eth0", cidr: cidr))
        }
        await converge(editor)
        await editor.run(.ping(node: id("PC1"), target: "10.0.0.2"))
        for _ in 0..<60 { await editor.tick(wallMs: 100) }
        let lines = editor.snapshot.apps.first?.lines ?? []
        if !lines.contains("4 packets transmitted, 4 received, 0% packet loss") { failures.append("ping across the tree \(lines)") }
        let tree = editor.snapshot.nodes.first { $0.name == "SW2" }?.stp.first?.ports.map { "\($0.iface) \($0.role.rawValue) \($0.state.rawValue)" }
        if tree != ["Gi0/1 root forwarding", "Gi0/2 blocked blocking", "Gi0/3 designated forwarding"] { failures.append("SW2 tree \(tree ?? [])") }
        if stpDot(IfaceRef(node: id("SW2"), iface: "Gi0/2"), in: editor.snapshot.nodes) != .blocking { failures.append("no red dot on SW2 Gi0/2") }
        if let bpdu = editor.events.last(where: { $0.proto == .stp && $0.kind == .tx && $0.node == id("SW1") }) {
            await editor.selectEvent(bpdu.id)
            if editor.pdu?.map(\.title) != ["IEEE 802.3 Ethernet", "LLC/SNAP", "STP"] { failures.append("BPDU PDU \(String(describing: editor.pdu?.map(\.title)))") }
        } else {
            failures.append("no BPDU sent by SW1")
        }
        editor.select(.node(id("SW1")))
        editor.inspectorTab = .ports
        if !render(editor, to: sibling(output, "m7b-ports")) { failures.append("could not write the M7b ports image") }
        editor.select(.node(id("SW2")))
        editor.inspectorTab = .tables
        if !render(editor, to: sibling(output, "m7b-stp")) { failures.append("could not write the M7b STP table image") }
        editor.inspectorTab = .services
        if !render(editor, to: sibling(output, "m7b-services")) { failures.append("could not write the M7b services image") }
        return failures
    }

    /// M8a: R1 and R2 cabled, PC1 on R1 and PC2 on R2, RIP on both with the PC side passive: R1 learns 192.168.2.0/24 [120/1]
    /// and the ping crosses with TTL 62; R1's Servizi (RIP section) and Tabelle (R route), a RIPv2 PDU.
    private static func ripScenario(output: String) async -> [String] {
        var failures: [String] = []
        let editor = Editor(client: Simulation())
        await editor.addDevice(.router, at: Pos(x: 460, y: 160))
        await editor.addDevice(.router, at: Pos(x: 760, y: 160))
        await editor.addDevice(.pc, at: Pos(x: 460, y: 380))
        await editor.addDevice(.pc, at: Pos(x: 760, y: 380))
        let id = { (name: String) in editor.snapshot.nodes.first { $0.name == name }?.id ?? "" }
        await editor.connect(id("R1"), id("PC1")) // R1 Gi0/0
        await editor.connect(id("R2"), id("PC2")) // R2 Gi0/0
        await editor.connect(id("R1"), id("R2")) // Gi0/1 — Gi0/1
        for (node, iface, cidr) in [("R1", "Gi0/0", "192.168.1.1/24"), ("R1", "Gi0/1", "10.0.12.1/30"),
                                    ("R2", "Gi0/0", "192.168.2.1/24"), ("R2", "Gi0/1", "10.0.12.2/30")] {
            await editor.edit(.setIp(node: id(node), iface: iface, cidr: cidr))
        }
        for (name, cidr, gateway) in [("PC1", "192.168.1.10/24", "192.168.1.1"), ("PC2", "192.168.2.10/24", "192.168.2.1")] {
            await editor.edit(.setIp(node: id(name), iface: "eth0", cidr: cidr))
            await editor.edit(.addRoute(node: id(name), cidr: "0.0.0.0/0", nextHop: gateway))
        }
        for router in ["R1", "R2"] {
            await editor.enableRip(id(router), true)
            await editor.setRipRole(id(router), iface: "Gi0/0", .passive)
        }
        for _ in 0..<20 { await editor.tick(wallMs: 100) }
        await editor.run(.ping(node: id("PC1"), target: "192.168.2.10"))
        for _ in 0..<60 { await editor.tick(wallMs: 100) }
        let lines = editor.snapshot.apps.first?.lines ?? []
        if !lines.contains("4 packets transmitted, 4 received, 0% packet loss") || !lines.contains(where: { $0.contains("ttl=62") }) {
            failures.append("ping over RIP \(lines)")
        }
        let routes = editor.snapshot.nodes.first { $0.name == "R1" }?.routes.map(routeColumns) ?? []
        if !routes.contains(["R", "192.168.2.0/24", "[120/1]", "10.0.12.2", "Gi0/1"]) { failures.append("R1 routes \(routes)") }
        if let update = editor.events.last(where: { $0.proto == .rip && $0.kind == .tx && $0.node == id("R1") }) {
            await editor.selectEvent(update.id)
            if editor.pdu?.map(\.title) != ["Ethernet II", "IPv4", "UDP", "RIPv2"] { failures.append("RIP PDU \(String(describing: editor.pdu?.map(\.title)))") }
        } else {
            failures.append("no RIP update sent by R1")
        }
        editor.select(.node(id("R1")))
        editor.inspectorTab = .services
        if !render(editor, to: sibling(output, "m8a-rip")) { failures.append("could not write the M8a RIP image") }
        editor.inspectorTab = .tables
        if !render(editor, to: sibling(output, "m8a-routes")) { failures.append("could not write the M8a routing table image") }
        return failures
    }

    /// M8b: R1 and R2 cabled (broadcast), PC1 on R1 and PC2 on R2, OSPF on both with the PC side passive. After the wait timer
    /// they are Full, at 45 s R1 has 192.168.2.0/24 [110/2] and the ping crosses; R1's Servizi (OSPF section) and Tabelle
    /// (neighbours, database, O route), a Hello PDU.
    private static func ospfScenario(output: String) async -> [String] {
        var failures: [String] = []
        let editor = Editor(client: Simulation())
        await editor.addDevice(.router, at: Pos(x: 460, y: 160))
        await editor.addDevice(.router, at: Pos(x: 760, y: 160))
        await editor.addDevice(.pc, at: Pos(x: 460, y: 380))
        await editor.addDevice(.pc, at: Pos(x: 760, y: 380))
        let id = { (name: String) in editor.snapshot.nodes.first { $0.name == name }?.id ?? "" }
        await editor.connect(id("R1"), id("PC1")) // R1 Gi0/0
        await editor.connect(id("R2"), id("PC2")) // R2 Gi0/0
        await editor.connect(id("R1"), id("R2")) // Gi0/1 — Gi0/1
        for (node, iface, cidr) in [("R1", "Gi0/0", "192.168.1.1/24"), ("R1", "Gi0/1", "10.0.12.1/30"),
                                    ("R2", "Gi0/0", "192.168.2.1/24"), ("R2", "Gi0/1", "10.0.12.2/30")] {
            await editor.edit(.setIp(node: id(node), iface: iface, cidr: cidr))
        }
        for (name, cidr, gateway) in [("PC1", "192.168.1.10/24", "192.168.1.1"), ("PC2", "192.168.2.10/24", "192.168.2.1")] {
            await editor.edit(.setIp(node: id(name), iface: "eth0", cidr: cidr))
            await editor.edit(.addRoute(node: id(name), cidr: "0.0.0.0/0", nextHop: gateway))
        }
        for router in ["R1", "R2"] {
            await editor.enableOspf(id(router), true)
            await editor.setOspfRole(id(router), iface: "Gi0/0", .passive)
        }
        for _ in 0..<460 { await editor.tick(wallMs: 100) }
        await editor.run(.ping(node: id("PC1"), target: "192.168.2.10"))
        for _ in 0..<60 { await editor.tick(wallMs: 100) }
        let lines = editor.snapshot.apps.first?.lines ?? []
        if !lines.contains("4 packets transmitted, 4 received, 0% packet loss") || !lines.contains(where: { $0.contains("ttl=62") }) {
            failures.append("ping over OSPF \(lines)")
        }
        let r1 = editor.snapshot.nodes.first { $0.name == "R1" }
        if !(r1?.routes.map(routeColumns) ?? []).contains(["O", "192.168.2.0/24", "[110/2]", "10.0.12.2", "Gi0/1"]) {
            failures.append("R1 routes \(String(describing: r1?.routes))")
        }
        if r1?.ospfNeighbors.map(\.state) != ["Full/DR"] { failures.append("R1 neighbours \(String(describing: r1?.ospfNeighbors))") }
        if let hello = editor.events.last(where: { $0.proto == .ospf && $0.kind == .tx && $0.node == id("R1") && $0.info.contains("Hello") }) {
            await editor.selectEvent(hello.id)
            if editor.pdu?.map(\.title) != ["Ethernet II", "IPv4", "OSPF"] { failures.append("OSPF PDU \(String(describing: editor.pdu?.map(\.title)))") }
        } else {
            failures.append("no OSPF Hello sent by R1")
        }
        editor.select(.node(id("R1")))
        editor.inspectorTab = .services
        if !render(editor, to: sibling(output, "m8b-ospf")) { failures.append("could not write the M8b OSPF image") }
        editor.inspectorTab = .tables
        if !render(editor, to: sibling(output, "m8b-tables")) { failures.append("could not write the M8b tables image") }
        return failures
    }

    /// M9a: R1 routes IPv6 between PC1 and PC2, which autoconfigure with SLAAC; PC1 pings PC2's address.
    private static func ipv6Scenario(output: String) async -> [String] {
        var failures: [String] = []
        let editor = Editor(client: Simulation())
        await editor.addDevice(.router, at: Pos(x: 560, y: 160))
        await editor.addDevice(.pc, at: Pos(x: 400, y: 380))
        await editor.addDevice(.pc, at: Pos(x: 720, y: 380))
        let id = { (name: String) in editor.snapshot.nodes.first { $0.name == name }?.id ?? "" }
        await editor.connect(id("R1"), id("PC1")) // R1 Gi0/0
        await editor.connect(id("R1"), id("PC2")) // R1 Gi0/1
        for (iface, cidr) in [("Gi0/0", "2001:db8:1::1/64"), ("Gi0/1", "2001:db8:2::1/64")] {
            await editor.edit(.setIpv6(node: id("R1"), iface: iface, config: Ipv6Config(address: cidr)))
        }
        await editor.edit(.setIpv6Routing(node: id("R1"), on: true))
        for pc in ["PC1", "PC2"] { await editor.edit(.setIpv6(node: id(pc), iface: "eth0", config: Ipv6Config(autoconfig: true))) }
        for _ in 0..<30 { await editor.tick(wallMs: 100) }
        let pc2 = editor.snapshot.nodes.first { $0.name == "PC2" }?.ifaces.first?.ipv6.last ?? ""
        let target = String(pc2.split(separator: "/").first ?? "")
        if !pc2.hasPrefix("2001:db8:2::") || !pc2.hasSuffix("SLAAC") { failures.append("PC2 addresses \(pc2)") }
        await editor.run(.ping(node: id("PC1"), target: target))
        for _ in 0..<50 { await editor.tick(wallMs: 100) }
        let lines = editor.snapshot.apps.first?.lines ?? []
        if !lines.contains("4 packets transmitted, 4 received, 0% packet loss") || !lines.contains(where: { $0.contains("ttl=63") }) {
            failures.append("ping over IPv6 \(lines)")
        }
        let pc1 = editor.snapshot.nodes.first { $0.name == "PC1" }
        if !(pc1?.routes.map(routeColumns) ?? []).contains(where: { $0.first == "ND" && $0[1] == "::/0" }) {
            failures.append("PC1 routes \(String(describing: pc1?.routes))")
        }
        if let ns = editor.events.last(where: { $0.proto == .ndp && $0.node == id("PC1") && $0.kind == .tx && $0.info.contains("NS chi ha") }) {
            await editor.selectEvent(ns.id)
            if editor.pdu?.map(\.title) != ["Ethernet II", "IPv6", "ICMPv6"] { failures.append("NDP PDU \(String(describing: editor.pdu?.map(\.title)))") }
        } else {
            failures.append("no NS sent by PC1")
        }
        editor.select(.node(id("PC1")))
        editor.inspectorTab = .interfaces
        if !render(editor, to: sibling(output, "m9a-interfaces")) { failures.append("could not write the M9a interfaces image") }
        editor.inspectorTab = .tables
        if !render(editor, to: sibling(output, "m9a-tables")) { failures.append("could not write the M9a tables image") }
        await editor.edit(.addRoute(node: id("R1"), cidr: "2001:db8:9::/64", nextHop: "2001:db8:2::99"))
        if !(editor.snapshot.nodes.first { $0.name == "R1" }?.routes.contains { $0.dest == "2001:db8:9::/64" && $0.isStatic } ?? false) {
            failures.append("R1 has no IPv6 static route")
        }
        editor.select(.node(id("R1")))
        editor.inspectorTab = .routing
        if !render(editor, to: sibling(output, "m9a-routing")) { failures.append("could not write the M9a routing image") }
        return failures
    }

    /// M9b (spec M9 §1): SRV1 serves srv1.lab (AAAA and A) and the sink; R1 advertises it with RDNSS; PC1 learns it, pings the
    /// name over IPv6 and sends TCP and UDP to it; then a rule on R1 denying 2001:db8:1::/64 stops the IPv6 ping, not the IPv4 one.
    private static func ipv6ServicesScenario(output: String) async -> [String] {
        var failures: [String] = []
        let editor = Editor(client: Simulation())
        await editor.addDevice(.router, at: Pos(x: 560, y: 160))
        await editor.addDevice(.pc, at: Pos(x: 400, y: 380))
        await editor.addDevice(.server, at: Pos(x: 720, y: 380))
        let id = { (name: String) in editor.snapshot.nodes.first { $0.name == name }?.id ?? "" }
        await editor.connect(id("R1"), id("PC1")) // R1 Gi0/0
        await editor.connect(id("R1"), id("SRV1")) // R1 Gi0/1
        for (name, iface, v4, v6) in [("R1", "Gi0/0", "10.0.1.1/24", "2001:db8:1::1/64"), ("R1", "Gi0/1", "10.0.2.1/24", "2001:db8:2::1/64"),
                                      ("SRV1", "eth0", "10.0.2.53/24", "2001:db8:2::53/64")] {
            await editor.edit(.setIp(node: id(name), iface: iface, cidr: v4))
            await editor.edit(.setIpv6(node: id(name), iface: iface, config: Ipv6Config(address: v6)))
        }
        await editor.edit(.setIp(node: id("PC1"), iface: "eth0", cidr: "10.0.1.10/24"))
        await editor.edit(.addRoute(node: id("PC1"), cidr: "0.0.0.0/0", nextHop: "10.0.1.1"))
        await editor.edit(.addRoute(node: id("SRV1"), cidr: "0.0.0.0/0", nextHop: "10.0.2.1"))
        await editor.edit(.setIpv6(node: id("PC1"), iface: "eth0", config: Ipv6Config(autoconfig: true)))
        await editor.edit(.setIpv6Routing(node: id("R1"), on: true))
        await editor.edit(.setRdnss(node: id("R1"), server: "2001:db8:2::53"))
        await editor.enableDns(id("SRV1"), true)
        await editor.addDnsRecord(id("SRV1"), name: "srv1.lab", ip: "2001:db8:2::53", ttl: "")
        await editor.addDnsRecord(id("SRV1"), name: "srv1.lab", ip: "10.0.2.53", ttl: "")
        await editor.edit(.setSink(node: id("SRV1"), on: true))
        for _ in 0..<30 { await editor.tick(wallMs: 100) }
        let pc1 = { editor.snapshot.nodes.first { $0.name == "PC1" } }
        if pc1()?.learnedNameServer != "2001:db8:2::53" { failures.append("PC1 learned \(String(describing: pc1()?.learnedNameServer))") }
        await editor.run(.ping(node: id("PC1"), target: "srv1.lab"))
        // One second apart: R1 queues at most 3 packets while it resolves SRV1's address (spec M9 §4).
        for _ in 0..<10 { await editor.tick(wallMs: 100) }
        if let reply = editor.events.first(where: { $0.proto == .dns && $0.info.hasPrefix("DNS Risposta") && $0.info.contains("AAAA") }) {
            await editor.selectEvent(reply.id)
            if editor.pdu?.map(\.title) != ["Ethernet II", "IPv6", "UDP", "DNS"] { failures.append("AAAA PDU \(String(describing: editor.pdu?.map(\.title)))") }
        } else {
            failures.append("no AAAA answer in the event list")
        }
        await editor.startTraffic(id("PC1"), target: "srv1.lab", kind: .tcp, amount: "1000000", seconds: "")
        await editor.startTraffic(id("PC1"), target: "srv1.lab", kind: .udp, amount: "1", seconds: "1")
        for _ in 0..<50 { await editor.tick(wallMs: 100) }
        let apps = editor.snapshot.apps
        if !(apps.first?.lines.contains("4 packets transmitted, 4 received, 0% packet loss") ?? false)
            || apps.first?.lines.first != "PING srv1.lab(2001:db8:2::53) 56 data bytes" { failures.append("ping by name over IPv6 \(apps.first?.lines ?? [])") }
        if apps.count != 3 || apps[1].lines.last != "iperf Done." || apps[2].lines.last != "iperf Done." { failures.append("IPv6 traffic \(apps.map(\.lines))") }
        if !(pc1()?.tcp.contains { $0.remote == "[2001:db8:2::53]:9" } ?? false) { failures.append("PC1 TCP rows \(pc1()?.tcp ?? [])") }
        await editor.edit(.setFirewall(node: id("R1"), config: FirewallConfig()))
        await editor.addFirewallRule(id("R1"), FirewallRule(iface: "Gi0/0", direction: .inbound, action: .deny, proto: .any, src: "2001:db8:1::/64", dst: ""), port: "")
        await editor.run(.ping(node: id("PC1"), target: "2001:db8:2::53"))
        await editor.run(.ping(node: id("PC1"), target: "10.0.2.53"))
        for _ in 0..<150 { await editor.tick(wallMs: 100) }
        let pings = editor.snapshot.apps.suffix(2).map(\.lines)
        if pings.count != 2 || !pings[0].contains("4 packets transmitted, 0 received, 100% packet loss")
            || !pings[1].contains("4 packets transmitted, 4 received, 0% packet loss") { failures.append("firewall IPv6 \(pings)") }
        editor.select(.node(id("SRV1")))
        editor.inspectorTab = .services
        if !render(editor, to: sibling(output, "m9b-dns")) { failures.append("could not write the M9b DNS image") }
        editor.select(.node(id("R1")))
        if !render(editor, to: sibling(output, "m9b-firewall")) { failures.append("could not write the M9b firewall image") }
        editor.inspectorTab = .routing
        if !render(editor, to: sibling(output, "m9b-routing")) { failures.append("could not write the M9b routing image") }
        editor.select(.node(id("PC1")))
        editor.inspectorTab = .tables
        if !render(editor, to: sibling(output, "m9b-tables")) { failures.append("could not write the M9b tables image") }
        editor.inspectorTab = .interfaces
        if !render(editor, to: sibling(output, "m9b-pc")) { failures.append("could not write the M9b host image") }
        return failures
    }

    /// M10 (spec M10 §1): the lab of the new devices as dropped; images of the lab, the printer and the palette in a short window.
    private static func m10Scenario(output: String) async -> [String] {
        var failures: [String] = []
        let editor = Editor(client: Simulation())
        // Staggered so the four cable labels and the minimap do not overlap.
        await editor.addDevice(.switch, at: Pos(x: 560, y: 60))
        await editor.addDevice(.server, at: Pos(x: 260, y: 220), preset: .dhcp)
        await editor.addDevice(.tv, at: Pos(x: 420, y: 330))
        await editor.addDevice(.printer, at: Pos(x: 700, y: 330))
        await editor.addDevice(.pc, at: Pos(x: 860, y: 220))
        let id = { (name: String) in editor.snapshot.nodes.first { $0.name == name }?.id ?? "" }
        for name in ["SRV1", "TV1", "PRN1", "PC1"] { await editor.connect(id("SW1"), id(name)) }
        await editor.edit(.setIp(node: id("PRN1"), iface: "eth0", cidr: "192.168.1.50/24"))
        await editor.edit(.setIfaceMode(node: id("PC1"), iface: "eth0", mode: .dhcp))
        for _ in 0..<610 { await editor.tick(wallMs: 100) }
        let ips = Set(["TV1", "PC1"].map { name in editor.snapshot.nodes.first { $0.name == name }?.ifaces.first?.cidr })
        if ips != ["192.168.1.100/24", "192.168.1.101/24"] { failures.append("M10 leases \(ips)") }
        await editor.startTraffic(id("PC1"), target: "192.168.1.50", kind: .tcp, amount: "100000", seconds: "")
        for _ in 0..<20 { await editor.tick(wallMs: 100) }
        if editor.snapshot.apps.last?.lines.last != "iperf Done." { failures.append("M10 print job \(editor.snapshot.apps.last?.lines ?? [])") }
        editor.select(.node(id("PRN1")))
        editor.inspectorTab = .services
        if !render(editor, to: sibling(output, "m10-lab")) { failures.append("could not write the M10 lab image") }
        editor.select(.node(id("TV1")))
        editor.inspectorTab = .interfaces
        if !render(editor, to: sibling(output, "m10-tv")) { failures.append("could not write the M10 TV image") }
        // The minimum window (640 pt) less the toolbar: the whole palette still fits, nothing cut.
        if !render(editor, to: sibling(output, "m10-palette-short"), height: 588) { failures.append("could not write the short palette image") }
        // Each port names the device and port at the other end (from v1); a long name shortens in the middle, on one line.
        await editor.edit(.rename(id: id("PRN1"), name: "Stampante-ufficio-secondo-piano"))
        let sw = editor.snapshot.nodes.first { $0.name == "SW1" }
        if sw.map({ peerLabel(IfaceRef(node: $0.id, iface: "Gi0/2"), in: editor.snapshot) }) != "TV1 eth0" { failures.append("SW1 Gi0/2 peer") }
        editor.select(.node(id("SW1")))
        editor.inspectorTab = .ports
        if !render(editor, to: sibling(output, "ux-ports")) { failures.append("could not write the ports peer image") }
        // The address hints skip SRV1, the leases and the pool .100–.199 (the menu itself opens in its own window: not in the image).
        let hints = addressSuggestions(IfaceRef(node: id("Stampante-ufficio-secondo-piano"), iface: "eth0"), in: editor.snapshot)
        if hints != ["192.168.1.1/24", "192.168.1.3/24", "192.168.1.4/24"] { failures.append("address hints \(hints)") }
        return failures
    }

    /// M11a (spec M11 §1): the Wi-Fi lab as dropped. Images: TAB1's DHCP DISCOVER (To DS) in the PDU inspector; the lab with TAB1's
    /// Wi-Fi tab and an Association Response in the PDU inspector under the full chip row; LAPTOP1's Wi-Fi tab (card, SSID, status);
    /// AP1's Wi-Fi tab with an SSID error and its tables; LAPTOP1's tables.
    private static func m11aScenario(output: String) async -> [String] {
        var failures: [String] = []
        let editor = Editor(client: Simulation())
        await editor.addDevice(.switch, at: Pos(x: 560, y: 60))
        await editor.addDevice(.server, at: Pos(x: 300, y: 180), preset: .dhcp)
        await editor.addDevice(.accessPoint, at: Pos(x: 560, y: 200))
        // Stations symmetric under AP1, LAPTOP1 clear of the minimap in the bottom-right corner.
        await editor.addDevice(.tablet, at: Pos(x: 430, y: 370))
        await editor.addDevice(.smartphone, at: Pos(x: 560, y: 390))
        await editor.addDevice(.laptop, at: Pos(x: 690, y: 370))
        let id = { (name: String) in editor.snapshot.nodes.first { $0.name == name }?.id ?? "" }
        let cidr = { (name: String) in editor.snapshot.nodes.first { $0.name == name }?.ifaces.first?.cidr }
        for name in ["SRV1", "AP1"] { await editor.connect(id("SW1"), id(name)) }
        await editor.setNic(id("LAPTOP1"), wifi: true)
        await editor.edit([.setStation(node: id("LAPTOP1"), config: StationConfig(ssid: "pac-track")),
                           .setIfaceMode(node: id("LAPTOP1"), iface: "wlan0", mode: .dhcp)])
        for _ in 0..<610 { await editor.tick(wallMs: 100) }
        if airLinks(editor.snapshot.nodes).count != 3 { failures.append("M11a air links \(airLinks(editor.snapshot.nodes).map(\.id))") }
        let ips = Set(["TAB1", "PHONE1", "LAPTOP1"].map(cidr))
        if ips != ["192.168.1.100/24", "192.168.1.101/24", "192.168.1.102/24"] { failures.append("M11a leases \(ips)") }
        await editor.run(.ping(node: id("TAB1"), target: cidr("PHONE1")?.split(separator: "/").first.map(String.init) ?? ""))
        for _ in 0..<50 { await editor.tick(wallMs: 100) }
        if !(editor.snapshot.apps.last?.lines.contains("4 packets transmitted, 4 received, 0% packet loss") ?? false) {
            failures.append("M11a ping \(editor.snapshot.apps.last?.lines ?? [])")
        }
        if let discover = editor.events.first(where: { $0.proto == .dhcp && $0.kind == .tx && $0.node == id("TAB1") }) {
            await editor.selectEvent(discover.id)
            if editor.pdu?.map(\.title) != ["IEEE 802.11", "LLC/SNAP", "IPv4", "UDP", "DHCP"] { failures.append("M11a data PDU \(String(describing: editor.pdu?.map(\.title)))") }
            let flag = editor.pdu?.first?.fields.first { $0.name == "Flag" }?.value
            if flag != "0x01 (To DS)" { failures.append("M11a data frame flag \(String(describing: flag))") }
            editor.bottomTab = .events
            if !render(editor, to: sibling(output, "m11a-data")) { failures.append("could not write the M11a data frame image") }
        } else {
            failures.append("no DHCP frame from TAB1 in the event list")
        }
        if let response = editor.events.first(where: { $0.proto == .wifi && $0.kind == .rx && $0.info.hasPrefix("Association Response") }) {
            await editor.selectEvent(response.id)
            if editor.pdu?.map(\.title) != ["IEEE 802.11", "Gestione 802.11"] { failures.append("M11a management PDU \(String(describing: editor.pdu?.map(\.title)))") }
        } else {
            failures.append("no Association Response in the event list")
        }
        editor.bottomTab = .events
        editor.select(.node(id("TAB1")))
        editor.inspectorTab = .wifi
        if !render(editor, to: sibling(output, "m11a-lab")) { failures.append("could not write the M11a lab image") }
        editor.select(.node(id("LAPTOP1")))
        let laptop = editor.snapshot.nodes.first { $0.name == "LAPTOP1" }
        let status = laptop?.station.map { wifiStatus($0, in: editor.snapshot.nodes) }
        if status != "Associato a pac-track · AP1 · canale 6" { failures.append("M11a LAPTOP1 status \(String(describing: status))") }
        if !render(editor, to: sibling(output, "m11a-laptop")) { failures.append("could not write the M11a laptop image") }
        await editor.edit(.setAccessPoint(node: id("AP1"), config: ApConfig(ssid: "", channel: 6)), key: "ssid:\(id("AP1"))")
        if editor.error?.message != "SSID must be 1 to 32 bytes" { failures.append("M11a SSID error \(String(describing: editor.error))") }
        editor.select(.node(id("AP1")))
        if !render(editor, to: sibling(output, "m11a-ap")) { failures.append("could not write the M11a access point image") }
        editor.inspectorTab = .tables
        if !render(editor, to: sibling(output, "m11a-ap-tables")) { failures.append("could not write the M11a access point tables image") }
        editor.select(.node(id("LAPTOP1")))
        if !render(editor, to: sibling(output, "m11a-tables")) { failures.append("could not write the M11a client tables image") }
        return failures
    }

    /// M12 (spec M12 §1): the home lab as dropped — ISP1, MODEM1, R1 with NAT and DHCP, SW1 with NAS1, CONSOLE1 and AP1, the IoT devices
    /// on AP1. Images: the lab with MODEM1's ports, NAS1's Servizi, LAMP1's and CONSOLE1's Wi-Fi tabs, the palette in a short window.
    private static func m12Scenario(output: String) async -> [String] {
        var failures: [String] = []
        let editor = Editor(client: Simulation())
        // Wide gaps on the top row for the cable labels; the IoT devices left of SW1, clear of the minimap in the bottom-right corner.
        let layout: [(DeviceKind, Double, Double)] = [(.cloud, 120, 60), (.modem, 380, 60), (.router, 640, 60), (.switch, 640, 190), (.nas, 520, 330),
                                                      (.console, 720, 290), (.accessPoint, 300, 190), (.smartBulb, 130, 330), (.thermostat, 270, 370),
                                                      (.smartSpeaker, 400, 310)]
        for (kind, x, y) in layout { await editor.addDevice(kind, at: Pos(x: x, y: y)) }
        let id = { (name: String) in editor.snapshot.nodes.first { $0.name == name }?.id ?? "" }
        let cidr = { (name: String) in editor.snapshot.nodes.first { $0.name == name }?.ifaces.first?.cidr }
        await editor.connect(id("MODEM1"), id("R1")) // R1 Gi0/0 — MODEM1 eth0, though cabled first
        await editor.connect(id("ISP1"), id("MODEM1")) // ISP1 Gi0/0 — MODEM1 dsl0
        for name in ["R1", "NAS1", "CONSOLE1", "AP1"] { await editor.connect(id("SW1"), id(name)) }
        let r1 = id("R1")
        await editor.edit([.setIp(node: r1, iface: "Gi0/0", cidr: "203.0.113.2/24"), .setIp(node: r1, iface: "Gi0/1", cidr: "192.168.1.1/24"),
                           .addRoute(node: r1, cidr: "0.0.0.0/0", nextHop: "203.0.113.1"),
                           .setNat(node: r1, config: NatConfig(inside: ["Gi0/1"], outside: "Gi0/0")),
                           .setDhcpServer(node: r1, config: DhcpConfig(start: "192.168.1.100", end: "192.168.1.199", gateway: "192.168.1.1", dns: "8.8.8.8"))])
        let line = editor.snapshot.links.first { [$0.a, $0.b].contains(IfaceRef(node: id("MODEM1"), iface: "dsl0")) }
        if line.map({ cableRate($0, in: editor.snapshot.nodes) }) != "100/20 Mb/s" || line.map({ [$0.a.node, $0.b.node] }) != [id("ISP1"), id("MODEM1")] {
            failures.append("M12 DSL line \(String(describing: line))")
        }
        for _ in 0..<610 { await editor.tick(wallMs: 100) }
        let ips = ["NAS1", "CONSOLE1", "LAMP1", "THERM1", "SPK1"].compactMap(cidr)
        if Set(ips).count != 5 || !ips.allSatisfy({ $0.hasPrefix("192.168.1.1") }) { failures.append("M12 leases \(ips)") }
        await editor.startTraffic(id("CONSOLE1"), target: cidr("NAS1")?.split(separator: "/").first.map(String.init) ?? "", kind: .tcp, amount: "100000", seconds: "")
        await editor.run(.ping(node: id("CONSOLE1"), target: "www.example.com"))
        for _ in 0..<60 { await editor.tick(wallMs: 100) }
        if editor.snapshot.apps.first?.lines.last != "iperf Done." { failures.append("M12 copy to the NAS \(editor.snapshot.apps.first?.lines ?? [])") }
        if !(editor.snapshot.apps.last?.lines.contains("4 packets transmitted, 4 received, 0% packet loss") ?? false) {
            failures.append("M12 ping through the modem \(editor.snapshot.apps.last?.lines ?? [])")
        }
        editor.bottomTab = .output
        editor.select(.node(id("MODEM1")))
        if !render(editor, to: sibling(output, "m12-lab")) { failures.append("could not write the M12 lab image") }
        editor.select(.node(id("NAS1")))
        editor.inspectorTab = .services
        if !render(editor, to: sibling(output, "m12-nas")) { failures.append("could not write the M12 NAS image") }
        editor.select(.node(id("LAMP1")))
        editor.inspectorTab = .wifi
        if !render(editor, to: sibling(output, "m12-iot")) { failures.append("could not write the M12 IoT image") }
        editor.select(.node(id("CONSOLE1")))
        if !render(editor, to: sibling(output, "m12-console")) { failures.append("could not write the M12 console image") }
        // The minimum window (640 pt) less the toolbar: the palette scrolls, nothing cut or wrapped.
        if !render(editor, to: sibling(output, "m12-palette-short"), height: 588) { failures.append("could not write the M12 short palette image") }
        return failures
    }

    /// "build/selftest.png" → "build/selftest-m3.png".
    static func sibling(_ path: String, _ suffix: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().path + "-\(suffix).png"
    }

    /// 31 s of simulated time: switch ports without PortFast reach forwarding after 2 × forward delay (spec M7 §4).
    private static func converge(_ editor: Editor) async {
        for _ in 0..<310 { await editor.tick(wallMs: 100) }
    }

    /// Two hubs cabled twice: the ARP broadcast circulates and the UI must warn (a switch loop is broken by STP).
    private static func loopScenario() async -> [String] {
        let editor = Editor(client: Simulation())
        await editor.addDevice(.hub, at: Pos(x: 0, y: 0))
        await editor.addDevice(.hub, at: Pos(x: 200, y: 0))
        await editor.addDevice(.pc, at: Pos(x: 0, y: 200))
        let id = { (name: String) in editor.snapshot.nodes.first { $0.name == name }?.id ?? "" }
        await editor.connect(id("HUB1"), id("HUB2"))
        await editor.connect(id("HUB1"), id("HUB2"))
        await editor.connect(id("PC1"), id("HUB1"))
        await editor.edit(.setIp(node: id("PC1"), iface: "eth0", cidr: "10.0.0.1/24"))
        await editor.run(.ping(node: id("PC1"), target: "10.0.0.9"))
        for _ in 0..<3 { await editor.tick(wallMs: 100) }
        var failures = editor.warning == nil ? ["no L2 loop warning"] : []
        if editor.snapshot.effectiveSpeed >= editor.snapshot.speed { failures.append("the storm did not lower the effective speed") }
        return failures
    }

    static func render(_ editor: Editor, to path: String, height: CGFloat = 860) -> Bool {
        let size = NSSize(width: 1400, height: height)
        let host = NSHostingView(rootView: MainContent(editor: editor).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3)) // let SwiftUI finish layout
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
