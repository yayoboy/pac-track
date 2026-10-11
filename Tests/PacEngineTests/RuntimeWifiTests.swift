import Testing
@testable import PacEngine

private func runFor(_ rt: Runtime, wallMs: Int) {
    for _ in stride(from: 0, to: wallMs, by: 100) { rt.advance(wallMs: 100) }
}

@Suite struct RuntimeWifiTests {
    /// Spec M11 §2: an access point (pac-track on channel 6, no address) and tablets and smartphones with wlan0 only; SSIDs counted in
    /// UTF-8 bytes; associations in the snapshot.
    @Test func accessPointsTabletsAndSmartphonesAndTheirWifiSettings() throws {
        let rt = Runtime()
        try rt.handle(.addNode(id: "ap", kind: .accessPoint, name: "AP1"))
        try rt.handle(.addNode(id: "t", kind: .tablet, name: "TAB1"))
        try rt.handle(.addNode(id: "s", kind: .smartphone, name: "PHONE1"))
        try rt.handle(.addNode(id: "p", kind: .printer, name: "PRN1"))
        var s = rt.snapshot()
        #expect(s.nodes.map { $0.ifaces.map(\.name) } == [["Gi0", "Dot11Radio0"], ["wlan0"], ["wlan0"], ["eth0"]])
        #expect(s.nodes.map { $0.ifaces.map(\.wireless) } == [[false, true], [true], [true], [false]])
        #expect(s.nodes[0].accessPoint == AccessPointView(config: ApConfig(ssid: "pac-track", channel: 6), clients: []))
        #expect(s.nodes[1].station == StationView(config: StationConfig(), state: .idle, bssid: nil, ap: nil, channel: nil))
        #expect(s.nodes[3].station == nil && s.nodes[3].accessPoint == nil && s.nodes[1].accessPoint == nil)
        expectError("SSID must be 1 to 32 bytes") { try rt.handle(.setAccessPoint(node: "ap", config: ApConfig(ssid: "", channel: 6))) }
        expectError("SSID must be 1 to 32 bytes") {
            try rt.handle(.setAccessPoint(node: "ap", config: ApConfig(ssid: String(repeating: "è", count: 17), channel: 6))) // 34 bytes
        }
        expectError("Channel must be 1, 6 or 11") { try rt.handle(.setAccessPoint(node: "ap", config: ApConfig(ssid: "lab", channel: 3))) }
        expectError("PRN1 is not an access point") { try rt.handle(.setAccessPoint(node: "p", config: ApConfig())) }
        expectError("PRN1 cannot use Wi-Fi") { try rt.handle(.setStation(node: "p", config: StationConfig(ssid: "lab"))) }
        expectError("TAB1 has only a Wi-Fi card") { try rt.handle(.setStation(node: "t", config: nil)) }
        expectError("SSID must be at most 32 bytes") { try rt.handle(.setStation(node: "t", config: StationConfig(ssid: String(repeating: "a", count: 33)))) }
        try rt.handle(.setAccessPoint(node: "ap", config: ApConfig(ssid: "lab", channel: 11)))
        for id in ["t", "s"] { try rt.handle(.setStation(node: id, config: StationConfig(ssid: "lab"))) }
        runFor(rt, wallMs: 200)
        s = rt.snapshot()
        let radio = s.nodes[0].ifaces[1].mac
        #expect(s.nodes[0].accessPoint?.clients == [AssociationRow(aid: 1, mac: s.nodes[1].ifaces[0].mac, node: "t"),
                                                    AssociationRow(aid: 2, mac: s.nodes[2].ifaces[0].mac, node: "s")])
        #expect(s.nodes[1].station == StationView(config: StationConfig(ssid: "lab"), state: .associated, bssid: radio, ap: "ap", channel: 11))
        #expect(s.nodes[1].ifaces[0].linked && s.nodes[0].ifaces[1].linked && !s.nodes[0].ifaces[0].linked)
        expectError("Cannot cable a wireless interface") {
            try rt.handle(.connect(id: "l", a: IfaceRef(node: "t", iface: "wlan0"), b: IfaceRef(node: "ap", iface: "Gi0")))
        }
        try rt.handle(.removeNode(id: "ap"))
        #expect(rt.snapshot().nodes.map { $0.station?.state } == [.scanning, .scanning, nil])
    }

    /// Spec M11 §2: a PC's Ethernet card gives way to a Wi-Fi one (wlan0, a new MAC, unconfigured) and back; refused with a cable in.
    @Test func aPcOrLaptopSwapsItsCardForWifiAndBack() throws {
        let rt = Runtime()
        try rt.handle(.addNode(id: "p", kind: .pc, name: "PC1"))
        try rt.handle(.addNode(id: "sw", kind: .switch, name: "SW1"))
        try rt.handle(.connect(id: "l", a: IfaceRef(node: "p", iface: "eth0"), b: IfaceRef(node: "sw", iface: "Gi0/1")))
        let eth = rt.snapshot().nodes[0].ifaces[0].mac
        expectError("eth0 is connected") { try rt.handle(.setStation(node: "p", config: StationConfig(ssid: "pac-track"))) }
        try rt.handle(.disconnect(id: "l"))
        try rt.handle(.setIfaceMode(node: "p", iface: "eth0", mode: .dhcp))
        try rt.handle(.setIpv6(node: "p", iface: "eth0", config: Ipv6Config(autoconfig: true)))
        try rt.handle(.setStation(node: "p", config: StationConfig(ssid: "pac-track")))
        var pc = rt.snapshot().nodes[0]
        #expect(pc.ifaces.map(\.name) == ["wlan0"] && pc.ifaces[0].mac != eth && pc.ifaces[0].wireless)
        #expect(pc.ifaces[0].mode == .static && pc.ifaces[0].cidr == nil && pc.ifaces[0].ipv6Config == nil && pc.dhcpClient == nil)
        #expect(pc.station?.config == StationConfig(ssid: "pac-track") && pc.station?.state == .scanning)
        let wlan = pc.ifaces[0].mac
        try rt.handle(.setStation(node: "p", config: nil))
        pc = rt.snapshot().nodes[0]
        #expect(pc.ifaces.map(\.name) == ["eth0"] && ![eth, wlan].contains(pc.ifaces[0].mac) && pc.station == nil)
        try rt.handle(.addNode(id: "l2", kind: .laptop, name: "LAPTOP1"))
        try rt.handle(.setStation(node: "l2", config: StationConfig()))
        #expect(rt.snapshot().nodes[2].ifaces.map(\.name) == ["wlan0"] && rt.snapshot().nodes[2].station?.state == .idle)
    }

    /// Spec M11 §10: the access point's network and the clients' (a PC with wlan0) come back from the file; associations are not
    /// saved: the stations associate again by themselves.
    @Test func wifiSettingsComeBackFromTheProjectFileAndStationsAssociateAgain() throws {
        let origin = Pos(x: 0, y: 0)
        let t = Topology(nodes: [
            TopologyNode(id: "ap", kind: .accessPoint, name: "AP1", pos: origin,
                         ifaces: [TopologyIface(name: "Gi0", cidr: nil), TopologyIface(name: "Dot11Radio0", cidr: nil)], routes: [],
                         accessPoint: ApConfig(ssid: "lab", channel: 1)),
            TopologyNode(id: "p", kind: .pc, name: "PC1", pos: origin, ifaces: [TopologyIface(name: "wlan0", cidr: "10.0.0.1/24")], routes: [],
                         station: StationConfig(ssid: "lab")),
            TopologyNode(id: "t", kind: .tablet, name: "TAB1", pos: origin, ifaces: [TopologyIface(name: "wlan0", cidr: nil, mode: .dhcp)],
                         routes: [], station: StationConfig(ssid: "lab")),
        ])
        let rt = Runtime()
        try rt.handle(.load(t))
        runFor(rt, wallMs: 200)
        let s = rt.snapshot()
        #expect(s.nodes[0].accessPoint?.config == ApConfig(ssid: "lab", channel: 1))
        #expect(s.nodes[1].ifaces.map(\.name) == ["wlan0"] && s.nodes[1].ifaces[0].cidr == "10.0.0.1/24" && s.nodes[2].ifaces[0].mode == .dhcp)
        #expect(s.nodes.dropFirst().map { $0.station?.state } == [.associated, .associated])
    }
}
