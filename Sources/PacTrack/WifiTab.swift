import PacEngine
import PacKit
import SwiftUI

/// The Wi-Fi tab (spec M11 §7, §8): an access point's (or home router's) SSID, channel and security; a client's card (PCs and
/// laptops), network, password, state and signal.
struct WifiTab: View {
    let node: NodeView
    @Bindable var editor: Editor
    /// The device on which WPA2-PSK was picked while no valid password is set yet: the password field shows, the network stays open.
    @State private var wpa2Picked: String?

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
                var c = ap.config
                c.ssid = text
                await editor.edit(.setAccessPoint(node: node.id, config: c), key: key)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Canale").font(Theme.small).foregroundStyle(Theme.muted)
                Picker("", selection: Binding(get: { ap.config.channel }, set: { channel in
                    var c = ap.config
                    c.channel = channel
                    Task { await editor.edit(.setAccessPoint(node: node.id, config: c), key: channelKey) }
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
            security(ap)
        }
    }

    /// Spec M11 §8: Aperta / WPA2-PSK; the network turns WPA2 when a valid password (8–63 characters) is entered.
    private func security(_ ap: AccessPointView) -> some View {
        let key = "psk:\(node.id)"
        let wpa2 = ap.config.passphrase != nil || wpa2Picked == node.id
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sicurezza").font(Theme.small).foregroundStyle(Theme.muted)
                Picker("", selection: Binding(get: { wpa2 }, set: { on in
                    wpa2Picked = on ? node.id : nil
                    guard !on, ap.config.passphrase != nil else { return }
                    var c = ap.config
                    c.passphrase = nil
                    Task { await editor.edit(.setAccessPoint(node: node.id, config: c), key: key) }
                })) {
                    Text("Aperta").tag(false)
                    Text("WPA2-PSK").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .accessibilityIdentifier("wifi-security")
            }
            if wpa2 {
                CommitField(label: "Password", value: ap.config.passphrase ?? "", placeholder: "8–63 caratteri", errorKey: key, editor: editor) { text in
                    var c = ap.config
                    c.passphrase = text
                    await editor.edit(.setAccessPoint(node: node.id, config: c), key: key)
                }
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
                var c = s.config
                c.ssid = text
                await editor.edit(.setStation(node: node.id, config: c), key: key)
            }
            // The password a WPA2 network asks for (spec M11 §8); empty: none.
            CommitField(label: "Password", value: s.config.passphrase ?? "", placeholder: "nessuna", errorKey: "psk:\(node.id)", editor: editor) { text in
                var c = s.config
                c.passphrase = text.isEmpty ? nil : text
                await editor.edit(.setStation(node: node.id, config: c), key: "psk:\(node.id)")
            }
            Text(wifiStatus(s, in: editor.snapshot.nodes))
                .font(Theme.small)
                .foregroundStyle(s.state == .associated ? Theme.ok : s.state == .wrongPassword ? Theme.err : Theme.muted)
                .accessibilityIdentifier("wifi-status")
            if let signal = wifiSignal(s) {
                Text(signal).font(Theme.small).foregroundStyle(Theme.muted).accessibilityIdentifier("wifi-signal")
            }
        }
    }
}
