/// MAC address, lowercase colon-separated: "02:00:00:00:00:0b".
typealias Mac = String

let BROADCAST_MAC: Mac = "ff:ff:ff:ff:ff:ff"
let BROADCAST_IP: UInt32 = 0xFFFF_FFFF

struct Cidr: Equatable, Sendable {
    var addr: UInt32
    var prefix: Int
}

/// Plain decimal without sign, spaces or leading zeros, at most `max`.
private func decimal(_ s: Substring, max: Int) -> Int? {
    guard !s.isEmpty, s.count <= 3, s.allSatisfy({ $0.isASCII && $0.isNumber }), s == "0" || s.first != "0",
          let value = Int(s), value <= max else { return nil }
    return value
}

func parseIp(_ s: String) throws -> UInt32 {
    let parts = s.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { throw EngineError("Invalid IPv4 address: \"\(s)\"") }
    var n: UInt32 = 0
    for part in parts {
        guard let octet = decimal(part, max: 255) else { throw EngineError("Invalid IPv4 address: \"\(s)\"") }
        n = n << 8 | UInt32(octet)
    }
    return n
}

func formatIp(_ n: UInt32) -> String {
    "\(n >> 24).\((n >> 16) & 255).\((n >> 8) & 255).\(n & 255)"
}

func parseCidr(_ s: String) throws -> Cidr {
    let parts = s.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, let prefix = decimal(parts[1], max: 32) else { throw EngineError("Invalid CIDR: \"\(s)\"") }
    return Cidr(addr: try parseIp(String(parts[0])), prefix: prefix)
}

func prefixMask(_ prefix: Int) -> UInt32 {
    prefix == 0 ? 0 : UInt32.max << (32 - prefix)
}

func networkOf(_ addr: UInt32, _ prefix: Int) -> UInt32 {
    addr & prefixMask(prefix)
}

func broadcastOf(_ addr: UInt32, _ prefix: Int) -> UInt32 {
    networkOf(addr, prefix) | ~prefixMask(prefix)
}

func inSubnet(_ addr: UInt32, _ network: UInt32, _ prefix: Int) -> Bool {
    networkOf(addr, prefix) == networkOf(network, prefix)
}

private func hex2(_ b: Int) -> String {
    let h = String(b, radix: 16)
    return h.count == 1 ? "0" + h : h
}

func macFromIndex(_ i: Int) -> Mac {
    [0x02, 0x00, (i >> 24) & 255, (i >> 16) & 255, (i >> 8) & 255, i & 255].map(hex2).joined(separator: ":")
}

/// True for broadcast and multicast MACs (I/G bit set).
func isGroupMac(_ mac: Mac) -> Bool {
    (Int(mac.prefix(2), radix: 16) ?? 0) & 1 == 1
}
