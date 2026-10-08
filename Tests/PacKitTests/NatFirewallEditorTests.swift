import PacEngine
import Testing
@testable import PacKit

@MainActor
@Suite struct NatFirewallEditorTests {
    let editor = Editor(client: Simulation())

    private var r1: NodeView { editor.snapshot.nodes[0] }

    private func router() async -> String {
        await editor.addDevice(.router, at: Pos(x: 0, y: 0))
        return r1.id
    }

    @Test func natRolesAllowOneOutsideAndNoRolesTurnNatOff() async {
        let r = await router()
        await editor.setNatRole(r, iface: "Gi0/2", .inside)
        await editor.setNatRole(r, iface: "Gi0/0", .inside)
        await editor.setNatRole(r, iface: "Gi0/1", .outside)
        #expect(r1.nat == NatConfig(inside: ["Gi0/0", "Gi0/2"], outside: "Gi0/1")) // interface order
        await editor.setNatRole(r, iface: "Gi0/3", .outside)
        #expect(r1.nat == NatConfig(inside: ["Gi0/0", "Gi0/2"], outside: "Gi0/3")) // the old outside loses its role
        #expect(natRole(r1.nat, "Gi0/1") == .off && natRole(r1.nat, "Gi0/3") == .outside && natRole(r1.nat, "Gi0/0") == .inside)
        await editor.undo()
        #expect(r1.nat?.outside == "Gi0/1")
        for name in ["Gi0/0", "Gi0/1", "Gi0/2"] { await editor.setNatRole(r, iface: name, .off) }
        #expect(r1.nat == nil && editor.current.nodes[0].nat == nil)
    }

    @Test func firewallRulesComeFromTypedFieldsAreRemovedAndSaved() async {
        let r = await router()
        let key = "fw:\(r)"
        await editor.edit(.setFirewall(node: r, config: FirewallConfig()))
        let deny = FirewallRule(iface: "Gi0/1", direction: .inbound, action: .deny, proto: .tcp, src: " ", dst: "203.0.113.1")
        var ok = await editor.addFirewallRule(r, deny, port: "ottanta")
        #expect(!ok && editor.error == EditorError(key: key, message: "Invalid number: \"ottanta\""))
        ok = await editor.addFirewallRule(r, FirewallRule(iface: "Gi0/1", direction: .inbound, action: .deny, proto: .icmp, src: "", dst: ""), port: "80")
        #expect(!ok && editor.error == EditorError(key: key, message: "A port needs TCP or UDP"))
        ok = await editor.addFirewallRule(r, deny, port: " 80 ")
        #expect(ok)
        await editor.addFirewallRule(r, FirewallRule(iface: "Gi0/0", direction: .outbound, action: .allow, proto: .any, src: "10.0.0.0/8", dst: ""),
                                     port: "")
        #expect(editor.error == nil)
        #expect(r1.firewall?.rules.map(ruleSummary) == ["in Gi0/1 · nega tcp any → 203.0.113.1 porta 80", "out Gi0/0 · consenti any 10.0.0.0/8 → any"])
        #expect(editor.current.nodes[0].firewall == r1.firewall)
        await editor.removeFirewallRule(r, at: 0)
        #expect(r1.firewall?.rules.count == 1)
        await editor.undo()
        #expect(r1.firewall?.rules.count == 2)
    }
}
