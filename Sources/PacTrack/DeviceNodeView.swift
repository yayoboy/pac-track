import PacEngine
import PacKit
import SwiftUI

struct Wire {
    let from: String
    var to: CGPoint
}

struct DeviceNodeView: View {
    let node: NodeView
    @Bindable var editor: Editor
    let zoom: CGFloat
    let center: CGPoint
    let nodeAt: (CGPoint) -> String?
    @Binding var wire: Wire?
    @State private var dragStart: Pos?

    var body: some View {
        let selected = editor.selection == .node(node.id)
        VStack(spacing: 1) {
            HStack(spacing: 5) {
                Image(systemName: node.kind.symbol).font(.system(size: 11))
                Text(node.name).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.fgStrong)
                Circle().fill(!node.powered ? Theme.err : node.ifaces.contains(where: \.linked) ? Theme.ok : Theme.muted).frame(width: 6, height: 6)
            }
            if let ip = firstIp(node) {
                Text(ip).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
            }
        }
        .frame(width: CanvasView.nodeSize.width, height: CanvasView.nodeSize.height)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Theme.accent : Theme.borderStrong, lineWidth: selected ? 1.5 : 1))
        .overlay(alignment: .bottom) { handle }
        .opacity(node.powered ? 1 : 0.5)
        .scaleEffect(zoom)
        .position(center)
        .gesture(drag)
        .onTapGesture { editor.select(.node(node.id)) }
        .contextMenu { NodeMenu(node: node, editor: editor) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("node-\(node.name)")
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(CanvasView.space))
            .onChanged { value in
                if dragStart == nil {
                    dragStart = editor.positions[node.id] ?? Pos(x: 0, y: 0)
                    editor.moveStart()
                    editor.select(.node(node.id))
                }
                let start = dragStart!
                editor.setPosition(node.id, snap(Pos(x: start.x + value.translation.width / zoom, y: start.y + value.translation.height / zoom)))
            }
            .onEnded { _ in
                dragStart = nil
                editor.moveEnd()
            }
    }

    private var handle: some View {
        Circle()
            .fill(Theme.muted)
            .frame(width: 9, height: 9)
            .offset(y: 4.5)
            .contentShape(Circle().inset(by: -4))
            .highPriorityGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(CanvasView.space))
                    .onChanged { wire = Wire(from: node.id, to: $0.location) }
                    .onEnded { value in
                        wire = nil
                        if let target = nodeAt(value.location), target != node.id {
                            Task { await editor.connect(node.id, target) }
                        }
                    }
            )
            .accessibilityIdentifier("handle-\(node.name)")
    }
}

struct NodeMenu: View {
    let node: NodeView
    let editor: Editor

    /// Other devices that have an address to aim an app at.
    static func targets(for id: String, in nodes: [NodeView]) -> [NodeView] {
        nodes.filter { $0.id != id && firstIp($0) != nil }
    }

    var body: some View {
        Button("Apri ispettore") { editor.select(.node(node.id)) }
        if node.kind.hasIp {
            let targets = Self.targets(for: node.id, in: editor.snapshot.nodes)
            Menu("Ping verso") {
                ForEach(targets) { t in
                    Button("\(t.name)  \(firstIp(t) ?? "")") { Task { await editor.run(.ping(node: node.id, target: firstIp(t) ?? ""), key: "app:\(node.id)") } }
                }
            }
            .disabled(targets.isEmpty || !node.powered)
            Menu("Traceroute verso") {
                ForEach(targets) { t in
                    Button("\(t.name)  \(firstIp(t) ?? "")") { Task { await editor.run(.traceroute(node: node.id, target: firstIp(t) ?? ""), key: "app:\(node.id)") } }
                }
            }
            .disabled(targets.isEmpty || !node.powered)
            if node.kind.isHost {
                Button("Rinnova DHCP") { Task { await editor.run(.renewDhcp(node: node.id), key: "app:\(node.id)") } }
                    .disabled(!node.powered || !node.ifaces.contains { $0.mode == .dhcp })
            }
        }
        Button(node.powered ? "Spegni" : "Accendi") { Task { await editor.edit(.setPower(id: node.id, on: !node.powered)) } }
        Divider()
        Button("Duplica") { Task { await editor.duplicate([node.id]) } }
        Button("Copia") { editor.copy([node.id]) }
        Divider()
        Button("Elimina", role: .destructive) { Task { await editor.remove(nodes: [node.id], links: []) } }
    }
}
