import AppKit
import PacEngine
import PacKit
import SwiftUI

private struct EditorKey: FocusedValueKey {
    typealias Value = Editor
}

extension FocusedValues {
    var editor: Editor? {
        get { self[EditorKey.self] }
        set { self[EditorKey.self] = newValue }
    }
}

struct PacTrackApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: PacDocument()) { file in
            MainView(document: file.$document)
        }
        .commands { EditCommands() }
    }
}

struct MainView: View {
    @Binding var document: PacDocument
    @State private var editor = Editor(client: Simulation())

    var body: some View {
        MainContent(editor: editor)
            .frame(minWidth: 1000, minHeight: 640)
            .toolbar { SimulationToolbar(editor: editor) }
            .focusedSceneValue(\.editor, editor)
            .preferredColorScheme(.dark)
            .task {
                await editor.load(document.topology)
                editor.onChange = { document.topology = $0 }
            }
            .task { await editor.runClock() }
    }
}

struct SimulationToolbar: ToolbarContent {
    @Bindable var editor: Editor

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { Task { await editor.undo() } } label: { Label("Annulla", systemImage: "arrow.uturn.backward") }
                .disabled(!editor.canUndo)
            Button { Task { await editor.redo() } } label: { Label("Ripeti", systemImage: "arrow.uturn.forward") }
                .disabled(!editor.canRedo)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            let running = editor.snapshot.running
            Button { Task { await editor.run(.setRunning(!running)) } } label: {
                Label(running ? "Pausa" : "Avvia", systemImage: running ? "pause.fill" : "play.fill")
            }
            Picker("Velocità", selection: Binding(get: { editor.snapshot.speed }, set: { v in Task { await editor.run(.setSpeed(v)) } })) {
                ForEach(SPEEDS, id: \.self) { Text("\($0.formatted())×").tag($0) }
            }
            .frame(width: 90)
            Text(String(format: "t = %.3f s", Double(editor.snapshot.timeNs) / 1e9))
                .font(Theme.mono)
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
                .frame(width: 110, alignment: .trailing)
        }
    }
}

/// Undo/redo for the network; inside a text field the same shortcut edits the text instead.
struct EditCommands: Commands {
    @FocusedValue(\.editor) private var editor

    private var typing: Bool { NSApp.keyWindow?.firstResponder is NSText }

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Annulla") {
                if typing { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) } else { Task { await editor?.undo() } }
            }
            .keyboardShortcut("z")
            Button("Ripeti") {
                if typing { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) } else { Task { await editor?.redo() } }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }
    }
}
