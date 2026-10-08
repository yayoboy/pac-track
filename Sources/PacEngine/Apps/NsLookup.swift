struct NsLookupResult: Sendable {
    var lines: [String] = []
    var done = false
}

/// BIND-style `nslookup name`: asks the configured server directly (no cache) and prints its answer.
// ponytail: A records only; no PTR (reverse) lookups
final class NsLookup {
    private(set) var result = NsLookupResult()

    init(node: IpNode, name: String) throws {
        guard let host = normalizeHostName(name) else { throw EngineError("Invalid host name: \"\(name)\"") }
        guard let server = node.effectiveNameServer else { throw EngineError("\(node.name) has no DNS server configured") }
        result.lines = ["Server:\t\t\(formatIp(server))", "Address:\t\(formatIp(server))#53", ""]
        node.resolver.lookup(host, server: server, useCache: false) { [weak self] r in self?.answered(host, r) }
    }

    func stop() {
        result.done = true
    }

    private func answered(_ host: String, _ r: Resolution) {
        guard !result.done else { return }
        switch r {
        case .found(let addrs):
            for a in addrs { result.lines += ["Name:\t\(host)", "Address: \(formatIp(a))"] }
        case .nxdomain:
            result.lines.append("** server can't find \(host): NXDOMAIN")
        case .failed:
            result.lines.append(";; connection timed out; no servers could be reached")
        }
        result.lines.append("")
        result.done = true
    }
}
