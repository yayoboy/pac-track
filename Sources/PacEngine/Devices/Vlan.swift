/// VLAN IDs a port or a subinterface may use: 0 and 4095 are reserved (802.1Q).
let VLAN_IDS = 1...4094

func checkVlan(_ vlan: Int) throws {
    guard VLAN_IDS.contains(vlan) else { throw EngineError("VLAN must be between 1 and 4094") }
}

/// IOS `switchport trunk allowed vlan` syntax: "all" or "10,20,30-35" (spaces allowed around commas and dashes, not inside a number:
/// "10 20" is refused, not read as 1020).
func parseVlanList(_ text: String) throws -> [ClosedRange<Int>] {
    if text.lowercased().split(whereSeparator: \.isWhitespace) == ["all"] { return [VLAN_IDS] }
    return try text.split(separator: ",", omittingEmptySubsequences: false).map { item in
        let ends = item.split(separator: "-", omittingEmptySubsequences: false).map { end in
            // One word of digits only: no inner space, no sign.
            let words = end.split(whereSeparator: \.isWhitespace)
            return words.count == 1 && words[0].allSatisfy({ ("0"..."9").contains($0) }) ? Int(words[0]) : nil
        }
        guard (1...2).contains(ends.count), let lo = ends[0], let hi = ends[ends.count - 1], lo <= hi else {
            throw EngineError("Invalid VLAN list: \"\(text)\"")
        }
        try checkVlan(lo)
        try checkVlan(hi)
        return lo...hi
    }
}

/// A switch port's 802.1Q role (spec M7 §2): an access port carries one VLAN, untagged; a trunk carries its allowed VLANs,
/// tagged, except the native one, untagged.
struct Switchport {
    private(set) var config = PortConfig()
    /// The VLANs a trunk carries, parsed from `config.allowed`.
    private var allowed = [VLAN_IDS]

    init() {}

    /// Checks every field, whatever the mode (the fields keep their values when the mode flips, as on IOS).
    init(_ c: PortConfig) throws {
        try checkVlan(c.vlan)
        try checkVlan(c.native)
        let allowed = try parseVlanList(c.allowed)
        guard allowed.contains(where: { $0.contains(c.native) }) else { throw EngineError("Native VLAN \(c.native) is not allowed on the trunk") }
        config = c
        self.allowed = allowed
    }

    func carries(_ vlan: Int) -> Bool {
        config.mode == .access ? vlan == config.vlan : allowed.contains { $0.contains(vlan) }
    }

    /// The VLAN of a frame arriving with `tag`; nil when the port refuses it: tagged on an access port, or a VLAN the trunk does not carry.
    func ingress(_ tag: Int?) -> Int? {
        guard let tag else { return config.mode == .access ? config.vlan : config.native }
        return config.mode == .trunk && carries(tag) ? tag : nil
    }

    /// The tag a frame of `vlan` leaves with: none on an access port and for the trunk's native VLAN.
    func tag(_ vlan: Int) -> Int? {
        config.mode == .trunk && vlan != config.native ? vlan : nil
    }
}
