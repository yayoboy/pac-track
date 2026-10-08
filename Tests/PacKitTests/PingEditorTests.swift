import PacEngine
import Testing
@testable import PacKit

@MainActor
@Suite struct PingEditorTests {
    let editor = Editor(client: Simulation())

    @Test func pingTakesCountIntervalSizeAndTtlFromTypedFields() async {
        await editor.addDevice(.pc, at: Pos(x: 0, y: 0))
        await editor.addDevice(.pc, at: Pos(x: 112, y: 0))
        let (a, b) = (editor.snapshot.nodes[0].id, editor.snapshot.nodes[1].id)
        await editor.connect(a, b)
        await editor.edit(.setIp(node: a, iface: "eth0", cidr: "10.0.0.1/24"))
        await editor.edit(.setIp(node: b, iface: "eth0", cidr: "10.0.0.2/24"))
        await editor.ping(a, target: "10.0.0.2", count: "2", interval: "0,2", size: "1472", ttl: "")
        for _ in 0..<10 { await editor.tick(wallMs: 100) }
        let lines = editor.snapshot.apps.first?.lines ?? []
        #expect(lines.first == "PING 10.0.0.2 (10.0.0.2) 1472(1500) bytes of data.")
        #expect(lines.filter { $0.hasPrefix("1480 bytes from 10.0.0.2") }.count == 2)
        #expect(lines.contains("2 packets transmitted, 2 received, 0% packet loss"))
        await editor.ping(a, target: "10.0.0.2", count: "due", interval: "1", size: "56", ttl: "")
        #expect(editor.error == EditorError(key: "app:\(a)", message: "Invalid number: \"due\""))
        await editor.ping(a, target: "10.0.0.2", count: "1", interval: "1", size: "56", ttl: "0")
        #expect(editor.error == EditorError(key: "app:\(a)", message: "Invalid ping option: TTL must be between 1 and 255"))
        #expect(editor.snapshot.apps.count == 1)
    }
}
