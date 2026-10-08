import PacEngine
import Testing
@testable import PacKit

@MainActor
@Suite struct TrafficEditorTests {
    let editor = Editor(client: Simulation())

    private func node(_ name: String) -> NodeView { editor.snapshot.nodes.first { $0.name == name }! }

    /// SRV1 (10.0.0.2/24, sink on) cabled to PC1 (10.0.0.1/24).
    private func pair() async -> (srv: String, pc: String) {
        await editor.addDevice(.server, at: Pos(x: 0, y: 0))
        await editor.addDevice(.pc, at: Pos(x: 100, y: 0))
        let (srv, pc) = (node("SRV1").id, node("PC1").id)
        await editor.connect(srv, pc)
        await editor.edit(.setIp(node: srv, iface: "eth0", cidr: "10.0.0.2/24"))
        await editor.edit(.setIp(node: pc, iface: "eth0", cidr: "10.0.0.1/24"))
        await editor.edit(.setSink(node: srv, on: true))
        return (srv, pc)
    }

    @Test func startsTrafficFromTheAppTabFieldsAndShowsTypingErrorsThere() async {
        let (_, pc) = await pair()
        let key = "app:\(pc)"
        await editor.startTraffic(pc, target: "10.0.0.2", kind: .tcp, amount: "1e6", seconds: "")
        #expect(editor.error == EditorError(key: key, message: "Invalid number: \"1e6\""))
        await editor.startTraffic(pc, target: "10.0.0.2", kind: .udp, amount: "1,5", seconds: "dieci")
        #expect(editor.error == EditorError(key: key, message: "Invalid number: \"dieci\""))
        await editor.startTraffic(pc, target: "10.0.0.2", kind: .udp, amount: "5000", seconds: "2")
        #expect(editor.error == EditorError(key: key, message: "Bitrate must be between 1 kb/s and 1 Gb/s"))
        #expect(editor.snapshot.apps.isEmpty)
        await editor.startTraffic(pc, target: "10.0.0.2", kind: .tcp, amount: " 100000 ", seconds: "")
        await editor.startTraffic(pc, target: "10.0.0.2", kind: .udp, amount: "1,5", seconds: "2")
        #expect(editor.error == nil)
        #expect(editor.snapshot.apps.map(\.title) == ["iperf3 -c 10.0.0.2 -p 9 -n 100000", "iperf3 -u -c 10.0.0.2 -p 9 -b 1500000 -t 2"])
        #expect(editor.bottomTab == .events)
    }

    @Test func theSinkIsOneUndoStepAndIsSaved() async {
        let (srv, _) = await pair()
        #expect(node("SRV1").sink)
        #expect(editor.current.nodes.first { $0.id == srv }?.sink == true)
        await editor.undo()
        #expect(!node("SRV1").sink)
    }
}
