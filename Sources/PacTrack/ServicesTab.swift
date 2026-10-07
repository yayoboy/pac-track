import PacEngine
import PacKit
import SwiftUI

/// DHCP server (routers, servers) and DNS server (servers): settings plus live tables (spec §7.1 ④).
struct ServicesTab: View {
    let node: NodeView
    @Bindable var editor: Editor
    @State private var name = ""
    @State private var ip = ""
    @State private var ttl = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            dhcp
            if node.kind == .server { dns }
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
