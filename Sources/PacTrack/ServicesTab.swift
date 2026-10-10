import PacEngine
import PacKit
import SwiftUI

/// DHCP server (routers, servers, clouds), DNS server (servers, clouds), sink (servers), RIP, OSPF, NAT and firewall (routers): settings plus live tables; on a switch, the Spanning Tree priorities (spec §7.1 ④).
struct ServicesTab: View {
    let node: NodeView
    @Bindable var editor: Editor
    @State private var name = ""
    @State private var ip = ""
    @State private var ttl = ""
    @State private var ruleIface = "Gi0/0"
    @State private var ruleDirection = FirewallDirection.inbound
    @State private var ruleAction = FirewallAction.deny
    @State private var ruleProto = FirewallProto.any
    @State private var ruleSrc = ""
    @State private var ruleDst = ""
    @State private var rulePort = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if node.kind == .switch {
                spanningTree
            } else {
                if node.kind == .cloud { internet }
                dhcp
                if node.kind == .server || node.kind == .cloud { dns }
                if node.kind == .server { sink }
                if node.kind == .router {
                    rip
                    ospf
                    nat
                    firewall
                }
            }
        }
    }

    private var internet: some View {
        Text("Internet simulata: \(node.name) risponde da sé a ogni indirizzo pubblico per cui non ha una route (ping, traceroute) e su ognuno fa da DNS pubblico, per esempio 8.8.8.8. Collega a Gi0/0 il router del cliente: 203.0.113.x/24, gateway 203.0.113.1.")
            .font(Theme.small)
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// PVST+ (spec M7 §5): one bridge priority per active VLAN; the lowest bridge ID becomes the root.
    private var spanningTree: some View {
        let key = "stp:\(node.id)"
        return VStack(alignment: .leading, spacing: 6) {
            Text("Spanning Tree (PVST+)").foregroundStyle(Theme.fgStrong)
            if node.stp.isEmpty { Text("Nessuna VLAN attiva: collega una porta.").font(Theme.small).foregroundStyle(Theme.muted) }
            ForEach(node.stp, id: \.vlan) { st in
                HStack {
                    Text("VLAN \(st.vlan)").font(Theme.mono)
                    Spacer()
                    Picker("", selection: Binding(get: { st.priority }, set: { priority in
                        Task { await editor.edit(.setStpPriority(node: node.id, vlan: st.vlan, priority: priority), key: key) }
                    })) {
                        ForEach(STP_PRIORITIES, id: \.self) { Text(String($0)).tag($0) } // 32768, not a localized 32.768
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityIdentifier("stp-priority-\(st.vlan)")
                }
            }
            ErrorLine(editor: editor, key: key)
            Text("Priorità del bridge per VLAN: vince la più bassa, a parità il MAC minore. Il valore effettivo aggiunge il numero di VLAN.")
                .font(Theme.small)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// RIPv2 (spec M8 §5): on/off and each interface's part.
    private var rip: some View {
        let key = "rip:\(node.id)"
        return VStack(alignment: .leading, spacing: 6) {
            Toggle("RIP v2", isOn: Binding(get: { node.rip != nil }, set: { on in
                Task { await editor.enableRip(node.id, on) }
            }))
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityIdentifier("rip-enabled")
            if node.rip != nil {
                ForEach(node.ifaces, id: \.name) { iface in
                    HStack {
                        Text(iface.name).font(Theme.mono)
                        Spacer()
                        Picker("", selection: Binding(get: { ripRole(node.rip, iface.name) }, set: { role in
                            Task { await editor.setRipRole(node.id, iface: iface.name, role) }
                        })) {
                            ForEach(RoutingRole.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                        .accessibilityIdentifier("rip-\(iface.name)")
                    }
                }
            }
            ErrorLine(editor: editor, key: key)
            Text(node.rip == nil ? "Spento." : "Update ogni 30 s verso 224.0.0.9 dalle interfacce attive; una passiva fa annunciare la sua rete ma non manda nulla. Route apprese in Tabelle.")
                .font(Theme.small)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// OSPF in area 0 (spec M8 §5): on/off, router ID, each interface's part, network type and priority.
    private var ospf: some View {
        let key = "ospf:\(node.id)"
        return VStack(alignment: .leading, spacing: 6) {
            Toggle("OSPF (area 0)", isOn: Binding(get: { node.ospf != nil }, set: { on in
                Task { await editor.enableOspf(node.id, on) }
            }))
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityIdentifier("ospf-enabled")
            if let config = node.ospf {
                CommitField(label: "Router ID (vuoto: automatico)", value: config.routerId ?? "", placeholder: node.ospfRouterId ?? "automatico",
                            errorKey: "\(key):rid", editor: editor) { text in
                    await editor.setOspfRouterId(node.id, text)
                }
                ForEach(node.ifaces, id: \.name) { iface in
                    let c = config.interfaces.first { $0.name == iface.name }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(iface.name).font(Theme.mono)
                            Spacer()
                            Picker("", selection: Binding(get: { ospfRole(node.ospf, iface.name) }, set: { role in
                                Task { await editor.setOspfRole(node.id, iface: iface.name, role) }
                            })) {
                                ForEach(RoutingRole.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .controlSize(.small)
                            .fixedSize()
                            .accessibilityIdentifier("ospf-\(iface.name)")
                        }
                        if let c, !c.passive {
                            HStack(alignment: .bottom) {
                                Picker("", selection: Binding(get: { c.pointToPoint }, set: { on in
                                    Task { await editor.setOspfPointToPoint(node.id, iface: iface.name, on) }
                                })) {
                                    Text("broadcast").tag(false)
                                    Text("point-to-point").tag(true)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .controlSize(.small)
                                .fixedSize()
                                Spacer()
                                if !c.pointToPoint {
                                    CommitField(label: "Priorità", value: String(c.priority), errorKey: "\(key):\(iface.name)", editor: editor) { text in
                                        await editor.setOspfPriority(node.id, iface: iface.name, text)
                                    }
                                    .frame(width: 70)
                                }
                            }
                        }
                    }
                }
            }
            ErrorLine(editor: editor, key: key)
            Text(node.ospf == nil ? "Spento." : "Hello ogni 10 s, dead 40 s. Il router ID cambia solo al riavvio di OSPF. Vicini, database e route in Tabelle.")
                .font(Theme.small)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var nat: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NAT / PAT (overload)").foregroundStyle(Theme.fgStrong)
            ForEach(node.ifaces, id: \.name) { iface in
                HStack {
                    Text(iface.name).font(Theme.mono)
                    Spacer()
                    Picker("", selection: Binding(get: { natRole(node.nat, iface.name) }, set: { role in
                        Task { await editor.setNatRole(node.id, iface: iface.name, role) }
                    })) {
                        ForEach(NatRole.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityIdentifier("nat-\(iface.name)")
                }
            }
            ErrorLine(editor: editor, key: "nat:\(node.id)")
            Text(node.nat?.outside != nil && node.nat?.inside.isEmpty == false
                 ? "Chi entra da una inside esce dalla outside con il suo indirizzo. Traduzioni in Tabelle."
                 : "Spento: serve una outside e almeno una inside.")
                .font(Theme.small)
                .foregroundStyle(Theme.muted)
        }
    }

    private var firewall: some View {
        let key = "fw:\(node.id)"
        return VStack(alignment: .leading, spacing: 8) {
            Toggle("Firewall", isOn: Binding(get: { node.firewall != nil }, set: { on in
                Task { await editor.edit(.setFirewall(node: node.id, config: on ? FirewallConfig() : nil), key: key) }
            }))
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityIdentifier("firewall-enabled")
            if let config = node.firewall {
                HStack {
                    Text("Policy predefinita").font(Theme.small).foregroundStyle(Theme.muted)
                    Picker("", selection: Binding(get: { config.defaultAction }, set: { action in
                        var next = config
                        next.defaultAction = action
                        Task { await editor.edit(.setFirewall(node: node.id, config: next), key: key) }
                    })) {
                        ForEach(FirewallAction.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityIdentifier("firewall-default")
                }
                Text("REGOLE (DECIDE LA PRIMA CHE CORRISPONDE)").font(.system(size: 9)).foregroundStyle(Theme.muted)
                if config.rules.isEmpty { Text("nessuna").font(Theme.small).foregroundStyle(Theme.muted) }
                ForEach(config.rules.indices, id: \.self) { i in
                    HStack {
                        Text("\(i + 1). \(ruleSummary(config.rules[i]))").font(Theme.mono).lineLimit(1)
                        Spacer()
                        Button { Task { await editor.removeFirewallRule(node.id, at: i) } } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .help("Rimuovi regola")
                    }
                }
                Group {
                    HStack {
                        Picker("", selection: $ruleIface) { ForEach(node.ifaces, id: \.name) { Text($0.name).tag($0.name) } }
                        Picker("", selection: $ruleDirection) { ForEach(FirewallDirection.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    }
                    HStack {
                        Picker("", selection: $ruleAction) { ForEach(FirewallAction.allCases, id: \.self) { Text($0.label).tag($0) } }
                        Picker("", selection: $ruleProto) { ForEach(FirewallProto.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                HStack {
                    TextField("sorgente", text: $ruleSrc).textFieldStyle(.roundedBorder).font(Theme.mono)
                    TextField("destinazione", text: $ruleDst).textFieldStyle(.roundedBorder).font(Theme.mono)
                    TextField("porta", text: $rulePort).textFieldStyle(.roundedBorder).font(Theme.mono).frame(width: 50)
                    Button("+") {
                        Task {
                            let rule = FirewallRule(iface: ruleIface, direction: ruleDirection, action: ruleAction, proto: ruleProto,
                                                    src: ruleSrc, dst: ruleDst)
                            if await editor.addFirewallRule(node.id, rule, port: rulePort) {
                                ruleSrc = ""
                                ruleDst = ""
                                rulePort = ""
                            }
                        }
                    }
                    .accessibilityIdentifier("firewall-add")
                }
                ErrorLine(editor: editor, key: key)
                Text(config.defaultAction == .deny
                     ? "Passano solo le regole «consenti» e le risposte ai flussi consentiti, anche verso il router (DHCP, ping)."
                     : "Indirizzi: any, un IP o un prefisso. Le risposte ai flussi consentiti passano sempre.")
                    .font(Theme.small)
                    .foregroundStyle(Theme.muted)
            } else {
                Text("Spento: \(node.name) inoltra tutto.").font(Theme.small).foregroundStyle(Theme.muted)
                ErrorLine(editor: editor, key: key)
            }
        }
    }

    private var sink: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Sink TCP/UDP (porta 9)", isOn: Binding(get: { node.sink }, set: { on in
                Task { await editor.edit(.setSink(node: node.id, on: on)) }
            }))
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityIdentifier("sink-enabled")
            Text(node.sink ? "Riceve e scarta il traffico del generatore." : "Spento: TCP risponde con RST, UDP con ICMP port unreachable.")
                .font(Theme.small)
                .foregroundStyle(Theme.muted)
        }
    }

    private var dhcp: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Server DHCP", isOn: Binding(get: { node.dhcpServer != nil }, set: { on in Task { await editor.enableDhcp(node.id, on) } }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityIdentifier("dhcp-enabled")
            ErrorLine(editor: editor, key: "dhcp:\(node.id):enabled")
            if let config = node.dhcpServer {
                ForEach(DhcpField.allCases, id: \.self) { field in
                    CommitField(label: field.label, value: field.format(config), placeholder: field.placeholder,
                                errorKey: "dhcp:\(node.id):\(field.rawValue)", editor: editor) {
                        await editor.setDhcp(node.id, field, $0)
                    }
                }
                TableSection(title: "Lease DHCP", head: ["IP", "MAC", "Scade", "Stato"], rows: leaseRows(node.leases))
            } else {
                Text("Spento: \(node.name) non assegna indirizzi.").font(Theme.small).foregroundStyle(Theme.muted)
            }
        }
    }

    private var dns: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Server DNS", isOn: Binding(get: { node.dnsRecords != nil }, set: { on in Task { await editor.enableDns(node.id, on) } }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityIdentifier("dns-enabled")
            if let records = node.dnsRecords {
                Text("RECORD A").font(.system(size: 9)).foregroundStyle(Theme.muted)
                if records.isEmpty { Text("nessuno").font(Theme.small).foregroundStyle(Theme.muted) }
                ForEach(records.indices, id: \.self) { i in
                    HStack {
                        Text("\(records[i].name)  \(records[i].ip)  TTL \(records[i].ttl)s").font(Theme.mono).lineLimit(1).minimumScaleFactor(0.75)
                        Spacer()
                        Button { Task { await editor.removeDnsRecord(node.id, at: i) } } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .help("Rimuovi record")
                    }
                }
                HStack {
                    TextField("nome.lab", text: $name).textFieldStyle(.roundedBorder).font(Theme.mono)
                    TextField("IP", text: $ip).textFieldStyle(.roundedBorder).font(Theme.mono)
                    TextField("TTL", text: $ttl).textFieldStyle(.roundedBorder).font(Theme.mono).frame(width: 50)
                    Button("+") {
                        Task {
                            if await editor.addDnsRecord(node.id, name: name, ip: ip, ttl: ttl) {
                                name = ""
                                ip = ""
                                ttl = ""
                            }
                        }
                    }
                }
            } else {
                Text("Spento: nessuna risposta alle query DNS.").font(Theme.small).foregroundStyle(Theme.muted)
            }
            ErrorLine(editor: editor, key: "dnsrec:\(node.id)")
        }
    }
}
