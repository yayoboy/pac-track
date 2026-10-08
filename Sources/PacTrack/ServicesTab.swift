import PacEngine
import PacKit
import SwiftUI

/// DHCP server (routers, servers), DNS server and sink (servers), NAT and firewall (routers): settings plus live tables (spec §7.1 ④).
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
            dhcp
            if node.kind == .server {
                dns
                sink
            }
            if node.kind == .router {
                nat
                firewall
            }
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
                        Text("\(records[i].name)  \(records[i].ip)  TTL \(records[i].ttl)s").font(Theme.mono).lineLimit(1)
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
