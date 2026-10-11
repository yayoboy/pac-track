import PacEngine
import PacKit
import SwiftUI

/// The Wi-Fi tab (spec M11 §7): an access point's SSID and channel; a client's card (PCs and laptops), network and state.
struct WifiTab: View {
    let node: NodeView
    @Bindable var editor: Editor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let ap = node.accessPoint { accessPoint(ap) }
            if [.pc, .laptop, .console].contains(node.kind) { card }
            if let s = node.station { station(s) }
        }
    }

    private func accessPoint(_ ap: AccessPointView) -> some View {
        let key = "ssid:\(node.id)"
        let channelKey = "channel:\(node.id)"
        return VStack(alignment: .leading, spacing: 10) {
            CommitField(label: "SSID", value: ap.config.ssid, placeholder: "pac-track", errorKey: key, editor: editor) { text in
                await editor.edit(.setAccessPoint(node: node.id, config: ApConfig(ssid: text, channel: ap.config.channel)), key: key)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Canale").font(Theme.small).foregroundStyle(Theme.muted)
                Picker("", selection: Binding(get: { ap.config.channel }, set: { channel in
                    Task { await editor.edit(.setAccessPoint(node: node.id, config: ApConfig(ssid: ap.config.ssid, channel: channel)), key: channelKey) }
                })) {
                    ForEach(WIFI_CHANNELS, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .accessibilityIdentifier("wifi-channel")
                ErrorLine(editor: editor, key: channelKey)
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Scheda di rete").font(Theme.small).foregroundStyle(Theme.muted)
            Picker("", selection: Binding(get: { node.station != nil }, set: { wifi in Task { await editor.setNic(node.id, wifi: wifi) } })) {
                Text("Ethernet").tag(false)
                Text("Wi-Fi").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .accessibilityIdentifier("wifi-card")
            ErrorLine(editor: editor, key: "nic:\(node.id)")
        }
    }

    private func station(_ s: StationView) -> some View {
        let key = "ssid:\(node.id)"
        return VStack(alignment: .leading, spacing: 4) {
            CommitField(label: "Rete (SSID)", value: s.config.ssid, placeholder: "pac-track", errorKey: key, editor: editor) { text in
                await editor.edit(.setStation(node: node.id, config: StationConfig(ssid: text)), key: key)
            }
            Text(wifiStatus(s, in: editor.snapshot.nodes))
                .font(Theme.small)
                .foregroundStyle(s.state == .associated ? Theme.ok : Theme.muted)
                .accessibilityIdentifier("wifi-status")
        }
    }
}
