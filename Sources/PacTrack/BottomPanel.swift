import PacKit
import SwiftUI

private enum BottomTab: String, CaseIterable {
    case events = "Eventi", output = "Output app"
}

/// Resizable panel under the canvas (spec §7.1 ⑤). Metriche arrives with M4.
struct BottomPanel: View {
    @Bindable var editor: Editor
    @State private var tab = BottomTab.events

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) { ForEach(BottomTab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            Divider()
            switch tab {
            case .events: EventsPanel(editor: editor)
            case .output: OutputPanel(editor: editor)
            }
        }
        .background(Theme.panel)
    }
}
