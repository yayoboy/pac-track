@testable import PacEngine // RouteRow's memberwise init
import Testing
@testable import PacKit

@MainActor
@Suite struct Ipv6EditorTests {
    let editor = Editor(client: Simulation())

    private func node(_ name: String) -> NodeView { editor.snapshot.nodes.first { $0.name == name }! }

    @Test func ipv6SettingsAreSavedUndoneAndCopiedWithoutAddresses() async {
        await editor.addDevice(.router, at: Pos(x: 0, y: 0))
        await editor.addDevice(.pc, at: Pos(x: 100, y: 0))
        let r = node("R1").id
        let pc = node("PC1").id
        await editor.edit(.setIpv6(node: r, iface: "Gi0/0", config: Ipv6Config(address: "2001:db8:1::1/64")))
        await editor.edit(.setIpv6Routing(node: r, on: true))
        await editor.edit(.setIpv6(node: pc, iface: "eth0", config: Ipv6Config(autoconfig: true)))
        await editor.edit(.addRoute(node: r, cidr: "2001:db8:9::/64", nextHop: "2001:db8:1::99"))
        let saved = editor.current
        #expect(saved.nodes[0].ipv6Routing && saved.nodes[0].ifaces[0].ipv6 == Ipv6Config(address: "2001:db8:1::1/64"))
        #expect(saved.nodes[0].routes == [TopologyRoute(cidr: "2001:db8:9::/64", nextHop: "2001:db8:1::99")])
        #expect(saved.nodes[1].ifaces[0].ipv6 == Ipv6Config(autoconfig: true))
        await editor.undo()
        #expect(editor.current.nodes[0].routes.isEmpty)
        await editor.duplicate([r, pc])
        #expect(!node("R2").ipv6Routing && node("R2").ifaces[0].ipv6Config == Ipv6Config()) // IPv6 stays on, the address stays behind
        #expect(node("PC2").ifaces[0].ipv6Config == Ipv6Config(autoconfig: true))
        await editor.edit(.setIpv6(node: r, iface: "Gi0/1", config: Ipv6Config(address: "2001:db8:1::2/64")), key: "ip6:\(r):Gi0/1")
        #expect(editor.error == EditorError(key: "ip6:\(r):Gi0/1", message: "2001:db8:1::2/64 overlaps with Gi0/0"))
    }

    @Test func routesFromRouterAdvertisementsShowTypeNd() {
        let row = RouteRow(dest: "::/0", nextHop: "fe80::ff:fe00:2", iface: "eth0", isStatic: false, ra: true)
        #expect(routeColumns(row) == ["ND", "::/0", "[2/0]", "fe80::ff:fe00:2", "eth0"])
    }
}
