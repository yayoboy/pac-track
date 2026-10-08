import Foundation

/// glibc resolver defaults (resolv.conf `timeout:5 attempts:2`).
let DNS_TIMEOUT_NS = 5 * S
let DNS_ATTEMPTS = 2

/// Lowercase host name without the trailing dot, or nil if malformed (RFC 1123 labels; a dotted quad is an address, not a name).
func normalizeHostName(_ s: String) -> String? {
    var n = s.trimmingCharacters(in: .whitespaces).lowercased()
    if n.hasSuffix(".") { n.removeLast() }
    guard !n.isEmpty, n.count <= 253, (try? parseIp(n)) == nil else { return nil }
    let labels = n.split(separator: ".", omittingEmptySubsequences: false)
    let valid = labels.allSatisfy { label in
        (1...63).contains(label.count) && label.first != "-" && label.last != "-"
            && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
    return valid ? n : nil
}

/// The address when `s` is written as one (so "10.0.0.300" fails as an address, never as a name); nil for a host name.
func literalIp(_ s: String) throws -> UInt32? {
    s.allSatisfy { $0.isNumber || $0 == "." } ? try parseIp(s) : nil
}

struct DnsEntry: Equatable {
    let name: String
    let addr: UInt32
    let ttl: Int
}

func parseDnsRecord(_ r: DnsRecord) throws -> DnsEntry {
    guard let name = normalizeHostName(r.name) else { throw EngineError("Invalid host name: \"\(r.name)\"") }
    let addr = try parseIp(r.ip.trimmingCharacters(in: .whitespaces))
    guard (0...2_147_483_647).contains(r.ttl) else { throw EngineError("TTL must be between 0 and 2147483647 s") }
    return DnsEntry(name: name, addr: addr, ttl: r.ttl)
}

/// Authoritative-only server for A records on UDP 53 (no recursion): NXDOMAIN for unknown names.
final class DnsServer {
    unowned let node: IpNode
    var records: [DnsEntry]
    private var unbind: () -> Void = {}

    init(node: IpNode, records: [DnsEntry]) throws {
        self.node = node
        self.records = records
        unbind = try node.bindUdp(PORT_DNS) { [weak self] p, u, _ in
            if case .dns(let m) = u.payload { self?.answer(m, to: p.src, from: p.dst, port: u.srcPort) }
        }
    }

    func stop() {
        unbind()
    }

    /// Answers from the address it was asked (a resolver drops replies from any other), like BIND.
    private func answer(_ q: DnsMessage, to client: UInt32, from server: UInt32, port: UInt16) {
        guard !q.response else { return }
        let hits = records.filter { $0.name == q.name.lowercased() }
        let reply = DnsMessage(id: q.id, response: true, authoritative: true, recursionDesired: q.recursionDesired,
                               rcode: hits.isEmpty ? DNS_NXDOMAIN : 0, name: q.name,
                               answers: hits.map { DnsAnswer(ttl: UInt32($0.ttl), addr: $0.addr) })
        node.sendPacket(client, .udp(makeUdp(srcPort: PORT_DNS, dstPort: port, payload: .dns(reply))), src: server)
    }
}

extension IpNode {
    /// Turns the DNS server on with these A records (replacing the previous ones) or off with nil.
    func configureDnsServer(_ records: [DnsRecord]?) throws {
        guard let records else {
            dnsServer?.stop()
            dnsServer = nil
            return
        }
        var entries: [DnsEntry] = []
        for r in records {
            let e = try parseDnsRecord(r)
            guard !entries.contains(where: { $0.name == e.name && $0.addr == e.addr }) else {
                throw EngineError("Record \(e.name) A \(formatIp(e.addr)) already exists")
            }
            entries.append(e)
        }
        if let server = dnsServer {
            server.records = entries
        } else {
            dnsServer = try DnsServer(node: self, records: entries)
        }
    }
}

enum Resolution: Equatable {
    case found([UInt32])
    case nxdomain
    /// Timeout, no route or no name server.
    case failed
}

struct DnsCacheEntry: Equatable {
    let name: String
    let addrs: [UInt32]
    let expiresAt: Int
}

private final class DnsQuery {
    let name: String
    let server: UInt32
    let id: UInt16
    let port: UInt16
    let useCache: Bool
    let done: (Resolution) -> Void
    var tries = 0
    var finished = false
    var unbind: () -> Void = {}

    init(name: String, server: UInt32, id: UInt16, port: UInt16, useCache: Bool, done: @escaping (Resolution) -> Void) {
        self.name = name
        self.server = server
        self.id = id
        self.port = port
        self.useCache = useCache
        self.done = done
    }
}

/// Stub resolver, glibc-like: one name server, 5 s timeout, 2 attempts, positive answers cached for their TTL.
/// Callers pass callbacks that capture them `weak` (the query outlives nothing but its own timer).
// ponytail: no negative caching (RFC 2308 needs an SOA) and concurrent lookups of one name are not merged
final class Resolver {
    unowned let node: IpNode
    private var cache: [DnsCacheEntry] = []
    private var queries: [DnsQuery] = []

    init(node: IpNode) {
        self.node = node
    }

    func entries() -> [DnsCacheEntry] {
        cache.filter { $0.expiresAt > node.sim.now }
    }

    /// Power cycle: forgets the cache and abandons pending queries without calling back.
    func reset() {
        for q in queries {
            q.finished = true
            q.unbind()
        }
        queries = []
        cache = []
    }

    /// Cache first, then the configured name server. `done` runs exactly once, possibly right away.
    func resolve(_ name: String, _ done: @escaping (Resolution) -> Void) {
        cache.removeAll { $0.expiresAt <= node.sim.now }
        if let hit = cache.first(where: { $0.name == name }) { return done(.found(hit.addrs)) }
        guard let server = node.effectiveNameServer else { return done(.failed) }
        lookup(name, server: server, useCache: true, done)
    }

    /// Asks `server` directly (what nslookup does); with `useCache` a positive answer is cached for its smallest TTL.
    func lookup(_ name: String, server: UInt32, useCache: Bool, _ done: @escaping (Resolution) -> Void) {
        // A random ephemeral port (Linux range 32768–60999) and id per query, like glibc.
        for _ in 0..<16 {
            let q = DnsQuery(name: name, server: server, id: UInt16(node.sim.rng.int(0x10000)),
                             port: UInt16(32768 + node.sim.rng.int(28232)), useCache: useCache, done: done)
            guard let unbind = try? node.bindUdp(q.port, { [weak self, weak q] p, u, _ in
                if let self, let q, case .dns(let m) = u.payload, p.src == q.server, u.srcPort == PORT_DNS { self.answer(q, m) }
            }) else { continue }
            q.unbind = unbind
            queries.append(q)
            return ask(q)
        }
        done(.failed)
    }

    private func ask(_ q: DnsQuery) {
        q.tries += 1
        let attempt = q.tries
        guard node.sendUdp(q.server, srcPort: q.port, dstPort: PORT_DNS, payload: .dns(DnsMessage(id: q.id, response: false, name: q.name))) else {
            return finish(q, .failed)
        }
        node.sim.sched.after(DNS_TIMEOUT_NS) { [self] in
            guard !q.finished, q.tries == attempt else { return }
            if q.tries < DNS_ATTEMPTS { ask(q) } else { finish(q, .failed) }
        }
    }

    private func answer(_ q: DnsQuery, _ m: DnsMessage) {
        guard !q.finished, m.response, m.id == q.id, m.name == q.name else { return }
        let addrs = m.answers.map(\.addr)
        guard m.rcode == 0, !addrs.isEmpty else { return finish(q, .nxdomain) }
        if q.useCache, let ttl = m.answers.map(\.ttl).min(), ttl > 0 {
            cache.removeAll { $0.name == q.name }
            cache.append(DnsCacheEntry(name: q.name, addrs: addrs, expiresAt: node.sim.now + Int(ttl) * S))
        }
        finish(q, .found(addrs))
    }

    private func finish(_ q: DnsQuery, _ r: Resolution) {
        q.finished = true
        q.unbind()
        queries.removeAll { $0 === q }
        q.done(r)
    }
}
