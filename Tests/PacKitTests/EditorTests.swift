import PacEngine
import Testing
@testable import PacKit

/// Records every command and forwards it to a real Simulation.
actor Recording: EngineClient {
    let simulation = Simulation()
    private(set) var sent: [String] = []

    func send(_ cmd: Command) async throws -> Snapshot {
        sent.append(cmd.key)
        return try await simulation.send(cmd)
    }

    func advance(wallMs: Double) async -> Snapshot {
        await simulation.advance(wallMs: wallMs)
    }

    private(set) var fetches: [Int] = []

    func events(from seq: Int, epoch: Int) async -> [EventView] {
        fetches.append(seq)
        return await simulation.events(from: seq, epoch: epoch)
    }

    func pdu(_ seq: Int, epoch: Int) async -> [PduLayer]? {
        await simulation.pdu(seq, epoch: epoch)
    }

    func clear() {
        sent = []
        fetches = []
    }
}

@MainActor
@Suite struct EditorTests {
    let client = Recording()
    let editor: Editor
    let origin = Pos(x: 0, y: 0)

    init() {
        editor = Editor(client: client)
    }

    private var names: [String] { editor.snapshot.nodes.map(\.name) }
    private func node(_ name: String) -> NodeView { editor.snapshot.nodes.first { $0.name == name }! }

    @Test func addsDevicesWithDefaultNamesPositionsAndSelection() async {
        await editor.addDevice(.pc, at: Pos(x: 10, y: 20))
        await editor.addDevice(.pc, at: Pos(x: 30, y: 20))
        await editor.addDevice(.router, at: origin)
        #expect(names == ["PC1", "PC2", "R1"])
        #expect(editor.positions[node("PC2").id] == Pos(x: 30, y: 20))
        #expect(editor.selection == .node(node("R1").id))
        #expect(editor.canUndo)
    }

    @Test func connectsThroughTheFirstFreePortsAndReportsFullDevices() async {
        await editor.addDevice(.pc, at: origin)
        await editor.addDevice(.switch, at: origin)
        await editor.addDevice(.pc, at: origin)
        await editor.connect(node("PC1").id, node("SW1").id)
        #expect(editor.snapshot.links.first.map { "\($0.a.iface)-\($0.b.iface)" } == "eth0-Gi0/1")
        await editor.connect(node("PC1").id, node("PC2").id)
        #expect(editor.error == EditorError(key: "connect", message: "PC1 has no free port"))
        #expect(editor.snapshot.links.count == 1)
    }

    @Test func aFailedEditShowsItsErrorAndAddsNoHistory() async {
        await editor.addDevice(.pc, at: origin)
        await editor.undo()
        await editor.redo()
        let ok = await editor.edit(.setIp(node: node("PC1").id, iface: "eth0", cidr: "nope"), key: "ip")
        #expect(!ok)
        #expect(editor.error == EditorError(key: "ip", message: "Invalid CIDR: \"nope\""))
        await editor.undo()
        #expect(names.isEmpty) // the only undo step left is the add
    }

    @Test func undoesAndRedoesAddingADeviceKeepingIdAndPosition() async {
        await editor.addDevice(.pc, at: Pos(x: 5, y: 6))
        let id = node("PC1").id
        await editor.undo()
        #expect(names.isEmpty)
        await editor.redo()
        #expect(node("PC1").id == id)
        #expect(editor.positions[id] == Pos(x: 5, y: 6))
    }

    @Test func deletingANodeWithCablesIsOneStepAndUndoRestoresEverything() async {
        await editor.addDevice(.switch, at: origin)
        await editor.addDevice(.pc, at: origin)
        await editor.addDevice(.pc, at: origin)
        await editor.connect(node("PC1").id, node("SW1").id)
        await editor.connect(node("PC2").id, node("SW1").id)
        let links = editor.snapshot.links
        await editor.remove(nodes: [node("SW1").id], links: links.map(\.id))
        #expect(names == ["PC1", "PC2"])
        #expect(editor.snapshot.links.isEmpty)
        await editor.undo()
        #expect(names == ["SW1", "PC1", "PC2"])
        #expect(editor.snapshot.links == links)
    }

