import PacKit
import SwiftUI

/// Window content without the toolbar (the selftest renders exactly this).
struct MainContent: View {
    @Bindable var editor: Editor

    var body: some View {
        HStack(spacing: 0) {
            PaletteView().frame(width: 170)
            Divider()
            VStack(spacing: 0) {
                CanvasView(editor: editor)
                Divider()
                OutputPanel(editor: editor).frame(height: 170)
            }
            Divider()
            InspectorView(editor: editor).frame(width: 290)
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.fg)
    }
}
