import PacKit
import SwiftUI

/// Window content without the toolbar (the selftest renders exactly this).
struct MainContent: View {
    @Bindable var editor: Editor

    var body: some View {
        HStack(spacing: 0) {
            Theme.panel.frame(width: 170)
            Divider()
            VStack(spacing: 0) {
                Theme.bg
                Divider()
                Theme.panel.frame(height: 170)
            }
            Divider()
            Theme.panel.frame(width: 290)
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.fg)
    }
}
