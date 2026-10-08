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
}
