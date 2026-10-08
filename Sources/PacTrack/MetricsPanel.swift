import Charts
import PacEngine
import PacKit
import SwiftUI

/// Metriche tab (spec §5.6): the selected cable per direction and every traffic flow, one point per 100 ms of simulated time.
struct MetricsPanel: View {
    @Bindable var editor: Editor

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView { link.padding(10).frame(maxWidth: .infinity, alignment: .leading) }
            Divider()
            ScrollView { flows.padding(10).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .font(Theme.mono)
        .background(Theme.panel)
        .accessibilityIdentifier("metrics")
    }

    private func name(_ id: String) -> String {
        editor.snapshot.nodes.first { $0.id == id }?.name ?? "(rimosso)"
    }

    @ViewBuilder
    private var link: some View {
        if case .link(let id) = editor.selection, let l = editor.snapshot.links.first(where: { $0.id == id }),
           let samples = editor.snapshot.linkSamples[id], let last = samples.last {
            let ab = "\(name(l.a.node)) → \(name(l.b.node))"
            let ba = "\(name(l.b.node)) → \(name(l.a.node))"
            VStack(alignment: .leading, spacing: 4) {
                Text("UTILIZZO DEL COLLEGAMENTO (%)").font(.system(size: 9)).foregroundStyle(Theme.muted)
                Chart {
                    ForEach(samples, id: \.timeNs) { s in
                        LineMark(x: .value("Tempo (s)", Double(s.timeNs) / 1e9), y: .value("Utilizzo", s.ab.utilization * 100),
                                 series: .value("Verso", ab))
                            .foregroundStyle(by: .value("Verso", ab))
                        LineMark(x: .value("Tempo (s)", Double(s.timeNs) / 1e9), y: .value("Utilizzo", s.ba.utilization * 100),
                                 series: .value("Verso", ba))
                            .foregroundStyle(by: .value("Verso", ba))
                    }
                }
                .chartYScale(domain: 0...100)
                .frame(height: 120)
                Text("\(ab): \(directionSummary(last.ab))")
                Text("\(ba): \(directionSummary(last.ba))")
            }
        } else {
            Text("Seleziona un collegamento (o «Mostra metriche» dal suo menu) per vederne utilizzo, coda e drop.")
                .foregroundStyle(Theme.muted)
        }
    }

    private var flows: some View {
        let apps = editor.snapshot.apps.filter { !$0.samples.isEmpty }
        return VStack(alignment: .leading, spacing: 12) {
            if apps.isEmpty {
                Text("Nessun flusso: avvia il generatore di traffico dalla scheda App di un host.").foregroundStyle(Theme.muted)
            }
            ForEach(apps) { app in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(name(app.node))$ \(app.title)").foregroundStyle(Theme.accent)
                    Chart(app.samples, id: \.timeNs) { s in
                        LineMark(x: .value("Tempo (s)", Double(s.timeNs) / 1e9), y: .value("Mb/s", s.bitsPerSecond / 1e6))
                    }
                    .frame(height: 80)
                    if let last = app.samples.last { Text(flowSummary(last)) }
                }
            }
        }
    }
}
