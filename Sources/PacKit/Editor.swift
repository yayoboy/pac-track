import Foundation
import Observation
import PacEngine

public enum Selection: Equatable, Sendable {
    case node(String)
    case link(String)
    /// Two or more devices, in the order they were picked.
    case nodes([String])
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
    /// Newest log entries pulled from the engine (at most `eventLimit`), oldest first.
    public private(set) var events: [EventView] = []
    /// PDUs being drawn on cables.
    public private(set) var flights: [Flight] = []
    public private(set) var selectedEvent: Int?
    /// Headers of `selectedEvent`; nil while loading or once the engine forgot it.
    public private(set) var pdu: [PduLayer]?
    /// Tab last picked in the node inspector; kept while moving between devices that have it.
    public var inspectorTab: InspectorTab?
    /// Bottom panel tab; "Mostra metriche" on a cable switches it to Metriche.
    public var bottomTab = BottomTab.events
    /// Canvas tool and the cable it draws (palette); per window, not saved.
    public var tool = Tool.move
    public var cable = CableKind.ethernet
    /// Grid shown and snapped to (spec §7.2 "Griglia on/off").
    public var grid = true
    private var dismissedWarning = 0
    @ObservationIgnored private var eventCursor = 0
    @ObservationIgnored private var eventEpoch = 0
    private var past: [Topology] = []
    private var future: [Topology] = []
    @ObservationIgnored private var pendingMove: Topology?
    /// Last queued action: user actions run one at a time, in order (a second Cmd+Z waits for the first).
    @ObservationIgnored private var tail: Task<Void, Never>?
    private let client: any EngineClient
    /// Called with the new topology after every network change (document autosave hooks in here).
    @ObservationIgnored public var onChange: ((Topology) -> Void)?

    private static let historyLimit = 100
    private static let eventLimit = 5000
    /// More than a node's height (46 pt), on the 14 pt grid: a copy never covers its original.
    private static let copyOffset = 56.0
    /// Process-wide device clipboard.
    // ponytail: in-memory, not NSPasteboard; enough to copy between windows of this app
    private static var clipboard: [TopologyNode] = []

