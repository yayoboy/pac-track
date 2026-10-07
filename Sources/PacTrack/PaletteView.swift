import PacEngine
import PacKit
import SwiftUI

struct PaletteView: View {
    private let groups: [(String, [DeviceKind])] = [("Rete", [.router, .switch, .hub]), ("Host", [.pc, .laptop, .server])]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
