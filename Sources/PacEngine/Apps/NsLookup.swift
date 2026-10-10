struct NsLookupResult: Sendable {
    var lines: [String] = []
    var done = false
}

/// BIND-style `nslookup name`: asks the configured server directly (no cache) for the A, then the AAAA when the device has IPv6 on
/// (spec M9 §10), and prints the answers.
// ponytail: no PTR (reverse) lookups
final class NsLookup {
    private(set) var result = NsLookupResult()
    private let node: IpNode
    private let host: String
    private let server: IpAddr
    private var types: [UInt16]
    private var found = false

    init(node: IpNode, name: String) throws {
        guard let host = normalizeHostName(name) else { throw EngineError("Invalid host name: \"\(name)\"") }
        guard let server = node.effectiveNameServer else { throw EngineError("\(node.name) has no DNS server configured") }
        self.node = node
        self.host = host
        self.server = server
        types = node.interfaces.contains { $0.v6 != nil } ? [DNS_TYPE_A, DNS_TYPE_AAAA] : [DNS_TYPE_A]
        result.lines = ["Server:\t\t\(server.text)", "Address:\t\(server.text)#53", ""]
        ask()
    }

    func stop() {
        result.done = true
    }

    private func ask() {
        node.resolver.lookup(host, server: server, type: types.removeFirst(), useCache: false) { [weak self] r in self?.answered(r) }
    }

    private func answered(_ r: Resolution) {
        guard !result.done else { return }
        switch r {
        case .found(let addrs):
            for a in addrs { result.lines += ["Name:\t\(host)", "Address: \(a.text)"] }
            found = found || !addrs.isEmpty
            if !types.isEmpty { return ask() }
            if !found { result.lines.append("*** Can't find \(host): No answer") }
        case .nxdomain:
            result.lines.append("** server can't find \(host): NXDOMAIN")
        case .failed:
            result.lines.append(";; connection timed out; no servers could be reached")
        }
        result.lines.append("")
        result.done = true
    }
}
