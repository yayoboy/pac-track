import PacEngine
import Testing
@testable import PacKit

@MainActor
@Suite struct RipEditorTests {
    let editor = Editor(client: Simulation())

    private func node(_ name: String) -> NodeView { editor.snapshot.nodes.first { $0.name == name }! }

    @Test func enablingRipMakesEveryAddressedInterfaceActiveAndRolesKeepInterfaceOrder() async {
        await editor.addDevice(.router, at: Pos(x: 0, y: 0))
        let r = node("R1").id
        await editor.edit(.setIp(node: r, iface: "Gi0/1", cidr: "10.0.12.1/30"))
        await editor.edit(.setIp(node: r, iface: "Gi0/0", cidr: "192.168.1.1/24"))
        await editor.enableRip(r, true)
        #expect(node("R1").rip == RipConfig(interfaces: ["Gi0/0", "Gi0/1"]))
        await editor.setRipRole(r, iface: "Gi0/0", .passive)
        await editor.setRipRole(r, iface: "Gi0/2", .active)
        await editor.setRipRole(r, iface: "Gi0/1", .off)
        #expect(node("R1").rip == RipConfig(interfaces: ["Gi0/0", "Gi0/2"], passive: ["Gi0/0"]))
        #expect(ripRole(node("R1").rip, "Gi0/0") == .passive && ripRole(node("R1").rip, "Gi0/2") == .active && ripRole(node("R1").rip, "Gi0/1") == .off)
        #expect(editor.current.nodes[0].rip == node("R1").rip)
        await editor.undo()
        #expect(node("R1").rip == RipConfig(interfaces: ["Gi0/0", "Gi0/1", "Gi0/2"], passive: ["Gi0/0"]))
        await editor.duplicate([r])
        #expect(node("R2").rip == nil) // a copy has no addresses, so no RIP (spec M8 §6)
        await editor.enableRip(r, false)
        #expect(node("R1").rip == nil)
    }

    @Test func routesLearnedByRipShowTheirTypeAndDistance() async {
        await editor.addDevice(.router, at: Pos(x: 0, y: 0))
        await editor.addDevice(.router, at: Pos(x: 200, y: 0))
        await editor.addDevice(.pc, at: Pos(x: 400, y: 0))
        let (r1, r2, pc) = (node("R1").id, node("R2").id, node("PC1").id)
        await editor.connect(r1, r2) // Gi0/0 — Gi0/0
        await editor.connect(r2, pc) // R2 Gi0/1
        await editor.edit(.setIp(node: r1, iface: "Gi0/0", cidr: "10.0.12.1/30"))
        await editor.edit(.setIp(node: r2, iface: "Gi0/0", cidr: "10.0.12.2/30"))
        await editor.edit(.setIp(node: r2, iface: "Gi0/1", cidr: "192.168.2.1/24"))
        await editor.edit(.addRoute(node: r1, cidr: "172.16.0.0/16", nextHop: "10.0.12.2"))
        await editor.enableRip(r1, true)
        await editor.enableRip(r2, true)
        await editor.tick(wallMs: 100)
        #expect(node("R1").routes.map(routeColumns) == [
            ["C", "10.0.12.0/30", "", "connessa", "Gi0/0"],
            ["S", "172.16.0.0/16", "[1/0]", "10.0.12.2", "Gi0/0"],
            ["R", "192.168.2.0/24", "[120/1]", "10.0.12.2", "Gi0/0"],
        ])
    }
}
