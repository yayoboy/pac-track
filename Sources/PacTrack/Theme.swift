import PacEngine
import SwiftUI

enum Theme {
    static let bg = Color(hex: 0x1E1F22)
    static let panel = Color(hex: 0x2B2D30)
    static let border = Color(hex: 0x393B40)
    static let borderStrong = Color(hex: 0x43454A)
    static let fg = Color(hex: 0xBCBEC4)
    static let fgStrong = Color(hex: 0xDFE1E5)
    static let muted = Color(hex: 0x6F737A)
    static let accent = Color(hex: 0x3574F0)
    static let ok = Color(hex: 0x5FB865)
    static let err = Color(hex: 0xE5507A)
    static let mono = Font.system(size: 11, design: .monospaced)
    static let small = Font.system(size: 10)
    static let warn = Color(hex: 0xF0A732)

    /// Spec §7.3 protocol colors.
    static func proto(_ p: Proto) -> Color {
        switch p {
        case .arp: Color(hex: 0xF0A732)
        case .icmp: Color(hex: 0xE5507A)
        case .udp: Color(hex: 0x2FBFC4)
        case .dhcp: Color(hex: 0x56A8F5)
        case .dns: Color(hex: 0xB083F0)
        case .tcp: Color(hex: 0x5FB865)
        case .stp: Color(hex: 0xD6C95E)
        case .rip: Color(hex: 0xCC7F52)
        case .ospf: Color(hex: 0xD47FD6)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension DeviceKind {
    var symbol: String {
        switch self {
        case .pc: "desktopcomputer"
        case .laptop: "laptopcomputer"
        case .server: "server.rack"
        case .router: "wifi.router"
        case .switch: "rectangle.connected.to.line.below"
        case .hub: "circle.hexagongrid"
        case .cloud: "cloud"
        }
    }
}
