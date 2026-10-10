@testable import PacEngine // RouteRow's memberwise init
import Testing
@testable import PacKit

@MainActor
@Suite struct OspfEditorTests {
    let editor = Editor(client: Simulation())

    private func node(_ name: String) -> NodeView { editor.snapshot.nodes.first { $0.name == name }! }

    @Test func enablingOspfMakesEveryAddressedInterfaceActiveAndEachSettingIsOneUndoStep() async {
        await editor.addDevice(.router, at: Pos(x: 0, y: 0))
        let r = node("R1").id
        await editor.edit(.setIp(node: r, iface: "Gi0/1", cidr: "10.0.12.1/30"))
        await editor.edit(.setIp(node: r, iface: "Gi0/0", cidr: "192.168.1.1/24"))
        await editor.enableOspf(r, true)
        #expect(node("R1").ospf == OspfConfig(interfaces: [OspfInterfaceConfig(name: "Gi0/0"), OspfInterfaceConfig(name: "Gi0/1")]))
        await editor.setOspfRole(r, iface: "Gi0/0", .passive)
        await editor.setOspfRole(r, iface: "Gi0/2", .active)
        await editor.setOspfRole(r, iface: "Gi0/1", .off)
        await editor.setOspfPointToPoint(r, iface: "Gi0/2", true)
        await editor.setOspfPriority(r, iface: "Gi0/2", " 0 ")
        await editor.setOspfRouterId(r, "1.1.1.1")
        #expect(node("R1").ospf == OspfConfig(routerId: "1.1.1.1", interfaces: [
            OspfInterfaceConfig(name: "Gi0/0", passive: true),
            OspfInterfaceConfig(name: "Gi0/2", pointToPoint: true, priority: 0),
        ]))
        #expect(ospfRole(node("R1").ospf, "Gi0/0") == .passive && ospfRole(node("R1").ospf, "Gi0/1") == .off)
        await editor.setOspfPriority(r, iface: "Gi0/2", "300")
        #expect(editor.error == EditorError(key: "ospf:\(r):Gi0/2", message: "OSPF priority must be between 0 and 255"))
        await editor.setOspfPriority(r, iface: "Gi0/2", "uno")
        #expect(editor.error == EditorError(key: "ospf:\(r):Gi0/2", message: "Invalid number: \"uno\""))
        await editor.setOspfRouterId(r, "1.2.3")
        #expect(editor.error == EditorError(key: "ospf:\(r):rid", message: "Invalid router ID: \"1.2.3\""))
        await editor.setOspfRouterId(r, " ")
        #expect(node("R1").ospf?.routerId == nil) // blank: automatic
        await editor.undo()
        #expect(node("R1").ospf?.routerId == "1.1.1.1")
        #expect(editor.current.nodes[0].ospf == node("R1").ospf)
        await editor.duplicate([r])
        #expect(node("R2").ospf == nil) // a copy has no addresses, so no OSPF (spec M8 §6)
        await editor.enableOspf(r, false)
        #expect(node("R1").ospf == nil)
    }

    @Test func ospfRoutesShowTypeO() async {
        let row = RouteRow(dest: "192.168.2.0/24", nextHop: "10.0.12.2", iface: "Gi0/1", isStatic: false, metric: 2, ospf: true)
        #expect(routeColumns(row) == ["O", "192.168.2.0/24", "[110/2]", "10.0.12.2", "Gi0/1"])
    }
}
