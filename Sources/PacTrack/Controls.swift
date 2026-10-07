import PacKit
import SwiftUI

struct ErrorLine: View {
    let editor: Editor
    let key: String

    var body: some View {
        if let error = editor.error, error.key == key {
            Text(error.message).font(Theme.small).foregroundStyle(Theme.err).accessibilityIdentifier("error-\(key)")
        }
    }
}

/// Text field that commits on Return or focus loss and reverts on Escape; shows the error tagged `errorKey`.
struct CommitField: View {
    let label: String
    let value: String
    var placeholder = ""
    let errorKey: String
    let editor: Editor
    let commit: (String) async -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Theme.small).foregroundStyle(Theme.muted)
            TextField(placeholder, text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(Theme.mono)
                .focused($focused)
                .onAppear { draft = value }
                .onChange(of: value) { _, newValue in if !focused { draft = newValue } }
                .onChange(of: focused) { _, isFocused in if !isFocused { submit() } }
                .onSubmit(submit)
                .onExitCommand {
                    draft = value
                    focused = false
                }
                .accessibilityIdentifier("field-\(errorKey)")
            ErrorLine(editor: editor, key: errorKey)
        }
    }

    private func submit() {
        guard draft != value else { return }
        let text = draft
        Task { await commit(text) }
    }
}

struct TableSection: View {
    let title: String
    let head: [String]
    let rows: [[String]]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.system(size: 9)).foregroundStyle(Theme.muted)
            if rows.isEmpty {
                Text("vuota").font(Theme.mono).foregroundStyle(Theme.muted)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                    GridRow { ForEach(head, id: \.self) { Text($0).foregroundStyle(Theme.muted) } }
                    ForEach(rows.indices, id: \.self) { i in
                        GridRow { ForEach(rows[i].indices, id: \.self) { j in Text(rows[i][j]) } }
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
            }
        }
    }
}
