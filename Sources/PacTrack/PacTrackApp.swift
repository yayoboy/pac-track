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
    /// Built once, on appear: a `@State` initial value would allocate a throwaway Editor + Simulation on every view init.
    @State private var editor: Editor?

    var body: some View {
        if let editor {
            DocumentWindow(document: $document, editor: editor)
        } else {
            Theme.bg
                .frame(minWidth: 1000, minHeight: 640)
                .onAppear { editor = Editor(client: Simulation()) }
        }
    }
}

private struct DocumentWindow: View {
    @Binding var document: PacDocument
    let editor: Editor

    var body: some View {
        MainContent(editor: editor)
            .frame(minWidth: 1000, minHeight: 640)
            .toolbar { SimulationToolbar(editor: editor) }
            .focusedSceneValue(\.editor, editor)
            .preferredColorScheme(.dark)
            .task {
                // Only a successfully loaded document may be overwritten by later edits.
                if await editor.load(document.topology) {
                    editor.onChange = { document.topology = $0 }
                }
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
            let s = editor.snapshot
            Picker("Modalità", selection: Binding(get: { s.mode }, set: { m in Task { await editor.run(.setMode(m)) } })) {
                Text("Realtime").tag(SimMode.realtime)
                Text("Simulation").tag(SimMode.simulation)
            }
            .pickerStyle(.segmented)
            .help("Realtime: il tempo scorre. Simulation: orologio fermo, avanzi evento per evento.")
            Button { Task { await editor.run(.setRunning(!s.running)) } } label: {
                Label(s.running ? "Pausa" : "Avvia", systemImage: s.running ? "pause.fill" : "play.fill")
            }
            .help(s.mode == .simulation ? "Avanza da solo, un evento alla volta" : "Avvia o ferma il tempo (Spazio)")
            Button { Task { await editor.step() } } label: { Label("Passo", systemImage: "forward.frame.fill") }
                .disabled(s.mode != .simulation)
                .help("Esegue il prossimo evento (tasto .)")
            Picker("Velocità", selection: Binding(get: { s.speed }, set: { v in Task { await editor.run(.setSpeed(v)) } })) {
                ForEach(SPEEDS, id: \.self) { Text("\($0.formatted())×").tag($0) }
            }
            .frame(width: 90)
            Text(s.mode == .simulation ? "t = " + formatSimTime(s.timeNs) : String(format: "t = %.3f s", Double(s.timeNs) / 1e9))
                .font(Theme.mono)
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
                .frame(width: 150, alignment: .trailing)
            if s.mode == .realtime && s.running && s.effectiveSpeed < s.speed * 0.9 {
                Text(String(format: "effettiva %.1f×", s.effectiveSpeed))
                    .font(Theme.mono)
                    .foregroundStyle(Theme.warn)
                    .help("Troppi eventi per tick: la simulazione non tiene la velocità scelta.")
            }
        }
    }
}

/// Undo/redo for the network; inside a text field the same shortcut edits the text instead.
struct EditCommands: Commands {
    @FocusedValue(\.editor) private var editor

    private var typing: Bool { NSApp.keyWindow?.firstResponder is NSText }

    private func send(_ action: String) {
        NSApp.sendAction(Selector((action)), to: nil, from: nil)
    }

    private var selectedNode: String? {
        if case .node(let id)? = editor?.selection { id } else { nil }
    }

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
        // Text fields keep the standard editing actions; elsewhere the shortcuts act on devices.
        CommandGroup(replacing: .pasteboard) {
            Button("Taglia") { if typing { send("cut:") } }
                .keyboardShortcut("x")
            Button("Copia") {
                if typing { send("copy:") } else if let id = selectedNode { editor?.copy([id]) }
            }
            .keyboardShortcut("c")
            Button("Incolla") {
                if typing { send("paste:") } else { Task { await editor?.paste(at: nil) } }
            }
            .keyboardShortcut("v")
            Button("Duplica") {
                if let id = selectedNode { Task { await editor?.duplicate([id]) } }
            }
            .keyboardShortcut("d")
            Button("Seleziona tutto") { if typing { send("selectAll:") } }
                .keyboardShortcut("a")
        }
    }
}
