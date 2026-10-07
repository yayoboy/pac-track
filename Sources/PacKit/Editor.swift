import Observation
import PacEngine

public enum Selection: Equatable, Sendable {
    case node(String)
    case link(String)
}

public struct EditorError: Equatable, Sendable {
    /// Which control shows the error (e.g. "ip:<node>:<iface>", "connect", "file").
    public let key: String
    public let message: String
}

/// All user actions on one document. Holds presentation state only; the network lives in the `EngineClient`.
@MainActor
@Observable
public final class Editor {
    public private(set) var snapshot = Snapshot.empty
    public var positions: [String: Pos] = [:]
    public private(set) var selection: Selection?
    public private(set) var error: EditorError?
    private var past: [Topology] = []
    private var future: [Topology] = []
    @ObservationIgnored private var pendingMove: Topology?
    /// Last queued action: user actions run one at a time, in order (a second Cmd+Z waits for the first).
    @ObservationIgnored private var tail: Task<Void, Never>?
    private let client: any EngineClient
    /// Called with the new topology after every network change (document autosave hooks in here).
    @ObservationIgnored public var onChange: ((Topology) -> Void)?

    private static let historyLimit = 100

    public init(client: any EngineClient) {
        self.client = client
    }

    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }
    public var current: Topology { makeTopology(snapshot, positions) }

    /// Accepts only snapshots newer than the one shown, so a late clock tick never rolls back an edit.
    func accept(_ s: Snapshot) {
        if s.version > snapshot.version { snapshot = s }
    }

    private func fail(_ key: String, _ error: any Error) {
        self.error = EditorError(key: key, message: (error as? EngineError)?.message ?? "\(error)")
    }

    private func remember(_ before: Topology) {
        past = Array((past + [before]).suffix(Self.historyLimit))
        future = []
        onChange?(current)
    }

    private func serialized<T: Sendable>(_ action: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return await action()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    /// Opens a document: replaces the network and clears history. Never counts as an edit. Returns false (and shows why) on failure.
    @discardableResult
    public func load(_ t: Topology) async -> Bool {
        await serialized { await self.loadNow(t) }
    }

    private func loadNow(_ t: Topology) async -> Bool {
        do {
            accept(try await client.send(.load(t)))
            positions = PacKit.positions(of: t)
            past = []
            future = []
            selection = nil
            error = nil
            return true
        } catch {
            fail("file", error)
            return false
        }
    }

    /// Sends a command that does not change the topology (apps, clock).
    @discardableResult
    public func run(_ cmd: Command, key: String? = nil) async -> Bool {
        await serialized { await self.runNow(cmd, key: key) }
    }

    private func runNow(_ cmd: Command, key: String?) async -> Bool {
        do {
            accept(try await client.send(cmd))
            error = nil
            return true
        } catch {
            fail(key ?? cmd.key, error)
            return false
        }
    }

    /// Sends topology changes as a single undo step.
    @discardableResult
    public func edit(_ cmds: [Command], key: String? = nil) async -> Bool {
        await serialized { await self.editNow(cmds, key: key) }
    }

    @discardableResult
    private func editNow(_ cmds: [Command], key: String? = nil) async -> Bool {
        let before = current
        for (i, cmd) in cmds.enumerated() {
            guard await runNow(cmd, key: key) else {
                if i > 0 { remember(before) }
                return false
            }
        }
        remember(before)
        return true
    }

    @discardableResult
    public func edit(_ cmd: Command, key: String? = nil) async -> Bool {
        await edit([cmd], key: key)
    }

    public func dismissError() {
        error = nil
    }

    public func select(_ s: Selection?) {
        selection = s
    }

    public func setPosition(_ id: String, _ pos: Pos) {
        positions[id] = pos
    }

    public func addDevice(_ kind: DeviceKind, at pos: Pos) async {
        await serialized { await self.addDeviceNow(kind, at: pos) }
    }

    private func addDeviceNow(_ kind: DeviceKind, at pos: Pos) async {
        let id = newId()
        positions[id] = pos
        if await editNow([.addNode(id: id, kind: kind, name: defaultName(kind, existing: snapshot.nodes))]) {
            selection = .node(id)
        }
    }

    public func connect(_ aId: String, _ bId: String) async {
        await serialized { await self.connectNow(aId, bId) }
    }

    private func connectNow(_ aId: String, _ bId: String) async {
        guard aId != bId, let a = snapshot.nodes.first(where: { $0.id == aId }), let b = snapshot.nodes.first(where: { $0.id == bId }) else { return }
        guard let ia = firstFreeIface(a), let ib = firstFreeIface(b) else {
            error = EditorError(key: "connect", message: "\(firstFreeIface(a) == nil ? a.name : b.name) has no free port")
            return
        }
        await editNow([.connect(id: newId(), a: IfaceRef(node: aId, iface: ia), b: IfaceRef(node: bId, iface: ib))], key: "connect")
    }

    /// Deletes nodes and cables in one undo step (cables of deleted nodes go with them).
    public func remove(nodes nodeIds: [String], links linkIds: [String]) async {
        await serialized { await self.removeNow(nodes: nodeIds, links: linkIds) }
    }

    private func removeNow(nodes nodeIds: [String], links linkIds: [String]) async {
        let gone = Set(nodeIds)
        let cables = linkIds.filter { id in snapshot.links.contains { $0.id == id && !gone.contains($0.a.node) && !gone.contains($0.b.node) } }
        let cmds = cables.map { Command.disconnect(id: $0) } + nodeIds.map { Command.removeNode(id: $0) }
        if !cmds.isEmpty { await editNow(cmds) }
        selection = nil
    }

    public func deleteSelection() async {
        switch selection {
        case .node(let id): await remove(nodes: [id], links: [])
        case .link(let id): await remove(nodes: [], links: [id])
        case nil: break
        }
    }

    public func moveStart() {
        pendingMove = current
    }

    public func moveEnd() {
        if let before = pendingMove, before != current { remember(before) }
        pendingMove = nil
    }

    /// Returns false (history untouched, error shown) if the engine refuses the state.
    private func restore(_ t: Topology) async -> Bool {
        if !sameNetwork(t, current) {
            do {
                accept(try await client.send(.load(t)))
            } catch {
                fail("history", error)
                return false
            }
        }
        positions = PacKit.positions(of: t)
        selection = nil
        error = nil
        return true
    }

    public func undo() async {
        await serialized {
            guard let previous = self.past.last else { return }
            let now = self.current
            guard await self.restore(previous) else { return }
            self.past.removeLast()
            self.future.insert(now, at: 0)
            self.onChange?(self.current)
        }
    }

    public func redo() async {
        await serialized {
            guard let next = self.future.first else { return }
            let now = self.current
            guard await self.restore(next) else { return }
            self.future.removeFirst()
            self.past.append(now)
            self.onChange?(self.current)
        }
    }

    public func tick(wallMs: Double) async {
        accept(await client.advance(wallMs: wallMs))
    }

    /// Advances the simulation every 50 ms until the calling task is cancelled.
    public func runClock() async {
        let clock = ContinuousClock()
        var last = clock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
            let now = clock.now
            await tick(wallMs: (now - last) / .milliseconds(1))
            last = now
        }
    }
}
