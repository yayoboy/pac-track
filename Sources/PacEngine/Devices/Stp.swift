/// 802.1D-1998 path cost of a cable, Cisco's default: the band at or below the cable's bandwidth (spec M7 §4).
func stpCost(_ bandwidthBps: Double) -> Int {
    bandwidthBps >= 10e9 ? 2 : bandwidthBps >= 1e9 ? 4 : bandwidthBps >= 100e6 ? 19 : 100
}

/// IOS default bridge priority; the VLAN is added to it as extended system ID.
let STP_PRIORITY = 32768

/// A port's 802.1D parameters in one VLAN: its state and the best configuration heard, or sent, on its segment.
private struct StpPort {
    var state = StpState.blocking
    var designatedRoot: BridgeId
    var designatedCost: Int
    var designatedBridge: BridgeId
    var designatedPort: Int
    /// Message age of the configuration stored here and when it arrived: what this switch relays is one second older.
    var messageAge = 0
    var receivedAt = 0
    /// Message age timer: the stored configuration expires at max age.
    var ageDue: Int?
    /// Forward delay timer: listening → learning → forwarding.
    var fdDue: Int?
    /// A TCN arrived here: the next configuration BPDU sent on this port acknowledges it.
    var tca = false
}

/// One PVST+ instance: the 802.1D spanning tree of one VLAN on one switch (spec M7 §4), following the procedures of
/// 802.1D-1998 §8. Timers are deadlines: an expiry does nothing if its deadline was moved or cleared since.
// ponytail: no hold timer (at most one BPDU per second per port); BPDUs only leave on hello, relay, reply and TCA
final class Stp {
    unowned let sw: Switch
    let vlan: Int
    private(set) var bridge: BridgeId
    private(set) var root: BridgeId
    private(set) var rootCost = 0
    private(set) var rootPort: Interface?
    /// TC flag: set by the root for max age + forward delay after a change, followed by the others from its BPDUs.
    /// Meanwhile the VLAN's MAC entries age out after forward delay.
    private(set) var topologyChange = false
    private var tcDetected = false
    private var tcUntil: Int?
    private var tcnDue: Int?
    private var helloDue: Int?
    /// Up ports carrying the VLAN; a port missing here is disabled.
    private var ports: [ObjectIdentifier: StpPort] = [:]

    /// 802.1D initialisation: the switch believes it is the root until told otherwise, its `members` start in blocking and
    /// its first BPDUs leave at once.
    init(sw: Switch, vlan: Int, members: [Interface]) {
        self.sw = sw
        self.vlan = vlan
        bridge = BridgeId(priority: sw.stpPriority[vlan] ?? STP_PRIORITY, vlan: vlan, mac: sw.interfaces[0].mac)
        root = bridge
        for p in members { enable(p) }
        configBpduGeneration()
        helloDue = arm(now + STP_HELLO_NS)
    }

    var isRoot: Bool { root == bridge }
    var isEmpty: Bool { ports.isEmpty }

    func state(_ p: Interface) -> StpState? {
        ports[ObjectIdentifier(p)]?.state
    }

    /// Each port as `show spanning-tree vlan <n>` lists it, in the switch's order.
    var rows: [(port: String, role: StpRole, state: StpState)] {
        members.map { p in (p.name, p === rootPort ? StpRole.root : designated(p) ? .designated : .blocked, self[p].state) }
    }

    /// Ports that left (down, or no longer carrying the VLAN) are disabled; new ones are enabled.
    func sync(_ up: [Interface]) {
        for p in members where !up.contains(where: { $0 === p }) { disable(p) }
        for p in up where ports[ObjectIdentifier(p)] == nil { enable(p) }
    }

    /// 802.1D received_config_bpdu and received_tcn_bpdu.
    func receive(_ b: Bpdu, on p: Interface) {
        guard ports[ObjectIdentifier(p)] != nil else { return }
        guard case .config(let c) = b else {
            if designated(p) {
                topologyChangeDetection()
                self[p].tca = true
                transmitConfig(p)
            }
            return
        }
        let wasRoot = isRoot
        guard supersedes(p, c) else {
            if designated(p) { transmitConfig(p) } // reply with the better information
            return
        }
        record(p, c)
        configurationUpdate()
        portStateSelection()
        if wasRoot && !isRoot {
            helloDue = nil
            if tcDetected {
                tcUntil = nil
                transmitTcn()
                tcnDue = arm(now + STP_HELLO_NS)
            }
        }
        if p === rootPort {
            topologyChange = c.tc
            configBpduGeneration()
            if c.tca {
                tcDetected = false
                tcnDue = nil
            }
        }
    }