    public init(client: any EngineClient) {
        self.client = client
    }

    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }
    public var current: Topology { makeTopology(snapshot, positions) }
    /// Newest L2 loop warning not dismissed yet.
    public var warning: WarningView? { snapshot.warnings.last.flatMap { $0.id > dismissedWarning ? $0 : nil } }

    /// Accepts only snapshots newer than the one shown, so a late clock tick never rolls back an edit.
    func accept(_ s: Snapshot) {
        if s.version > snapshot.version { snapshot = s }
    }

    /// Pulls only log entries newer than those shown and starts their animations.
    func syncEvents() async {
        let s = snapshot
        if s.epoch != eventEpoch {
            eventEpoch = s.epoch
            eventCursor = 0
            events = []
            flights = []
            selectedEvent = nil
            pdu = nil
            dismissedWarning = 0
        }
        guard s.eventCount > eventCursor else { return }
        let batch = await client.events(from: eventCursor, epoch: s.epoch)
        let fresh = batch.filter { $0.id >= eventCursor }
        guard eventEpoch == s.epoch, let last = fresh.last else { return }
        eventCursor = last.id + 1
        events = Array((events + fresh).suffix(Self.eventLimit))
        flights = updateFlights(flights, with: fresh, links: snapshot.links, now: Date.timeIntervalSinceReferenceDate)
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
            await syncEvents()
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
            await syncEvents()
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

    /// Devices in the selection, in the order they were picked; empty for a cable or nothing.
    public var selectedNodes: [String] {
        switch selection {
        case .node(let id): [id]
        case .nodes(let ids): ids
        case .link, nil: []
        }
    }

    /// Several devices at once (rectangle, Seleziona tutto): none clears, one is an ordinary selection.
    public func select(nodes ids: [String]) {
        selection = ids.count > 1 ? .nodes(ids) : ids.first.map { .node($0) }
    }

    /// Shift-click: adds the device to the selected ones or takes it out.
    public func toggle(_ id: String) {
        let ids = selectedNodes
        select(nodes: ids.contains(id) ? ids.filter { $0 != id } : ids + [id])
    }

    /// Shift-drag rectangle: adds its devices to the selected ones (macOS convention).
    public func extendSelection(with ids: [String]) {
        let selected = selectedNodes
        select(nodes: selected + ids.filter { !selected.contains($0) })
    }

    public func selectAll() {
        select(nodes: snapshot.nodes.map(\.id))
    }

    public func setPosition(_ id: String, _ pos: Pos) {
        positions[id] = pos
    }

    /// Where a device dropped or dragged at `p` lands: on the grid while it is shown.
    public func aligned(_ p: Pos) -> Pos {
        grid ? snap(p) : p
    }

    public func addDevice(_ kind: DeviceKind, at pos: Pos) async {
        await serialized { await self.addDeviceNow(kind, at: pos) }
    }

    private func addDeviceNow(_ kind: DeviceKind, at pos: Pos) async {
        let id = newId()
        positions[id] = pos
        var cmds: [Command] = [.addNode(id: id, kind: kind, name: defaultName(kind, existing: snapshot.nodes))]
        // A Cloud/ISP arrives ready (spec §5.5): the provider end of a customer link (RFC 5737) and a public name to resolve.
        if kind == .cloud {
            cmds += [.setIp(node: id, iface: "Gi0/0", cidr: "203.0.113.1/24"),
                     .setDnsServer(node: id, records: [DnsRecord(name: "www.example.com", ip: "198.51.100.10")])]
        }
        if await editNow(cmds) {
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
        let id = newId()
        let options = cable.options
        // Ethernet is the engine's default cable; another kind sets its link in the same undo step.
        let cmds: [Command] = [.connect(id: id, a: IfaceRef(node: aId, iface: ia), b: IfaceRef(node: bId, iface: ib))]
            + (options == LinkOptions() ? [] : [.updateLink(id: id, options: options)])
        // Personalizzato: the new cable opens in the inspector for its values.
        if await editNow(cmds, key: "connect"), cable == .custom { selection = .link(id) }
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
        case .nodes(let ids): await remove(nodes: ids, links: [])
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
            await syncEvents()
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
        await syncEvents()
        let kept = pruneFlights(flights, links: snapshot.links, now: Date.timeIntervalSinceReferenceDate)
        if kept.count != flights.count { flights = kept }
    }

    /// Simulation mode: runs to the next logged event and opens its PDU (the "current PDU").
    public func step() async {
        await serialized {
            let before = self.eventCursor
            guard await self.runNow(.step, key: nil), self.eventCursor > before, let last = self.events.last else { return }
            await self.selectEventNow(last.id)
        }
    }

    public func selectEvent(_ id: Int?) async {
        await serialized { await self.selectEventNow(id) }
    }

    private func selectEventNow(_ id: Int?) async {
        selectedEvent = id
        pdu = nil
        guard let id else { return }
        let layers = await client.pdu(id, epoch: eventEpoch)
        if selectedEvent == id { pdu = layers }
    }

    public func dismissWarning() {
        dismissedWarning = snapshot.warnings.last?.id ?? dismissedWarning
    }

    public func copy(_ ids: [String]) {
        Self.clipboard = current.nodes.filter { ids.contains($0.id) }
    }

    /// Pastes the copied devices with the first one at `pos` (the group keeps its shape), or `copyOffset` below-right of the last copy.
    public func paste(at pos: Pos?) async {
        await serialized {
            guard let first = Self.clipboard.first else { return }
            let dx = pos.map { $0.x - first.pos.x } ?? Self.copyOffset
            let dy = pos.map { $0.y - first.pos.y } ?? Self.copyOffset
            let moved = Self.clipboard.map { n -> TopologyNode in
                var c = n
                c.pos = Pos(x: n.pos.x + dx, y: n.pos.y + dy)
                return c
            }
            if pos == nil { Self.clipboard = moved }
            await self.insertCopies(of: moved)
        }
    }

    public func duplicate(_ ids: [String]) async {
        await serialized {
            let srcs = self.current.nodes.filter { ids.contains($0.id) }.map { n -> TopologyNode in
                var c = n
                c.pos = Pos(x: n.pos.x + Self.copyOffset, y: n.pos.y + Self.copyOffset)
                return c
            }
            await self.insertCopies(of: srcs)
        }
    }

    /// Adds devices of the same kind, power state, interface modes, name server, switch size, port VLANs and subinterfaces as `srcs` (no addresses, routes or cables: a copied IP
    /// would silently conflict on the same segment, and static routes need an address), with distinct default names, in one undo step,
    /// and selects them.
    private func insertCopies(of srcs: [TopologyNode]) async {
        guard !srcs.isEmpty else { return }
        var taken = Set(snapshot.nodes.map(\.name))
        var ids: [String] = []
        var cmds: [Command] = []
        for src in srcs {
            let id = newId()
            let name = defaultName(src.kind, taken: taken)
            taken.insert(name)
            ids.append(id)
            positions[id] = src.pos
            cmds.append(.addNode(id: id, kind: src.kind, name: name))
            if src.kind == .switch { cmds.append(.setPorts(id: id, count: src.ifaces.count)) }
            // Port VLANs and subinterfaces are structure, like the size; their addresses stay behind.
            for i in src.ifaces {
                if let c = i.switchport { cmds.append(.setSwitchport(node: id, iface: i.name, config: c)) }
                if i.name.contains(".") { cmds.append(.addSubinterface(node: id, iface: i.name)) }
            }
            // Modes and the name server are not addresses: a copied DHCP PC asks for its own lease.
            for i in src.ifaces where i.mode == .dhcp { cmds.append(.setIfaceMode(node: id, iface: i.name, mode: .dhcp)) }
            if let server = src.nameServer { cmds.append(.setNameServer(node: id, ip: server)) }
            if !src.powered { cmds.append(.setPower(id: id, on: false)) }
        }
        if await editNow(cmds, key: "paste") { select(nodes: ids) }
    }

    /// Applies one link property typed in the inspector; parse and range errors show on that field.
    public func setLink(_ id: String, _ field: LinkField, _ text: String) async {
        await serialized {
            let key = "link:\(id):\(field.rawValue)"
            guard let link = self.snapshot.links.first(where: { $0.id == id }) else { return }
            let options: LinkOptions
            do {
                options = try field.apply(text, to: link.options)
            } catch {
                self.fail(key, error)
                return
            }
            await self.editNow([.updateLink(id: id, options: options)], key: key)
        }
    }

    /// Turns the DHCP server on with a pool suggested from the device's first address (router: itself as gateway;
    /// with a DNS server running: itself as DNS), or off.
    public func enableDhcp(_ id: String, _ on: Bool) async {
        await serialized {
            let key = "dhcp:\(id):enabled"
            guard on else {
                await self.editNow([.setDhcpServer(node: id, config: nil)], key: key)
                return
            }
            guard let node = self.snapshot.nodes.first(where: { $0.id == id }), let cidr = node.ifaces.lazy.compactMap(\.cidr).first,
                  var config = suggestedDhcpConfig(cidr: cidr) else {
                self.error = EditorError(key: key, message: "Assign an IPv4 address to an interface first")
                return
            }
            let own = String(cidr.split(separator: "/")[0])
            config.gateway = node.kind == .router || node.kind == .cloud ? own : gatewayOf(node)
            config.dns = node.dnsRecords != nil ? own : node.nameServer
            await self.editNow([.setDhcpServer(node: id, config: config)], key: key)
        }
    }

    /// Applies one DHCP setting typed in the Servizi tab; errors show under that field.
    public func setDhcp(_ id: String, _ field: DhcpField, _ text: String) async {
        await serialized {
            let key = "dhcp:\(id):\(field.rawValue)"
            guard let config = self.snapshot.nodes.first(where: { $0.id == id })?.dhcpServer else { return }
            let next: DhcpConfig
            do {
                next = try field.apply(text, to: config)
            } catch {
                self.fail(key, error)
                return
            }
            await self.editNow([.setDhcpServer(node: id, config: next)], key: key)
        }
    }

    public func enableDns(_ id: String, _ on: Bool) async {
        await edit(.setDnsServer(node: id, records: on ? [] : nil), key: "dnsrec:\(id)")
    }

    /// Adds an A record (empty TTL: 3600 s). Returns false, with the error under the record form, if refused.
    @discardableResult
    public func addDnsRecord(_ id: String, name: String, ip: String, ttl: String) async -> Bool {
        await serialized {
            let key = "dnsrec:\(id)"
            guard let records = self.snapshot.nodes.first(where: { $0.id == id })?.dnsRecords else { return false }
            let t = ttl.trimmingCharacters(in: .whitespaces)
            guard let seconds = t.isEmpty ? DnsRecord.defaultTtl : Int(t) else {
                self.error = EditorError(key: key, message: "Invalid number: \"\(ttl)\"")
                return false
            }
            return await self.editNow([.setDnsServer(node: id, records: records + [DnsRecord(name: name, ip: ip, ttl: seconds)])], key: key)
        }
    }

    public func removeDnsRecord(_ id: String, at index: Int) async {
        await serialized {
            guard var records = self.snapshot.nodes.first(where: { $0.id == id })?.dnsRecords, records.indices.contains(index) else { return }
            records.remove(at: index)
            await self.editNow([.setDnsServer(node: id, records: records)], key: "dnsrec:\(id)")
        }
    }

    /// Gives a router interface a NAT role; a new outside replaces the old one and no roles left turn NAT off. Errors show under NAT.
    public func setNatRole(_ id: String, iface: String, _ role: NatRole) async {
        await serialized {
            guard let node = self.snapshot.nodes.first(where: { $0.id == id }) else { return }
            var c = node.nat ?? NatConfig()
            c.inside.removeAll { $0 == iface }
            if c.outside == iface { c.outside = nil }
            switch role {
            case .off: break
            case .inside:
                let kept = c.inside
                c.inside = node.ifaces.map(\.name).filter { kept.contains($0) || $0 == iface }
            case .outside: c.outside = iface
            }
            await self.editNow([.setNat(node: id, config: c.inside.isEmpty && c.outside == nil ? nil : c)], key: "nat:\(id)")
        }
    }

    /// Appends a rule typed in the Servizi tab (blank addresses: any; blank port: any port). Returns false, with the error under
    /// the rule form, if refused.
    @discardableResult
    public func addFirewallRule(_ id: String, _ rule: FirewallRule, port: String) async -> Bool {
        await serialized {
            let key = "fw:\(id)"
            guard var config = self.snapshot.nodes.first(where: { $0.id == id })?.firewall else { return false }
            let anyIfBlank = { (s: String) in s.trimmingCharacters(in: .whitespaces).isEmpty ? "any" : s.trimmingCharacters(in: .whitespaces) }
            var r = rule
            r.src = anyIfBlank(r.src)
            r.dst = anyIfBlank(r.dst)
            let p = port.trimmingCharacters(in: .whitespaces)
            if !p.isEmpty {
                guard let n = Int(p) else {
                    self.error = EditorError(key: key, message: "Invalid number: \"\(port)\"")
                    return false
                }
                r.port = n
            }
            config.rules.append(r)
            return await self.editNow([.setFirewall(node: id, config: config)], key: key)
        }
    }

    public func removeFirewallRule(_ id: String, at index: Int) async {
        await serialized {
            guard var config = self.snapshot.nodes.first(where: { $0.id == id })?.firewall, config.rules.indices.contains(index) else { return }
            config.rules.remove(at: index)
            await self.editNow([.setFirewall(node: id, config: config)], key: "fw:\(id)")
        }
    }

    /// The App tab's ping (spec §5.6): count, interval in seconds, payload bytes, TTL (blank: the device's default). Errors show under the App tab.
    public func ping(_ id: String, target: String, count: String, interval: String, size: String, ttl: String) async {
        await serialized {
            let key = "app:\(id)"
            let text = { (s: String) in s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".") }
            guard let c = Int(text(count)) else { return self.fail(key, EngineError("Invalid number: \"\(count)\"")) }
            guard let i = Double(text(interval)), i.isFinite, abs(i) < 1e6 else { return self.fail(key, EngineError("Invalid number: \"\(interval)\"")) }
            guard let s = Int(text(size)) else { return self.fail(key, EngineError("Invalid number: \"\(size)\"")) }
            let t = text(ttl)
            guard t.isEmpty || Int(t) != nil else { return self.fail(key, EngineError("Invalid number: \"\(ttl)\"")) }
            let options = PingOptions(count: c, intervalNs: Int((i * 1e9).rounded()), size: s, ttl: Int(t))
            _ = await self.runNow(.ping(node: id, target: target, options: options), key: key)
        }
    }

    /// Starts the App tab's generator: TCP sends `amount` bytes; UDP sends `amount` Mb/s for `seconds`. Errors show under the App tab.
    public func startTraffic(_ id: String, target: String, kind: TrafficKind, amount: String, seconds: String) async {
        await serialized {
            let key = "app:\(id)"
            let number = amount.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            let cmd: Command
            switch kind {
            case .tcp:
                guard let bytes = Int(number) else { return self.fail(key, EngineError("Invalid number: \"\(amount)\"")) }
                cmd = .trafficTcp(node: id, target: target, bytes: bytes)
            case .udp:
                guard let mbps = Double(number), mbps.isFinite else { return self.fail(key, EngineError("Invalid number: \"\(amount)\"")) }
                guard let s = Int(seconds.trimmingCharacters(in: .whitespaces)) else {
                    return self.fail(key, EngineError("Invalid number: \"\(seconds)\""))
                }
                cmd = .trafficUdp(node: id, target: target, bitsPerSecond: mbps * 1e6, seconds: s)
            }
            _ = await self.runNow(cmd, key: key)
        }
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
