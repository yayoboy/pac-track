import PacEngine
import PacKit
import SwiftUI

struct CanvasView: View {
    static let space = "canvas"
    static let nodeSize = CGSize(width: 104, height: 46)
    private static let grid: CGFloat = 14

    @Bindable var editor: Editor
    @State private var offset = CGSize.zero
    @State private var zoom: CGFloat = 1
    @State private var panStart: CGSize?
    @State private var zoomStart: CGFloat?
    @State private var wire: Wire?
    @State private var hover = CGPoint.zero

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                background
                ForEach(editor.snapshot.links) { link in cable(link) }
                // Under the nodes: a PDU leaves from and disappears into its device.
                if !editor.flights.isEmpty {
                    TimelineView(.animation) { context in
                        let now = context.date.timeIntervalSinceReferenceDate
                        // An explicit ZStack: several children directly inside a TimelineView are stacked like a VStack.
                        ZStack(alignment: .topLeading) {
                            ForEach(editor.flights) { flight in
                                if let link = editor.snapshot.links.first(where: { $0.id == flight.link }) {
                                    let a = center(flight.from)
                                    let b = center(link.a.node == flight.from ? link.b.node : link.a.node)
                                    let t = flightProgress(flight, now: now)
                                    PduTag(proto: flight.proto).position(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .allowsHitTesting(false)
                }
                ForEach(editor.snapshot.nodes) { node in
                    DeviceNodeView(node: node, editor: editor, zoom: zoom, center: center(node.id), nodeAt: nodeAt, wire: $wire)
                }
                if let wire {
                    Path { p in
                        p.move(to: center(wire.from))
                        p.addLine(to: wire.to)
                    }
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .allowsHitTesting(false)
                }
            }
            .coordinateSpace(.named(Self.space))
            .clipped()
            .onContinuousHover(coordinateSpace: .named(Self.space)) { phase in
                if case .active(let p) = phase { hover = p }
            }
            .dropDestination(for: String.self) { items, location in
                guard let kind = items.first.flatMap(DeviceKind.init(rawValue:)) else { return false }
                Task { await editor.addDevice(kind, at: snap(toWorld(location))) }
                return true
            }
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        let start = zoomStart ?? zoom
                        zoomStart = start
                        zoom = min(max(start * value.magnification, 0.3), 3)
                    }
                    .onEnded { _ in zoomStart = nil }
            )
            .contextMenu { paneMenu(size: geo.size) }
            .focusable()
            .focusEffectDisabled()
            .onDeleteCommand { Task { await editor.deleteSelection() } }
            .onKeyPress(.space) {
                Task { await editor.run(.setRunning(!editor.snapshot.running)) }
                return .handled
            }
            .onKeyPress(KeyEquivalent(".")) {
                guard editor.snapshot.mode == .simulation else { return .ignored }
                Task { await editor.step() }
                return .handled
            }
        }
    }

    // MARK: geometry

    private func toScreen(_ p: Pos) -> CGPoint {
        CGPoint(x: p.x * zoom + offset.width, y: p.y * zoom + offset.height)
    }

    private func toWorld(_ p: CGPoint) -> Pos {
        Pos(x: (p.x - offset.width) / zoom, y: (p.y - offset.height) / zoom)
    }

    private func center(_ id: String) -> CGPoint {
        toScreen(editor.positions[id] ?? Pos(x: 0, y: 0))
    }

    private func nodeAt(_ point: CGPoint) -> String? {
        let w = Self.nodeSize.width * zoom
        let h = Self.nodeSize.height * zoom
        return editor.snapshot.nodes.last { node in
            let c = center(node.id)
            return CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h).contains(point)
        }?.id
    }

    private func fit(_ size: CGSize) {
        let points = editor.snapshot.nodes.compactMap { editor.positions[$0.id] }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return }
        zoom = min(max(min(size.width / (maxX - minX + 240), size.height / (maxY - minY + 160)), 0.3), 1.5)
        offset = CGSize(width: size.width / 2 - (minX + maxX) / 2 * zoom, height: size.height / 2 - (minY + maxY) / 2 * zoom)
    }

    // MARK: layers

    private var background: some View {
        Canvas { ctx, size in
            let step = Self.grid * zoom
            guard step >= 6 else { return }
            var x0 = offset.width.truncatingRemainder(dividingBy: step)
            if x0 < 0 { x0 += step }
            var y0 = offset.height.truncatingRemainder(dividingBy: step)
            if y0 < 0 { y0 += step }
            for x in stride(from: x0, through: size.width, by: step) {
                for y in stride(from: y0, through: size.height, by: step) {
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.2, height: 1.2)), with: .color(Theme.border))
                }
            }
        }
        .background(Theme.bg)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    let start = panStart ?? offset
                    panStart = start
                    offset = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                }
                .onEnded { _ in panStart = nil }
        )
        .onTapGesture { editor.select(nil) }
    }

    private func cable(_ link: LinkView) -> some View {
        let a = center(link.a.node)
        let b = center(link.b.node)
        let selected = editor.selection == .link(link.id)
        let line = Path { p in
            p.move(to: a)
            p.addLine(to: b)
        }
        return ZStack {
            line.stroke(selected ? Theme.accent : link.up ? Theme.muted : Theme.err, style: StrokeStyle(lineWidth: selected ? 2.5 : 1.5, dash: link.up ? [] : [5, 4]))
            Text("\(link.a.iface) ↔ \(link.b.iface) · \(formatBandwidth(link.options.bandwidthBps))")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 3)
                .background(Theme.bg)
                .position(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        .contentShape(line.strokedPath(StrokeStyle(lineWidth: 12)))
        .onTapGesture { editor.select(.link(link.id)) }
        .contextMenu {
            Button("Proprietà") { editor.select(.link(link.id)) }
            Button(link.up ? "Simula guasto" : "Ripristina") { Task { await editor.edit(.setLinkUp(id: link.id, up: !link.up)) } }
            Divider()
            Button("Scollega", role: .destructive) { Task { await editor.remove(nodes: [], links: [link.id]) } }
        }
        .accessibilityIdentifier("link-\(link.a.iface)-\(link.b.iface)")
    }

    @ViewBuilder
    private func paneMenu(size: CGSize) -> some View {
        Menu("Aggiungi dispositivo") {
            ForEach(DeviceKind.allCases, id: \.self) { kind in
                Button { Task { await editor.addDevice(kind, at: snap(toWorld(hover))) } } label: { Label(kind.label, systemImage: kind.symbol) }
            }
        }
        Button("Incolla") {
            let at = snap(toWorld(hover))
            Task { await editor.paste(at: at) }
        }
        Button("Adatta alla vista") { fit(size) }
    }
}

/// A PDU on a cable: protocol name on its spec color.
private struct PduTag: View {
    let proto: Proto

    var body: some View {
        Text(proto.label)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .foregroundStyle(Theme.bg)
            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.proto(proto)))
    }
}