    /// 802.1D set_bridge_priority: a better bridge ID can take the root at once.
    func setPriority(_ priority: Int) {
        let wasRoot = isRoot
        let old = bridge
        bridge.priority = priority
        for p in members where self[p].designatedBridge == old && self[p].designatedPort == portId(p) { self[p].designatedBridge = bridge }
        configurationUpdate()
        portStateSelection()
        if isRoot && !wasRoot { becameRoot() }
    }

    /// PortFast turned on for `p`: listening or learning, it forwards now.
    func portfastOn(_ p: Interface) {
        guard portfast(p), let state = state(p), state == .listening || state == .learning else { return }
        setState(p, .forwarding)
        self[p].fdDue = nil
    }

    // MARK: 802.1D procedures

    private var now: Int { sw.sim.now }
    private var members: [Interface] { sw.interfaces.filter { ports[ObjectIdentifier($0)] != nil } }

    private subscript(_ p: Interface) -> StpPort {
        get { ports[ObjectIdentifier(p)]! }
        set { ports[ObjectIdentifier(p)] = newValue }
    }

    /// Priority 128 and the port number (Gi0/n → n): 0x8001 is 128.1.
    private func portId(_ p: Interface) -> Int {
        0x8000 + sw.interfaces.firstIndex { $0 === p }! + 1
    }

    private func cost(_ p: Interface) -> Int {
        stpCost(p.link?.opts.bandwidthBps ?? 0)
    }

    private func designated(_ p: Interface) -> Bool {
        self[p].designatedBridge == bridge && self[p].designatedPort == portId(p)
    }

    private func portfast(_ p: Interface) -> Bool {
        p.switchport.config.portfast && p.switchport.config.mode == .access
    }

    private func arm(_ due: Int) -> Int {
        sw.sim.sched.at(due) { [weak self] in self?.expire(due) }
        return due
    }

    private func log(_ p: Interface, _ from: String, _ to: String) {
        sw.sim.emit(.state, node: sw.id, iface: p.name, note: "VLAN \(vlan): \(from) → \(to)")
    }

    /// 802.1D enable_port: a port that comes up (or joins the VLAN) starts in blocking, designated until it hears better.
    private func enable(_ p: Interface) {
        self[p] = StpPort(designatedRoot: root, designatedCost: rootCost, designatedBridge: bridge, designatedPort: portId(p))
        log(p, "disabled", StpState.blocking.rawValue)
        portStateSelection()
    }

    /// 802.1D disable_port: recomputed at once, without waiting for max age (spec M7 §4).
    private func disable(_ p: Interface) {
        let wasRoot = isRoot
        let state = self[p].state
        log(p, state.rawValue, "disabled")
        if state == .forwarding || state == .learning { sw.flush(p, vlan) }
        ports[ObjectIdentifier(p)] = nil
        configurationUpdate()
        portStateSelection()
        if isRoot && !wasRoot {
            becameRoot()
        } else if state == .forwarding && !portfast(p) {
            topologyChangeDetection()
        }
    }

    private func supersedes(_ p: Interface, _ c: StpConfig) -> Bool {
        let s = self[p]
        if c.root != s.designatedRoot { return c.root < s.designatedRoot }
        if c.cost != s.designatedCost { return c.cost < s.designatedCost }
        if c.bridge != s.designatedBridge { return c.bridge < s.designatedBridge }
        return c.bridge != bridge || c.port <= s.designatedPort
    }

    private func record(_ p: Interface, _ c: StpConfig) {
        self[p].designatedRoot = c.root
        self[p].designatedCost = c.cost
        self[p].designatedBridge = c.bridge
        self[p].designatedPort = c.port
        self[p].messageAge = c.messageAge
        self[p].receivedAt = now
        self[p].ageDue = arm(now + STP_MAX_AGE_NS - c.messageAge * S)
    }

    private func configurationUpdate() {
        rootSelection()
        designatedPortSelection()
    }

    /// The port with the best path: lowest root, then cost, sender bridge, sender port, own port.
    private func rootSelection() {
        let key = { (p: Interface) in
            (self[p].designatedRoot, self[p].designatedCost + self.cost(p), self[p].designatedBridge, self[p].designatedPort, self.portId(p))
        }
        guard let best = members.filter({ !designated($0) && self[$0].designatedRoot < bridge }).min(by: { key($0) < key($1) }) else {
            root = bridge
            rootCost = 0
            rootPort = nil
            return
        }
        root = self[best].designatedRoot
        rootCost = self[best].designatedCost + cost(best)
        rootPort = best
    }

