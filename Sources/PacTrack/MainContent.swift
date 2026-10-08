import PacKit
import SwiftUI

/// Window content without the toolbar (the selftest renders exactly this).
struct MainContent: View {
    @Bindable var editor: Editor

    var body: some View {
        HStack(spacing: 0) {
            PaletteView(editor: editor).frame(width: 170)
            Divider()
            VSplitView {
                CanvasView(editor: editor)
                    .overlay(alignment: .top) {
                        VStack(spacing: 0) {
                            ErrorBanner(editor: editor)
                            WarningBanner(editor: editor)
                        }
                    }
                    .frame(minHeight: 220)
                BottomPanel(editor: editor)
                    .frame(minHeight: 110, idealHeight: 240)
            }
            Divider()
            InspectorView(editor: editor).frame(width: 300)
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.fg)
    }
}
