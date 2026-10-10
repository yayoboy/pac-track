import PacEngine
import PacKit
import SwiftUI

/// Event list (filterable by protocol and node) beside the PDU inspector.
struct EventsPanel: View {
    @Bindable var editor: Editor
    @State private var protos = Set(Proto.allCases)
    @State private var node: String?

    static let widths: [CGFloat] = [104, 38, 40, 130]

    var body: some View {
        let shown = filterEvents(editor.events, protos: protos, node: node)
        HSplitView {
            VStack(spacing: 0) {
                filters(count: shown.count)
                Divider()
                list(shown)
            }
            .frame(minWidth: 440)
            PduInspector(editor: editor)
                .frame(minWidth: 240, idealWidth: 330, maxWidth: 420)
        }
    }

    private func filters(count: Int) -> some View {
        HStack(spacing: 6) {
            // Chips never wrap: when the panel is narrower than all of them, the row scrolls sideways.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Proto.allCases, id: \.self) { p in
                        let on = protos.contains(p)
                        Button {
                            if on { protos.remove(p) } else { protos.insert(p) }
                        } label: {
                            Text(p.label)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Theme.proto(p).opacity(on ? 0.22 : 0)))
                                .overlay(Capsule().stroke(Theme.proto(p).opacity(on ? 1 : 0.35)))
                                .foregroundStyle(on ? Theme.proto(p) : Theme.muted)
                        }
                        .buttonStyle(.plain)
                        .help(on ? "Nascondi \(p.label)" : "Mostra \(p.label)")
                        .accessibilityIdentifier("filter-\(p.rawValue)")
                    }
                }
                .padding(.vertical, 1) // room for the capsule strokes
            }
            Picker("Nodo", selection: $node) {
                Text("Tutti i nodi").tag(String?.none)
                ForEach(editor.snapshot.nodes) { Text($0.name).tag(Optional($0.id)) }
            }
            .labelsHidden()
            .frame(width: 110)
            Text("\(count) eventi").font(Theme.small).foregroundStyle(Theme.muted).fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func list(_ shown: [EventView]) -> some View {
        let names = Dictionary(uniqueKeysWithValues: editor.snapshot.nodes.map { ($0.id, $0.name) })
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if shown.isEmpty {
                        Text("Nessun evento: avvia il tempo o fai un ping (in Simulation premi Passo).")
                            .foregroundStyle(Theme.muted)
                            .padding(10)
                    }
                    ForEach(shown) { e in
                        EventRow(event: e, node: names[e.node] ?? "(rimosso)", selected: editor.selectedEvent == e.id)
                            .id(e.id)
                            .contentShape(Rectangle())
                            .onTapGesture { Task { await editor.selectEvent(e.id) } }
                    }
                }
                .font(.system(size: 10, design: .monospaced))
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: shown.last?.id) { _, last in
                if let last { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
        .accessibilityIdentifier("events")
    }
}

private struct EventRow: View {
    let event: EventView
    let node: String
    let selected: Bool

    var body: some View {
        let w = EventsPanel.widths
        HStack(spacing: 8) {
            Text(formatSimTime(event.timeNs)).foregroundStyle(Theme.muted).frame(width: w[0], alignment: .trailing)
            Text(event.kind.label).foregroundStyle(event.kind == .drop ? Theme.err : Theme.muted).frame(width: w[1], alignment: .leading)
            Text(event.proto.label).foregroundStyle(Theme.proto(event.proto)).frame(width: w[2], alignment: .leading)
            Text("\(node) \(event.iface ?? "")").lineLimit(1).frame(width: w[3], alignment: .leading)
            Text((event.reason.map { "[\($0)] " } ?? "") + event.info + " · \(event.bytes) B").lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(selected ? Theme.accent.opacity(0.35) : Color.clear)
    }
}

/// The selected frame, header by header, with real field values (spec §7.1 ⑤).
struct PduInspector: View {
    let editor: Editor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if editor.selectedEvent == nil {
                    Text("Seleziona un evento per vederne la PDU header per header.").foregroundStyle(Theme.muted)
                } else if let layers = editor.pdu {
                    ForEach(layers.indices, id: \.self) { PduLayerView(layer: layers[$0]) }
                } else {
                    Text("PDU non più disponibile nel registro eventi.").foregroundStyle(Theme.muted)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg)
        .accessibilityIdentifier("pdu-inspector")
    }
}

private struct PduLayerView: View {
    let layer: PduLayer
    @State private var open = true

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                ForEach(layer.fields.indices, id: \.self) { i in
                    GridRow {
                        Text(layer.fields[i].name).foregroundStyle(Theme.muted)
                        Text(layer.fields[i].value).foregroundStyle(Theme.fgStrong).textSelection(.enabled)
                    }
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .padding(.leading, 4)
        } label: {
            Text("\(layer.title) · \(layer.bytes) B").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.fgStrong)
        }
    }
}
