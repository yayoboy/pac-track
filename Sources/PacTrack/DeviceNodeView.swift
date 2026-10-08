import AppKit
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
    @State private var dragStart: [String: Pos]?

    var body: some View {
        let selected = editor.selectedNodes.contains(node.id)
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
        .onTapGesture {
            // Shift-click adds the device to the selection or takes it out (spec §7.1 ③).
            if NSEvent.modifierFlags.contains(.shift) { editor.toggle(node.id) } else { editor.select(.node(node.id)) }
        }
        .contextMenu { NodeMenu(node: node, editor: editor) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("node-\(node.name)")
    }

    /// Sposta: moves the device, or every selected device when it is one of them, one undo step per drag.
    /// Collega: draws a cable from the device to the one under the pointer.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(CanvasView.space))
            .onChanged { value in
                if editor.tool == .connect {
                    wire = Wire(from: node.id, to: value.location)
                    return
                }
                if dragStart == nil {
                    if !editor.selectedNodes.contains(node.id) { editor.select(.node(node.id)) }
                    dragStart = Dictionary(uniqueKeysWithValues: editor.selectedNodes.map { ($0, editor.positions[$0] ?? Pos(x: 0, y: 0)) })
                    editor.moveStart()
                }
                for (id, start) in dragStart ?? [:] {
                    editor.setPosition(id, editor.aligned(Pos(x: start.x + value.translation.width / zoom, y: start.y + value.translation.height / zoom)))
                }
            }
            .onEnded { value in
                if editor.tool == .connect {
                    wire = nil
                    if let target = nodeAt(value.location), target != node.id { Task { await editor.connect(node.id, target) } }
                    return
                }
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
        let group = editor.selectedNodes
        if group.count > 1 && group.contains(node.id) {
            groupMenu(group)
        } else {
            single
        }
    }

    /// Spec §7.2: only what makes sense for several devices at once.
    @ViewBuilder
    private func groupMenu(_ ids: [String]) -> some View {
        let anyOn = editor.snapshot.nodes.contains { ids.contains($0.id) && $0.powered }
        Button("Duplica") { Task { await editor.duplicate(ids) } }
        Button("Copia") { editor.copy(ids) }
        Button(anyOn ? "Spegni" : "Accendi") { Task { await editor.edit(ids.map { .setPower(id: $0, on: !anyOn) }) } }
        Divider()
        Button("Elimina", role: .destructive) { Task { await editor.remove(nodes: ids, links: []) } }
    }

    /// One device (spec §7.2): the previous menu plus *Mostra tabelle*.
    @ViewBuilder
    private var single: some View {
        Button("Apri ispettore") { editor.select(.node(node.id)) }
        if inspectorTabs(for: node.kind).contains(.tables) {
            Button("Mostra tabelle") {
                editor.select(.node(node.id))
                editor.inspectorTab = .tables
            }
        }
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
