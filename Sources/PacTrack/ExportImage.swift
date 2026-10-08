import AppKit
import PacKit
import SwiftUI
import UniformTypeIdentifiers

/// File ▸ Esporta immagine… (spec §8): every device and cable as a PNG at 2×, framed with a margin, as on screen.
@MainActor
enum ExportImage {
    static func png(_ editor: Editor) -> Data? {
        let centers = editor.snapshot.nodes.compactMap { editor.positions[$0.id] }
        guard let r = exportBounds(centers, nodeSize: CanvasView.nodeSize, margin: 40) else { return nil }
        let content = CanvasView(editor: editor, exportOffset: CGSize(width: -r.minX, height: -r.minY))
            .frame(width: r.width, height: r.height)
            .foregroundStyle(Theme.fg)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func save(_ editor: Editor) {
        guard let data = png(editor) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "rete.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
