import PacEngine
import Testing
@testable import PacKit

@MainActor
@Suite struct SelectionEditorTests {
    let editor = Editor(client: Simulation())

    private var names: [String] { editor.snapshot.nodes.map(\.name) }
    private func id(_ name: String) -> String { editor.snapshot.nodes.first { $0.name == name }!.id }

    private func threePcs() async {
        for x in [0.0, 112, 224] { await editor.addDevice(.pc, at: Pos(x: x, y: 0)) }
    }

    @Test func shiftClicksBuildAMultipleSelectionAndSelectAllTakesEveryDevice() async {
        await threePcs()
        editor.select(.node(id("PC1")))
        editor.toggle(id("PC3"))
        #expect(editor.selection == .nodes([id("PC1"), id("PC3")]))
        #expect(editor.selectedNodes == [id("PC1"), id("PC3")])
        editor.toggle(id("PC1"))
        #expect(editor.selection == .node(id("PC3"))) // one left: an ordinary selection, the inspector shows it
        editor.toggle(id("PC3"))
        #expect(editor.selection == nil && editor.selectedNodes.isEmpty)
        editor.select(.link("x"))
        editor.toggle(id("PC2")) // a cable is not a device: shift-click starts over
        #expect(editor.selection == .node(id("PC2")))
        editor.selectAll()
        #expect(editor.selectedNodes == [id("PC1"), id("PC2"), id("PC3")])
        editor.select(nodes: [])
        #expect(editor.selection == nil)
    }

    @Test func aShiftRectangleAddsToTheSelection() async {
        await threePcs()
        editor.select(.node(id("PC1")))
        editor.extendSelection(with: [id("PC1"), id("PC3")]) // already selected devices are not listed twice
        #expect(editor.selection == .nodes([id("PC1"), id("PC3")]))
        editor.select(.link("x"))
        editor.extendSelection(with: [id("PC2")]) // a cable is not a device: the rectangle starts over
        #expect(editor.selection == .node(id("PC2")))
    }

    @Test func duplicatesPowersAndDeletesSeveralDevicesAsOneStepEach() async {
        await threePcs()
        let pcs = [id("PC1"), id("PC3")]
        await editor.duplicate(pcs)
        #expect(names == ["PC1", "PC2", "PC3", "PC4", "PC5"]) // distinct names in one step
        #expect(editor.positions[id("PC4")] == Pos(x: 56, y: 56) && editor.positions[id("PC5")] == Pos(x: 280, y: 56))
        #expect(editor.selection == .nodes([id("PC4"), id("PC5")]))
        await editor.edit(editor.selectedNodes.map { .setPower(id: $0, on: false) })
        #expect(editor.snapshot.nodes.map(\.powered) == [true, true, true, false, false])
        editor.select(nodes: [id("PC4"), id("PC5")])
        await editor.deleteSelection()
        #expect(names == ["PC1", "PC2", "PC3"])
        await editor.undo()
        #expect(names == ["PC1", "PC2", "PC3", "PC4", "PC5"])
        await editor.undo()
        #expect(editor.snapshot.nodes.allSatisfy { $0.powered })
        await editor.undo()
        #expect(names == ["PC1", "PC2", "PC3"])
    }
}