    private func designatedPortSelection() {
        for p in members {
            let s = self[p]
            if designated(p) || s.designatedRoot != root || rootCost < s.designatedCost
                || (rootCost == s.designatedCost && (bridge < s.designatedBridge || (bridge == s.designatedBridge && portId(p) <= s.designatedPort))) {
                becomeDesignated(p)
            }
        }
    }

    private func becomeDesignated(_ p: Interface) {
        self[p].designatedRoot = root
        self[p].designatedCost = rootCost
        self[p].designatedBridge = bridge
        self[p].designatedPort = portId(p)
    }

    private func portStateSelection() {
        for p in members {
            if p === rootPort {
                self[p].tca = false
                makeForwarding(p)
            } else if designated(p) {
                self[p].ageDue = nil
                makeForwarding(p)
            } else {
                self[p].tca = false
                makeBlocking(p)
            }
        }
    }

    private func makeForwarding(_ p: Interface) {
        guard self[p].state == .blocking else { return }
        if portfast(p) { return setState(p, .forwarding) }
        setState(p, .listening)
        self[p].fdDue = arm(now + STP_FORWARD_DELAY_NS)
    }

    private func makeBlocking(_ p: Interface) {
        let state = self[p].state
        guard state != .blocking else { return }
        setState(p, .blocking)
        self[p].fdDue = nil
        if state == .forwarding && !portfast(p) { topologyChangeDetection() }
    }

    /// A port that stops learning forgets the addresses it learned in this VLAN.
    private func setState(_ p: Interface, _ state: StpState) {
        let old = self[p].state
        log(p, old.rawValue, state.rawValue)
        if (old == .forwarding || old == .learning) && (state == .blocking || state == .listening) { sw.flush(p, vlan) }
        self[p].state = state
    }

    /// A timer fired: whatever still has `due` as its deadline expires.
    private func expire(_ due: Int) {
        guard sw.stp[vlan] === self else { return }
        if tcUntil == due {
            tcUntil = nil
            tcDetected = false
            topologyChange = false
        }
        if tcnDue == due {
            transmitTcn()
            tcnDue = arm(due + STP_HELLO_NS)
        }
        if helloDue == due {
            configBpduGeneration()
            helloDue = arm(due + STP_HELLO_NS)
        }
        for p in members {
            if self[p].ageDue == due { messageAgeExpiry(p) }
            if self[p].fdDue == due { forwardDelayExpiry(p) }
        }
    }

    private func forwardDelayExpiry(_ p: Interface) {
        if self[p].state == .listening {
            setState(p, .learning)
            self[p].fdDue = arm(now + STP_FORWARD_DELAY_NS)
        } else {
            setState(p, .forwarding)
            self[p].fdDue = nil
            topologyChangeDetection()
        }
    }

    /// The configuration held by a port aged out: it starts over as designated (spec M7 §4).
    private func messageAgeExpiry(_ p: Interface) {
        let wasRoot = isRoot
        self[p].ageDue = nil
        becomeDesignated(p)
        configurationUpdate()
        portStateSelection()
        if isRoot && !wasRoot { becameRoot() }
    }

    /// 802.1D, when the switch finds itself root: it announces the change, sends its BPDUs and starts its hello timer.
    private func becameRoot() {
        topologyChangeDetection()
        tcnDue = nil
        configBpduGeneration()
        helloDue = arm(now + STP_HELLO_NS)
    }

    private func topologyChangeDetection() {
        if isRoot {
            topologyChange = true
            tcUntil = arm(now + STP_TC_NS)
        } else if !tcDetected {
            transmitTcn()
            tcnDue = arm(now + STP_HELLO_NS)
        }
        tcDetected = true
    }

    private func transmitTcn() {
        if let rootPort { send(.tcn, on: rootPort) }
    }

    private func configBpduGeneration() {
        for p in members where designated(p) { transmitConfig(p) }
    }

    private func transmitConfig(_ p: Interface) {
        var age = 0
        if let rootPort { age = self[rootPort].messageAge + (now - self[rootPort].receivedAt) / S + 1 }
        guard age < STP_MAX_AGE_NS / S else { return }
        send(.config(StpConfig(root: root, cost: rootCost, bridge: bridge, port: portId(p), messageAge: age, tc: topologyChange, tca: self[p].tca)), on: p)
        self[p].tca = false
    }

    /// To the SSTP group address, tagged with the VLAN on a trunk unless it is the native one.
    private func send(_ b: Bpdu, on p: Interface) {
        p.send(EthernetFrame(id: sw.sim.nextId(), src: p.mac, dst: SSTP_MAC, etherType: UInt16(b.size), payload: .bpdu(b),
                             vlan: p.switchport.tag(vlan)))
    }
}
