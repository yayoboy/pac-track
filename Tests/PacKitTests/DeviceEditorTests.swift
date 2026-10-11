import PacEngine
import Testing
@testable import PacKit

@MainActor
@Suite struct DeviceEditorTests {
    let editor = Editor(client: Simulation())

    @Test func aSwitchSizeIsOneUndoStepAndCopiesKeepIt() async {
        await editor.addDevice(.switch, at: Pos(x: 0, y: 0))
        let sw = editor.snapshot.nodes[0].id
        await editor.edit(.setPorts(id: sw, count: 24), key: "ports:\(sw)")
        #expect(editor.snapshot.nodes[0].ifaces.count == 24 && editor.current.nodes[0].ifaces.count == 24)
        await editor.duplicate([sw])
        #expect(editor.snapshot.nodes.map(\.ifaces.count) == [24, 24])
        await editor.undo()
        await editor.undo()
        #expect(editor.snapshot.nodes.map(\.ifaces.count) == [8])
        await editor.edit(.setPorts(id: sw, count: 12), key: "ports:\(sw)")
        #expect(editor.error == EditorError(key: "ports:\(sw)", message: "A switch has 8, 24 or 48 ports"))
    }

    @Test func aCloudArrivesPreconfiguredInOneStepAndSurvivesSaving() async {
        await editor.addDevice(.cloud, at: Pos(x: 0, y: 0))
        let isp = editor.snapshot.nodes[0]
        #expect(isp.name == "ISP1" && isp.kind == .cloud)
        #expect(isp.ifaces.map(\.name) == ["Gi0/0", "Gi0/1", "Gi0/2", "Gi0/3"] && isp.ifaces[0].cidr == "203.0.113.1/24")
        #expect(isp.dnsRecords == [DnsRecord(name: "www.example.com", ip: "198.51.100.10")])
        #expect(inspectorTabs(for: .cloud) == [.interfaces, .routing, .services, .tables, .app])
        let saved = editor.current
        await editor.undo()
        #expect(editor.snapshot.nodes.isEmpty) // one step
        let opened = await editor.load(saved)
        #expect(opened && editor.snapshot.nodes[0].kind == .cloud && editor.snapshot.nodes[0].dnsRecords?.count == 1)
        await editor.enableDhcp(editor.snapshot.nodes[0].id, true)
        #expect(editor.snapshot.nodes[0].dhcpServer?.gateway == "203.0.113.1") // the cloud routes: it is the gateway
    }

    @Test func aPrinterArrivesWithTheSinkAndATvInDhcpEachInOneStep() async throws {
        await editor.addDevice(.printer, at: Pos(x: 0, y: 0))
        await editor.addDevice(.tv, at: Pos(x: 100, y: 0))
        let (prn, tv) = (editor.snapshot.nodes[0], editor.snapshot.nodes[1])
        #expect(prn.name == "PRN1" && prn.sink && prn.ifaces.map(\.name) == ["eth0"] && prn.ifaces[0].cidr == nil && prn.ifaces[0].mode == .static)
        #expect(tv.name == "TV1" && !tv.sink && tv.ifaces[0].mode == .dhcp)
        let saved = editor.current
        #expect(try ProjectFile.decode(try ProjectFile.encode(saved)) == saved)
        await editor.undo()
        #expect(editor.snapshot.nodes.map(\.name) == ["PRN1"]) // the TV and its mode in one step
        await editor.undo()
        #expect(editor.snapshot.nodes.isEmpty)
        let opened = await editor.load(saved)
        #expect(opened && editor.snapshot.nodes.map(\.kind) == [.printer, .tv])
        #expect(editor.snapshot.nodes[0].sink && editor.snapshot.nodes[1].ifaces[0].mode == .dhcp)
        // The default is the editor's: a printer saved with the sink off opens with it off.
        await editor.edit(.setSink(node: editor.snapshot.nodes[0].id, on: false))
        let off = editor.current
        _ = await editor.load(off)
        #expect(!editor.snapshot.nodes[0].sink)
    }

    @Test func copiesKeepTheSink() async {
        await editor.addDevice(.printer, at: Pos(x: 0, y: 0))
        await editor.addDevice(.server, at: Pos(x: 100, y: 0))
        await editor.addDevice(.printer, at: Pos(x: 200, y: 0))
        let ids = editor.snapshot.nodes.map(\.id)
        await editor.edit(.setSink(node: ids[1], on: true))
        await editor.edit(.setSink(node: ids[2], on: false))
        await editor.duplicate(ids)
        #expect(editor.snapshot.nodes.map { "\($0.name) \($0.sink)" }
            == ["PRN1 true", "SRV1 true", "PRN2 false", "PRN3 true", "SRV2 true", "PRN4 false"])
    }
}
