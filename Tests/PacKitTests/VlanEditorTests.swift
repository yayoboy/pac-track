import PacEngine
import Testing
@testable import PacKit

@MainActor
@Suite struct VlanEditorTests {
    let editor = Editor(client: Simulation())
    let origin = Pos(x: 0, y: 0)

    private func node(_ name: String) -> NodeView? {
        editor.snapshot.nodes.first { $0.name == name }
    }

    @Test func vlanSettingsAndSubinterfacesSurviveSavingUndoAndCopies() async throws {
        await editor.addDevice(.switch, at: origin)
        await editor.addDevice(.router, at: Pos(x: 200, y: 0))
        let sw = node("SW1")?.id ?? ""
        let r = node("R1")?.id ?? ""
        let trunk = PortConfig(mode: .trunk, allowed: "1,10,20")
        await editor.edit(.setSwitchport(node: sw, iface: "Gi0/1", config: PortConfig(vlan: 10)))
        await editor.edit(.setSwitchport(node: sw, iface: "Gi0/8", config: trunk))
        await editor.edit([.addSubinterface(node: r, iface: "Gi0/0.10"), .setIp(node: r, iface: "Gi0/0.10", cidr: "10.0.10.1/24")])
        let saved = editor.current
        #expect(saved.nodes[0].ifaces.compactMap { $0.switchport } == [PortConfig(vlan: 10), trunk]) // only ports off the default
        #expect(saved.nodes[1].ifaces.map { "\($0.name) \($0.cidr ?? "-")" } == ["Gi0/0 -", "Gi0/0.10 10.0.10.1/24", "Gi0/1 -", "Gi0/2 -", "Gi0/3 -"])
        let file = try ProjectFile.decode(try ProjectFile.encode(saved))
        let reopened = Editor(client: Simulation())
        let opened = await reopened.load(file)
        #expect(opened && sameNetwork(reopened.current, saved))
        await editor.undo() // the subinterface and its address: one step
        #expect(node("R1")?.ifaces.count == 4)
        await editor.redo()
        #expect(node("R1")?.ifaces[1].cidr == "10.0.10.1/24")
        await editor.duplicate([sw, r])
        #expect(node("SW2")?.ifaces.map { $0.switchport } == node("SW1")?.ifaces.map { $0.switchport })
        #expect(node("R2")?.ifaces.map { "\($0.name) \($0.cidr ?? "-")" } == ["Gi0/0 -", "Gi0/0.10 -", "Gi0/1 -", "Gi0/2 -", "Gi0/3 -"])
    }
}
