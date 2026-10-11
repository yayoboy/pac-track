import PacEngine
import PacKit
import SwiftUI

/// One palette entry: a device kind, or a server preset (spec M10 §3).
struct PaletteItem: Hashable {
    let kind: DeviceKind
    var preset: ServerPreset? = nil

    var label: String { preset?.label ?? kind.label }
    /// What a drag carries.
    var payload: String { preset?.rawValue ?? kind.rawValue }
}

extension PaletteItem {
    init?(payload: String) {
        if let preset = ServerPreset(rawValue: payload) {
            self.init(kind: .server, preset: preset)
        } else if let kind = DeviceKind(rawValue: payload) {
            self.init(kind: kind)
        } else {
            return nil
        }
    }
}

struct PaletteView: View {
    @Bindable var editor: Editor
    private static let all: [(String, [PaletteItem])] = [
        ("Rete", [.router, .switch, .hub, .cloud].map { PaletteItem(kind: $0) }),
        ("Host", [.pc, .laptop, .printer, .tv].map { PaletteItem(kind: $0) }),
        ("Server", [PaletteItem(kind: .server), PaletteItem(kind: .server, preset: .dns), PaletteItem(kind: .server, preset: .dhcp)]),
        ("Wireless", [.accessPoint, .homeRouter, .tablet, .smartphone].map { PaletteItem(kind: $0) }),
    ]
    /// Words that find a whole section besides its title (spec M11 §7).
    private static let aliases = ["Wireless": "wifi wi-fi ap"]
    @State private var query = ""

    /// Categories with the devices whose name (or category) contains `query`.
    static func groups(matching query: String) -> [(String, [PaletteItem])] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return all.compactMap { title, kinds in
            let hits = q.isEmpty || "\(title) \(aliases[title] ?? "")".localizedCaseInsensitiveContains(q) ? kinds : kinds.filter { $0.label.localizedCaseInsensitiveContains(q) }
            return hits.isEmpty ? nil : (title, hits)
        }
    }

    var body: some View {
        let groups = Self.groups(matching: query)
        VStack(alignment: .leading, spacing: 12) {
            TextField("Cerca", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("palette-search")
            // Sections and cables scroll in a short window (spec M10 §5); search and hint stay put.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if groups.isEmpty { Text("Nessun dispositivo").font(Theme.small).foregroundStyle(Theme.muted) }
                    ForEach(groups, id: \.0) { title, items in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title.uppercased()).font(.system(size: 9)).foregroundStyle(Theme.muted).padding(.horizontal, 6)
                            ForEach(items, id: \.self) { item in
                                Label(item.label, systemImage: item.kind.symbol)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                                    .draggable(item.payload)
                                    .accessibilityIdentifier("palette-\(item.payload)")
                            }
                        }
                    }
                    let q = query.trimmingCharacters(in: .whitespaces)
                    let cables = CableKind.allCases.filter { q.isEmpty || $0.rawValue.localizedCaseInsensitiveContains(q) || "cavi".localizedCaseInsensitiveContains(q) }
                    if !cables.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("CAVI").font(.system(size: 9)).foregroundStyle(Theme.muted).padding(.horizontal, 6)
                            ForEach(cables, id: \.self) { cable in
                                // Marked under Sposta too (lighter): the port dot draws this cable as well.
                                let on = editor.cable == cable
                                Label(cable.rawValue, systemImage: cable == .fiber ? "fibrechannel" : cable == .custom ? "slider.horizontal.3" : "cable.connector")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 4)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(on ? Theme.accent.opacity(editor.tool == .connect ? 0.35 : 0.18) : Color.clear))
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        editor.cable = cable
                                        editor.tool = .connect
                                    }
                                    .accessibilityIdentifier("cable-\(cable)")
                            }
                        }
                    }
                }
            }
            Text("Trascina un dispositivo sul canvas. Per collegare, trascina dal pallino in basso, oppure scegli un cavo e trascina da un dispositivo all'altro.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.muted)
        }
        .padding(10)
        .background(Theme.panel)
    }
}
