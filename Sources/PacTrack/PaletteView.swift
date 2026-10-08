import PacEngine
import PacKit
import SwiftUI

struct PaletteView: View {
    @Bindable var editor: Editor
    private static let all: [(String, [DeviceKind])] = [("Rete", [.router, .switch, .hub, .cloud]), ("Host", [.pc, .laptop, .server])]
    @State private var query = ""

    /// Categories with the devices whose name (or category) contains `query`.
    static func groups(matching query: String) -> [(String, [DeviceKind])] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return all.compactMap { title, kinds in
            let hits = q.isEmpty || title.localizedCaseInsensitiveContains(q) ? kinds : kinds.filter { $0.label.localizedCaseInsensitiveContains(q) }
            return hits.isEmpty ? nil : (title, hits)
        }
    }

    var body: some View {
        let groups = Self.groups(matching: query)
        VStack(alignment: .leading, spacing: 12) {
            TextField("Cerca", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("palette-search")
            if groups.isEmpty { Text("Nessun dispositivo").font(Theme.small).foregroundStyle(Theme.muted) }
            ForEach(groups, id: \.0) { title, kinds in
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.uppercased()).font(.system(size: 9)).foregroundStyle(Theme.muted).padding(.horizontal, 6)
                    ForEach(kinds, id: \.self) { kind in
                        Label(kind.label, systemImage: kind.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .draggable(kind.rawValue)
                            .accessibilityIdentifier("palette-\(kind.rawValue)")
                    }
                }
            }
            let q = query.trimmingCharacters(in: .whitespaces)
            let cables = CableKind.allCases.filter { q.isEmpty || $0.rawValue.localizedCaseInsensitiveContains(q) || "cavi".localizedCaseInsensitiveContains(q) }
            if !cables.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CAVI").font(.system(size: 9)).foregroundStyle(Theme.muted).padding(.horizontal, 6)
                    ForEach(cables, id: \.self) { cable in
                        let on = editor.tool == .connect && editor.cable == cable
                        Label(cable.rawValue, systemImage: cable == .fiber ? "fibrechannel" : cable == .custom ? "slider.horizontal.3" : "cable.connector")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 4).fill(on ? Theme.accent.opacity(0.35) : Color.clear))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editor.cable = cable
                                editor.tool = .connect
                            }
                            .accessibilityIdentifier("cable-\(cable)")
                    }
                }
            }
            Spacer()
            Text("Trascina un dispositivo sul canvas. Per collegare, trascina dal pallino in basso, oppure scegli un cavo e trascina da un dispositivo all'altro.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.muted)
        }
        .padding(10)
        .background(Theme.panel)
    }
}
