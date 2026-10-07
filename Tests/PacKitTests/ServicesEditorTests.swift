import PacEngine
import Testing
@testable import PacKit

@MainActor
@Suite struct ServicesEditorTests {
    let editor = Editor(client: Simulation())

    private func node(_ name: String) -> NodeView { editor.snapshot.nodes.first { $0.name == name }! }

    /// SRV1 (10.0.0.2/24) cabled to PC1.
    private func pair() async -> (srv: String, pc: String) {
        await editor.addDevice(.server, at: Pos(x: 0, y: 0))
        await editor.addDevice(.pc, at: Pos(x: 100, y: 0))
        let (srv, pc) = (node("SRV1").id, node("PC1").id)
        await editor.connect(srv, pc)
        await editor.edit(.setIp(node: srv, iface: "eth0", cidr: "10.0.0.2/24"))
        return (srv, pc)
    }

    @Test func enablingDhcpSuggestsAPoolFromTheAddressAndIsOneUndoStep() async {
        let (srv, _) = await pair()
        await editor.enableDns(srv, true)
        await editor.enableDhcp(srv, true)
        #expect(node("SRV1").dhcpServer == DhcpConfig(start: "10.0.0.100", end: "10.0.0.199", dns: "10.0.0.2"))
        await editor.undo()
        #expect(node("SRV1").dhcpServer == nil)
        #expect(node("SRV1").dnsRecords == [])
    }

    @Test func aRouterSuggestsItselfAsGatewayAndExplainsAMissingAddress() async {
        await editor.addDevice(.router, at: Pos(x: 0, y: 0))
        let r = node("R1").id
        await editor.enableDhcp(r, true)
        #expect(editor.error == EditorError(key: "dhcp:\(r):enabled", message: "Assign an IPv4 address to an interface first"))
        await editor.edit(.setIp(node: r, iface: "Gi0/1", cidr: "192.168.5.1/24"))
        await editor.enableDhcp(r, true)
        #expect(node("R1").dhcpServer == DhcpConfig(start: "192.168.5.100", end: "192.168.5.199", gateway: "192.168.5.1"))
    }

    @Test func showsDhcpFieldErrorsOnTheFieldAndKeepsTheConfig() async {
        let (srv, _) = await pair()
        await editor.enableDhcp(srv, true)
        await editor.setDhcp(srv, .end, "10.0.1.250")
        #expect(editor.error == EditorError(key: "dhcp:\(srv):end", message: "DHCP pool 10.0.0.100-10.0.1.250 is outside the subnets of SRV1"))
        await editor.setDhcp(srv, .lease, "un giorno")
        #expect(editor.error == EditorError(key: "dhcp:\(srv):lease", message: "Invalid number: \"un giorno\""))
        await editor.setDhcp(srv, .excluded, "10.0.0.100, 10.0.0.150-10.0.0.160,")
        #expect(editor.error == nil)
        #expect(node("SRV1").dhcpServer?.excluded == ["10.0.0.100", "10.0.0.150-10.0.0.160"])
        #expect(node("SRV1").dhcpServer?.end == "10.0.0.199")
    }

    @Test func managesDnsRecordsWithErrorsUnderTheForm() async {
        let (srv, _) = await pair()
        await editor.enableDns(srv, true)
        #expect(await editor.addDnsRecord(srv, name: "WWW.Lab", ip: "10.0.0.80", ttl: ""))
        #expect(await editor.addDnsRecord(srv, name: "db.lab", ip: "10.0.0.81", ttl: "60"))
        #expect(!(await editor.addDnsRecord(srv, name: "bad name", ip: "10.0.0.82", ttl: "")))
        #expect(editor.error == EditorError(key: "dnsrec:\(srv)", message: "Invalid host name: \"bad name\""))
        #expect(!(await editor.addDnsRecord(srv, name: "x.lab", ip: "10.0.0.82", ttl: "abc")))
        #expect(editor.error == EditorError(key: "dnsrec:\(srv)", message: "Invalid number: \"abc\""))
        #expect(node("SRV1").dnsRecords == [DnsRecord(name: "www.lab", ip: "10.0.0.80"), DnsRecord(name: "db.lab", ip: "10.0.0.81", ttl: 60)])
        await editor.removeDnsRecord(srv, at: 0)
        #expect(node("SRV1").dnsRecords?.map(\.name) == ["db.lab"])
    }

    @Test func savesModesAndServicesButNeverLeasedAddressesOrRoutes() async {
        let (srv, pc) = await pair()
        await editor.enableDhcp(srv, true)
        await editor.setDhcp(srv, .gateway, "10.0.0.1")
        await editor.edit(.setIfaceMode(node: pc, iface: "eth0", mode: .dhcp))
        await editor.edit(.setNameServer(node: pc, ip: "10.0.0.2"))
        for _ in 0..<10 { await editor.tick(wallMs: 100) }
        #expect(node("PC1").ifaces[0].cidr == "10.0.0.100/24")
        #expect(node("PC1").routes.contains { $0.dhcp })
        let saved = editor.current.nodes.first { $0.id == pc }!
        #expect(saved.ifaces == [TopologyIface(name: "eth0", cidr: nil, mode: .dhcp)])
        #expect(saved.routes.isEmpty)
        #expect(saved.nameServer == "10.0.0.2")
        #expect(editor.current.nodes.first { $0.id == srv }!.dhcp?.gateway == "10.0.0.1")
        let copy = editor.current
        #expect(await editor.load(copy))
        #expect(editor.current == copy)
    }

    @Test func duplicatesKeepDhcpModeAndDnsServer() async {
        let (_, pc) = await pair()
        await editor.edit(.setIfaceMode(node: pc, iface: "eth0", mode: .dhcp))
        await editor.edit(.setNameServer(node: pc, ip: "10.0.0.2"))
        await editor.duplicate(pc)
        #expect(node("PC2").ifaces[0].mode == .dhcp)
        #expect(node("PC2").nameServer == "10.0.0.2")
    }

    @Test func formatsDhcpFieldsClientStatusLeasesAndTabs() throws {
        let c = DhcpConfig(start: "10.0.0.100", end: "10.0.0.199", excluded: ["10.0.0.150"], leaseS: 3600)
        #expect(DhcpField.allCases.map { $0.format(c) } == ["10.0.0.100", "10.0.0.199", "10.0.0.150", "", "", "3600"])
        #expect(try DhcpField.gateway.apply(" 10.0.0.1 ", to: c).gateway == "10.0.0.1")
        #expect(try DhcpField.dns.apply("", to: c).dns == nil)
        #expect(dhcpStatus(DhcpClientView(state: "BOUND", server: "10.0.0.2", leaseS: 3500, renewS: 1700))
            == "BOUND · server 10.0.0.2 · lease 3500 s · rinnovo tra 1700 s")
        #expect(dhcpStatus(DhcpClientView(state: "SELECTING", server: nil, leaseS: nil, renewS: nil)) == "SELECTING · in attesa del server DHCP")
        #expect(inspectorTabs(for: .server) == [.interfaces, .routing, .services, .tables, .app])
        #expect(inspectorTabs(for: .laptop) == [.interfaces, .routing, .tables, .app])
        #expect(inspectorTabs(for: .switch) == [.ports, .tables])
        #expect(DeviceKind.allCases.filter(\.isHost) == [.pc, .laptop, .server])
    }
}
