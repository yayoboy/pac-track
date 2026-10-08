import PacKit
import SwiftUI

/// Resizable panel under the canvas (spec §7.1 ⑤).
struct BottomPanel: View {
    @Bindable var editor: Editor

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $editor.bottomTab) { ForEach(BottomTab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            Divider()
            switch editor.bottomTab {
            case .events: EventsPanel(editor: editor)
            case .output: OutputPanel(editor: editor)
            case .metrics: MetricsPanel(editor: editor)
            }
        }
        .background(Theme.panel)
    }
}