    @Test func undoingAMoveRestoresPositionsWithoutReloadingTheNetwork() async {
        await editor.addDevice(.pc, at: origin)
        let id = node("PC1").id
        editor.moveStart()
        editor.setPosition(id, Pos(x: 100, y: 50))
        editor.moveEnd()
        await client.clear()
        await editor.undo()
        #expect(editor.positions[id] == origin)
        #expect(await client.sent.isEmpty)
    }

    @Test func aClickWithoutMovementAddsNoHistoryAndANewEditClearsRedo() async {
        await editor.addDevice(.pc, at: origin)
        editor.moveStart()
        editor.moveEnd()
        await editor.undo()
        #expect(names.isEmpty && !editor.canUndo && editor.canRedo)
        await editor.addDevice(.hub, at: origin)
        #expect(!editor.canRedo)
    }

    @Test func reportsEveryNetworkChangeToTheDocument() async {
        var saved: [Topology] = []
        editor.onChange = { saved.append($0) }
        await editor.addDevice(.pc, at: origin)
        _ = await editor.run(.setRunning(false))
        await editor.undo()
        #expect(saved.map(\.nodes.count) == [1, 0])
    }

    @Test func loadsADocumentAndClearsHistory() async throws {
        await editor.addDevice(.router, at: Pos(x: 1, y: 2))
        let t = editor.current
        let fresh = Editor(client: Simulation())
        await fresh.load(t)
        #expect(fresh.current == t)
        #expect(!fresh.canUndo)
        var broken = t
        broken.version = 7
        await fresh.load(broken)
        #expect(fresh.error?.key == "file")
        #expect(fresh.current == t)
    }

    @Test func ignoresSnapshotsOlderThanTheOneShown() async {
        await editor.addDevice(.pc, at: origin)
        let shown = editor.snapshot
        editor.accept(Snapshot.empty)
        #expect(editor.snapshot == shown)
    }

    @Test func reopensANetworkWhoseStaticRouteLostItsNextHop() async {
        await editor.addDevice(.pc, at: origin)
        let pc = node("PC1").id
        await editor.edit(.setIp(node: pc, iface: "eth0", cidr: "10.0.0.1/24"))
        await editor.edit(.addRoute(node: pc, cidr: "0.0.0.0/0", nextHop: "10.0.0.254"))
        await editor.edit(.setIp(node: pc, iface: "eth0", cidr: "192.168.1.5/24"))
        let saved = editor.current
        let reopened = Editor(client: Simulation())
        #expect(await reopened.load(saved))
        #expect(reopened.error == nil)
        #expect(reopened.current == saved)
    }

    @Test func overlappingUndosApplyOneAfterTheOther() async {
        await editor.addDevice(.pc, at: origin)
        await editor.addDevice(.pc, at: origin)
        async let first: Void = editor.undo()
        async let second: Void = editor.undo()
        _ = await (first, second)
        #expect(names.isEmpty)
        await editor.redo()
        #expect(names == ["PC1"])
    }

    private func lan() async -> (String, String) {
        await editor.addDevice(.switch, at: origin)
        await editor.addDevice(.pc, at: origin)
        await editor.addDevice(.pc, at: origin)
        await editor.connect(node("SW1").id, node("PC1").id)
        await editor.connect(node("SW1").id, node("PC2").id)
        await editor.edit(.setIp(node: node("PC1").id, iface: "eth0", cidr: "10.0.0.1/24"))
        await editor.edit(.setIp(node: node("PC2").id, iface: "eth0", cidr: "10.0.0.2/24"))
        return (node("PC1").id, node("PC2").id)
    }

    @Test func stepsInSimulationModeAndShowsTheNewPduAndItsFlight() async {
        let (pc1, _) = await lan()
        await editor.run(.setMode(.simulation))
        await editor.run(.ping(node: pc1, target: "10.0.0.2"))
        await editor.step()
        #expect(editor.events.map { "\($0.kind.rawValue) \($0.proto.rawValue)" } == ["tx arp"])
        #expect(editor.selectedEvent == editor.events[0].id)
        #expect(editor.pdu?.map(\.title) == ["Ethernet II", "ARP"])
        #expect(editor.flights.map(\.from) == [pc1])
    }

