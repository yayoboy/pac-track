import PacEngine
import Testing
@testable import PacKit

@MainActor
@Suite struct Ipv6ServicesEditorTests {
    let editor = Editor(client: Simulation())

    private func node(_ name: String) -> NodeView { editor.snapshot.nodes.first { $0.name == name }! }

    @Test func theAdvertisedServerIsSavedAndUndoneButNotCopied() async {
        await editor.addDevice(.router, at: Pos(x: 0, y: 0))
        let r = node("R1").id
        await editor.edit(.setRdnss(node: r, server: "2001:db8:2::53"))
        #expect(editor.current.nodes[0].rdnss == "2001:db8:2::53")
        await editor.duplicate([r])
        #expect(node("R2").rdnss == nil) // like ipv6 unicast-routing (spec M9 §10)
        await editor.undo()
        await editor.undo()
        #expect(editor.current.nodes[0].rdnss == nil)
    }
}
