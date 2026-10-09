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

    @Test func portFastAndPrioritiesSurviveSavingAndUndoCopiesKeepOnlyPortFast() async throws {
        await editor.addDevice(.switch, at: origin)
        let sw = node("SW1")?.id ?? ""
        await editor.edit(.setSwitchport(node: sw, iface: "Gi0/1", config: PortConfig(portfast: true)))
        await editor.edit(.setStpPriority(node: sw, vlan: 10, priority: 4096), key: "stp:\(sw)")
        let saved = editor.current
        #expect(saved.nodes[0].ifaces[0].switchport == PortConfig(portfast: true))
        #expect(saved.nodes[0].stpPriorities == [StpPriority(vlan: 10, priority: 4096)])
        let reopened = Editor(client: Simulation())
        let opened = await reopened.load(try ProjectFile.decode(try ProjectFile.encode(saved)))
        #expect(opened && sameNetwork(reopened.current, saved))
        await editor.undo() // the priority: one step
        #expect(editor.current.nodes[0].stpPriorities == nil)
        await editor.redo()
        await editor.duplicate([sw])
        #expect(node("SW2")?.ifaces[0].switchport == PortConfig(portfast: true))
        #expect(node("SW2")?.stpPriorities == [])
    }

    @Test func portFieldsApplyTypedVlansAndShowErrorsOnTheirField() async {
        await editor.addDevice(.switch, at: origin)
        let sw = node("SW1")?.id ?? ""
        await editor.setPort(sw, iface: "Gi0/1", .vlan, "dieci")
        #expect(editor.error == EditorError(key: "port:\(sw):Gi0/1:vlan", message: "Invalid number: \"dieci\""))
        await editor.setPort(sw, iface: "Gi0/1", .vlan, " 10 ")
        #expect(node("SW1")?.ifaces[0].switchport == PortConfig(vlan: 10) && editor.error == nil)
        await editor.edit(.setSwitchport(node: sw, iface: "Gi0/2", config: PortConfig(mode: .trunk)))
        await editor.setPort(sw, iface: "Gi0/2", .allowed, "10,20")
        #expect(editor.error == EditorError(key: "port:\(sw):Gi0/2:allowed", message: "Native VLAN 1 is not allowed on the trunk"))
        await editor.setPort(sw, iface: "Gi0/2", .native, "10")
        await editor.setPort(sw, iface: "Gi0/2", .allowed, "10 20") // a typo, not VLAN 1020
        #expect(editor.error == EditorError(key: "port:\(sw):Gi0/2:allowed", message: "Invalid VLAN list: \"10 20\""))
        await editor.setPort(sw, iface: "Gi0/2", .allowed, " 10,20 ")
        let trunk = PortConfig(mode: .trunk, allowed: "10,20", native: 10)
        #expect(node("SW1")?.ifaces[1].switchport == trunk)
        #expect([PortField.vlan, .allowed, .native].map { $0.format(trunk) } == ["1", "10,20", "10"])
        await editor.undo()
        #expect(node("SW1")?.ifaces[1].switchport?.allowed == "all")
    }

    @Test func aCableToATrunkPortIsLabelledTrunk() async {
        await editor.addDevice(.switch, at: origin)
        await editor.addDevice(.switch, at: Pos(x: 200, y: 0))
        let sw2 = node("SW2")?.id ?? ""
        await editor.connect(node("SW1")?.id ?? "", sw2) // Gi0/1 ↔ Gi0/1
        #expect(!isTrunk(editor.snapshot.links[0], in: editor.snapshot.nodes))
        await editor.edit(.setSwitchport(node: sw2, iface: "Gi0/1", config: PortConfig(mode: .trunk)))
        #expect(isTrunk(editor.snapshot.links[0], in: editor.snapshot.nodes))
    }

    @Test func theSubinterfaceFormAddsInOneStepAndDeleteWaitsForNatToLetGo() async {
        await editor.addDevice(.router, at: origin)
        let r = node("R1")?.id ?? ""
        let key = "sub:\(r)"
        var ok = await editor.addSubinterface(r, parent: "Gi0/0", vlan: "dieci", cidr: "")
        #expect(!ok && editor.error == EditorError(key: key, message: "Invalid number: \"dieci\""))
        ok = await editor.addSubinterface(r, parent: "Gi0/0", vlan: " 10 ", cidr: " 10.0.10.1/24 ")
        #expect(ok && node("R1")?.ifaces[1].name == "Gi0/0.10" && node("R1")?.ifaces[1].cidr == "10.0.10.1/24")
        ok = await editor.addSubinterface(r, parent: "Gi0/0", vlan: "10", cidr: "")
        #expect(!ok && editor.error == EditorError(key: key, message: "Gi0/0.10 already exists"))
        await editor.undo()
        #expect(node("R1")?.ifaces.count == 4) // subinterface and address: one step
        await editor.redo()
        await editor.setNatRole(r, iface: "Gi0/0.10", .inside)
        await editor.edit(.removeSubinterface(node: r, iface: "Gi0/0.10"), key: key)
        #expect(editor.error == EditorError(key: key, message: "Gi0/0.10 has a NAT role"))
        await editor.setNatRole(r, iface: "Gi0/0.10", .off)
        await editor.edit(.removeSubinterface(node: r, iface: "Gi0/0.10"), key: key)
        #expect(node("R1")?.ifaces.map(\.name) == ["Gi0/0", "Gi0/1", "Gi0/2", "Gi0/3"])
    }
}
