import AppKit
import PacEngine
import PacKit
import SwiftUI

/// `PacTrack --selftest out.png`: drives the real Editor + Simulation, renders the window offscreen, exits 0/1.
@MainActor
enum SelfTest {
    static func run(output: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let failures = await scenario(output: output)
            print(failures.isEmpty ? "SELFTEST OK" : "SELFTEST FAIL: " + failures.joined(separator: "; "))
            exit(failures.isEmpty ? 0 : 1)
        }
        app.run()
        exit(1)
    }

    private static func scenario(output: String) async -> [String] {
        var failures: [String] = []
        let editor = Editor(client: Simulation())
        for _ in 0..<5 { await editor.tick(wallMs: 100) }
        if editor.snapshot.timeNs != 500_000_000 { failures.append("clock at \(editor.snapshot.timeNs) ns, expected 500 ms") }

        await editor.addDevice(.switch, at: Pos(x: 560, y: 140))
        await editor.addDevice(.pc, at: Pos(x: 380, y: 340))
        await editor.addDevice(.pc, at: Pos(x: 740, y: 340))
        let id = { (name: String) in editor.snapshot.nodes.first { $0.name == name }?.id ?? "" }
        await editor.connect(id("SW1"), id("PC1"))
        await editor.connect(id("SW1"), id("PC2"))
        if editor.snapshot.links.count != 2 { failures.append("expected 2 cables, got \(editor.snapshot.links.count)") }
        if !render(editor, to: output) { failures.append("could not write \(output)") }
        return failures
    }

    static func render(_ editor: Editor, to path: String) -> Bool {
        let size = NSSize(width: 1400, height: 860)
        let host = NSHostingView(rootView: MainContent(editor: editor).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3)) // let SwiftUI finish layout
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
