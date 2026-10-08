import PacKit
import SwiftUI

struct OutputPanel: View {
    @Bindable var editor: Editor

    var body: some View {
        let apps = editor.snapshot.apps
        let name = { (id: String) in editor.snapshot.nodes.first { $0.id == id }?.name ?? "(rimosso)" }
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if apps.isEmpty {
                            Text("Nessuna applicazione avviata: usa la scheda App dell'ispettore o il menu contestuale di un dispositivo.")
                                .foregroundStyle(Theme.muted)
                        }
                        ForEach(apps) { app in
                            VStack(alignment: .leading, spacing: 0) {
                                Text("\(name(app.node))$ \(app.title)\(app.done ? "" : " …")").foregroundStyle(Theme.accent)
                                ForEach(app.lines.indices, id: \.self) { Text(app.lines[$0]) }
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .font(Theme.mono)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: apps.reduce(0) { $0 + $1.lines.count }) { proxy.scrollTo("end") }
            }
        }
        .background(Theme.panel)
        .accessibilityIdentifier("output")
    }
}