    @Test func pullsOnlyNewEventsAndClearsThemWhenTheNetworkIsReloaded() async {
        let (pc1, _) = await lan()
        await editor.run(.ping(node: pc1, target: "10.0.0.2"))
        for _ in 0..<5 { await editor.tick(wallMs: 100) }
        let ids = editor.events.map(\.id)
        #expect(!ids.isEmpty && ids == Array(0..<ids.count))
        await client.clear()
        for _ in 0..<10 { await editor.tick(wallMs: 100) } // the second echo goes out at 1 s
        #expect(await client.fetches.first == ids.count)
        await editor.run(.setRunning(false))
        await client.clear()
        await editor.tick(wallMs: 100)
        #expect(await client.fetches.isEmpty)
        await editor.undo() // reloads the network: a new epoch
        #expect(editor.events.isEmpty && editor.flights.isEmpty && editor.selectedEvent == nil)
    }

    @Test func copiesPastesAndDuplicatesADeviceWithItsConfiguration() async {
        await editor.addDevice(.pc, at: Pos(x: 14, y: 14))
        let pc = node("PC1").id
        await editor.edit(.setIp(node: pc, iface: "eth0", cidr: "10.0.0.1/24"))
        await editor.edit(.addRoute(node: pc, cidr: "0.0.0.0/0", nextHop: "10.0.0.254"))
        await editor.edit(.setPower(id: pc, on: false))
        editor.copy(pc)
        await editor.paste(at: nil)
        #expect(names == ["PC1", "PC2"])
        let copy = node("PC2")
        #expect(copy.ifaces[0].cidr == nil && gatewayOf(copy) == nil && !copy.powered) // no duplicate IP on the segment
        #expect(editor.positions[copy.id] == Pos(x: 70, y: 70)) // one node height below: copies never overlap
        #expect(editor.selection == .node(copy.id))
        await editor.paste(at: Pos(x: 140, y: 0))
        #expect(editor.positions[node("PC3").id] == Pos(x: 140, y: 0))
        await editor.duplicate(copy.id)
        #expect(names == ["PC1", "PC2", "PC3", "PC4"])
        #expect(editor.positions[node("PC4").id] == Pos(x: 126, y: 126))
        await editor.undo()
        await editor.undo()
        await editor.undo()
        #expect(names == ["PC1"])
    }

    @Test func setsLinkPropertiesFromTextAndShowsParseErrorsOnTheField() async {
        await editor.addDevice(.pc, at: origin)
        await editor.addDevice(.pc, at: origin)
        await editor.connect(node("PC1").id, node("PC2").id)
        let link = editor.snapshot.links[0].id
        await editor.setLink(link, .bandwidth, "10")
        await editor.setLink(link, .loss, "2,5")
        #expect(editor.snapshot.links[0].options == LinkOptions(bandwidthBps: 10e6, lossRate: 0.025))
        await editor.setLink(link, .delay, "abc")
        #expect(editor.error == EditorError(key: "link:\(link):delay", message: "Invalid number: \"abc\""))
        await editor.setLink(link, .loss, "150")
        #expect(editor.error?.key == "link:\(link):loss" && editor.error?.message.contains("loss rate") == true)
        await editor.undo()
        #expect(editor.snapshot.links[0].options == LinkOptions(bandwidthBps: 10e6))
    }

    @Test func showsAnL2LoopWarningUntilDismissed() async {
        await editor.addDevice(.switch, at: origin)
        await editor.addDevice(.switch, at: origin)
        await editor.addDevice(.pc, at: origin)
        await editor.connect(node("SW1").id, node("SW2").id)
        await editor.connect(node("SW1").id, node("SW2").id)
        await editor.connect(node("PC1").id, node("SW1").id)
        await editor.edit(.setIp(node: node("PC1").id, iface: "eth0", cidr: "10.0.0.1/24"))
        await editor.run(.ping(node: node("PC1").id, target: "10.0.0.9"))
        await editor.tick(wallMs: 10)
        #expect(editor.warning != nil)
        editor.dismissWarning()
        #expect(editor.warning == nil)
    }
}
