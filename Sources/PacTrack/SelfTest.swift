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
        if PaletteView.groups(matching: "rou").map(\.1) != [[.router]] { failures.append("palette search") }
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

    /// M6: a fibre cable drawn with the Collega tool, the grid hidden, the minimap in the corner.
    private static func toolsScenario(output: String) async -> [String] {
        var failures: [String] = []
        let editor = Editor(client: Simulation())
        await editor.addDevice(.switch, at: Pos(x: 420, y: 200))
        await editor.addDevice(.server, at: Pos(x: 700, y: 360))
        editor.tool = .connect
        editor.cable = .fiber
        let ids = editor.snapshot.nodes.map(\.id)
        await editor.connect(ids[0], ids[1])
        if editor.snapshot.links.first?.options.bandwidthBps != 10e9 { failures.append("fibre cable \(String(describing: editor.snapshot.links.first))") }
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

    /// "build/selftest.png" → "build/selftest-m3.png".
    static func sibling(_ path: String, _ suffix: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().path + "-\(suffix).png"
    }

    /// Two switches cabled twice: the ARP broadcast circulates and the UI must warn.
    private static func loopScenario() async -> [String] {
        let editor = Editor(client: Simulation())
        await editor.addDevice(.switch, at: Pos(x: 0, y: 0))
        await editor.addDevice(.switch, at: Pos(x: 200, y: 0))
        await editor.addDevice(.pc, at: Pos(x: 0, y: 200))
        let id = { (name: String) in editor.snapshot.nodes.first { $0.name == name }?.id ?? "" }
        await editor.connect(id("SW1"), id("SW2"))
        await editor.connect(id("SW1"), id("SW2"))
        await editor.connect(id("PC1"), id("SW1"))
        await editor.edit(.setIp(node: id("PC1"), iface: "eth0", cidr: "10.0.0.1/24"))
        await editor.run(.ping(node: id("PC1"), target: "10.0.0.9"))
        for _ in 0..<3 { await editor.tick(wallMs: 100) }
        var failures = editor.warning == nil ? ["no L2 loop warning"] : []
        if editor.snapshot.effectiveSpeed >= editor.snapshot.speed { failures.append("the storm did not lower the effective speed") }
        return failures
    }

    static func render(_ editor: Editor, to path: String) -> Bool {
        let size = NSSize(width: 1400, height: 860)
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
