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
    let addr: IpAddr
    let ttl: Int
}

/// An A record, or an AAAA when the address is IPv6 (spec M9 §10).
func parseDnsRecord(_ r: DnsRecord) throws -> DnsEntry {
    guard let name = normalizeHostName(r.name) else { throw EngineError("Invalid host name: \"\(r.name)\"") }
    let text = r.ip.trimmingCharacters(in: .whitespaces)
    let addr: IpAddr = text.contains(":") ? .v6(try parseIp6(text)) : .v4(try parseIp(text))
    guard (0...2_147_483_647).contains(r.ttl) else { throw EngineError("TTL must be between 0 and 2147483647 s") }
    return DnsEntry(name: name, addr: addr, ttl: r.ttl)
}

/// The record type an address answers.
private func recordType(_ a: IpAddr) -> UInt16 {
    if case .v6 = a { DNS_TYPE_AAAA } else { DNS_TYPE_A }
}

/// The address as answer data.
private func rdata(_ a: IpAddr) -> UInt128 {
    switch a {
    case .v4(let v): UInt128(v)
    case .v6(let v): v
    }
}

/// Authoritative-only server for A and AAAA records on UDP 53 of both stacks (no recursion): NXDOMAIN for unknown names, no answers
/// (NODATA, RFC 2308 §2.2) for a known name without records of the type asked (spec M9 §10).
final class DnsServer {
    unowned let node: IpNode
    var records: [DnsEntry]
    private var unbind: () -> Void = {}

    init(node: IpNode, records: [DnsEntry]) throws {
        self.node = node
        self.records = records
        unbind = try node.bindDualUdp(PORT_DNS) { [weak self] client, server, u in
            if case .dns(let m) = u.payload { self?.answer(m, to: client, from: server, port: u.srcPort) }
        }
    }

    func stop() {
        unbind()
    }

    /// Answers from the address it was asked (a resolver drops replies from any other), like BIND.
    private func answer(_ q: DnsMessage, to client: IpAddr, from server: IpAddr, port: UInt16) {
        guard !q.response else { return }
        let named = records.filter { $0.name == q.name.lowercased() }
        let hits = named.filter { recordType($0.addr) == q.type }
        let reply = DnsMessage(id: q.id, response: true, authoritative: true, recursionDesired: q.recursionDesired,
                               rcode: named.isEmpty ? DNS_NXDOMAIN : 0, name: q.name,
                               answers: hits.map { DnsAnswer(ttl: UInt32($0.ttl), addr: rdata($0.addr)) }, type: q.type)
        node.sendUdp(client, srcPort: PORT_DNS, dstPort: port, payload: .dns(reply), src: server)
    }
}

extension IpNode {
    /// Turns the DNS server on with these A and AAAA records (replacing the previous ones) or off with nil.
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
                throw EngineError("Record \(e.name) \(dnsTypeName(recordType(e.addr))) \(e.addr.text) already exists")
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
    case found([IpAddr])
    case nxdomain
    /// Timeout, no route or no name server.
    case failed
}

struct DnsCacheEntry: Equatable {
    let name: String
    let type: UInt16
    let addrs: [IpAddr]
    let expiresAt: Int
}

private final class DnsQuery {
    let name: String
    let server: IpAddr
    let type: UInt16
    let id: UInt16
    let port: UInt16
    let useCache: Bool
    let done: (Resolution) -> Void
    var tries = 0
    var finished = false
    var unbind: () -> Void = {}

    init(name: String, server: IpAddr, type: UInt16, id: UInt16, port: UInt16, useCache: Bool, done: @escaping (Resolution) -> Void) {
        self.name = name
        self.server = server
        self.type = type
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

    /// getaddrinfo with AI_ADDRCONFIG (spec M9 §10): the A, and the AAAA too when the device has a usable global IPv6 address, both
    /// asked at once like glibc; IPv6 addresses come first (RFC 6724 §6). Each type comes from the cache or the configured name
    /// server. `done` runs exactly once, possibly right away.
    func resolve(_ name: String, _ done: @escaping (Resolution) -> Void) {
        cache.removeAll { $0.expiresAt <= node.sim.now }
        let types = node.v6.hasGlobal ? [DNS_TYPE_A, DNS_TYPE_AAAA] : [DNS_TYPE_A]
        var answers: [UInt16: Resolution] = [:]
        for type in types {
            let collect = { (r: Resolution) in
                answers[type] = r
                if answers.count == types.count { done(merged(types.reversed().compactMap { answers[$0] })) }
            }
            if let hit = cache.first(where: { $0.name == name && $0.type == type }) {
                collect(.found(hit.addrs))
            } else if let server = node.effectiveNameServer {
                lookup(name, server: server, type: type, useCache: true, collect)
            } else {
                collect(.failed)
            }
        }
    }

    /// Asks `server` directly for one record type (what nslookup does); with `useCache` a positive answer is cached for its smallest
    /// TTL. A name without records of the type answers `.found([])` (NODATA).
    func lookup(_ name: String, server: IpAddr, type: UInt16 = DNS_TYPE_A, useCache: Bool, _ done: @escaping (Resolution) -> Void) {
        // A random ephemeral port (Linux range 32768–60999) and id per query, like glibc.
        for _ in 0..<16 {
            let q = DnsQuery(name: name, server: server, type: type, id: UInt16(node.sim.rng.int(0x10000)),
                             port: UInt16(32768 + node.sim.rng.int(28232)), useCache: useCache, done: done)
            guard let unbind = try? node.bindDualUdp(q.port, { [weak self, weak q] src, _, u in
                if let self, let q, case .dns(let m) = u.payload, src == q.server, u.srcPort == PORT_DNS { self.answer(q, m) }
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
        guard node.sendUdp(q.server, srcPort: q.port, dstPort: PORT_DNS, payload: .dns(DnsMessage(id: q.id, response: false, name: q.name, type: q.type))) else {
            return finish(q, .failed)
        }
        node.sim.sched.after(DNS_TIMEOUT_NS) { [self] in
            guard !q.finished, q.tries == attempt else { return }
            if q.tries < DNS_ATTEMPTS { ask(q) } else { finish(q, .failed) }
        }
    }

    private func answer(_ q: DnsQuery, _ m: DnsMessage) {
        guard !q.finished, m.response, m.id == q.id, m.name == q.name, m.type == q.type else { return }
        guard m.rcode == 0 else { return finish(q, .nxdomain) }
        let addrs = m.answers.map(m.address)
        if q.useCache, !addrs.isEmpty, let ttl = m.answers.map(\.ttl).min(), ttl > 0 {
            cache.removeAll { $0.name == q.name && $0.type == q.type }
            cache.append(DnsCacheEntry(name: q.name, type: q.type, addrs: addrs, expiresAt: node.sim.now + Int(ttl) * S))
        }
        finish(q, .found(addrs)) // empty: NODATA
    }

    private func finish(_ q: DnsQuery, _ r: Resolution) {
        q.finished = true
        q.unbind()
        queries.removeAll { $0 === q }
        q.done(r)
    }
}

/// getaddrinfo's answer from one answer per type: every address, else "not found" unless a query failed.
private func merged(_ results: [Resolution]) -> Resolution {
    let addrs = results.flatMap { r -> [IpAddr] in if case .found(let a) = r { a } else { [] } }
    if !addrs.isEmpty { return .found(addrs) }
    return results.contains(.failed) ? .failed : .nxdomain
}
