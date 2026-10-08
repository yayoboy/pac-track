import PacEngine
import Testing
@testable import PacKit

@MainActor
@Suite struct ToolsEditorTests {
    let editor = Editor(client: Simulation())

    @Test func paletteCablesSetTheLinkInOneStepAndCustomOpensItsProperties() async {
        #expect(CableKind.allCases.map(\.rawValue) == ["Ethernet 1 Gb/s", "Fibra 10 Gb/s", "Personalizzato"])
        await editor.addDevice(.switch, at: Pos(x: 0, y: 0))
        await editor.addDevice(.pc, at: Pos(x: 112, y: 0))
        await editor.addDevice(.pc, at: Pos(x: 224, y: 0))
        let ids = editor.snapshot.nodes.map(\.id)
        editor.cable = .fiber
        await editor.connect(ids[0], ids[1])
        #expect(editor.snapshot.links[0].options == LinkOptions(bandwidthBps: 10e9, propDelayNs: 5_000))
        await editor.undo()
        #expect(editor.snapshot.links.isEmpty) // the cable and its settings: one step
        editor.cable = .custom
        await editor.connect(ids[0], ids[2])
        #expect(editor.snapshot.links[0].options == LinkOptions())
        #expect(editor.selection == .link(editor.snapshot.links[0].id)) // opens in the inspector
        editor.cable = .ethernet
        await editor.connect(ids[0], ids[1])
        #expect(editor.snapshot.links[1].options == LinkOptions() && editor.selection == .link(editor.snapshot.links[0].id))
    }

    @Test func theGridSnapsOnlyWhileShown() {
        #expect(editor.aligned(Pos(x: 20, y: 6)) == Pos(x: 14, y: 0))
        editor.grid = false
        #expect(editor.aligned(Pos(x: 20, y: 6)) == Pos(x: 20, y: 6))
    }
}
