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
                    LinkInspector(link: link, editor: editor).id(link.id)
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

private struct NodeInspector: View {
    let node: NodeView
    @Bindable var editor: Editor
    var body: some View {
        let tabs = inspectorTabs(for: node.kind)
        let tab = editor.inspectorTab.flatMap { tabs.contains($0) ? $0 : nil } ?? tabs[0]
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 8) {
                Image(systemName: node.kind.symbol).font(.system(size: 16))
                CommitField(label: node.kind.label, value: node.name, errorKey: "name:\(node.id)", editor: editor) {
                    await editor.edit(.rename(id: node.id, name: $0), key: "name:\(node.id)")
                }
                Button { Task { await editor.edit(.setPower(id: node.id, on: !node.powered)) } } label: {
                    Image(systemName: "power").foregroundStyle(node.powered ? Theme.ok : Theme.err)
                }
                .buttonStyle(.borderless)
                .help(node.powered ? "Spegni" : "Accendi")
                .accessibilityIdentifier("power")
            }
            Picker("", selection: Binding(get: { tab }, set: { editor.inspectorTab = $0 })) {
                ForEach(tabs, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            switch tab {
            case .interfaces: interfaces
            case .ports: ports
            case .routing: RoutingTab(node: node, editor: editor)
            case .services: ServicesTab(node: node, editor: editor)
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
                let modeKey = "mode:\(node.id):\(iface.name)"
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(iface.name).foregroundStyle(Theme.fgStrong)
                        Spacer()
                        Text(iface.linked ? "● collegata" : "○ libera").foregroundStyle(iface.linked ? Theme.ok : Theme.muted)
                    }
                    .font(.system(size: 11))
                    if node.kind.isHost {
                        Picker("", selection: Binding(get: { iface.mode }, set: { mode in
                            Task { await editor.edit(.setIfaceMode(node: node.id, iface: iface.name, mode: mode), key: modeKey) }
                        })) {
                            Text("Statico").tag(IfaceMode.`static`)
                            Text("DHCP").tag(IfaceMode.dhcp)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        .accessibilityIdentifier("mode-\(iface.name)")
                        ErrorLine(editor: editor, key: modeKey)
                    }
                    if iface.mode == .dhcp {
                        Text("Indirizzo IPv4 (da DHCP)").font(Theme.small).foregroundStyle(Theme.muted)
                        Text(iface.cidr ?? "in attesa…").font(Theme.mono).foregroundStyle(iface.cidr == nil ? Theme.muted : Theme.fgStrong)
                        if let client = node.dhcpClient {
                            Text(dhcpStatus(client)).font(Theme.small).foregroundStyle(Theme.muted)
                        }
                    } else {
                        CommitField(label: "Indirizzo IPv4 / prefisso", value: iface.cidr ?? "", placeholder: "192.168.1.10/24", errorKey: key, editor: editor) { text in
                            let trimmed = text.trimmingCharacters(in: .whitespaces)
                            await editor.edit(.setIp(node: node.id, iface: iface.name, cidr: trimmed.isEmpty ? nil : trimmed), key: key)
                        }
                    }
                    Text("MAC \(iface.mac)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
                }
            }
            if node.kind.isHost {
                let key = "dns:\(node.id)"
                CommitField(label: "Server DNS", value: node.nameServer ?? "",
                            placeholder: node.learnedNameServer.map { "\($0) (da DHCP)" } ?? "10.0.0.53", errorKey: key, editor: editor) { text in
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    await editor.edit(.setNameServer(node: node.id, ip: trimmed.isEmpty ? nil : trimmed), key: key)
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
                             rows: node.routes.map { [$0.dest, ($0.nextHop ?? "connessa") + ($0.dhcp ? " (DHCP)" : ""), $0.iface] })
                TableSection(title: "Cache ARP", head: ["IP", "MAC", "Int.", "TTL"], rows: node.arp.map { [$0.ip, $0.mac, $0.iface, "\($0.ttlS)s"] })
                TableSection(title: "Connessioni TCP", head: ["Locale", "Remoto", "Stato"], rows: node.tcp.map { [$0.local, $0.remote, $0.state] })
                if node.nat != nil {
                    // Two lines per entry, so all five fields fit the 300 pt column; the scroll only catches the longest addresses.
                    ScrollView(.horizontal) {
                        TableSection(title: "Traduzioni NAT", head: ["Proto", "Inside locale\nInside globale", "Outside\nTTL"],
                                     rows: node.natTable.map { [$0.proto, "\($0.insideLocal)\n\($0.insideGlobal)", "\($0.outside)\n\($0.ttlS)s"] })
                    }
                }
                if node.kind.isHost {
                    TableSection(title: "Cache DNS", head: ["Nome", "IP", "TTL"], rows: node.dnsCache.map { [$0.name, $0.ip, "\($0.ttlS)s"] })
                }
                if node.dhcpServer != nil {
                    TableSection(title: "Lease DHCP", head: ["IP", "MAC", "Scade", "Stato"], rows: leaseRows(node.leases))
                }
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
    @State private var kind = TrafficKind.tcp
    @State private var amount = "1000000"
    @State private var seconds = "10"

    var body: some View {
        let key = "app:\(node.id)"
        VStack(alignment: .leading, spacing: 8) {
            Text("Destinazione").font(Theme.small).foregroundStyle(Theme.muted)
            TextField("10.0.0.2 o nome host", text: $target).textFieldStyle(.roundedBorder).font(Theme.mono).accessibilityIdentifier("app-target")
            HStack {
                Button("Ping") { Task { await editor.run(.ping(node: node.id, target: target), key: key) } }
                Button("Traceroute") { Task { await editor.run(.traceroute(node: node.id, target: target), key: key) } }
                Button("nslookup") { Task { await editor.run(.nslookup(node: node.id, name: target), key: key) } }
            }
            ErrorLine(editor: editor, key: key)
            Text("L'output compare nel pannello in basso.").font(Theme.small).foregroundStyle(Theme.muted)
            Divider()
            Text("GENERATORE DI TRAFFICO").font(.system(size: 9)).foregroundStyle(Theme.muted)
            Picker("", selection: $kind) { ForEach(TrafficKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .onChange(of: kind) { _, k in amount = k == .tcp ? "1000000" : "1" }
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind == .tcp ? "Byte da inviare" : "Bitrate (Mb/s)").font(Theme.small).foregroundStyle(Theme.muted)
                    TextField("", text: $amount).textFieldStyle(.roundedBorder).font(Theme.mono).accessibilityIdentifier("traffic-amount")
                }
                if kind == .udp {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Durata (s)").font(Theme.small).foregroundStyle(Theme.muted)
                        TextField("", text: $seconds).textFieldStyle(.roundedBorder).font(Theme.mono).frame(width: 60)
                    }
                }
            }
            Button("Avvia traffico") {
                Task { await editor.startTraffic(node.id, target: target, kind: kind, amount: amount, seconds: seconds) }
            }
            .accessibilityIdentifier("traffic-start")
            Text("Destinazione: un server con il sink attivo (Servizi). Risultati in Output app e Metriche.")
                .font(Theme.small)
                .foregroundStyle(Theme.muted)
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
            Toggle("Collegamento attivo", isOn: Binding(get: { link.up }, set: { up in Task { await editor.edit(.setLinkUp(id: link.id, up: up)) } }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityIdentifier("link-up")
            ForEach(LinkField.allCases, id: \.self) { field in
                CommitField(label: field.label, value: field.format(link.options), errorKey: "link:\(link.id):\(field.rawValue)", editor: editor) {
                    await editor.setLink(link.id, field, $0)
                }
            }
            Button("Scollega", role: .destructive) { Task { await editor.remove(nodes: [], links: [link.id]) } }
        }
        .padding(12)
    }
}
