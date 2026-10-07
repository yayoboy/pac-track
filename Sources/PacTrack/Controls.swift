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
                // Return ends editing: the focus-loss handler commits once, and Cmd+Z then reaches the network undo.
                .onSubmit { focused = false }
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

/// Errors with no field of their own (opening a file, cabling, apps launched from a menu, undo) show here.
struct ErrorBanner: View {
    let editor: Editor
    private static let fieldPrefixes = ["ip:", "gw:", "route:", "name:", "link:", "mode:", "dns:", "dhcp:", "dnsrec:"]

    var body: some View {
        if let error = editor.error, !Self.fieldPrefixes.contains(where: error.key.hasPrefix) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.err)
                Text(error.message).foregroundStyle(Theme.fgStrong)
                Button { editor.dismissError() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Chiudi")
            }
            .font(.system(size: 11))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.err.opacity(0.6)))
            .padding(10)
            .accessibilityIdentifier("error-banner")
        }
    }
}

/// Non-blocking L2 loop warning (spec §5.4, §9); stays until dismissed or a new loop is detected.
struct WarningBanner: View {
    let editor: Editor

    var body: some View {
        if let w = editor.warning {
            let name = editor.snapshot.nodes.first { $0.id == w.node }?.name ?? w.node
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Theme.warn)
                Text("Possibile loop L2 su \(name): lo stesso frame è tornato più volte (t = \(formatSimTime(w.timeNs))). Controlla i collegamenti ridondanti tra switch.")
                    .foregroundStyle(Theme.fgStrong)
                Button { editor.dismissWarning() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Chiudi")
            }
            .font(.system(size: 11))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.warn.opacity(0.7)))
            .padding(10)
            .accessibilityIdentifier("warning-banner")
        }
    }
}
