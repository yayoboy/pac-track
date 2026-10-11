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
            case .nodes(let ids):
                Text("\(ids.count) dispositivi selezionati. Trascinane uno per spostarli insieme; con il tasto destro: Duplica, Copia, Spegni/Accendi, Elimina.")
                    .foregroundStyle(Theme.muted)
                    .padding(12)
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
                        Text(iface.name).foregroundStyle(Theme.fgStrong).layoutPriority(1)
                        Spacer()
                        cableEnd(iface)
                        if iface.name.contains(".") {
                            Button("Elimina", role: .destructive) {
                                Task { await editor.edit(.removeSubinterface(node: node.id, iface: iface.name), key: "sub:\(node.id)") }
                            }
                            .buttonStyle(.borderless)
                            .help("Elimina la sottointerfaccia")
                            .accessibilityIdentifier("subif-delete-\(iface.name)")
                        }
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
                        CommitField(label: "Indirizzo IPv4 / prefisso", value: iface.cidr ?? "", placeholder: "192.168.1.10/24",
                                    suggestions: addressSuggestions(IfaceRef(node: node.id, iface: iface.name), in: editor.snapshot), errorKey: key, editor: editor) { text in
                            let trimmed = text.trimmingCharacters(in: .whitespaces)
                            await editor.edit(.setIp(node: node.id, iface: iface.name, cidr: trimmed.isEmpty ? nil : trimmed), key: key)
                        }
                    }
                    Ipv6Fields(node: node, iface: iface, editor: editor)
                    Text("MAC \(iface.mac)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
                }
            }
            if node.kind == .router { SubinterfaceForm(node: node, editor: editor) }
            if node.kind.isHost {
                let key = "dns:\(node.id)"
                CommitField(label: "Server DNS", value: node.nameServer ?? "",
                            placeholder: node.learnedNameServer.map { "\($0) (da \($0.contains(":") ? "RA" : "DHCP"))" } ?? "10.0.0.53", errorKey: key, editor: editor) { text in
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    await editor.edit(.setNameServer(node: node.id, ip: trimmed.isEmpty ? nil : trimmed), key: key)
                }
            }
        }
    }

    private var ports: some View {
        VStack(alignment: .leading, spacing: node.kind == .switch ? 10 : 2) {
            if node.kind == .switch {
                let key = "ports:\(node.id)"
                Picker("Porte", selection: Binding(get: { node.ifaces.count }, set: { n in
                    Task { await editor.edit(.setPorts(id: node.id, count: n), key: key) }
                })) {
                    ForEach(SWITCH_PORTS, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .accessibilityIdentifier("switch-ports")
                ErrorLine(editor: editor, key: key)
            }
            ForEach(node.ifaces, id: \.name) { iface in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(iface.name).layoutPriority(1)
                        Spacer()
                        cableEnd(iface)
                    }
                    .font(Theme.mono)
                    if let port = iface.switchport { SwitchportFields(node: node.id, iface: iface.name, port: port, editor: editor) }
                }
            }
        }
    }

    /// "● SW1 Gi0/2", the device and port at the other end of the cable, or "○ libera"; one line, shortened in the middle.
    private func cableEnd(_ iface: IfaceView) -> some View {
        Text(iface.linked ? "● " + (peerLabel(IfaceRef(node: node.id, iface: iface.name), in: editor.snapshot) ?? "collegata") : "○ libera")
            .foregroundStyle(iface.linked ? Theme.ok : Theme.muted)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var tables: some View {
        VStack(alignment: .leading, spacing: 14) {
            if node.kind == .switch {
                TableSection(title: "Tabella MAC", head: ["VLAN", "MAC", "Porta", "Età"],
                             rows: node.mac.map { ["\($0.vlan)", $0.mac, $0.iface, "\($0.ageS)s"] })
                ForEach(node.stp, id: \.vlan) { st in
                    VStack(alignment: .leading, spacing: 4) {
                        TableSection(title: "Spanning Tree VLAN \(st.vlan)", head: ["Porta", "Ruolo", "Stato"],
                                     rows: st.ports.map { [$0.iface, $0.role.rawValue, $0.state.rawValue] })
                        Text("Root \(st.root) · costo \(st.cost) · " + (st.rootPort.map { "root port \($0)" } ?? "questo switch è la root"))
                            .font(Theme.small)
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                TableSection(title: "Tabella di routing", head: ["Tipo", "Destinazione", "AD/m", "Next hop", "Int."],
                             rows: node.routes.filter { !$0.dest.contains(":") }.map(routeColumns))
                if node.ifaces.contains(where: { $0.ipv6Config != nil }) {
                    // Destination over next hop and address over MAC, as the NAT table does: IPv6 addresses are too long for one line each.
                    TableSection(title: "Tabella di routing IPv6", head: ["Tipo", "Destinazione\nNext hop", "AD/m", "Int."],
                                 rows: node.routes.filter { $0.dest.contains(":") }.map(routeColumns).map { [$0[0], "\($0[1])\n\($0[3])", $0[2], $0[4]] })
                    TableSection(title: "Vicini IPv6", head: ["Indirizzo\nMAC", "Stato", "Int."],
                                 rows: node.neighbors6.map { ["\($0.addr)\n\($0.mac)", $0.state, $0.iface] })
                }
                if node.ospf != nil {
                    TableSection(title: "Vicini OSPF" + (node.ospfRouterId.map { " · router ID \($0)" } ?? ""), head: ["Router ID", "Pri", "Stato", "Indirizzo", "Int."],
                                 rows: node.ospfNeighbors.map { [$0.routerId, "\($0.priority)", $0.state, $0.address, $0.iface] })
                    TableSection(title: "Database OSPF · tipo 1 router, 2 network", head: ["Tipo", "Link ID", "ADV router", "Età", "Seq"],
                                 rows: node.ospfDatabase.map { ["\($0.type)", $0.linkId, $0.advRouter, "\($0.ageS)s", $0.seq] })
                }
                TableSection(title: "Cache ARP", head: ["IP", "MAC", "Int.", "TTL"], rows: node.arp.map { [$0.ip, $0.mac, $0.iface, "\($0.ttlS)s"] })
                TableSection(title: "Connessioni TCP", head: ["Locale\nRemoto", "Stato"], rows: node.tcp.map { ["\($0.local)\n\($0.remote)", $0.state] })
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

/// A switch port's VLAN role (spec M7 §5): Access with its VLAN and PortFast, or Trunk with the allowed VLANs and the native one; errors under the field.
private struct SwitchportFields: View {
    let node: String
    let iface: String
    let port: PortConfig
    @Bindable var editor: Editor

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 12) {
                Picker("", selection: Binding(get: { port.mode }, set: { mode in
                    var c = port
                    c.mode = mode
                    Task { await editor.edit(.setSwitchport(node: node, iface: iface, config: c)) }
                })) {
                    Text("Access").tag(PortMode.access)
                    Text("Trunk").tag(PortMode.trunk)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .accessibilityIdentifier("port-mode-\(iface)")
                if port.mode == .access {
                    Toggle("PortFast", isOn: Binding(get: { port.portfast }, set: { on in
                        var c = port
                        c.portfast = on
                        Task { await editor.edit(.setSwitchport(node: node, iface: iface, config: c)) }
                    }))
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Forwarding subito, senza TCN: per le porte verso PC e server")
                    .accessibilityIdentifier("portfast-\(iface)")
                }
            }
            HStack(alignment: .top) {
                ForEach(port.mode == .access ? [PortField.vlan] : [.allowed, .native], id: \.self) { field in
                    CommitField(label: field.label, value: field.format(port), errorKey: "port:\(node):\(iface):\(field.rawValue)", editor: editor) {
                        await editor.setPort(node, iface: iface, field, $0)
                    }
                    .frame(maxWidth: field == .allowed ? .infinity : 80)
                }
            }
        }
    }
}

/// Router-on-a-stick (spec M7 §5): a subinterface `<fisica>.<VID>` with its address.
private struct SubinterfaceForm: View {
    let node: NodeView
    @Bindable var editor: Editor
    @State private var parent = "Gi0/0"
    @State private var vlan = ""
    @State private var cidr = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SOTTOINTERFACCIA 802.1Q").font(.system(size: 9)).foregroundStyle(Theme.muted)
            HStack {
                Picker("", selection: $parent) {
                    ForEach(node.ifaces.filter { !$0.name.contains(".") }, id: \.name) { Text($0.name).tag($0.name) }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                TextField("VID", text: $vlan).textFieldStyle(.roundedBorder).font(Theme.mono).frame(width: 50)
                TextField("10.0.10.1/24", text: $cidr).textFieldStyle(.roundedBorder).font(Theme.mono)
            }
            Button("Aggiungi sottointerfaccia") {
                Task {
                    if await editor.addSubinterface(node.id, parent: parent, vlan: vlan, cidr: cidr) {
                        vlan = ""
                        cidr = ""
                    }
                }
            }
            .accessibilityIdentifier("subif-add")
            ErrorLine(editor: editor, key: "sub:\(node.id)")
            Text("Nome <fisica>.<VID>, stesso MAC della fisica: collega la fisica a una porta trunk.")
                .font(Theme.small)
                .foregroundStyle(Theme.muted)
        }
    }
}

/// IPv6 on an interface (spec M9 §8): on/off, SLAAC on hosts, the manual address, and every address with its origin and state.
private struct Ipv6Fields: View {
    let node: NodeView
    let iface: IfaceView
    @Bindable var editor: Editor

    var body: some View {
        let key = "ip6:\(node.id):\(iface.name)"
        let apply = { (c: Ipv6Config?) in Task { await editor.edit(.setIpv6(node: node.id, iface: iface.name, config: c), key: key) } }
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 12) {
                Toggle("IPv6", isOn: Binding(get: { iface.ipv6Config != nil }, set: { on in
                    _ = apply(on ? Ipv6Config(autoconfig: node.kind.isHost) : nil)
                }))
                .accessibilityIdentifier("ipv6-\(iface.name)")
                if node.kind.isHost, let c = iface.ipv6Config {
                    Toggle("SLAAC", isOn: Binding(get: { c.autoconfig }, set: { on in
                        var n = c
                        n.autoconfig = on
                        _ = apply(n)
                    }))
                    .help("Indirizzo dal prefisso annunciato dal router (RA) + EUI-64")
                    .accessibilityIdentifier("slaac-\(iface.name)")
                }
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            if let c = iface.ipv6Config {
                CommitField(label: "Indirizzo IPv6 / prefisso", value: c.address ?? "", placeholder: "2001:db8:1::10/64", errorKey: key, editor: editor) { text in
                    var n = c
                    let t = text.trimmingCharacters(in: .whitespaces)
                    n.address = t.isEmpty ? nil : t
                    await editor.edit(.setIpv6(node: node.id, iface: iface.name, config: n), key: key)
                }
                ForEach(iface.ipv6, id: \.self) { line in
                    Text(line).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.fg).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ErrorLine(editor: editor, key: key)
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
            if node.kind == .router {
                let key = "ip6:\(node.id)"
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Routing IPv6 (ipv6 unicast-routing)", isOn: Binding(get: { node.ipv6Routing }, set: { on in
                        Task { await editor.edit(.setIpv6Routing(node: node.id, on: on), key: key) }
                    }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Inoltra IPv6 e manda le Router Advertisement sulle interfacce IPv6")
                    .accessibilityIdentifier("ipv6-routing")
                    ErrorLine(editor: editor, key: key)
                }
                if node.ipv6Routing {
                    let dnsKey = "rdnss:\(node.id)"
                    CommitField(label: "Server DNS annunciato (RDNSS)", value: node.rdnss ?? "", placeholder: "2001:db8:2::53",
                                errorKey: dnsKey, editor: editor) { text in
                        let trimmed = text.trimmingCharacters(in: .whitespaces)
                        await editor.edit(.setRdnss(node: node.id, server: trimmed.isEmpty ? nil : trimmed), key: dnsKey)
                    }
                }
            }
            CommitField(label: "Gateway predefinito", value: gateway, placeholder: "192.168.1.1",
                        suggestions: node.kind.isHost ? gatewaySuggestions(node.id, in: editor.snapshot) : [], errorKey: gwKey, editor: editor) { text in
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
                Text("IPv4 o IPv6, es. 2001:db8:9::/64 via 2001:db8:1::2").font(Theme.small).foregroundStyle(Theme.muted)
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
    @State private var count = "4"
    @State private var interval = "1"
    @State private var size = "56"
    @State private var ttl = ""

    var body: some View {
        let key = "app:\(node.id)"
        VStack(alignment: .leading, spacing: 8) {
            Text("Destinazione").font(Theme.small).foregroundStyle(Theme.muted)
            TextField("10.0.0.2 o nome host", text: $target).textFieldStyle(.roundedBorder).font(Theme.mono).accessibilityIdentifier("app-target")
            HStack(spacing: 6) {
                field("Pacchetti", $count)
                field("Intervallo s", $interval)
                field("Byte", $size)
                field("TTL", $ttl, placeholder: "auto")
            }
            HStack {
                Button("Ping") {
                    Task { await editor.ping(node.id, target: target, count: count, interval: interval, size: size, ttl: ttl) }
                }
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
            Text("Destinazione: un server o una stampante con il sink attivo (Servizi). Risultati in Output app e Metriche.")
                .font(Theme.small)
                .foregroundStyle(Theme.muted)
        }
    }

    private func field(_ label: String, _ text: Binding<String>, placeholder: String = "") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Theme.small).foregroundStyle(Theme.muted).lineLimit(1)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder).font(Theme.mono)
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
