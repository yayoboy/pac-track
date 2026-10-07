import PacEngine
import PacKit
import SwiftUI

struct InspectorView: View {
    @Bindable var editor: Editor

    var body: some View {
        ScrollView {
            switch editor.selection {
            case .node(let id):
                if let node = editor.snapshot.nodes.first(where: { $0.id == id }) {
                    NodeInspector(node: node, editor: editor).id(node.id)
                }
            case .link(let id):
                if let link = editor.snapshot.links.first(where: { $0.id == id }) {
                    LinkInspector(link: link, editor: editor)
                }
            case nil:
                Text("Seleziona un dispositivo o un collegamento.").foregroundStyle(Theme.muted).padding(12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.panel)
        .accessibilityIdentifier("inspector")
    }
}

private enum Tab: String, CaseIterable {
    case interfaces = "Interfacce", ports = "Porte", routing = "Routing", tables = "Tabelle", app = "App"
}

private struct NodeInspector: View {
    let node: NodeView
    @Bindable var editor: Editor
    @State private var tab: Tab

    init(node: NodeView, editor: Editor) {
        self.node = node
        self.editor = editor
        _tab = State(initialValue: node.kind.hasIp ? .interfaces : .ports)
    }

    private var tabs: [Tab] {
        node.kind.hasIp ? [.interfaces, .routing, .tables, .app] : node.kind == .switch ? [.ports, .tables] : [.ports]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 8) {
                Image(systemName: node.kind.symbol).font(.system(size: 16))
                CommitField(label: node.kind.label, value: node.name, errorKey: "name:\(node.id)", editor: editor) {
                    await editor.edit(.rename(id: node.id, name: $0), key: "name:\(node.id)")
                }
            }
            Picker("", selection: $tab) { ForEach(tabs, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented)
                .labelsHidden()
            switch tab {
            case .interfaces: interfaces
            case .ports: ports
            case .routing: RoutingTab(node: node, editor: editor)
            case .tables: tables
            case .app: AppTab(node: node, editor: editor)
            }
        }
        .padding(12)
    }

    private var interfaces: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(node.ifaces, id: \.name) { iface in
                let key = "ip:\(node.id):\(iface.name)"
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(iface.name).foregroundStyle(Theme.fgStrong)
                        Spacer()
                        Text(iface.linked ? "● collegata" : "○ libera").foregroundStyle(iface.linked ? Theme.ok : Theme.muted)
                    }
                    .font(.system(size: 11))
                    CommitField(label: "Indirizzo IPv4 / prefisso", value: iface.cidr ?? "", placeholder: "192.168.1.10/24", errorKey: key, editor: editor) { text in
                        let trimmed = text.trimmingCharacters(in: .whitespaces)
                        await editor.edit(.setIp(node: node.id, iface: iface.name, cidr: trimmed.isEmpty ? nil : trimmed), key: key)
                    }
                    Text("MAC \(iface.mac)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private var ports: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(node.ifaces, id: \.name) { iface in
                HStack {
                    Text(iface.name)
                    Spacer()
                    Text(iface.linked ? "● collegata" : "○ libera").foregroundStyle(iface.linked ? Theme.ok : Theme.muted)
                }
                .font(Theme.mono)
            }
        }
    }

    private var tables: some View {
        VStack(alignment: .leading, spacing: 14) {
            if node.kind == .switch {
                TableSection(title: "Tabella MAC", head: ["MAC", "Porta", "Età"], rows: node.mac.map { [$0.mac, $0.iface, "\($0.ageS)s"] })
            } else {
                TableSection(title: "Tabella di routing", head: ["Destinazione", "Next hop", "Int."],
                             rows: node.routes.map { [$0.dest, $0.nextHop ?? "connessa", $0.iface] })
                TableSection(title: "Cache ARP", head: ["IP", "MAC", "Int.", "TTL"], rows: node.arp.map { [$0.ip, $0.mac, $0.iface, "\($0.ttlS)s"] })
            }
        }
    }
}

private struct RoutingTab: View {
    let node: NodeView
    @Bindable var editor: Editor
    @State private var cidr = ""
    @State private var via = ""

    var body: some View {
        let gateway = gatewayOf(node) ?? ""
        let gwKey = "gw:\(node.id)"
        let routeKey = "route:\(node.id)"
        VStack(alignment: .leading, spacing: 14) {
            CommitField(label: "Gateway predefinito", value: gateway, placeholder: "192.168.1.1", errorKey: gwKey, editor: editor) { text in
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    await editor.edit(.addRoute(node: node.id, cidr: "0.0.0.0/0", nextHop: trimmed), key: gwKey)
                } else if !gateway.isEmpty {
                    await editor.edit(.removeRoute(node: node.id, cidr: "0.0.0.0/0"), key: gwKey)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("ROUTE STATICHE").font(.system(size: 9)).foregroundStyle(Theme.muted)
                let statics = node.routes.filter { $0.isStatic && $0.dest != "0.0.0.0/0" }
                if statics.isEmpty { Text("nessuna").font(Theme.small).foregroundStyle(Theme.muted) }
                ForEach(statics, id: \.dest) { route in
                    HStack {
                        Text("\(route.dest) via \(route.nextHop ?? "-")").font(Theme.mono)
                        Spacer()
                        Button { Task { await editor.edit(.removeRoute(node: node.id, cidr: route.dest), key: routeKey) } } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .help("Rimuovi route")
                    }
                }
                HStack {
                    TextField("10.0.2.0/24", text: $cidr).textFieldStyle(.roundedBorder).font(Theme.mono)
                    TextField("next hop", text: $via).textFieldStyle(.roundedBorder).font(Theme.mono)
                    Button("+") {
                        Task {
                            if await editor.edit(.addRoute(node: node.id, cidr: cidr, nextHop: via), key: routeKey) {
                                cidr = ""
                                via = ""
                            }
                        }
                    }
                }
                ErrorLine(editor: editor, key: routeKey)
            }
        }
    }
}

private struct AppTab: View {
    let node: NodeView
    @Bindable var editor: Editor
    @State private var target = ""

    var body: some View {
        let key = "app:\(node.id)"
        VStack(alignment: .leading, spacing: 8) {
            Text("Destinazione").font(Theme.small).foregroundStyle(Theme.muted)
            TextField("10.0.0.2", text: $target).textFieldStyle(.roundedBorder).font(Theme.mono).accessibilityIdentifier("app-target")
            HStack {
                Button("Ping") { Task { await editor.run(.ping(node: node.id, target: target), key: key) } }
                Button("Traceroute") { Task { await editor.run(.traceroute(node: node.id, target: target), key: key) } }
            }
            ErrorLine(editor: editor, key: key)
            Text("L'output compare nel pannello in basso.").font(Theme.small).foregroundStyle(Theme.muted)
        }
    }
}

private struct LinkInspector: View {
    let link: LinkView
    @Bindable var editor: Editor

    var body: some View {
        let name = { (id: String) in editor.snapshot.nodes.first { $0.id == id }?.name ?? "?" }
        VStack(alignment: .leading, spacing: 10) {
            Text("Collegamento Ethernet").foregroundStyle(Theme.fgStrong)
            Text("\(name(link.a.node)) \(link.a.iface) ↔ \(name(link.b.node)) \(link.b.iface)").font(Theme.mono)
            Text("1 Gb/s · 500 ns (modificabile nella prossima versione)").font(Theme.small).foregroundStyle(Theme.muted)
            Button("Scollega", role: .destructive) { Task { await editor.remove(nodes: [], links: [link.id]) } }
        }
        .padding(12)
    }
}
