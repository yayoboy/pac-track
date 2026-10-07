import PacEngine
import PacKit
import SwiftUI

struct PaletteView: View {
    private static let all: [(String, [DeviceKind])] = [("Rete", [.router, .switch, .hub]), ("Host", [.pc, .laptop, .server])]
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
            Spacer()
            Text("Trascina un dispositivo sul canvas. Collega due dispositivi trascinando dal pallino in basso.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.muted)
        }
        .padding(10)
        .background(Theme.panel)
    }
}
